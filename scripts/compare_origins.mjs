#!/usr/bin/env node
// Compare "primary" vs "dup" eye origins and gaze directions to determine
// whether the dup columns are raw/uncalibrated values.
//
// Collects N frames and prints per-frame deltas between:
//   0x02 (eye_origin_L) vs 0x17 (eye_origin_L_dup)
//   0x08 (eye_origin_R) vs 0x18 (eye_origin_R_dup)
//   0x03 (gaze_dir_L)   vs 0x25 (gaze_dir_25)
//   0x09 (gaze_dir_R)   vs 0x27 (gaze_dir_27)
//
// If the "dup" is pre-calibration, the delta should be nonzero and
// systematic (calibration correction). If they're just copies, delta ≈ 0.
//
// Also compares tracker-space vs display-space origins:
//   0x02 vs 0x22, 0x08 vs 0x24

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

// Per-frame raw column snapshot
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
      // Snapshot the current frame's columns
      if (Object.keys(currentFrame).length > 0) {
        frames.push({ ...currentFrame });
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

// Set a reasonable display area — tracker won't produce valid gaze without one.
// 400×300mm, centered, 100mm in front.
console.log('Setting display area (400×300mm)...');
{
  exp.request_set_display_area(400, 300, -200, -150, 100);
  await usbSend(takeOutBytes());
}

// Enable raw columns + subscribe
exp.raw_columns_enable(1);
exp.request_subscribe(0x500);
await usbSend(takeOutBytes());

// Give the tracker time to warm up after connection
console.log('Waiting 2s for tracker to warm up...');
await new Promise(r => setTimeout(r, 2000));

console.log('Collecting 5s of gaze — keep your head still, look at a fixed point...\n');
await new Promise(r => setTimeout(r, 5000));

console.log(`Collected ${frames.length} frames.\n`);

// ─── Analysis ────────────────────────────────────────────────────────

// Diagnostic: show validity distribution
const valLCounts = {};
const valRCounts = {};
for (const f of frames) {
  const vl = f[0x07]?.v0 ?? -1;
  const vr = f[0x0d]?.v0 ?? -1;
  valLCounts[vl] = (valLCounts[vl] || 0) + 1;
  valRCounts[vr] = (valRCounts[vr] || 0) + 1;
}
console.log('Validity distribution:');
console.log('  Left  (0x07):', valLCounts);
console.log('  Right (0x0d):', valRCounts);

// Print a sample invalid frame to see what data looks like
const sampleFrame = frames[Math.floor(frames.length / 2)];
if (sampleFrame) {
  console.log('\nSample frame (mid-collection):');
  for (const [id, v] of Object.entries(sampleFrame).sort((a, b) => Number(a[0]) - Number(b[0]))) {
    const hex = `0x${Number(id).toString(16).padStart(2, '0')}`;
    console.log(`  ${hex}: (${v.v0.toFixed(4)}, ${v.v1.toFixed(4)}, ${v.v2.toFixed(4)})`);
  }
}
console.log();

// Accept frames where at least one eye is valid
const validL = frames.filter(f => f[0x07]?.v0 === 0 && f[0x02] && f[0x17]);
const validR = frames.filter(f => f[0x0d]?.v0 === 0 && f[0x08] && f[0x18]);
const valid = validL.length >= validR.length ? validL : validR;
const whichEye = validL.length >= validR.length ? 'left' : 'right';
console.log(`Valid left-eye frames: ${validL.length}, right-eye: ${validR.length}`);
console.log(`Using ${whichEye} eye (${valid.length} frames)\n`);

if (valid.length === 0) {
  console.log('No valid frames. Check tracker position and try again.');
  abortCtl.abort();
  try { await device.close(); } catch {}
  process.exit(1);
}

function analyzePair(label, idA, idB, frames) {
  const deltas = frames.map(f => {
    const a = f[idA], b = f[idB];
    if (!a || !b) return null;
    return {
      dx: a.v0 - b.v0,
      dy: a.v1 - b.v1,
      dz: a.v2 - b.v2,
    };
  }).filter(Boolean);

  if (deltas.length === 0) { console.log(`${label}: no data\n`); return; }

  const stats = (key) => {
    const vals = deltas.map(d => d[key]);
    const mean = vals.reduce((a, b) => a + b, 0) / vals.length;
    const min = Math.min(...vals);
    const max = Math.max(...vals);
    const std = Math.sqrt(vals.reduce((a, v) => a + (v - mean) ** 2, 0) / vals.length);
    return { mean, min, max, std };
  };

  console.log(`${label} (${deltas.length} frames):`);
  for (const axis of ['dx', 'dy', 'dz']) {
    const s = stats(axis);
    const allZero = s.min === 0 && s.max === 0;
    if (allZero) {
      console.log(`  ${axis}: always 0 (identical)`);
    } else {
      console.log(`  ${axis}: mean=${s.mean.toFixed(4)}  std=${s.std.toFixed(4)}  range=[${s.min.toFixed(4)}, ${s.max.toFixed(4)}]`);
    }
  }

  // Print first 5 individual deltas
  console.log(`  first 5 deltas:`);
  for (let i = 0; i < Math.min(5, deltas.length); i++) {
    const d = deltas[i];
    console.log(`    (${d.dx.toFixed(4)}, ${d.dy.toFixed(4)}, ${d.dz.toFixed(4)})`);
  }
  console.log();
}

console.log('=== Eye origin: primary (0x02/0x08) vs dup (0x17/0x18) ===\n');
analyzePair('Left eye origin: 0x02 - 0x17', 0x02, 0x17, valid);
analyzePair('Right eye origin: 0x08 - 0x18', 0x08, 0x18, valid);

console.log('=== Eye origin: tracker-space (0x02/0x08) vs display-space (0x22/0x24) ===\n');
analyzePair('Left eye: 0x02 - 0x22', 0x02, 0x22, valid);
analyzePair('Right eye: 0x08 - 0x24', 0x08, 0x24, valid);

console.log('=== Gaze direction: primary (0x03/0x09) vs alt (0x25/0x27) ===\n');
analyzePair('Left gaze dir: 0x03 - 0x25', 0x03, 0x25, valid);
analyzePair('Right gaze dir: 0x09 - 0x27', 0x09, 0x27, valid);

// Also check: are 0x1c and 0x20 different? (combined 2d norm vs "dup")
console.log('=== 2D norm: combined (0x1c) vs dup (0x20) ===\n');
analyzePair('2D norm: 0x1c - 0x20', 0x1c, 0x20, valid);

// Check 0x05 vs 0x0b (per-eye 2d) vs 0x1c (combined)
console.log('=== 2D norm: left (0x05) vs combined (0x1c) ===\n');
analyzePair('2D L vs combined: 0x05 - 0x1c', 0x05, 0x1c, valid);
console.log('=== 2D norm: right (0x0b) vs combined (0x1c) ===\n');
analyzePair('2D R vs combined: 0x0b - 0x1c', 0x0b, 0x1c, valid);

abortCtl.abort();
try { await device.close(); } catch {}
console.log('Done.');
process.exit(0);
