// main.ts — opens an ET5 via WebUSB, subscribes to the 0x500 gaze
// stream, and projects the normalized gaze point onto the window.
//
// The ET5 reports gaze_point_2d_norm in [0..1] × [0..1] where (0,0) is
// the top-left of the display area configured via setDisplayArea.
// Without calibration to the user's actual monitor, the mapping here
// is approximate — we just stretch the normalized point across the
// browser viewport.

import { Tobii, UsbSource, type Source, type GazeSample, type DisplayArea, type RawGazeColumn } from 'tobiifree-sdk-ts';
import { createScene } from './scene';

const $ = <T extends HTMLElement>(id: string): T => {
  const el = document.getElementById(id);
  if (!el) throw new Error(`#${id} missing`);
  return el as T;
};

const transportSel = $<HTMLSelectElement>('transport');
const wsUrlInput = $<HTMLInputElement>('ws-url');
const connectBtn = $<HTMLButtonElement>('connect');
const gazeEl = $<HTMLDivElement>('gaze');

transportSel.addEventListener('change', () => {
  wsUrlInput.style.display = transportSel.value === 'ws' ? '' : 'none';
});
const statsEl = $<HTMLPreElement>('stats');
const errEl = $<HTMLDivElement>('err');
const hintEl = $<HTMLDivElement>('hint');
const daBox = $<HTMLDivElement>('da');
const daGrid = $<HTMLDivElement>('da-grid');
const rectGrid = $<HTMLDivElement>('rect-grid');
const daReload = $<HTMLButtonElement>('da-reload');
const daReset = $<HTMLButtonElement>('da-reset');
const daDiag = $<HTMLButtonElement>('da-diag');
const diagOut = $<HTMLPreElement>('diag-out');
const daCal = $<HTMLButtonElement>('da-cal');
const daCollect = $<HTMLButtonElement>('da-collect');
const daCollect2 = $<HTMLButtonElement>('da-collect2');
const daLoad = $<HTMLButtonElement>('da-load');
const daWinPerm = $<HTMLButtonElement>('da-winperm');
const daFs = $<HTMLButtonElement>('da-fs');
const daOnboardCal = $<HTMLButtonElement>('da-onboard-cal');
const daOnboardPts = $<HTMLSelectElement>('da-onboard-pts');
const calOverlay = $<HTMLDivElement>('cal-overlay');
const calTarget = $<HTMLDivElement>('cal-target');
const onboardCalDot = $<HTMLDivElement>('onboard-cal-dot');
const collectTarget = $<HTMLDivElement>('collect-target');
const calStatus = $<HTMLDivElement>('cal-status');
const daLock = $<HTMLInputElement>('da-lock');
const tiltSlider = $<HTMLInputElement>('da-tilt');
const tiltVal = $<HTMLDivElement>('da-tilt-val');
const stage3d = $<HTMLCanvasElement>('stage3d');

const scene3d = createScene(stage3d);

// Defined up here because pushViewportRect (called at module init
// below) reads it before the Window Management block runs.
type ScreenDetailed = {
  availLeft: number; availTop: number;
  availWidth: number; availHeight: number;
  width: number; height: number;
  isPrimary: boolean;
};
type ScreenDetails = {
  currentScreen: ScreenDetailed;
  screens: ScreenDetailed[];
};
let screenDetails: ScreenDetails | null = null;

function pushViewportRect() {
  const r = computeViewportRect();
  const cur = screenDetails?.currentScreen;
  // console.log('[viewport]', r,
  //   'sL,sT=', window.screenLeft, window.screenTop,
  //   'cur=', cur ? { availLeft: cur.availLeft, availTop: cur.availTop, w: cur.width, h: cur.height } : null,
  //   'outer=', window.outerWidth, 'x', window.outerHeight,
  //   'inner=', window.innerWidth, 'x', window.innerHeight,
  // );
  scene3d.setViewportRect(r);
}
pushViewportRect();
window.addEventListener('resize', pushViewportRect);

// Track the mouse in viewport-normalized coords and echo into the 3D
// scene. Hidden when the pointer leaves the window.
window.addEventListener('pointermove', (e) => {
  scene3d.setMouse({
    nx: e.clientX / window.innerWidth,
    ny: e.clientY / window.innerHeight,
  });
});
window.addEventListener('pointerout', (e) => {
  if (!e.relatedTarget) scene3d.setMouse(null);
});
// No 'move' event exists — poll position at 2Hz when window is focused.
setInterval(() => { if (document.hasFocus()) pushViewportRect(); }, 500);
// Try the Window Management API silently; if the permission was
// previously granted this resolves without a prompt.
void (async () => {
  const w = window as unknown as { permissions?: { query: (opts: { name: string }) => Promise<{ state: string }> } };
  try {
    const s = await w.permissions?.query({ name: 'window-management' });
    if (s?.state === 'granted') await requestScreenDetails();
  } catch { /* ignore */ }
})();

let tracker: Source | null = null;
let sampleCount = 0;
let lastStatsT = performance.now();
let lastSample: GazeSample | null = null;
// Latest value of each column keyed by colId — used to surface unknown
// columns in the stats readout for protocol RE.
const lastRawCols = new Map<number, RawGazeColumn>();

function setError(msg: string) { errEl.textContent = msg; }
function clearError() { errEl.textContent = ''; }

function render(sample: GazeSample) {
  lastSample = sample;
  sampleCount++;
  scene3d.setGaze(sample);

  const p = sample.gaze_point_2d_norm
    ?? sample.gaze_point_2d_L_norm
    ?? sample.gaze_point_2d_R_norm;

  const valid = (sample.validity_L === 0) || (sample.validity_R === 0);

  if (collectRunning || calRunning) {
    gazeEl.style.opacity = '0';
  } else if (p && valid) {
    const x = Math.max(0, Math.min(1, p.x)) * window.innerWidth;
    const y = Math.max(0, Math.min(1, p.y)) * window.innerHeight;
    gazeEl.style.transform = `translate(${x}px, ${y}px)`;
    gazeEl.style.opacity = '1';
  } else {
    gazeEl.style.opacity = '0.25';
  }
}

function pumpStats() {
  const now = performance.now();
  const dt = now - lastStatsT;
  if (dt >= 500) {
    const hz = (sampleCount * 1000 / dt).toFixed(1);
    const s = lastSample;
    const fmt = (v: number | undefined, d = 3) =>
      v === undefined ? '—' : v.toFixed(d);
    const p = s?.gaze_point_2d_norm;
    const col = (id: number) => {
      const c = lastRawCols.get(id);
      if (!c) return '—';
      const f = (v: number) => v.toFixed(3);
      if (c.kind === 'point3d') return `(${f(c.v0)}, ${f(c.v1)}, ${f(c.v2)})`;
      if (c.kind === 'point2d') return `(${f(c.v0)}, ${f(c.v1)})`;
      return `${f(c.v0)}`;
    };
    statsEl.textContent = [
      `rate     : ${hz} Hz`,
      `valid L/R: ${s?.validity_L ?? '—'} / ${s?.validity_R ?? '—'}`,
      `gaze 2d  : (${fmt(p?.x)}, ${fmt(p?.y)})`,
      `pupil L/R: ${fmt(s?.pupil_diameter_L_mm, 2)} / ${fmt(s?.pupil_diameter_R_mm, 2)} mm`,
      `frame #  : ${s?.frame_counter ?? '—'}`,
      `--- raw columns ---`,
      `0x03 dirL   : ${col(0x03)}`,
      `0x09 dirR   : ${col(0x09)}`,
      `0x25 dir25  : ${col(0x25)}`,
      `0x27 dir27  : ${col(0x27)}`,
      `0x04 gp3L   : ${col(0x04)}`,
      `0x0a gp3R   : ${col(0x0a)}`,
      `0x22 eoL_d  : ${col(0x22)}`,
      `0x24 eoR_d  : ${col(0x24)}`,
    ].join('\n');
    sampleCount = 0;
    lastStatsT = now;
  }
  requestAnimationFrame(pumpStats);
}

async function connect() {
  clearError();
  try {
    if (transportSel.value === 'ws') {
      await connectWithWs(wsUrlInput.value.trim() || 'ws://localhost:7081');
    } else {
      const device = await navigator.usb.requestDevice({
        filters: [{ vendorId: 0x2104, productId: 0x0313 }],
      });
      await connectWithDevice(device);
    }
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    setError(msg);
  }
}

async function connectWithDevice(device: USBDevice) {
  connectBtn.disabled = true;
  connectBtn.textContent = 'Connecting…';
  try {
    const src = await Tobii.fromUsb({ device });
    src.onParseError((code) => {
      console.warn('parse error', code.toString(16));
    });
    src.subscribeToRawGaze((cols) => {
      for (const c of cols) lastRawCols.set(c.colId, c);
    });
    await onConnected(src);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    setError(msg);
    connectBtn.textContent = 'Connect';
    connectBtn.disabled = false;
  }
}

async function connectWithWs(url: string) {
  connectBtn.disabled = true;
  connectBtn.textContent = 'Connecting…';
  try {
    const src = await Tobii.fromDaemon({ url });
    await onConnected(src);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    setError(msg);
    connectBtn.textContent = 'Connect';
    connectBtn.disabled = false;
  }
}

async function onConnected(src: Source) {
  tracker = src;
  hintEl.textContent = 'Streaming gaze. Look around.';
  connectBtn.textContent = 'Disconnect';
  connectBtn.disabled = false;
  connectBtn.onclick = disconnect;
  transportSel.disabled = true;

  tracker.subscribeToGaze(render);
  requestAnimationFrame(pumpStats);
  daBox.style.display = 'block';

  // Device is source of truth. If device was power-cycled (tiny area), restore
  // last-known-good from localStorage, falling back to the hardcoded default.
  try {
    const area = tracker.displayArea ?? await tracker.getDisplayArea();
    if (isResetArea(area)) {
      const fallback = loadLastGoodArea() ?? DEFAULT_AREA;
      console.log('[connect] device area reset, applying fallback', fallback);
      await tracker.setDisplayAreaCorners(fallback);
      setFormValues(fallback);
    } else {
      // Device has a valid area — use it and remember as last-known-good.
      saveLastGoodArea(area);
      setFormValues(area);
      console.log('[connect] display_area from device', area);
    }
  } catch (e) {
    console.warn('getDisplayArea failed', e);
  }
  // Re-apply stored onboard calibration blob if available.
  const calB64 = localStorage.getItem('tobii_onboard_cal');
  if (calB64 && tracker) {
    try {
      const bin = atob(calB64);
      const blob = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) blob[i] = bin.charCodeAt(i);
      await tracker.calApply(blob);
      console.log(`[connect] restored onboard calibration (${blob.byteLength}B)`);
    } catch (e) {
      console.warn('restore onboard calibration failed', e);
    }
  }
}

async function disconnect() {
  connectBtn.disabled = true;
  try { await tracker?.close(); } catch { }
  tracker = null;
  gazeEl.style.opacity = '0';
  statsEl.textContent = '';
  daBox.style.display = 'none';
  hintEl.textContent = 'Select transport and connect';
  connectBtn.textContent = 'Connect';
  connectBtn.disabled = false;
  connectBtn.onclick = connect;
  transportSel.disabled = false;
}

// ---------- Display area form (9 sliders, write on change) ----------

type CornerKey = 'tl' | 'tr' | 'bl';
type AxisKey = 'x' | 'y' | 'z';
const CORNERS: CornerKey[] = ['tl', 'tr', 'bl'];
const AXES: AxisKey[] = ['x', 'y', 'z'];
// Each axis: symmetric range in mm. Wide enough for calibrated values
// to survive slider clamping even when the plane ends up well away
// from the tracker.
const RANGE: Record<AxisKey, { min: number; max: number; step: number }> = {
  x: { min: -800, max: 800, step: 0.5 },
  y: { min: -800, max: 800, step: 0.5 },
  z: { min: -1000, max: 1000, step: 0.5 },
};

const sliders: Record<CornerKey, Record<AxisKey, HTMLInputElement>> = {
  tl: {} as Record<AxisKey, HTMLInputElement>,
  tr: {} as Record<AxisKey, HTMLInputElement>,
  bl: {} as Record<AxisKey, HTMLInputElement>,
};
const valLabels: Record<CornerKey, Record<AxisKey, HTMLDivElement>> = {
  tl: {} as Record<AxisKey, HTMLDivElement>,
  tr: {} as Record<AxisKey, HTMLDivElement>,
  bl: {} as Record<AxisKey, HTMLDivElement>,
};

// Default: 400mm × 300mm plane, BL at (-200, 0, 0), tracker-relative.
const DEFAULT_AREA: DisplayArea = {
  tl: { x: -200, y: 300, z: 0 },
  tr: { x: 200, y: 300, z: 0 },
  bl: { x: -200, y: 0, z: 0 },
};

const STORAGE_KEY_AREA = 'tobii_last_good_area';

function isResetArea(da: DisplayArea): boolean {
  const w = Math.abs(da.tr.x - da.tl.x);
  const h = Math.abs(da.tl.y - da.bl.y);
  return w < 50 || h < 50;
}

function saveLastGoodArea(area: DisplayArea): void {
  try { localStorage.setItem(STORAGE_KEY_AREA, JSON.stringify(area)); } catch {}
}

function loadLastGoodArea(): DisplayArea | null {
  try {
    const s = localStorage.getItem(STORAGE_KEY_AREA);
    return s ? JSON.parse(s) as DisplayArea : null;
  } catch { return null; }
}

// Plane-locked mode: the 9 corners are constrained to a rectangular,
// axis-aligned-in-xy rect that can tilt backward/forward around its
// bottom edge. That's 6 DOF — the canonical screen config plus tilt.
// Dependency graph (locked):
//   bl.x := tl.x              (left edge vertical)
//   tr.y := tl.y              (top edge horizontal)
//   tr.z := tl.z              (top edge at constant z)
//   tl.z := bl.z + tiltMm     (top z offset from bottom)
// Free corner sliders when locked: tl.x, tl.y, tr.x, bl.y, bl.z.
// The tilt slider is an extra control, active only when locked.
type SliderKey = `${CornerKey}.${AxisKey}`;
const DEPENDENTS: SliderKey[] = ['bl.x', 'tr.y', 'tr.z', 'tl.z'];
const isDependent = (c: CornerKey, a: AxisKey) =>
  DEPENDENTS.includes(`${c}.${a}` as SliderKey);

function applyLockConstraints() {
  const tilt = Number(tiltSlider.value);
  const blz = Number(sliders.bl.z.value);
  setSliderValue('bl', 'x', Number(sliders.tl.x.value));
  setSliderValue('tr', 'y', Number(sliders.tl.y.value));
  setSliderValue('tl', 'z', blz + tilt);
  setSliderValue('tr', 'z', blz + tilt);
}

function setSliderValue(c: CornerKey, a: AxisKey, v: number) {
  sliders[c][a].value = String(v);
  valLabels[c][a].textContent = v.toFixed(1);
}

function updateLockUi() {
  const locked = daLock.checked;
  for (const c of CORNERS) {
    for (const a of AXES) {
      const dep = isDependent(c, a);
      sliders[c][a].disabled = locked && dep;
      valLabels[c][a].classList.toggle('locked', locked && dep);
    }
  }
  // Tilt only meaningful when locked (otherwise corners are independent).
  tiltSlider.disabled = !locked;
  tiltVal.classList.toggle('locked', !locked);
}

function syncTiltFromCorners() {
  // Reverse-derive tilt from the current corner values: tilt = tl.z - bl.z.
  const tilt = Number(sliders.tl.z.value) - Number(sliders.bl.z.value);
  tiltSlider.value = String(tilt);
  tiltVal.textContent = tilt.toFixed(1);
}

let writeInFlight = false;
let writeDirty = false;

async function writeDisplayArea() {
  const area = readForm();
  scene3d.setDisplayArea(area);
  if (!tracker) return;
  if (writeInFlight) { writeDirty = true; return; }
  writeInFlight = true;
  try {
    await tracker.setDisplayAreaCorners(area);
    saveLastGoodArea(area);
  } catch (e) {
    setError(e instanceof Error ? e.message : String(e));
  } finally {
    writeInFlight = false;
    if (writeDirty) { writeDirty = false; void writeDisplayArea(); }
  }
}

function readForm(): DisplayArea {
  const read = (c: CornerKey) => ({
    x: Number(sliders[c].x.value),
    y: Number(sliders[c].y.value),
    z: Number(sliders[c].z.value),
  });
  return { tl: read('tl'), tr: read('tr'), bl: read('bl') };
}

function setFormValues(area: DisplayArea) {
  for (const c of CORNERS) {
    for (const a of AXES) {
      setSliderValue(c, a, area[c][a]);
    }
  }
  syncTiltFromCorners();
  if (daLock.checked) applyLockConstraints();
  syncRectFromCorners();
  scene3d.setDisplayArea(readForm());
}

function buildForm() {
  for (const c of CORNERS) {
    const header = document.createElement('div');
    header.className = 'group';
    header.style.gridColumn = '1 / -1';
    header.textContent = c.toUpperCase();
    daGrid.appendChild(header);
    for (const a of AXES) {
      const r = RANGE[a];
      const label = document.createElement('label');
      label.textContent = a;
      const input = document.createElement('input');
      input.type = 'range';
      input.min = String(r.min);
      input.max = String(r.max);
      input.step = String(r.step);
      input.value = String(DEFAULT_AREA[c][a]);
      const val = document.createElement('div');
      val.className = 'val';
      val.textContent = DEFAULT_AREA[c][a].toFixed(1);
      input.addEventListener('input', () => {
        val.textContent = Number(input.value).toFixed(1);
        if (daLock.checked) applyLockConstraints();
        else syncTiltFromCorners();
        syncRectFromCorners();
        void writeDisplayArea();
      });
      daGrid.appendChild(label);
      daGrid.appendChild(input);
      daGrid.appendChild(val);
      sliders[c][a] = input;
      valLabels[c][a] = val;
    }
  }
}

// ---------- Screen rect sliders (width/height/center) ----------
// Higher-level parametrisation of the locked rectangular plane. Tilt
// stays as a separate control. All rect sliders only make sense in
// locked mode: they describe the rigid rectangle that lock enforces.
//
// Forward (rect → corners, using current tilt):
//   half_w = width / 2
//   bl.x = cx - half_w    tr.x = cx + half_w    tl.x = bl.x
//   bl.y = cy             bl.z = cz
//   dy   = √(max(0, height² - tilt²))    // preserve diagonal length
//   tl.y = bl.y + dy      tl.z = bl.z + tilt
//   tr.y = tl.y           tr.z = tl.z
//
// Reverse (corners → rect):
//   width  = tr.x - tl.x
//   height = √((tl.y - bl.y)² + (tl.z - bl.z)²)
//   cx     = (tl.x + tr.x) / 2
//   cy     = bl.y         cz = bl.z

type RectKey = 'width' | 'height' | 'cx' | 'cy' | 'cz';
const RECT_DEFS: Array<{ key: RectKey; label: string; min: number; max: number; step: number }> = [
  { key: 'width', label: 'w', min: 50, max: 1200, step: 0.5 },
  { key: 'height', label: 'h', min: 50, max: 900, step: 0.5 },
  { key: 'cx', label: 'cx', min: -500, max: 500, step: 0.5 },
  { key: 'cy', label: 'cy', min: -200, max: 600, step: 0.5 },
  { key: 'cz', label: 'cz', min: -200, max: 200, step: 0.5 },
];
const rectSliders = {} as Record<RectKey, HTMLInputElement>;
const rectVals = {} as Record<RectKey, HTMLDivElement>;

function buildRectForm() {
  const header = document.createElement('div');
  header.className = 'group';
  header.style.gridColumn = '1 / -1';
  header.textContent = 'SCREEN RECT';
  rectGrid.appendChild(header);
  for (const d of RECT_DEFS) {
    const label = document.createElement('label');
    label.textContent = d.label;
    const input = document.createElement('input');
    input.type = 'range';
    input.min = String(d.min);
    input.max = String(d.max);
    input.step = String(d.step);
    const val = document.createElement('div');
    val.className = 'val';
    input.addEventListener('input', () => {
      val.textContent = Number(input.value).toFixed(1);
      applyRectToCorners();
      void writeDisplayArea();
    });
    rectGrid.appendChild(label);
    rectGrid.appendChild(input);
    rectGrid.appendChild(val);
    rectSliders[d.key] = input;
    rectVals[d.key] = val;
  }
}

function applyRectToCorners() {
  const w = Number(rectSliders.width.value);
  const h = Number(rectSliders.height.value);
  const cx = Number(rectSliders.cx.value);
  const cy = Number(rectSliders.cy.value);
  const cz = Number(rectSliders.cz.value);
  const tilt = Number(tiltSlider.value);
  // Clamp tilt so the panel can still be |tilt| tall in z.
  const tEff = Math.max(-h, Math.min(h, tilt));
  if (tEff !== tilt) {
    tiltSlider.value = String(tEff);
    tiltVal.textContent = tEff.toFixed(1);
  }
  const dy = Math.sqrt(Math.max(0, h * h - tEff * tEff));
  const halfW = w / 2;
  setSliderValue('bl', 'x', cx - halfW);
  setSliderValue('bl', 'y', cy);
  setSliderValue('bl', 'z', cz);
  setSliderValue('tl', 'x', cx - halfW);
  setSliderValue('tl', 'y', cy + dy);
  setSliderValue('tl', 'z', cz + tEff);
  setSliderValue('tr', 'x', cx + halfW);
  setSliderValue('tr', 'y', cy + dy);
  setSliderValue('tr', 'z', cz + tEff);
}

function syncRectFromCorners() {
  const tlx = Number(sliders.tl.x.value);
  const tly = Number(sliders.tl.y.value);
  const tlz = Number(sliders.tl.z.value);
  const trx = Number(sliders.tr.x.value);
  const blx = Number(sliders.bl.x.value);
  const bly = Number(sliders.bl.y.value);
  const blz = Number(sliders.bl.z.value);
  const width = trx - tlx;
  const height = Math.hypot(tly - bly, tlz - blz);
  const cx = (tlx + trx) / 2;
  // If not perfectly rectangular (unlock mode), cx still reflects the
  // top edge's midpoint — a reasonable readout. bl.x isn't averaged in
  // on purpose: we want rect→corners edits to round-trip exactly.
  void blx;
  const setRect = (k: RectKey, v: number) => {
    rectSliders[k].value = String(v);
    rectVals[k].textContent = v.toFixed(1);
  };
  setRect('width', width);
  setRect('height', height);
  setRect('cx', cx);
  setRect('cy', bly);
  setRect('cz', blz);
}

function updateRectLockUi() {
  const locked = daLock.checked;
  for (const d of RECT_DEFS) {
    rectSliders[d.key].disabled = !locked;
    rectVals[d.key].classList.toggle('locked', !locked);
  }
}

buildRectForm();
buildForm();
syncTiltFromCorners();
updateLockUi();
updateRectLockUi();
syncRectFromCorners();

tiltSlider.addEventListener('input', () => {
  tiltVal.textContent = Number(tiltSlider.value).toFixed(1);
  if (daLock.checked) applyLockConstraints();
  syncRectFromCorners();
  void writeDisplayArea();
});

daLock.addEventListener('change', () => {
  updateLockUi();
  updateRectLockUi();
  if (daLock.checked) {
    syncTiltFromCorners();
    applyLockConstraints();
    syncRectFromCorners();
    void writeDisplayArea();
  }
});

daReload.addEventListener('click', async () => {
  if (!tracker) return;
  try {
    const area = await tracker.getDisplayArea();
    setFormValues(area);
  } catch (e) {
    setError(e instanceof Error ? e.message : String(e));
  }
});

daReset.addEventListener('click', () => {
  setFormValues(DEFAULT_AREA);
  void writeDisplayArea();
});

// ---------- Diagnostic: does display_area affect 3D fields? ----------
// Holds the user's head still while the display_area is toggled between
// two very different configurations. Captures N samples per phase, then
// reports per-field mean & stddev deltas. Tracker-frame fields (eye
// origin, gaze direction, 3D gaze point in tracker frame) should be
// invariant; gaze_point_2d_norm should change dramatically (control).

type V3 = { x: number; y: number; z: number };
type Stats = { mean: V3; std: V3; n: number };

function statsFromSamples(vals: V3[]): Stats {
  const n = vals.length;
  if (n === 0) return { mean: { x: NaN, y: NaN, z: NaN }, std: { x: NaN, y: NaN, z: NaN }, n };
  const mean = { x: 0, y: 0, z: 0 };
  for (const v of vals) { mean.x += v.x; mean.y += v.y; mean.z += v.z; }
  mean.x /= n; mean.y /= n; mean.z /= n;
  const sq = { x: 0, y: 0, z: 0 };
  for (const v of vals) {
    sq.x += (v.x - mean.x) ** 2;
    sq.y += (v.y - mean.y) ** 2;
    sq.z += (v.z - mean.z) ** 2;
  }
  return {
    mean,
    std: { x: Math.sqrt(sq.x / n), y: Math.sqrt(sq.y / n), z: Math.sqrt(sq.z / n) },
    n,
  };
}

function fmtV3(v: V3, d = 2) { return `(${v.x.toFixed(d)}, ${v.y.toFixed(d)}, ${v.z.toFixed(d)})`; }
function subV3(a: V3, b: V3): V3 { return { x: a.x - b.x, y: a.y - b.y, z: a.z - b.z }; }
function normV3(v: V3) { return Math.hypot(v.x, v.y, v.z); }

async function runDiagnostic() {
  if (!tracker) { diagOut.textContent = 'Connect the tracker first.'; return; }
  daDiag.disabled = true;
  const origArea = readForm();
  // Two very different planes in tracker frame:
  //   A1: the user's current configuration (read from sliders).
  //   A2: scaled 2x, translated +500mm in z.
  const A1 = origArea;
  const A2: DisplayArea = {
    tl: { x: A1.tl.x * 2, y: A1.tl.y * 2, z: A1.tl.z + 500 },
    tr: { x: A1.tr.x * 2, y: A1.tr.y * 2, z: A1.tr.z + 500 },
    bl: { x: A1.bl.x * 2, y: A1.bl.y * 2, z: A1.bl.z + 500 },
  };

  type Bucket = {
    eyeL: V3[]; eyeR: V3[];
    dirL: V3[]; dirR: V3[];
    gp3L: V3[]; gp3R: V3[];
    gp2: V3[]; // stored as (x, y, 0) for uniform stats
  };
  const mkBucket = (): Bucket => ({ eyeL: [], eyeR: [], dirL: [], dirR: [], gp3L: [], gp3R: [], gp2: [] });

  async function capture(ms: number, dst: Bucket) {
    return new Promise<void>((resolve) => {
      const until = performance.now() + ms;
      const unsub = tracker!.subscribeToGaze((s) => {
        if (s.validity_L !== 0 && s.validity_R !== 0) return;
        if (s.eye_origin_L_mm) dst.eyeL.push(s.eye_origin_L_mm);
        if (s.eye_origin_R_mm) dst.eyeR.push(s.eye_origin_R_mm);
        if (s.trackbox_eye_pos_L) dst.dirL.push(s.trackbox_eye_pos_L);
        if (s.trackbox_eye_pos_R) dst.dirR.push(s.trackbox_eye_pos_R);
        if (s.gaze_point_3d_L_mm) dst.gp3L.push(s.gaze_point_3d_L_mm);
        if (s.gaze_point_3d_R_mm) dst.gp3R.push(s.gaze_point_3d_R_mm);
        if (s.gaze_point_2d_norm) dst.gp2.push({ x: s.gaze_point_2d_norm.x, y: s.gaze_point_2d_norm.y, z: 0 });
        if (performance.now() >= until) { unsub(); resolve(); }
      });
    });
  }

  try {
    diagOut.textContent = 'Hold still, look at one point. Phase A (3s)…';
    await tracker.setDisplayAreaCorners(A1);
    await new Promise(r => setTimeout(r, 400)); // settle
    const bA = mkBucket();
    await capture(3000, bA);

    diagOut.textContent = 'Keep holding still. Switching plane… Phase B (3s)…';
    await tracker.setDisplayAreaCorners(A2);
    await new Promise(r => setTimeout(r, 400));
    const bB = mkBucket();
    await capture(3000, bB);

    // Restore
    await tracker.setDisplayAreaCorners(origArea);

    // Report
    const lines: string[] = [];
    const report = (name: string, a: V3[], b: V3[]) => {
      const sA = statsFromSamples(a);
      const sB = statsFromSamples(b);
      const d = subV3(sB.mean, sA.mean);
      lines.push(`${name}`);
      lines.push(`  A mean=${fmtV3(sA.mean)} std=${fmtV3(sA.std)} n=${sA.n}`);
      lines.push(`  B mean=${fmtV3(sB.mean)} std=${fmtV3(sB.std)} n=${sB.n}`);
      lines.push(`  Δmean=${fmtV3(d)} |Δ|=${normV3(d).toFixed(3)}`);
    };
    lines.push(`A1 corners: tl=${fmtV3(A1.tl, 0)} tr=${fmtV3(A1.tr, 0)} bl=${fmtV3(A1.bl, 0)}`);
    lines.push(`A2 corners: tl=${fmtV3(A2.tl, 0)} tr=${fmtV3(A2.tr, 0)} bl=${fmtV3(A2.bl, 0)}`);
    lines.push('');
    report('eye_origin_L_mm (tracker frame?)', bA.eyeL, bB.eyeL);
    report('eye_origin_R_mm (tracker frame?)', bA.eyeR, bB.eyeR);
    report('trackbox_eye_pos_L', bA.dirL, bB.dirL);
    report('trackbox_eye_pos_R', bA.dirR, bB.dirR);
    report('gaze_point_3d_L_mm', bA.gp3L, bB.gp3L);
    report('gaze_point_3d_R_mm', bA.gp3R, bB.gp3R);
    report('gaze_point_2d_norm (CONTROL)', bA.gp2, bB.gp2);
    lines.push('');
    lines.push('Interpretation:');
    lines.push('  |Δ| ~ std → invariant (tracker frame).');
    lines.push('  |Δ| ≫ std → display-dependent.');
    diagOut.textContent = lines.join('\n');
  } catch (e) {
    diagOut.textContent = `diagnostic failed: ${e instanceof Error ? e.message : String(e)}`;
    try { await tracker.setDisplayAreaCorners(origArea); } catch { }
  } finally {
    daDiag.disabled = false;
  }
}

daDiag.addEventListener('click', () => { void runDiagnostic(); });

// ---------- Calibration: refit display_area from gaze rays -----------
// The ET5's raw "direction" columns aren't usable visual-axis vectors
// (verified: 0x03/0x09/0x25/0x27 barely change with gaze shifts). But
// we can *reconstruct* the true gaze ray from two responsive outputs:
//   eye_origin_L_mm (O)     — tracker-frame invariant
//   gaze_point_3d_L_mm (W_P) — ray ∩ current plane P
// The ray is then (O, normalize(W_P − O)), regardless of how wrong P is.
//
// Procedure:
//   1. In fullscreen (viewport == monitor), show fixation dots at k
//      known screen-normalized targets (t.nx, t.ny).
//   2. Per target, capture N samples and average to get one ray per
//      eye: origin O_i and direction d_i = normalize(W_P_i − O_i).
//   3. Fit plane P* = (tl, u, v) and per-sample depths s_i such that
//        O_i + s_i·d_i = tl + t.nx_i·u + t.ny_i·v
//      for every i. 3k equations, 9+k unknowns — solvable for k ≥ 5.
//      Least-squares via the normal equations.
//   4. Push P* to the device.
//
// Fixed-point concern: after pushing P*, the device recomputes
// gaze_point_3d against P*, which changes the reconstructed direction
// too — but the ray *through the eye* is unchanged (that's the
// invariant we rely on). Re-running calibration after push should
// converge in one iteration.

type CalPoint = { nx: number; ny: number };
const CAL_TARGETS: CalPoint[] = [
  { nx: 0.1, ny: 0.1 },
  { nx: 0.9, ny: 0.1 },
  { nx: 0.5, ny: 0.5 },
  { nx: 0.1, ny: 0.9 },
  { nx: 0.9, ny: 0.9 },
];

type V3c = { x: number; y: number; z: number };
const add3 = (a: V3c, b: V3c): V3c => ({ x: a.x + b.x, y: a.y + b.y, z: a.z + b.z });

// Viewport-in-monitor rectangle, in normalized monitor coords.
// Assumes chrome (tabs/URL bar) sits at the top of the browser window
// and any remaining difference between outerHeight/innerHeight is
// bottom chrome (rare in practice). Window position is relative to the
// primary monitor origin; on multi-monitor setups screenX/Y can be
// negative, in which case we clamp to [0,1] so the viewport drawn in
// the scene stays on-screen (and the calibration math is still valid
// as long as the tracker is facing the primary monitor).
type NormRect = { x0: number; y0: number; x1: number; y1: number };

// Modern Chromium locks down screenX/Y/screenLeft/Top to 0 for
// privacy on multi-monitor setups. The Window Management API
// (getScreenDetails, permission 'window-management') returns accurate
// window placement data. When unavailable, the viewport rect will be
// inaccurate (we assume the window is at the primary screen's origin).
function computeViewportRect(): NormRect {
  // In fullscreen the viewport covers the entire monitor by
  // definition, so return the full unit rect regardless of what the
  // browser reports for screen dimensions (which can be wrong on
  // multi-monitor setups with Chrome's locked-down screen APIs).
  if (document.fullscreenElement) {
    return { x0: 0, y0: 0, x1: 1, y1: 1 };
  }
  const oW = window.outerWidth, oH = window.outerHeight;
  const iW = window.innerWidth, iH = window.innerHeight;
  // Prefer screenLeft/Top (updates reliably across Chromium versions)
  // and fall back to screenX/Y. Both are 0 when locked down.
  const wx = window.screenLeft ?? window.screenX;
  const wy = window.screenTop ?? window.screenY;
  // If the Window Management API is granted, read per-screen dims.
  // Otherwise fall back to window.screen (global primary info).
  const cur = screenDetails?.currentScreen;
  const sW = cur?.width ?? window.screen.width;
  const sH = cur?.height ?? window.screen.height;
  const sOffX = cur?.availLeft ?? 0;
  const sOffY = cur?.availTop ?? 0;
  const chromeTop = oH - iH;          // height of tabs+URL bar
  const leftBorder = (oW - iW) / 2;    // assume symmetric side borders
  const vpLeft = (wx - sOffX) + leftBorder;
  const vpTop = (wy - sOffY) + chromeTop;
  return {
    x0: vpLeft / sW,
    y0: vpTop / sH,
    x1: (vpLeft + iW) / sW,
    y1: (vpTop + iH) / sH,
  };
}

type WindowWithScreenDetails = Window & {
  getScreenDetails?: () => Promise<ScreenDetails>;
};

async function requestScreenDetails(): Promise<void> {
  const w = window as WindowWithScreenDetails;
  if (typeof w.getScreenDetails !== 'function') {
    console.warn('Window Management API not available; viewport position will be inaccurate.');
    return;
  }
  try {
    screenDetails = await w.getScreenDetails();
    pushViewportRect();
  } catch (e) {
    console.warn('getScreenDetails() rejected:', e);
  }
}

// Map a viewport-normalized (vx, vy) to screen-normalized (sx, sy).
function viewportToScreen(vx: number, vy: number, r: NormRect): { x: number; y: number } {
  return { x: r.x0 + vx * (r.x1 - r.x0), y: r.y0 + vy * (r.y1 - r.y0) };
}

// Solve 3×3 A·x = b (Cramer).
type M3 = [number, number, number, number, number, number, number, number, number];
type V3t = [number, number, number];
function solve3(A: M3, b: V3t): V3t | null {
  const [a0, a1, a2, a3, a4, a5, a6, a7, a8] = A;
  const [b0, b1, b2] = b;
  const det = a0 * (a4 * a8 - a5 * a7) - a1 * (a3 * a8 - a5 * a6) + a2 * (a3 * a7 - a4 * a6);
  if (Math.abs(det) < 1e-9) return null;
  const inv = 1 / det;
  const x = inv * (b0 * (a4 * a8 - a5 * a7) - a1 * (b1 * a8 - a5 * b2) + a2 * (b1 * a7 - a4 * b2));
  const y = inv * (a0 * (b1 * a8 - a5 * b2) - b0 * (a3 * a8 - a5 * a6) + a2 * (a3 * b2 - b1 * a6));
  const z = inv * (a0 * (a4 * b2 - b1 * a7) - a1 * (a3 * b2 - b1 * a6) + b0 * (a3 * a7 - a4 * a6));
  return [x, y, z];
}

type Ray = { O: V3c; d: V3c };

// Fit (tl, u, v, s_1..s_k) such that O_i + s_i·d_i = tl + nx_i·u + ny_i·v
// for every sample, in the least-squares sense. 3k equations in 9+k
// unknowns. Layout of x = [tl(3), u(3), v(3), s_1..s_k]. The system is
// naturally sparse; we just build AᵀA (small: (9+k)² ≤ 196) and solve
// by Gaussian elimination.
function fitDisplayAreaRays(pts: CalPoint[], rays: Ray[]): DisplayArea | null {
  const k = pts.length;
  if (k < 5 || rays.length !== k) return null;
  const N = 9 + k;
  // Row layout per sample i, axis a∈{x,y,z}:
  //   -tl_a - nx_i·u_a - ny_i·v_a + d_i.a · s_i = -O_i.a
  //   (we multiply the whole row by -1 — tl_a + nx·u_a + ny·v_a - d·s = O_a)
  // Column indices: tl_x=0,tl_y=1,tl_z=2, u_x=3,u_y=4,u_z=5,
  //                 v_x=6,v_y=7,v_z=8, s_i=9+i.
  const AtA = new Float64Array(N * N);
  const Atb = new Float64Array(N);
  const addRow = (row: number[], rhs: number) => {
    for (let r = 0; r < N; r++) {
      const rv = row[r]!;
      if (rv === 0) continue;
      Atb[r] = Atb[r]! + rv * rhs;
      for (let c = 0; c < N; c++) {
        const cv = row[c]!;
        if (cv === 0) continue;
        AtA[r * N + c] = AtA[r * N + c]! + rv * cv;
      }
    }
  };
  for (let i = 0; i < k; i++) {
    const { nx, ny } = pts[i]!;
    const { O, d } = rays[i]!;
    const axes: Array<'x' | 'y' | 'z'> = ['x', 'y', 'z'];
    for (let a = 0; a < 3; a++) {
      const row = new Array<number>(N).fill(0);
      row[a] = 1;           // tl_a
      row[3 + a] = nx;      // u_a
      row[6 + a] = ny;      // v_a
      row[9 + i] = -d[axes[a]!]; // −s_i · d_i.a
      addRow(row, O[axes[a]!]);
    }
  }
  // Gaussian elimination with partial pivoting on [AtA | Atb].
  const M = new Float64Array(N * (N + 1));
  for (let r = 0; r < N; r++) {
    for (let c = 0; c < N; c++) M[r * (N + 1) + c] = AtA[r * N + c]!;
    M[r * (N + 1) + N] = Atb[r]!;
  }
  for (let col = 0; col < N; col++) {
    let piv = col;
    let best = Math.abs(M[col * (N + 1) + col]!);
    for (let r = col + 1; r < N; r++) {
      const v = Math.abs(M[r * (N + 1) + col]!);
      if (v > best) { best = v; piv = r; }
    }
    if (best < 1e-9) return null;
    if (piv !== col) {
      for (let c = 0; c <= N; c++) {
        const tmp = M[col * (N + 1) + c]!;
        M[col * (N + 1) + c] = M[piv * (N + 1) + c]!;
        M[piv * (N + 1) + c] = tmp;
      }
    }
    const inv = 1 / M[col * (N + 1) + col]!;
    for (let r = 0; r < N; r++) {
      if (r === col) continue;
      const f = M[r * (N + 1) + col]! * inv;
      if (f === 0) continue;
      for (let c = col; c <= N; c++) {
        M[r * (N + 1) + c] = M[r * (N + 1) + c]! - f * M[col * (N + 1) + c]!;
      }
    }
  }
  const x = new Array<number>(N);
  for (let r = 0; r < N; r++) x[r] = M[r * (N + 1) + N]! / M[r * (N + 1) + r]!;
  const tl = { x: x[0]!, y: x[1]!, z: x[2]! };
  const u = { x: x[3]!, y: x[4]!, z: x[5]! };
  const v = { x: x[6]!, y: x[7]!, z: x[8]! };
  // Sanity: require all depths positive (gaze points are in front of eye).
  for (let i = 0; i < k; i++) if (x[9 + i]! <= 0) return null;
  return { tl, tr: add3(tl, u), bl: add3(tl, v) };
}

// ---------- Sample collection for offline calibration analysis -----
//
// Collects labelled "user looking at cursor" gaze samples. Fullscreen,
// with a huge centered plane configured as the display_area so the
// device reports meaningful 2d_norm (and 3d_mm won't be clamped
// weirdly). While any mouse button is held, every incoming GazeSample
// is stamped with the live cursor position (viewport-normalized) and
// stored. Pressing Enter finishes and downloads the dataset as JSON.
// Esc cancels without downloading.
//
// Output schema (v1):
//   {
//     version: 1,
//     captured_at: <ISO string>,
//     user_agent: <string>,
//     viewport_px: [w, h],           // innerWidth/Height at start (fullscreen)
//     display_area_used: DisplayArea, // the huge plane we set
//     prior_display_area: DisplayArea,// what was configured before
//     samples: [
//       {
//         t_ms: number,              // performance.now relative to start
//         cursor_norm: [nx, ny],     // in viewport coords, 0..1
//         cursor_px: [x, y],
//         sample: GazeSample,        // raw (subset we can JSON)
//       }, ...
//     ]
//   }

type CollectedRecord = {
  t_ms: number;
  cursor_norm: [number, number];
  cursor_px: [number, number];
  sample: {
    validity_L?: number; validity_R?: number;
    eye_origin_L_mm?: { x: number; y: number; z: number };
    eye_origin_R_mm?: { x: number; y: number; z: number };
    trackbox_eye_pos_L?: { x: number; y: number; z: number };
    trackbox_eye_pos_R?: { x: number; y: number; z: number };
    gaze_point_3d_L_mm?: { x: number; y: number; z: number };
    gaze_point_3d_R_mm?: { x: number; y: number; z: number };
    gaze_point_2d_norm?: { x: number; y: number };
    gaze_point_2d_L_norm?: { x: number; y: number };
    gaze_point_2d_R_norm?: { x: number; y: number };
  };
};

type CollectedDataset = {
  version: 1;
  captured_at: string;
  user_agent: string;
  viewport_px: [number, number];
  display_area_used: DisplayArea;
  prior_display_area: DisplayArea;
  samples: CollectedRecord[];
};

let collectRunning = false;

async function runSampleCollection() {
  if (!tracker || collectRunning) return;
  collectRunning = true;
  daCollect.disabled = true;
  const prior = readForm();

  // A large, centered, axis-aligned plane. Big enough that any visual
  // ray from ~700mm away hits somewhere inside it, giving the device
  // plenty of room to compute 2d_norm without clamping.
  const big: DisplayArea = {
    tl: { x: -500, y: 500, z: 0 },
    tr: { x: 500, y: 500, z: 0 },
    bl: { x: -500, y: 0, z: 0 },
  };

  // Enter fullscreen so cursor_norm == display_normalized.
  try {
    if (!document.fullscreenElement) {
      await document.documentElement.requestFullscreen();
    }
  } catch (e) {
    calStatus.textContent = `Could not enter fullscreen: ${e instanceof Error ? e.message : String(e)}`;
    collectRunning = false;
    daCollect.disabled = false;
    return;
  }

  try {
    await tracker.setDisplayAreaCorners(big);
  } catch (e) {
    calStatus.textContent = `Could not set collection plane: ${e instanceof Error ? e.message : String(e)}`;
    if (document.fullscreenElement) { try { await document.exitFullscreen(); } catch { } }
    collectRunning = false;
    daCollect.disabled = false;
    return;
  }
  setFormValues(big);

  calOverlay.classList.add('active');
  calOverlay.style.cursor = 'crosshair';
  calTarget.style.display = 'none';

  const startedAt = performance.now();
  const samples: CollectedRecord[] = [];
  let cursorX = window.innerWidth / 2;
  let cursorY = window.innerHeight / 2;
  let mouseDown = false;
  let done: 'finish' | 'cancel' | null = null;

  const onMove = (e: PointerEvent) => { cursorX = e.clientX; cursorY = e.clientY; };
  const onDown = (e: PointerEvent) => { if (e.button === 0) mouseDown = true; };
  const onUp = (e: PointerEvent) => { if (e.button === 0) mouseDown = false; };
  const onKey = (e: KeyboardEvent) => {
    if (e.key === 'Enter') { done = 'finish'; }
    else if (e.key === 'Escape') { done = 'cancel'; }
  };
  calOverlay.addEventListener('pointermove', onMove);
  calOverlay.addEventListener('pointerdown', onDown);
  calOverlay.addEventListener('pointerup', onUp);
  window.addEventListener('keydown', onKey);

  const unsub = tracker.subscribeToGaze((s) => {
    if (!mouseDown) return;
    const vw = window.innerWidth, vh = window.innerHeight;
    samples.push({
      t_ms: performance.now() - startedAt,
      cursor_norm: [cursorX / vw, cursorY / vh],
      cursor_px: [cursorX, cursorY],
      sample: {
        validity_L: s.validity_L,
        validity_R: s.validity_R,
        eye_origin_L_mm: s.eye_origin_L_mm && { ...s.eye_origin_L_mm },
        eye_origin_R_mm: s.eye_origin_R_mm && { ...s.eye_origin_R_mm },
        trackbox_eye_pos_L: s.trackbox_eye_pos_L && { ...s.trackbox_eye_pos_L },
        trackbox_eye_pos_R: s.trackbox_eye_pos_R && { ...s.trackbox_eye_pos_R },
        gaze_point_3d_L_mm: s.gaze_point_3d_L_mm && { ...s.gaze_point_3d_L_mm },
        gaze_point_3d_R_mm: s.gaze_point_3d_R_mm && { ...s.gaze_point_3d_R_mm },
        gaze_point_2d_norm: s.gaze_point_2d_norm && { ...s.gaze_point_2d_norm },
        gaze_point_2d_L_norm: s.gaze_point_2d_L_norm && { ...s.gaze_point_2d_L_norm },
        gaze_point_2d_R_norm: s.gaze_point_2d_R_norm && { ...s.gaze_point_2d_R_norm },
      },
    });
  });

  // Periodic status tick so the user sees progress.
  const tickTimer = setInterval(() => {
    const held = mouseDown ? ' · HOLDING' : '';
    calStatus.textContent =
      `Hold mouse button while looking at cursor · ${samples.length} samples${held} · Enter: download · Esc: cancel`;
  }, 100);

  // Wait until Enter or Esc.
  await new Promise<void>((resolve) => {
    const poll = setInterval(() => {
      if (done) { clearInterval(poll); resolve(); }
    }, 50);
  });

  clearInterval(tickTimer);
  unsub();
  calOverlay.removeEventListener('pointermove', onMove);
  calOverlay.removeEventListener('pointerdown', onDown);
  calOverlay.removeEventListener('pointerup', onUp);
  window.removeEventListener('keydown', onKey);
  calOverlay.classList.remove('active');
  calOverlay.style.cursor = '';
  calTarget.style.display = '';

  // Restore prior plane regardless.
  try { await tracker.setDisplayAreaCorners(prior); } catch { }
  setFormValues(prior);

  if (document.fullscreenElement) { try { await document.exitFullscreen(); } catch { } }

  if (done === 'finish' && samples.length > 0) {
    const dataset: CollectedDataset = {
      version: 1,
      captured_at: new Date().toISOString(),
      user_agent: navigator.userAgent,
      viewport_px: [window.innerWidth, window.innerHeight],
      display_area_used: big,
      prior_display_area: prior,
      samples,
    };
    const blob = new Blob([JSON.stringify(dataset, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    a.href = url;
    a.download = `gaze-samples-${stamp}.json`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    calStatus.textContent = `Downloaded ${samples.length} samples`;
  } else if (done === 'cancel') {
    calStatus.textContent = 'Collection cancelled';
  } else {
    calStatus.textContent = 'No samples collected';
  }

  collectRunning = false;
  daCollect.disabled = false;
}

// --- Two-plane collection: same as above but alternates between two
// parallel planes (A at z=0 and B at z=+300mm) every 400ms. Each
// sample is tagged with which plane was active when it was captured.
// Purpose: recover the device's internal gaze ray per fixation by
// triangulating (gaze_point_3d on A) and (gaze_point_3d on B).

type CollectedRecord2 = CollectedRecord & { plane: 'A' | 'B' };

type CollectedDataset2 = {
  version: 2;
  captured_at: string;
  user_agent: string;
  viewport_px: [number, number];
  plane_A: DisplayArea;
  plane_B: DisplayArea;
  prior_display_area: DisplayArea;
  samples: CollectedRecord2[];
};

// Fit a display_area from two-plane gaze samples using per-plane affine
// regression.  On each configured plane, gaze_2d_norm relates to the true
// cursor position via an affine transform:  gaze_2d = A·cursor + b.
// Fitting this from ALL valid settled samples (not binned) and mapping
// the cursor corners (0,0), (1,0), (0,1) through each plane's affine
// yields two 3D points per corner (one on each plane).  The line through
// those two points is the gaze ray for that corner.  Picking any
// interpolation parameter t ∈ (0,1) along the ray produces a valid
// display_area — the normalized gaze output is depth-independent.
type TwoPlaneFitResult = {
  area: DisplayArea;
  nA: number;                   // settled valid samples on plane A
  nB: number;                   // settled valid samples on plane B
  rmseA: number;                // affine residual (normalised) on A
  rmseB: number;                // affine residual (normalised) on B
  width_mm: number;
  height_mm: number;
  uv_angle_deg: number;
};

function fitAffine2d(rows: Array<{ cx: number; cy: number; gx: number; gy: number }>) {
  // Fit gx = ax[0]*cx + ax[1]*cy + ax[2],  gy = ay[0]*cx + ay[1]*cy + ay[2]
  let m00 = 0, m01 = 0, m02 = 0, m11 = 0, m12 = 0, m22 = 0;
  let bx0 = 0, bx1 = 0, bx2 = 0, by0 = 0, by1 = 0, by2 = 0;
  for (const r of rows) {
    m00 += r.cx * r.cx; m01 += r.cx * r.cy; m02 += r.cx;
    m11 += r.cy * r.cy; m12 += r.cy; m22 += 1;
    bx0 += r.cx * r.gx; bx1 += r.cy * r.gx; bx2 += r.gx;
    by0 += r.cx * r.gy; by1 += r.cy * r.gy; by2 += r.gy;
  }
  const M: M3 = [m00, m01, m02, m01, m11, m12, m02, m12, m22];
  const ax = solve3(M, [bx0, bx1, bx2]);
  const ay = solve3(M, [by0, by1, by2]);
  if (!ax || !ay) return null;
  let rss = 0;
  for (const r of rows) {
    const px = ax[0] * r.cx + ax[1] * r.cy + ax[2] - r.gx;
    const py = ay[0] * r.cx + ay[1] * r.cy + ay[2] - r.gy;
    rss += px * px + py * py;
  }
  return { ax, ay, rmse: Math.sqrt(rss / rows.length) };
}

function cornerOnPlane(
  aff: { ax: V3t; ay: V3t },
  cx: number, cy: number,
  plane: DisplayArea,
): V3c {
  const nx = aff.ax[0] * cx + aff.ax[1] * cy + aff.ax[2];
  const ny = aff.ay[0] * cx + aff.ay[1] * cy + aff.ay[2];
  const ux = plane.tr.x - plane.tl.x, uy = plane.tr.y - plane.tl.y, uz = plane.tr.z - plane.tl.z;
  const vx = plane.bl.x - plane.tl.x, vy = plane.bl.y - plane.tl.y, vz = plane.bl.z - plane.tl.z;
  return {
    x: plane.tl.x + nx * ux + ny * vx,
    y: plane.tl.y + nx * uy + ny * vy,
    z: plane.tl.z + nx * uz + ny * vz,
  };
}

function fitFromTwoPlaneSamples(
  samples: CollectedRecord2[],
  pA: DisplayArea,
  pB: DisplayArea,
): TwoPlaneFitResult | null {
  const S = samples.filter((r) => r.sample.validity_L === 0 && r.sample.validity_R === 0);
  // Settle: drop first 150ms of each plane run.
  const settled: CollectedRecord2[] = [];
  let lastPlane: 'A' | 'B' | null = null;
  let runStart = 0;
  for (const r of S) {
    if (r.plane !== lastPlane) { lastPlane = r.plane; runStart = r.t_ms; }
    if (r.t_ms - runStart >= 150) settled.push(r);
  }

  const toRows = (arr: CollectedRecord2[]) =>
    arr.filter((r) => r.sample.gaze_point_2d_norm != null).map((r) => ({
      cx: r.cursor_norm[0], cy: r.cursor_norm[1],
      gx: r.sample.gaze_point_2d_norm!.x, gy: r.sample.gaze_point_2d_norm!.y,
    }));
  const rowsA = toRows(settled.filter((r) => r.plane === 'A'));
  const rowsB = toRows(settled.filter((r) => r.plane === 'B'));
  if (rowsA.length < 10 || rowsB.length < 10) return null;

  const affA = fitAffine2d(rowsA);
  const affB = fitAffine2d(rowsB);
  if (!affA || !affB) return null;

  // Map cursor corners through each plane's affine, then interpolate.
  // t=0.85 is arbitrary — the resulting gaze_2d_norm is depth-independent.
  const T = 0.85;
  const lerp = (a: V3c, b: V3c): V3c => ({
    x: a.x + T * (b.x - a.x),
    y: a.y + T * (b.y - a.y),
    z: a.z + T * (b.z - a.z),
  });
  const tl = lerp(cornerOnPlane(affA, 0, 0, pA), cornerOnPlane(affB, 0, 0, pB));
  const tr = lerp(cornerOnPlane(affA, 1, 0, pA), cornerOnPlane(affB, 1, 0, pB));
  const bl = lerp(cornerOnPlane(affA, 0, 1, pA), cornerOnPlane(affB, 0, 1, pB));
  const area: DisplayArea = { tl, tr, bl };

  const u = { x: tr.x - tl.x, y: tr.y - tl.y, z: tr.z - tl.z };
  const v = { x: bl.x - tl.x, y: bl.y - tl.y, z: bl.z - tl.z };
  const ulen = Math.hypot(u.x, u.y, u.z);
  const vlen = Math.hypot(v.x, v.y, v.z);
  const dotuv = u.x * v.x + u.y * v.y + u.z * v.z;
  const uv_angle_deg = Math.acos(Math.max(-1, Math.min(1, dotuv / (ulen * vlen)))) * 180 / Math.PI;

  return {
    area,
    nA: rowsA.length,
    nB: rowsB.length,
    rmseA: affA.rmse,
    rmseB: affB.rmse,
    width_mm: ulen,
    height_mm: vlen,
    uv_angle_deg,
  };
}

async function runSampleCollection2Plane() {
  if (!tracker || collectRunning) return;
  collectRunning = true;
  daCollect2.disabled = true;
  const prior = readForm();

  // Two parallel axis-aligned planes at different z. Both large enough
  // that any ray from ~700mm intersects inside. Separation of 300mm
  // gives strong triangulation (at 600mm eye-to-plane distance, this
  // moves the 3d intersection by ~half the plane offset per angular
  // unit of gaze → plenty of signal).
  const planeA: DisplayArea = {
    tl: { x: -500, y: 500, z: 0 },
    tr: { x: 500, y: 500, z: 0 },
    bl: { x: -500, y: 0, z: 0 },
  };
  const planeB: DisplayArea = {
    tl: { x: -500, y: 500, z: 300 },
    tr: { x: 500, y: 500, z: 300 },
    bl: { x: -500, y: 0, z: 300 },
  };

  try {
    if (!document.fullscreenElement) {
      await document.documentElement.requestFullscreen();
    }
  } catch (e) {
    calStatus.textContent = `Could not enter fullscreen: ${e instanceof Error ? e.message : String(e)}`;
    collectRunning = false;
    daCollect2.disabled = false;
    return;
  }

  try {
    await tracker.setDisplayAreaCorners(planeA);
  } catch (e) {
    calStatus.textContent = `Could not set plane A: ${e instanceof Error ? e.message : String(e)}`;
    if (document.fullscreenElement) { try { await document.exitFullscreen(); } catch { } }
    collectRunning = false;
    daCollect2.disabled = false;
    return;
  }
  setFormValues(planeA);

  calOverlay.classList.add('active');
  calOverlay.style.cursor = 'none';
  calTarget.style.display = 'none';

  const startedAt = performance.now();
  const samples: CollectedRecord2[] = [];
  let cursorX = window.innerWidth / 2;
  let cursorY = window.innerHeight / 2;
  let mouseDown = false;
  let done: 'finish' | 'cancel' | null = null;
  let currentPlane: 'A' | 'B' = 'A';

  // Show spinning target at cursor position.
  collectTarget.style.left = `${cursorX}px`;
  collectTarget.style.top = `${cursorY}px`;
  collectTarget.style.display = 'block';

  const onMove = (e: PointerEvent) => {
    cursorX = e.clientX; cursorY = e.clientY;
    collectTarget.style.left = `${cursorX}px`;
    collectTarget.style.top = `${cursorY}px`;
  };
  const onDown = (e: PointerEvent) => { if (e.button === 0) mouseDown = true; };
  const onUp = (e: PointerEvent) => { if (e.button === 0) mouseDown = false; };
  const onKey = (e: KeyboardEvent) => {
    if (e.key === 'Enter') { done = 'finish'; }
    else if (e.key === 'Escape') { done = 'cancel'; }
  };
  calOverlay.addEventListener('pointermove', onMove);
  calOverlay.addEventListener('pointerdown', onDown);
  calOverlay.addEventListener('pointerup', onUp);
  window.addEventListener('keydown', onKey);

  // Only capture while mouse is held — user holds button while staring
  // at cursor, releases to rest eyes.
  const unsub = tracker.subscribeToGaze((s) => {
    if (!mouseDown) return;
    const vw = window.innerWidth, vh = window.innerHeight;
    samples.push({
      t_ms: performance.now() - startedAt,
      cursor_norm: [cursorX / vw, cursorY / vh],
      cursor_px: [cursorX, cursorY],
      plane: currentPlane,
      sample: {
        validity_L: s.validity_L,
        validity_R: s.validity_R,
        eye_origin_L_mm: s.eye_origin_L_mm && { ...s.eye_origin_L_mm },
        eye_origin_R_mm: s.eye_origin_R_mm && { ...s.eye_origin_R_mm },
        trackbox_eye_pos_L: s.trackbox_eye_pos_L && { ...s.trackbox_eye_pos_L },
        trackbox_eye_pos_R: s.trackbox_eye_pos_R && { ...s.trackbox_eye_pos_R },
        gaze_point_3d_L_mm: s.gaze_point_3d_L_mm && { ...s.gaze_point_3d_L_mm },
        gaze_point_3d_R_mm: s.gaze_point_3d_R_mm && { ...s.gaze_point_3d_R_mm },
        gaze_point_2d_norm: s.gaze_point_2d_norm && { ...s.gaze_point_2d_norm },
        gaze_point_2d_L_norm: s.gaze_point_2d_L_norm && { ...s.gaze_point_2d_L_norm },
        gaze_point_2d_R_norm: s.gaze_point_2d_R_norm && { ...s.gaze_point_2d_R_norm },
      },
    });
  });

  // Plane-switch timer — 1000ms per plane gives ~850ms of usable data
  // per run after the 150ms settle window.
  const switchTimer = setInterval(async () => {
    currentPlane = currentPlane === 'A' ? 'B' : 'A';
    try {
      await tracker!.setDisplayAreaCorners(currentPlane === 'A' ? planeA : planeB);
    } catch { }
  }, 1000);

  // Status tick — also show unique-bin coverage and valid-sample count
  // so the user knows when to stop.
  const tickTimer = setInterval(() => {
    const nA = samples.filter((r) => r.plane === 'A' && r.sample.validity_L === 0 && r.sample.validity_R === 0).length;
    const nB = samples.filter((r) => r.plane === 'B' && r.sample.validity_L === 0 && r.sample.validity_R === 0).length;
    const bins = new Set<string>();
    for (const r of samples) {
      if (r.sample.validity_L !== 0 || r.sample.validity_R !== 0) continue;
      const bx = Math.floor(r.cursor_norm[0] * 12);
      const by = Math.floor(r.cursor_norm[1] * 12);
      bins.add(`${bx},${by}`);
    }
    const held = mouseDown ? ' · HOLDING' : '';
    calStatus.textContent =
      `Hold button + look at cursor · plane ${currentPlane} · valid A=${nA} B=${nB} · cells=${bins.size}${held} · Enter: stop · Esc: cancel`;
  }, 100);

  await new Promise<void>((resolve) => {
    const poll = setInterval(() => {
      if (done) { clearInterval(poll); resolve(); }
    }, 50);
  });

  clearInterval(switchTimer);
  clearInterval(tickTimer);
  unsub();
  calOverlay.removeEventListener('pointermove', onMove);
  calOverlay.removeEventListener('pointerdown', onDown);
  calOverlay.removeEventListener('pointerup', onUp);
  window.removeEventListener('keydown', onKey);
  calOverlay.classList.remove('active');
  calOverlay.style.cursor = '';
  calTarget.style.display = '';
  collectTarget.style.display = 'none';

  if (document.fullscreenElement) { try { await document.exitFullscreen(); } catch { } }

  if (done === 'finish' && samples.length > 0) {
    // Always download the raw dataset first so we can debug offline,
    // regardless of whether the user applies the fit.
    const dataset: CollectedDataset2 = {
      version: 2,
      captured_at: new Date().toISOString(),
      user_agent: navigator.userAgent,
      viewport_px: [window.innerWidth, window.innerHeight],
      plane_A: planeA,
      plane_B: planeB,
      prior_display_area: prior,
      samples,
    };
    const blob = new Blob([JSON.stringify(dataset, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    a.href = url;
    a.download = `gaze-samples-2plane-${stamp}.json`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);

    // Compute the fit inline.
    const fit = fitFromTwoPlaneSamples(samples, planeA, planeB);
    const bad = fit && (fit.uv_angle_deg < 70 || fit.uv_angle_deg > 110);
    const summary = fit
      ? `Fit: ${fit.width_mm.toFixed(0)}×${fit.height_mm.toFixed(0)}mm · angle=${fit.uv_angle_deg.toFixed(1)}° · ` +
      `affine RMSE A=${(fit.rmseA * 1000).toFixed(0)} B=${(fit.rmseB * 1000).toFixed(0)} milli-norm · ` +
      `n=${fit.nA}/${fit.nB}` +
      (bad ? ' — SUSPECT' : '')
      : `Fit failed (not enough valid samples; got ${samples.length})`;
    console.log('[2-plane fit]', fit);
    calStatus.textContent = `${summary} · downloaded samples`;

    const apply = fit ? window.confirm(
      `${summary}\n\n${bad ? '⚠ Fit looks bad — cursor error or plane skew is out of range. Applying will likely make gaze wildly wrong.\n\n' : ''}Apply this display_area to the device?\n\n` +
      `tl=(${fit.area.tl.x.toFixed(0)}, ${fit.area.tl.y.toFixed(0)}, ${fit.area.tl.z.toFixed(0)})\n` +
      `tr=(${fit.area.tr.x.toFixed(0)}, ${fit.area.tr.y.toFixed(0)}, ${fit.area.tr.z.toFixed(0)})\n` +
      `bl=(${fit.area.bl.x.toFixed(0)}, ${fit.area.bl.y.toFixed(0)}, ${fit.area.bl.z.toFixed(0)})\n\n` +
      `Raw samples already downloaded.\n` +
      `Cancel to restore the prior display_area.`,
    ) : false;

    if (apply && fit) {
      try {
        await tracker.setDisplayAreaCorners(fit.area);
        setFormValues(fit.area);
        calStatus.textContent = `Applied fit. ${summary} · downloaded samples`;
      } catch (e) {
        calStatus.textContent = `Apply failed: ${e instanceof Error ? e.message : String(e)}. Restoring prior.`;
        try { await tracker.setDisplayAreaCorners(prior); } catch { }
        setFormValues(prior);
      }
    } else {
      try { await tracker.setDisplayAreaCorners(prior); } catch { }
      setFormValues(prior);
    }
  } else if (done === 'cancel') {
    try { await tracker.setDisplayAreaCorners(prior); } catch { }
    setFormValues(prior);
    calStatus.textContent = 'Collection cancelled';
  } else {
    try { await tracker.setDisplayAreaCorners(prior); } catch { }
    setFormValues(prior);
    calStatus.textContent = 'No samples collected';
  }

  collectRunning = false;
  daCollect2.disabled = false;
}

let calRunning = false;
let calCancel: (() => void) | null = null;

async function runCalibration() {
  if (!tracker || calRunning) return;
  calRunning = true;
  daCal.disabled = true;
  const origArea = readForm();
  const capturedRays: Ray[] = [];
  // In fullscreen the viewport fills the physical monitor, so the
  // target's viewport-normalized coords double as screen-normalized
  // coords — exactly what we want to fit the display_area against.
  const capturedPts: CalPoint[] = [];

  // Enter fullscreen so the viewport == physical monitor. Chrome
  // locks down window-position APIs, so fullscreen is the simplest
  // way to get an accurate viewport→screen mapping. We exit on
  // success, cancel, or error.
  try {
    if (!document.fullscreenElement) {
      await document.documentElement.requestFullscreen();
    }
  } catch (e) {
    calStatus.textContent = `Could not enter fullscreen: ${e instanceof Error ? e.message : String(e)}`;
    calRunning = false;
    daCal.disabled = false;
    return;
  }

  // Cursor-driven flow: user moves the mouse to wherever they want,
  // *looks at the cursor*, and clicks to capture. The calOverlay
  // covers the whole viewport but uses the normal cursor (not the
  // big green dot). Minimum 5 clicks; press Enter to finish, Esc to
  // cancel.
  calOverlay.classList.add('active');
  calOverlay.style.cursor = 'crosshair';
  calTarget.style.display = 'none';
  calTarget.classList.remove('capturing');
  let cancelled = false;
  let finished = false;
  const onKey = (e: KeyboardEvent) => {
    if (e.key === 'Escape') { cancelled = true; calCancel?.(); }
    else if (e.key === 'Enter') { finished = true; calCancel?.(); }
  };
  window.addEventListener('keydown', onKey);

  try {
    // Main capture loop — each iteration is one click.
    let i = 0;
    for (; ;) {
      if (cancelled) break;
      const minPts = 5;
      const enough = capturedPts.length >= minPts;
      calStatus.textContent = enough
        ? `Look at cursor · click to add (${capturedPts.length} captured) · Enter to finish · Esc to cancel`
        : `Look at cursor · click to add (${capturedPts.length}/${minPts}) · Esc to cancel`;

      // Wait for a click (or Enter/Esc).
      const clickPos = await new Promise<{ x: number; y: number } | null>((resolve) => {
        const onClick = (e: MouseEvent) => { cleanup(); resolve({ x: e.clientX, y: e.clientY }); };
        const cancel = () => { cleanup(); resolve(null); };
        const cleanup = () => {
          calOverlay.removeEventListener('click', onClick);
          calCancel = null;
        };
        calOverlay.addEventListener('click', onClick, { once: true });
        calCancel = cancel;
      });
      if (cancelled || finished || clickPos == null) break;

      // Record the cursor's viewport-normalized coords as the target.
      // In fullscreen viewport == monitor, so these are the display-
      // normalized coords we want to fit against.
      const tx = clickPos.x / window.innerWidth;
      const ty = clickPos.y / window.innerHeight;
      i++;

      // Visual feedback during capture: pin a shrinking-ring dot at
      // the click position and hide the cursor, so the user knows to
      // keep looking there until the ring completes. The animation
      // runs for the full two-plane capture duration (~2500ms).
      calTarget.style.left = `${clickPos.x}px`;
      calTarget.style.top = `${clickPos.y}px`;
      calTarget.style.display = '';
      // Force reflow so restarting the animation works even on the
      // same element.
      void calTarget.offsetWidth;
      calTarget.classList.add('capturing');
      calOverlay.classList.add('capturing');

      // Capture phase — two-plane triangulation.
      //
      // The device's `gaze_point_3d` is the intersection of an internal
      // visual-axis ray with the currently configured plane. That ray
      // is NOT simply (eye_origin → gaze_point_3d): the device applies
      // per-user calibration offsets that move the effective origin
      // away from the pupil midpoint. Sanity-checked empirically: the
      // reconstructed O→W line implied 50°+ angles between horizontally-
      // adjacent targets, ~2× the true angular extent of a monitor at
      // 700mm distance.
      //
      // However, the ray *is* geometric in tracker frame and
      // independent of which plane is configured. So we capture W on
      // two different planes (A and B, offset along +z by ~120mm). The
      // ray is the line through W_A and W_B, and its direction and any
      // point on it are well-defined.
      calStatus.textContent = `Capturing sample ${i} (plane A)…`;
      await tracker.setDisplayAreaCorners(origArea);
      await new Promise(r => setTimeout(r, 350)); // settle
      const captureMean = async (label: string): Promise<V3c | null> => {
        calStatus.textContent = `Capturing sample ${i} (${label})…`;
        const sum: V3c = { x: 0, y: 0, z: 0 };
        let n = 0;
        await new Promise<void>((resolve) => {
          const until = performance.now() + 900;
          const unsub = tracker!.subscribeToGaze((s) => {
            if (s.validity_L !== 0 || s.validity_R !== 0) return;
            if (!s.gaze_point_3d_L_mm || !s.gaze_point_3d_R_mm) return;
            sum.x += (s.gaze_point_3d_L_mm.x + s.gaze_point_3d_R_mm.x) * 0.5;
            sum.y += (s.gaze_point_3d_L_mm.y + s.gaze_point_3d_R_mm.y) * 0.5;
            sum.z += (s.gaze_point_3d_L_mm.z + s.gaze_point_3d_R_mm.z) * 0.5;
            n++;
            if (performance.now() >= until) { unsub(); resolve(); }
          });
          calCancel = () => { unsub(); resolve(); };
        });
        if (n < 8) return null;
        return { x: sum.x / n, y: sum.y / n, z: sum.z / n };
      };
      const Wa = await captureMean('plane A');
      if (cancelled) break;
      // Shift plane B by +shift mm along origArea's normal, chosen so
      // that B is *farther from the user* than A. The user sits on the
      // +z side of the tracker (eye_origin.z > 0 in our data), so the
      // screen is the side of the tracker plane with z < eye.z. We
      // push along the normal that has z < 0 relative to tl.
      const nrm = (() => {
        const ux = origArea.tr.x - origArea.tl.x, uy = origArea.tr.y - origArea.tl.y, uz = origArea.tr.z - origArea.tl.z;
        const vx = origArea.bl.x - origArea.tl.x, vy = origArea.bl.y - origArea.tl.y, vz = origArea.bl.z - origArea.tl.z;
        let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
        // Flip so normal points away-from-user (−z-ish).
        if (nz > 0) { nx = -nx; ny = -ny; nz = -nz; }
        const nl = Math.hypot(nx, ny, nz) || 1;
        return { x: nx / nl, y: ny / nl, z: nz / nl };
      })();
      const shift = 120;
      const planeB: DisplayArea = {
        tl: { x: origArea.tl.x + nrm.x * shift, y: origArea.tl.y + nrm.y * shift, z: origArea.tl.z + nrm.z * shift },
        tr: { x: origArea.tr.x + nrm.x * shift, y: origArea.tr.y + nrm.y * shift, z: origArea.tr.z + nrm.z * shift },
        bl: { x: origArea.bl.x + nrm.x * shift, y: origArea.bl.y + nrm.y * shift, z: origArea.bl.z + nrm.z * shift },
      };
      await tracker.setDisplayAreaCorners(planeB);
      await new Promise(r => setTimeout(r, 350));
      const Wb = await captureMean('plane B');
      if (cancelled) break;
      // Restore origArea for the next target.
      await tracker.setDisplayAreaCorners(origArea);
      if (!Wa || !Wb) {
        calStatus.textContent = 'Not enough samples — click again';
        calTarget.classList.remove('capturing');
        calTarget.style.display = 'none';
        calOverlay.classList.remove('capturing');
        i--;
        continue;
      }
      // Ray direction: from Wa to Wb (plane B is farther from the
      // user, so on the ray Wb lies beyond Wa in the user→screen
      // direction).
      const dx = Wb.x - Wa.x, dy = Wb.y - Wa.y, dz = Wb.z - Wa.z;
      const dl = Math.hypot(dx, dy, dz);
      if (dl < 1) {
        calStatus.textContent = 'Plane shift produced no ray — click again';
        calTarget.classList.remove('capturing');
        calTarget.style.display = 'none';
        calOverlay.classList.remove('capturing');
        i--;
        continue;
      }
      const d: V3c = { x: dx / dl, y: dy / dl, z: dz / dl };
      // Use Wa as the ray's anchor point. (The ray passes through both
      // Wa and Wb — any point on it works as "O" in the fitter.)
      capturedRays.push({ O: Wa, d });
      // In fullscreen the viewport fills the whole monitor, so the
      // cursor's viewport-normalized coords are already the
      // screen-normalized coords we need.
      capturedPts.push({ nx: tx, ny: ty });

      // Clear capture feedback, restore cursor.
      calTarget.classList.remove('capturing');
      calTarget.style.display = 'none';
      calOverlay.classList.remove('capturing');
    }

    if (cancelled) { calStatus.textContent = 'Cancelled'; return; }
    if (capturedPts.length < 5) { calStatus.textContent = 'Not enough samples (need 5)'; return; }

    const fit = fitDisplayAreaRays(capturedPts, capturedRays);
    if (!fit) { calStatus.textContent = 'Fit degenerate'; return; }

    // Debug: dump rays, fit, and original plane so we can see what the
    // solver is producing before sliders clamp it.
    console.log('[cal] origArea:', origArea);
    console.log('[cal] fit:', fit);
    for (let i = 0; i < capturedRays.length; i++) {
      const r = capturedRays[i]!, p = capturedPts[i]!;
      console.log(`[cal] ray ${i} target=(${p.nx},${p.ny})`,
        `Wa=(${r.O.x.toFixed(1)},${r.O.y.toFixed(1)},${r.O.z.toFixed(1)})`,
        `d=(${r.d.x.toFixed(3)},${r.d.y.toFixed(3)},${r.d.z.toFixed(3)})`);
    }

    // Compute residuals: distance from each ray to its target point on
    // the fitted plane. Better than closest-point-on-ray because it's
    // the quantity the device will actually render to the user.
    let rss = 0;
    for (let i = 0; i < capturedPts.length; i++) {
      const p = capturedPts[i]!, ray = capturedRays[i]!;
      const Tp = {
        x: fit.tl.x + p.nx * (fit.tr.x - fit.tl.x) + p.ny * (fit.bl.x - fit.tl.x),
        y: fit.tl.y + p.nx * (fit.tr.y - fit.tl.y) + p.ny * (fit.bl.y - fit.tl.y),
        z: fit.tl.z + p.nx * (fit.tr.z - fit.tl.z) + p.ny * (fit.bl.z - fit.tl.z),
      };
      // Closest-point-to-line distance: |(T − O) × d| (d is unit).
      const rx = Tp.x - ray.O.x, ry = Tp.y - ray.O.y, rz = Tp.z - ray.O.z;
      const cx = ry * ray.d.z - rz * ray.d.y;
      const cy = rz * ray.d.x - rx * ray.d.z;
      const cz = rx * ray.d.y - ry * ray.d.x;
      rss += cx * cx + cy * cy + cz * cz;
    }
    const rmse = Math.sqrt(rss / capturedPts.length);
    calStatus.textContent = `Calibrated · residual ${rmse.toFixed(1)} mm · applying…`;

    // The fit may violate the rectangular-plane constraint, so drop
    // lock-mode until the user re-enables it.
    if (daLock.checked) { daLock.checked = false; updateLockUi(); updateRectLockUi(); }
    setFormValues(fit);
    await tracker.setDisplayAreaCorners(fit);
    calStatus.textContent = `Calibrated · residual ${rmse.toFixed(1)} mm · done`;
    await new Promise(r => setTimeout(r, 800));
  } catch (e) {
    calStatus.textContent = `Error: ${e instanceof Error ? e.message : String(e)}`;
    await new Promise(r => setTimeout(r, 1500));
    try { await tracker.setDisplayAreaCorners(origArea); } catch { }
  } finally {
    window.removeEventListener('keydown', onKey);
    calOverlay.classList.remove('active', 'capturing');
    calOverlay.style.cursor = '';
    calTarget.style.display = '';
    calTarget.classList.remove('capturing');
    if (document.fullscreenElement) {
      try { await document.exitFullscreen(); } catch { }
    }
    calRunning = false;
    calCancel = null;
    daCal.disabled = false;
  }
}

// ────────── Onboard calibration (device-side model) ──────────────────
//
// Uses the device's built-in calibration pipeline: unlock realm →
// cal_add_point × N → cal_compute_and_apply → cal_retrieve. The device
// collects raw gaze samples during each cal_add_point call and uses them
// to fit its internal per-user gaze model. This complements the
// geometric display_area calibration above — display_area corrects
// *where* the screen is; onboard cal corrects *how* the device maps
// each user's eyes.

function makeCalGrid(n: 5 | 9 | 16): [number, number][] {
  const margin = 0.1;
  if (n === 5) {
    return [
      [0.5, 0.5],
      [margin, margin], [1 - margin, margin],
      [margin, 1 - margin], [1 - margin, 1 - margin],
    ];
  }
  if (n === 9) {
    const pts: [number, number][] = [[0.5, 0.5]];
    for (const y of [margin, 0.5, 1 - margin])
      for (const x of [margin, 0.5, 1 - margin])
        if (x !== 0.5 || y !== 0.5) pts.push([x, y]);
    return pts;
  }
  // 16: 4×4 grid
  const pts: [number, number][] = [[0.5, 0.5]];
  const steps = [margin, margin + (1 - 2 * margin) / 3, 1 - margin - (1 - 2 * margin) / 3, 1 - margin];
  for (const y of steps)
    for (const x of steps)
      if (x !== 0.5 || y !== 0.5) pts.push([x, y]);
  return pts;
}

async function runOnboardCalibration() {
  if (!tracker || calRunning) return;
  calRunning = true;
  daOnboardCal.disabled = true;
  daCal.disabled = true;

  try {
    if (!document.fullscreenElement) {
      await document.documentElement.requestFullscreen();
    }
  } catch (e) {
    calStatus.textContent = `Fullscreen failed: ${e instanceof Error ? e.message : String(e)}`;
    calRunning = false;
    daOnboardCal.disabled = false;
    daCal.disabled = false;
    return;
  }

  calOverlay.classList.add('active');
  calOverlay.style.cursor = 'crosshair';
  calTarget.style.display = 'none';
  collectTarget.style.display = 'none';
  onboardCalDot.style.display = 'none';
  let cancelled = false;
  const onKey = (e: KeyboardEvent) => {
    if (e.key === 'Escape') { cancelled = true; calCancel?.(); }
  };
  window.addEventListener('keydown', onKey);

  try {
    calStatus.textContent = 'Starting calibration…';
    await tracker.startCalibration();

    // Click-driven flow: user clicks to place each calibration point,
    // looks at the dot, device collects gaze, then user clicks for next.
    const pts = makeCalGrid(Number(daOnboardPts.value) as 5 | 9 | 16);
    const total = pts.length;
    for (let i = 0; i < total; i++) {
      if (cancelled) break;
      const [nx, ny] = pts[i]!;
      const px = nx * window.innerWidth;
      const py = ny * window.innerHeight;

      // Show the target dot and wait for user click to start collection.
      onboardCalDot.style.left = `${px}px`;
      onboardCalDot.style.top = `${py}px`;
      onboardCalDot.style.display = 'block';
      onboardCalDot.classList.remove('collecting');
      calStatus.textContent = `Point ${i + 1}/${total} — look at the dot, then click to capture · Esc to cancel`;

      // Wait for click or cancel.
      const clicked = await new Promise<boolean>((resolve) => {
        const onClick = () => { cleanup(); resolve(true); };
        const cancel = () => { cleanup(); resolve(false); };
        const cleanup = () => {
          calOverlay.removeEventListener('click', onClick);
          calCancel = null;
        };
        calOverlay.addEventListener('click', onClick, { once: true });
        calCancel = cancel;
      });
      if (cancelled || !clicked) break;

      // User clicked — hide cursor and start device-side gaze collection.
      calOverlay.style.cursor = 'none';
      onboardCalDot.classList.add('collecting');
      calStatus.textContent = `Point ${i + 1}/${total} — hold your gaze…`;

      try {
        await tracker.addCalibrationPoint(nx, ny);
      } catch (e) {
        console.warn(`addCalibrationPoint(${nx}, ${ny}) failed:`, e);
        calStatus.textContent = `Point ${i + 1} failed — ${e instanceof Error ? e.message : String(e)}`;
        await new Promise(r => setTimeout(r, 1500));
      }

      onboardCalDot.classList.remove('collecting');
      calOverlay.style.cursor = 'crosshair';
    }

    onboardCalDot.style.display = 'none';

    if (cancelled) {
      calStatus.textContent = 'Cancelled';
      return;
    }

    calStatus.textContent = 'Computing calibration…';
    const blob = await tracker.finishCalibration();
    const b64 = btoa(String.fromCharCode(...blob));
    localStorage.setItem('tobii_onboard_cal', b64);
    console.log(`[onboard-cal] stored ${blob.byteLength}B calibration blob`);

    calStatus.textContent = `Calibration complete · ${blob.byteLength} bytes stored`;
    await new Promise(r => setTimeout(r, 1500));

  } catch (e) {
    calStatus.textContent = `Error: ${e instanceof Error ? e.message : String(e)}`;
    console.error('[onboard-cal]', e);
    await new Promise(r => setTimeout(r, 2000));
  } finally {
    window.removeEventListener('keydown', onKey);
    calOverlay.classList.remove('active', 'capturing');
    calOverlay.style.cursor = '';
    onboardCalDot.style.display = 'none';
    onboardCalDot.classList.remove('collecting');
    if (document.fullscreenElement) {
      try { await document.exitFullscreen(); } catch { }
    }
    calRunning = false;
    calCancel = null;
    daOnboardCal.disabled = false;
    daCal.disabled = false;
  }
}

daOnboardCal.addEventListener('click', () => { void runOnboardCalibration(); });
daCal.addEventListener('click', () => { void runCalibration(); });
daCollect.addEventListener('click', () => { void runSampleCollection(); });
daCollect2.addEventListener('click', () => { void runSampleCollection2Plane(); });
daLoad.addEventListener('click', () => {
  const input = document.createElement('input');
  input.type = 'file';
  input.accept = '.json';
  input.addEventListener('change', async () => {
    const file = input.files?.[0];
    if (!file) return;
    try {
      const text = await file.text();
      const data = JSON.parse(text) as CollectedDataset2;
      if (data.version !== 2 || !Array.isArray(data.samples)) {
        diagOut.textContent = 'Not a v2 two-plane sample file.';
        return;
      }
      const fit = fitFromTwoPlaneSamples(data.samples, data.plane_A, data.plane_B);
      if (!fit) {
        diagOut.textContent = `Fit failed from ${file.name} (not enough valid samples).`;
        return;
      }
      const summary =
        `${file.name}: ${fit.width_mm.toFixed(0)}×${fit.height_mm.toFixed(0)}mm · ` +
        `angle=${fit.uv_angle_deg.toFixed(1)}° · affine RMSE A=${(fit.rmseA * 1000).toFixed(0)} B=${(fit.rmseB * 1000).toFixed(0)} · ` +
        `n=${fit.nA}/${fit.nB}`;
      console.log('[load fit]', fit);
      diagOut.textContent = summary;
      const apply = window.confirm(
        `${summary}\n\nApply this display_area?\n\n` +
        `tl=(${fit.area.tl.x.toFixed(0)}, ${fit.area.tl.y.toFixed(0)}, ${fit.area.tl.z.toFixed(0)})\n` +
        `tr=(${fit.area.tr.x.toFixed(0)}, ${fit.area.tr.y.toFixed(0)}, ${fit.area.tr.z.toFixed(0)})\n` +
        `bl=(${fit.area.bl.x.toFixed(0)}, ${fit.area.bl.y.toFixed(0)}, ${fit.area.bl.z.toFixed(0)})`,
      );
      if (apply && tracker) {
        await tracker.setDisplayAreaCorners(fit.area);
        setFormValues(fit.area);
        diagOut.textContent = `Applied. ${summary}`;
      }
    } catch (e) {
      diagOut.textContent = `Load failed: ${e instanceof Error ? e.message : String(e)}`;
    }
  });
  input.click();
});
daWinPerm.addEventListener('click', () => { void requestScreenDetails(); });
daFs.addEventListener('click', async () => {
  try {
    if (document.fullscreenElement) await document.exitFullscreen();
    else await document.documentElement.requestFullscreen();
  } catch (e) {
    console.warn('fullscreen toggle failed:', e);
  }
});
document.addEventListener('fullscreenchange', () => {
  daFs.textContent = document.fullscreenElement ? 'Exit fullscreen' : 'Fullscreen';
  pushViewportRect();
});

connectBtn.onclick = connect;

// Auto-connect if the user has previously authorised an ET5. Browsers
// persist the grant across reloads, and `getDevices()` returns it
// without requiring a user gesture (unlike `requestDevice()`).
async function tryAutoConnect() {
  if (transportSel.value !== 'usb') return;
  if (typeof navigator === 'undefined' || !('usb' in navigator)) return;
  try {
    const devices = await navigator.usb.getDevices();
    const dev = devices.find(d => d.vendorId === 0x2104 && d.productId === 0x0313);
    if (dev) await connectWithDevice(dev);
  } catch (e) {
    console.warn('auto-connect failed', e);
  }
}

// React to hotplug events for already-authorised devices.
if (typeof navigator !== 'undefined' && 'usb' in navigator) {
  navigator.usb.addEventListener('connect', (e) => {
    const dev = (e as USBConnectionEvent).device;
    if (tracker || transportSel.value !== 'usb') return;
    if (dev.vendorId === 0x2104 && dev.productId === 0x0313) {
      void connectWithDevice(dev);
    }
  });
  navigator.usb.addEventListener('disconnect', (e) => {
    const dev = (e as USBConnectionEvent).device;
    if (!tracker) return;
    if (dev.vendorId === 0x2104 && dev.productId === 0x0313) {
      void disconnect();
    }
  });
}

void tryAutoConnect();
