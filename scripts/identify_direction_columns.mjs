#!/usr/bin/env node
// Identify the nature of gaze_direction columns 0x03/0x09 and 0x25/0x27.
//
// Collects live samples and tests multiple hypotheses:
//
// H1: 0x03/0x09 are gaze rays (O + k·d = gaze_point_3d)?
// H2: 0x25/0x27 are gaze rays in display-space (O_disp + k·d = gaze_point_3d)?
// H3: 0x03/0x09 = 0x25/0x27 (identical, just a copy)?
// H4: 0x25/0x27 = rotation of 0x03/0x09 (display-area tilt rotation)?
// H5: Either set is the negation of the other?
// H6: Either set, negated, gives a valid gaze ray?
// H7: The vectors respond to gaze shifts (correlation with gaze_point_2d)?
// H8: The vectors respond to head translation (correlation with eye_origin)?
//
// Usage: node scripts/identify_direction_columns.mjs
//   — keep head still for first 3s, then move gaze around for 5s,
//     then move head around for 5s.

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');

const TOBII_VID = 0x2104;
const TOBII_PID_RUNTIME = 0x0313;
const EP_IN = 3;
const EP_OUT = 5;

const { WebUSB } = await import('usb');
const webusb = new WebUSB({ allowAllDevices: true });
const devices = await webusb.getDevices();
const device = devices.find(d => d.vendorId === TOBII_VID && d.productId === TOBII_PID_RUNTIME);
if (!device) { console.error('ET5 not found'); process.exit(1); }

await device.open();
if (device.configuration === null) await device.selectConfiguration(1);
try { await device.claimInterface(0); } catch (e) {
  console.error(`Cannot claim USB interface: ${e.message}`); process.exit(1);
}
await device.controlTransferOut({
  requestType: 'vendor', recipient: 'interface',
  request: 0x41, value: 0, index: 0,
});

async function usbSend(bytes) {
  const buf = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buf).set(bytes);
  await device.transferOut(EP_OUT, buf);
}

// ─── WASM ────────────────────────────────────────────────────────────

const wasmPath = resolve(root, 'driver/zig-out/bin/tobiifree_core.wasm');
const wasmBytes = await readFile(wasmPath);
const pending = new Map();

let currentFrame = {};
const frames = [];

const { instance } = await WebAssembly.instantiate(wasmBytes, {
  env: {
    on_ttp_frame: () => {},
    on_response: (requestId, pptr, plen) => {
      const data = new Uint8Array(instance.exports.memory.buffer, pptr, plen).slice();
      const r = pending.get(requestId);
      if (r) { pending.delete(requestId); clearTimeout(r.timer); r.resolve(data); }
    },
    on_gaze: () => {
      if (Object.keys(currentFrame).length > 0) {
        frames.push({ ...currentFrame, t: Date.now() });
      }
      currentFrame = {};
    },
    on_raw_columns: (ptr, n) => {
      const view = new DataView(instance.exports.memory.buffer, ptr, n * 32);
      for (let i = 0; i < n; i++) {
        const off = i * 32;
        const colId = view.getUint32(off, true);
        const v0 = view.getFloat64(off + 8, true);
        const v1 = view.getFloat64(off + 16, true);
        const v2 = view.getFloat64(off + 24, true);
        currentFrame[colId] = { v0, v1, v2 };
      }
    },
    on_parse_error: (code) => { console.error(`parse error: 0x${code.toString(16)}`); },
  },
});

const exp = instance.exports;
exp.session_reset();
const currentPages = exp.memory.buffer.byteLength / 65536;
exp.memory.grow(2);
const IN_BUF_PTR = currentPages * 65536;
const sessionOutPtr = exp.session_out_ptr();

function takeOutBytes() {
  const n = exp.session_out_len_();
  return new Uint8Array(exp.memory.buffer, sessionOutPtr, n).slice();
}

function awaitResponse(requestId, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(requestId); reject(new Error('timeout')); }, timeoutMs);
    pending.set(requestId, { resolve, reject, timer });
  });
}

const abortCtl = new AbortController();
(async () => {
  while (!abortCtl.signal.aborted) {
    let r;
    try { r = await device.transferIn(EP_IN, 16384); }
    catch { if (abortCtl.signal.aborted) return; throw new Error('pump'); }
    if (abortCtl.signal.aborted) return;
    const chunk = new Uint8Array(r.data.buffer, r.data.byteOffset, r.data.byteLength);
    new Uint8Array(exp.memory.buffer, IN_BUF_PTR, chunk.byteLength).set(chunk);
    exp.feed_usb_in(IN_BUF_PTR, chunk.byteLength);
  }
})().catch(e => { if (!abortCtl.signal.aborted) console.error('pump:', e); });

// Hello
{ const id = exp.request_hello(); const w = awaitResponse(id); await usbSend(takeOutBytes()); await w; }

// Set a known display area — tilted screen, typical ET5 setup.
// 600×340mm, bottom at tracker height, top tilted 20mm back.
console.log('Setting display area (600×340mm, tilted)...');
{
  // request_set_display_area(w, h, center_x, center_y_bottom_edge, z_front)
  // We want: bl=(-300, 0, 0), tr=(300, 340, -20), tl=(-300, 340, -20)
  // The wasm API takes (w_mm, h_mm, cx, cy_bottom, z_front):
  //   tl = (cx - w/2, cy_bottom + h, z_front - tilt)
  //   bl = (cx - w/2, cy_bottom, z_front)
  // But let's just use a plausible config. The exact values don't matter
  // for identifying column semantics; we just need valid gaze output.
  exp.request_set_display_area(600, 340, 0, 0, 0);
  await usbSend(takeOutBytes());
}

// Enable raw columns + subscribe
exp.raw_columns_enable(1);
exp.request_subscribe(0x500);
await usbSend(takeOutBytes());

console.log('Warming up (2s)...');
await new Promise(r => setTimeout(r, 2000));
frames.length = 0; // discard warmup

console.log('\n=== COLLECTING (8s) — move your gaze around, then move your head ===\n');
const collectStart = Date.now();
await new Promise(r => setTimeout(r, 8000));

console.log(`Collected ${frames.length} frames.\n`);

// ─── Filter valid frames with all required columns ───────────────────

const valid = frames.filter(f =>
  f[0x07]?.v0 === 0 &&   // validity_L = valid
  f[0x0d]?.v0 === 0 &&   // validity_R = valid
  f[0x02] && f[0x08] &&  // eye origins (tracker-space)
  f[0x03] && f[0x09] &&  // gaze dir (tracker-space)
  f[0x04] && f[0x0a] &&  // gaze_point_3d
  f[0x1c]                 // gaze_point_2d_norm
);

const hasDisplay = valid.filter(f => f[0x22] && f[0x24] && f[0x25] && f[0x27]);
console.log(`Valid frames: ${valid.length} (${hasDisplay.length} with display-space columns)\n`);

if (valid.length < 10) {
  console.log('Not enough valid frames. Ensure tracker can see both eyes.');
  abortCtl.abort();
  try { await device.close(); } catch {}
  process.exit(1);
}

// ─── Helpers ─────────────────────────────────────────────────────────

function v3(f, col) { return [f[col].v0, f[col].v1, f[col].v2]; }
function v2(f, col) { return [f[col].v0, f[col].v1]; }
function dot(a, b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
function sub(a, b) { return [a[0]-b[0], a[1]-b[1], a[2]-b[2]]; }
function add(a, b) { return [a[0]+b[0], a[1]+b[1], a[2]+b[2]]; }
function scale(a, s) { return [a[0]*s, a[1]*s, a[2]*s]; }
function norm(a) { return Math.hypot(...a); }
function normalize(a) { const l = norm(a); return l > 0 ? scale(a, 1/l) : a; }
function cross(a, b) { return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]; }

function mean(arr) { return arr.reduce((a,b)=>a+b,0)/arr.length; }
function std(arr) { const m = mean(arr); return Math.sqrt(arr.reduce((a,b)=>a+(b-m)**2,0)/arr.length); }
function corrcoef(xs, ys) {
  const mx = mean(xs), my = mean(ys);
  let sxy = 0, sxx = 0, syy = 0;
  for (let i = 0; i < xs.length; i++) {
    const dx = xs[i] - mx, dy = ys[i] - my;
    sxy += dx*dy; sxx += dx*dx; syy += dy*dy;
  }
  return sxy / Math.sqrt(sxx * syy + 1e-30);
}

function rmse(errs) { return Math.sqrt(errs.reduce((a,b)=>a+b*b,0)/errs.length); }

// ─── Print first 3 frames for visual inspection ─────────────────────

console.log('=== SAMPLE FRAMES (first 3 valid) ===\n');
for (let i = 0; i < Math.min(3, valid.length); i++) {
  const f = valid[i];
  const cols = {
    'eye_origin_L (0x02)':    v3(f, 0x02),
    'eye_origin_R (0x08)':    v3(f, 0x08),
    'gaze_dir_L   (0x03)':    v3(f, 0x03),
    'gaze_dir_R   (0x09)':    v3(f, 0x09),
    'gaze_3d_L    (0x04)':    v3(f, 0x04),
    'gaze_3d_R    (0x0a)':    v3(f, 0x0a),
    'gaze_2d_norm (0x1c)':    v2(f, 0x1c),
  };
  if (f[0x22]) cols['eye_origin_L_disp (0x22)'] = v3(f, 0x22);
  if (f[0x24]) cols['eye_origin_R_disp (0x24)'] = v3(f, 0x24);
  if (f[0x25]) cols['gaze_dir_25'] = v3(f, 0x25);
  if (f[0x27]) cols['gaze_dir_27'] = v3(f, 0x27);

  console.log(`Frame ${i}:`);
  for (const [k, v] of Object.entries(cols)) {
    console.log(`  ${k.padEnd(30)} = (${v.map(x => x.toFixed(4)).join(', ')})`);
  }
  console.log();
}

// ─── H1: O_tracker + k·d_03 = gaze_point_3d? ───────────────────────

console.log('=== H1: Does eye_origin(0x02) + k·dir(0x03) = gaze_point_3d(0x04)? ===\n');
{
  const ks = [], resids = [];
  for (const f of valid) {
    const O = v3(f, 0x02), d = v3(f, 0x03), W = v3(f, 0x04);
    // Solve k from z: k = (W.z - O.z) / d.z
    if (Math.abs(d[2]) < 1e-9) continue;
    const k = (W[2] - O[2]) / d[2];
    const pred = add(O, scale(d, k));
    const err = norm(sub(pred, W));
    ks.push(k);
    resids.push(err);
  }
  console.log(`  k (from z): mean=${mean(ks).toFixed(1)}  std=${std(ks).toFixed(1)}  range=[${Math.min(...ks).toFixed(1)}, ${Math.max(...ks).toFixed(1)}]`);
  console.log(`  xy residual: mean=${mean(resids).toFixed(1)}mm  rmse=${rmse(resids).toFixed(1)}mm`);
  console.log(`  → ${rmse(resids) < 5 ? 'CONSISTENT (gaze ray)' : 'NOT a gaze ray'}\n`);
}

// ─── H1b: Same with negated direction ────────────────────────────────

console.log('=== H1b: Does O(0x02) + k·(-dir(0x03)) = gaze_point_3d(0x04)? ===\n');
{
  const ks = [], resids = [];
  for (const f of valid) {
    const O = v3(f, 0x02), d = scale(v3(f, 0x03), -1), W = v3(f, 0x04);
    if (Math.abs(d[2]) < 1e-9) continue;
    const k = (W[2] - O[2]) / d[2];
    const pred = add(O, scale(d, k));
    const err = norm(sub(pred, W));
    ks.push(k);
    resids.push(err);
  }
  console.log(`  k (from z): mean=${mean(ks).toFixed(1)}  std=${std(ks).toFixed(1)}`);
  console.log(`  xy residual: rmse=${rmse(resids).toFixed(1)}mm`);
  console.log(`  → ${rmse(resids) < 5 ? 'CONSISTENT (negated gaze ray)' : 'NOT a negated gaze ray'}\n`);
}

// ─── H2: O_display + k·d_25 = gaze_point_3d? ───────────────────────

if (hasDisplay.length > 10) {
  console.log('=== H2: Does eye_origin_disp(0x22) + k·dir(0x25) = gaze_point_3d(0x04)? ===\n');
  {
    const ks = [], resids = [];
    for (const f of hasDisplay) {
      const O = v3(f, 0x22), d = v3(f, 0x25), W = v3(f, 0x04);
      if (Math.abs(d[2]) < 1e-9) continue;
      const k = (W[2] - O[2]) / d[2];
      const pred = add(O, scale(d, k));
      const err = norm(sub(pred, W));
      ks.push(k);
      resids.push(err);
    }
    console.log(`  k (from z): mean=${mean(ks).toFixed(1)}  std=${std(ks).toFixed(1)}`);
    console.log(`  xy residual: rmse=${rmse(resids).toFixed(1)}mm`);
    console.log(`  → ${rmse(resids) < 5 ? 'CONSISTENT' : 'NOT matching'}\n`);
  }

  console.log('=== H2b: Does O_disp(0x22) + k·(-dir(0x25)) = gaze_point_3d(0x04)? ===\n');
  {
    const ks = [], resids = [];
    for (const f of hasDisplay) {
      const O = v3(f, 0x22), d = scale(v3(f, 0x25), -1), W = v3(f, 0x04);
      if (Math.abs(d[2]) < 1e-9) continue;
      const k = (W[2] - O[2]) / d[2];
      const pred = add(O, scale(d, k));
      const err = norm(sub(pred, W));
      ks.push(k);
      resids.push(err);
    }
    console.log(`  k (from z): mean=${mean(ks).toFixed(1)}  std=${std(ks).toFixed(1)}`);
    console.log(`  xy residual: rmse=${rmse(resids).toFixed(1)}mm`);
    console.log(`  → ${rmse(resids) < 5 ? 'CONSISTENT' : 'NOT matching'}\n`);
  }
}

// ─── H3: Are 0x03 and 0x25 identical? ───────────────────────────────

if (hasDisplay.length > 10) {
  console.log('=== H3: Are dir(0x03) and dir(0x25) identical? ===\n');
  const diffs = hasDisplay.map(f => norm(sub(v3(f, 0x03), v3(f, 0x25))));
  console.log(`  |d03 - d25|: mean=${mean(diffs).toFixed(6)}  max=${Math.max(...diffs).toFixed(6)}`);
  console.log(`  → ${Math.max(...diffs) < 1e-9 ? 'IDENTICAL' : 'DIFFERENT'}\n`);

  // Same for right eye
  const diffsR = hasDisplay.map(f => norm(sub(v3(f, 0x09), v3(f, 0x27))));
  console.log(`  |d09 - d27|: mean=${mean(diffsR).toFixed(6)}  max=${Math.max(...diffsR).toFixed(6)}`);
  console.log(`  → ${Math.max(...diffsR) < 1e-9 ? 'IDENTICAL' : 'DIFFERENT'}\n`);
}

// ─── H4: Is 0x25 a rotation of 0x03? ────────────────────────────────

if (hasDisplay.length > 10) {
  console.log('=== H4: Is dir(0x25) a rotation of dir(0x03)? ===\n');

  // Check if the angle between 0x03 and 0x25 is constant across frames
  const angles = hasDisplay.map(f => {
    const a = v3(f, 0x03), b = v3(f, 0x25);
    const d = dot(a, b) / (norm(a) * norm(b));
    return Math.acos(Math.min(1, Math.max(-1, d))) * 180 / Math.PI;
  });
  console.log(`  angle(d03, d25): mean=${mean(angles).toFixed(3)}°  std=${std(angles).toFixed(3)}°  range=[${Math.min(...angles).toFixed(3)}, ${Math.max(...angles).toFixed(3)}]`);
  console.log(`  → ${std(angles) < 0.1 ? 'CONSISTENT rotation (constant angle)' : 'NOT a simple rotation (angle varies)'}\n`);

  // Try to find the rotation axis by averaging cross products
  const axes = hasDisplay.map(f => {
    const a = normalize(v3(f, 0x03)), b = normalize(v3(f, 0x25));
    return normalize(cross(a, b));
  });
  const avgAxis = normalize([mean(axes.map(a=>a[0])), mean(axes.map(a=>a[1])), mean(axes.map(a=>a[2]))]);
  console.log(`  estimated rotation axis: (${avgAxis.map(x=>x.toFixed(4)).join(', ')})`);

  // Check axis consistency
  const axisDots = axes.map(a => Math.abs(dot(a, avgAxis)));
  console.log(`  axis consistency (|dot with mean|): mean=${mean(axisDots).toFixed(4)}  min=${Math.min(...axisDots).toFixed(4)}`);
  console.log();
}

// ─── H5: Is one the negation of the other? ──────────────────────────

if (hasDisplay.length > 10) {
  console.log('=== H5: Is dir(0x25) = -dir(0x03)? ===\n');
  const diffs = hasDisplay.map(f => norm(add(v3(f, 0x03), v3(f, 0x25))));
  console.log(`  |d03 + d25|: mean=${mean(diffs).toFixed(6)}  max=${Math.max(...diffs).toFixed(6)}`);
  console.log(`  → ${Math.max(...diffs) < 1e-6 ? 'YES, they are negations' : 'NO'}\n`);
}

// ─── H6: Relationship between tracker-space and display-space origins ─

if (hasDisplay.length > 10) {
  console.log('=== H6: How do tracker-space and display-space origins differ? ===\n');
  const dL = hasDisplay.map(f => sub(v3(f, 0x02), v3(f, 0x22)));
  const dR = hasDisplay.map(f => sub(v3(f, 0x08), v3(f, 0x24)));
  console.log(`  O_tracker_L - O_disp_L:`);
  console.log(`    x: mean=${mean(dL.map(d=>d[0])).toFixed(2)}  std=${std(dL.map(d=>d[0])).toFixed(4)}`);
  console.log(`    y: mean=${mean(dL.map(d=>d[1])).toFixed(2)}  std=${std(dL.map(d=>d[1])).toFixed(4)}`);
  console.log(`    z: mean=${mean(dL.map(d=>d[2])).toFixed(2)}  std=${std(dL.map(d=>d[2])).toFixed(4)}`);
  const isConstant = std(dL.map(d=>d[0])) < 0.01 && std(dL.map(d=>d[1])) < 0.01 && std(dL.map(d=>d[2])) < 0.01;
  console.log(`    → ${isConstant ? 'CONSTANT offset (pure translation)' : 'VARIABLE (rotation + translation?)'}`);

  // Check if O_disp is O_tracker rotated around some axis
  // If it's a rotation, |O_disp| ≠ |O_tracker| + const, but angles differ
  const anglesO = hasDisplay.map(f => {
    const a = v3(f, 0x02), b = v3(f, 0x22);
    const d = dot(a, b) / (norm(a) * norm(b));
    return Math.acos(Math.min(1, Math.max(-1, d))) * 180 / Math.PI;
  });
  console.log(`    angle(O_tracker, O_disp): mean=${mean(anglesO).toFixed(3)}°  std=${std(anglesO).toFixed(3)}°`);
  console.log();
}

// ─── H7: Correlation with gaze (does direction track where you look?) ─

console.log('=== H7: Does direction correlate with gaze_point_2d (tracks where you look)? ===\n');
{
  const gx = valid.map(f => f[0x1c].v0);
  const gy = valid.map(f => f[0x1c].v1);
  const d03x = valid.map(f => f[0x03].v0);
  const d03y = valid.map(f => f[0x03].v1);
  const d03z = valid.map(f => f[0x03].v2);
  console.log('  corr(dir_03.x, gaze_2d.x) = ' + corrcoef(d03x, gx).toFixed(4));
  console.log('  corr(dir_03.y, gaze_2d.y) = ' + corrcoef(d03y, gy).toFixed(4));
  console.log('  corr(dir_03.z, gaze_2d.x) = ' + corrcoef(d03z, gx).toFixed(4));
  console.log('  corr(dir_03.z, gaze_2d.y) = ' + corrcoef(d03z, gy).toFixed(4));
  console.log();

  if (hasDisplay.length > 10) {
    const d25x = hasDisplay.map(f => f[0x25].v0);
    const d25y = hasDisplay.map(f => f[0x25].v1);
    const d25z = hasDisplay.map(f => f[0x25].v2);
    const gx2 = hasDisplay.map(f => f[0x1c].v0);
    const gy2 = hasDisplay.map(f => f[0x1c].v1);
    console.log('  corr(dir_25.x, gaze_2d.x) = ' + corrcoef(d25x, gx2).toFixed(4));
    console.log('  corr(dir_25.y, gaze_2d.y) = ' + corrcoef(d25y, gy2).toFixed(4));
    console.log('  corr(dir_25.z, gaze_2d.x) = ' + corrcoef(d25z, gx2).toFixed(4));
    console.log('  corr(dir_25.z, gaze_2d.y) = ' + corrcoef(d25z, gy2).toFixed(4));
    console.log();
  }
}

// ─── H8: Correlation with eye origin (tracks head movement?) ────────

console.log('=== H8: Does direction correlate with eye_origin (tracks head pose)? ===\n');
{
  const ox = valid.map(f => f[0x02].v0);
  const oy = valid.map(f => f[0x02].v1);
  const oz = valid.map(f => f[0x02].v2);
  const d03x = valid.map(f => f[0x03].v0);
  const d03y = valid.map(f => f[0x03].v1);
  const d03z = valid.map(f => f[0x03].v2);
  console.log('  corr(dir_03.x, origin.x) = ' + corrcoef(d03x, ox).toFixed(4));
  console.log('  corr(dir_03.y, origin.y) = ' + corrcoef(d03y, oy).toFixed(4));
  console.log('  corr(dir_03.z, origin.z) = ' + corrcoef(d03z, oz).toFixed(4));
  console.log();
}

// ─── H9: Best-fit ray test — closest approach to gaze_point_3d ──────

console.log('=== H9: Closest approach of ray(O, dir) to gaze_point_3d ===\n');
{
  // For each (O, d, W), compute the closest point on line O+t*d to W
  // dist = |cross(W-O, d)| / |d|
  for (const [label, originCol, dirCol] of [
    ['O(0x02) + t·d(0x03)', 0x02, 0x03],
    ['O(0x02) + t·(-d(0x03))', 0x02, 0x03],
  ]) {
    const dists = [], ts = [];
    const neg = label.includes('-d');
    for (const f of valid) {
      const O = v3(f, originCol);
      let d = v3(f, dirCol);
      if (neg) d = scale(d, -1);
      const W = v3(f, 0x04);
      const OW = sub(W, O);
      const cr = cross(OW, d);
      const dist = norm(cr) / norm(d);
      const t = dot(OW, d) / dot(d, d);
      dists.push(dist);
      ts.push(t);
    }
    console.log(`  ${label}:`);
    console.log(`    closest dist: mean=${mean(dists).toFixed(1)}mm  rmse=${rmse(dists).toFixed(1)}mm`);
    console.log(`    t parameter:  mean=${mean(ts).toFixed(1)}  std=${std(ts).toFixed(1)}`);
    console.log();
  }

  if (hasDisplay.length > 10) {
    for (const [label, originCol, dirCol] of [
      ['O_disp(0x22) + t·d(0x25)', 0x22, 0x25],
      ['O_disp(0x22) + t·(-d(0x25))', 0x22, 0x25],
    ]) {
      const dists = [], ts = [];
      const neg = label.includes('-d');
      for (const f of hasDisplay) {
        const O = v3(f, originCol);
        let d = v3(f, dirCol);
        if (neg) d = scale(d, -1);
        const W = v3(f, 0x04);
        const OW = sub(W, O);
        const cr = cross(OW, d);
        const dist = norm(cr) / norm(d);
        const t = dot(OW, d) / dot(d, d);
        dists.push(dist);
        ts.push(t);
      }
      console.log(`  ${label}:`);
      console.log(`    closest dist: mean=${mean(dists).toFixed(1)}mm  rmse=${rmse(dists).toFixed(1)}mm`);
      console.log(`    t parameter:  mean=${mean(ts).toFixed(1)}  std=${std(ts).toFixed(1)}`);
      console.log();
    }
  }
}

// ─── H10: Variance analysis — what changes more, gaze or head? ──────

console.log('=== H10: Variance analysis — what drives direction changes? ===\n');
{
  const d03x = valid.map(f => f[0x03].v0);
  const d03y = valid.map(f => f[0x03].v1);
  const d03z = valid.map(f => f[0x03].v2);
  const ox = valid.map(f => f[0x02].v0);
  const oy = valid.map(f => f[0x02].v1);
  const gx = valid.map(f => f[0x1c].v0);
  const gy = valid.map(f => f[0x1c].v1);
  console.log(`  std(dir_03.x)=${std(d03x).toFixed(6)}  std(dir_03.y)=${std(d03y).toFixed(6)}  std(dir_03.z)=${std(d03z).toFixed(6)}`);
  console.log(`  std(origin.x)=${std(ox).toFixed(2)}mm  std(origin.y)=${std(oy).toFixed(2)}mm`);
  console.log(`  std(gaze_2d.x)=${std(gx).toFixed(4)}  std(gaze_2d.y)=${std(gy).toFixed(4)}`);
  console.log(`  → If dir has low variance vs gaze_2d, it's not tracking gaze`);
  console.log();
}

// ─── H11: Unit vector check ─────────────────────────────────────────

console.log('=== H11: Are they unit vectors? ===\n');
{
  const norms03 = valid.map(f => norm(v3(f, 0x03)));
  console.log(`  |dir(0x03)|: mean=${mean(norms03).toFixed(6)}  range=[${Math.min(...norms03).toFixed(6)}, ${Math.max(...norms03).toFixed(6)}]`);
  if (hasDisplay.length > 10) {
    const norms25 = hasDisplay.map(f => norm(v3(f, 0x25)));
    console.log(`  |dir(0x25)|: mean=${mean(norms25).toFixed(6)}  range=[${Math.min(...norms25).toFixed(6)}, ${Math.max(...norms25).toFixed(6)}]`);
  }
  console.log();
}

// ─── H12: Direction sign — which way does it point? ─────────────────

console.log('=== H12: Direction sign — which way does each component point? ===\n');
{
  const d03 = valid.map(f => v3(f, 0x03));
  console.log(`  dir(0x03) L mean: (${mean(d03.map(d=>d[0])).toFixed(4)}, ${mean(d03.map(d=>d[1])).toFixed(4)}, ${mean(d03.map(d=>d[2])).toFixed(4)})`);
  const d09 = valid.map(f => v3(f, 0x09));
  console.log(`  dir(0x09) R mean: (${mean(d09.map(d=>d[0])).toFixed(4)}, ${mean(d09.map(d=>d[1])).toFixed(4)}, ${mean(d09.map(d=>d[2])).toFixed(4)})`);

  if (hasDisplay.length > 10) {
    const d25 = hasDisplay.map(f => v3(f, 0x25));
    console.log(`  dir(0x25) L mean: (${mean(d25.map(d=>d[0])).toFixed(4)}, ${mean(d25.map(d=>d[1])).toFixed(4)}, ${mean(d25.map(d=>d[2])).toFixed(4)})`);
    const d27 = hasDisplay.map(f => v3(f, 0x27));
    console.log(`  dir(0x27) R mean: (${mean(d27.map(d=>d[0])).toFixed(4)}, ${mean(d27.map(d=>d[1])).toFixed(4)}, ${mean(d27.map(d=>d[2])).toFixed(4)})`);
  }

  // Compare with eye→gaze_point direction
  const trueDir = valid.map(f => normalize(sub(v3(f, 0x04), v3(f, 0x02))));
  console.log(`\n  true ray (normalize(W-O)) L mean: (${mean(trueDir.map(d=>d[0])).toFixed(4)}, ${mean(trueDir.map(d=>d[1])).toFixed(4)}, ${mean(trueDir.map(d=>d[2])).toFixed(4)})`);

  // Dot product between dir(0x03) and true ray
  const dots03 = valid.map((f, i) => dot(v3(f, 0x03), trueDir[i]));
  console.log(`  dot(dir_03, true_ray): mean=${mean(dots03).toFixed(4)}  std=${std(dots03).toFixed(4)}`);
  console.log(`  → ${mean(dots03) > 0.9 ? 'ALIGNED' : mean(dots03) < -0.9 ? 'ANTI-ALIGNED (reversed)' : 'POORLY aligned'}`);
  console.log();
}

// ─── Done ────────────────────────────────────────────────────────────

abortCtl.abort();
try { await device.close(); } catch {};
console.log('Done.');
process.exit(0);
