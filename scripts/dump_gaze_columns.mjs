#!/usr/bin/env node
// Dump all raw gaze columns from the ET5 to identify unknown fields.
// Usage: node scripts/dump_gaze_columns.mjs
//
// Connects to the tracker, subscribes to gaze (0x500) with raw columns
// enabled, collects N frames, and prints a summary table of every column
// seen: ID, TLV type, value ranges, and whether the values change.

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');

// ─── USB setup ───────────────────────────────────────────────────────

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
try {
  await device.claimInterface(0);
} catch (e) {
  console.error(`Cannot claim USB interface: ${e.message}`);
  process.exit(1);
}

const sessR = await device.controlTransferOut({
  requestType: 'vendor', recipient: 'interface',
  request: 0x41, value: 0, index: 0,
});
if (sessR.status !== 'ok') throw new Error(`session-open: ${sessR.status}`);

async function usbSend(bytes) {
  const buf = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buf).set(bytes);
  const r = await device.transferOut(EP_OUT, buf);
  if (r.status !== 'ok') throw new Error(`OUT: ${r.status}`);
}

// ─── WASM core setup ─────────────────────────────────────────────────

const wasmPath = resolve(root, 'driver/zig-out/bin/tobiifree_core.wasm');
const wasmBytes = await readFile(wasmPath);

const KIND_NAMES = ['s64', 'u32', 'point2d', 'point3d', 'fixed16x16'];

const LABELS = {
  0x01: 'timestamp_us',
  0x02: 'eye_origin_L_mm',
  0x03: 'gaze_direction_L_unit',
  0x04: 'gaze_point_3d_L_mm',
  0x05: 'gaze_point_2d_L_norm',
  0x06: 'pupil_diameter_L_mm',
  0x07: 'validity_L',
  0x08: 'eye_origin_R_mm',
  0x09: 'gaze_direction_R_unit',
  0x0a: 'gaze_point_3d_R_mm',
  0x0b: 'gaze_point_2d_R_norm',
  0x0c: 'pupil_diameter_R_mm',
  0x0d: 'validity_R',
  0x0e: 'status_0e',
  0x11: 'status_11',
  0x14: 'frame_counter',
  0x15: 'status_15',
  0x16: 'status_16',
  0x17: 'eye_origin_L_mm_dup',
  0x18: 'eye_origin_R_mm_dup',
  0x19: 'point2d_19',
  0x1a: 'point2d_1a',
  0x1b: 'status_1b',
  0x1c: 'gaze_point_2d_norm',
  0x1d: 'status_1d',
  0x1e: 'status_1e',
  0x1f: 'status_1f',
  0x20: 'gaze_point_2d_norm_dup',
  0x21: 'status_21',
  0x22: 'eye_origin_L_display_mm',
  0x23: 'status_23',
  0x24: 'eye_origin_R_display_mm',
  0x25: 'gaze_direction_25',
  0x26: 'status_26',
  0x27: 'gaze_direction_27',
  0x28: 'status_28',
  0x29: 'scalar_29',
  0x2a: 'status_2a',
  0x2b: 'scalar_2b',
  0x2c: 'status_2c',
};

const pending = new Map();

// Per-column statistics: colId → { kind, count, min/max for each component,
// distinct value sets (capped), sample values }
const colStats = new Map();
let frameCount = 0;

function updateStats(colId, kind, v0, v1, v2) {
  let s = colStats.get(colId);
  if (!s) {
    s = {
      kind,
      count: 0,
      v0_min: Infinity, v0_max: -Infinity,
      v1_min: Infinity, v1_max: -Infinity,
      v2_min: Infinity, v2_max: -Infinity,
      // Keep first and last few samples for inspection
      first: null,
      last: null,
      // Track distinct values for scalars
      distinctV0: new Set(),
    };
    colStats.set(colId, s);
  }
  s.count++;
  s.v0_min = Math.min(s.v0_min, v0);
  s.v0_max = Math.max(s.v0_max, v0);
  s.v1_min = Math.min(s.v1_min, v1);
  s.v1_max = Math.max(s.v1_max, v1);
  s.v2_min = Math.min(s.v2_min, v2);
  s.v2_max = Math.max(s.v2_max, v2);
  if (!s.first) s.first = { v0, v1, v2 };
  s.last = { v0, v1, v2 };
  if (s.distinctV0.size < 50) s.distinctV0.add(v0);
}

const { instance } = await WebAssembly.instantiate(wasmBytes, {
  env: {
    on_ttp_frame: () => {},
    on_response: (requestId, pptr, plen) => {
      const view = new Uint8Array(instance.exports.memory.buffer, pptr, plen);
      const data = view.slice();
      const r = pending.get(requestId);
      if (r) { pending.delete(requestId); clearTimeout(r.timer); r.resolve(data); }
    },
    on_gaze: () => { frameCount++; },
    on_raw_columns: (ptr, n) => {
      const view = new DataView(instance.exports.memory.buffer, ptr, n * 32);
      for (let i = 0; i < n; i++) {
        const off = i * 32;
        const colId = view.getUint32(off, true);
        const kindIdx = view.getUint32(off + 4, true);
        const kind = KIND_NAMES[kindIdx] ?? `?${kindIdx}`;
        const v0 = view.getFloat64(off + 8, true);
        const v1 = view.getFloat64(off + 16, true);
        const v2 = view.getFloat64(off + 24, true);
        updateStats(colId, kind, v0, v1, v2);
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
    const timer = setTimeout(() => {
      pending.delete(requestId);
      reject(new Error(`request ${requestId} timed out`));
    }, timeoutMs);
    pending.set(requestId, { resolve, reject, timer });
  });
}

// ─── Inbound pump ────────────────────────────────────────────────────

const abortCtl = new AbortController();
const pumpPromise = (async () => {
  while (!abortCtl.signal.aborted) {
    let r;
    try {
      r = await device.transferIn(EP_IN, 16384);
    } catch (e) {
      if (abortCtl.signal.aborted) return;
      throw e;
    }
    if (abortCtl.signal.aborted) return;
    if (r.status !== 'ok' || !r.data) throw new Error(`IN: ${r.status}`);
    const chunk = new Uint8Array(r.data.buffer, r.data.byteOffset, r.data.byteLength);
    const dst = new Uint8Array(exp.memory.buffer, IN_BUF_PTR, chunk.byteLength);
    dst.set(chunk);
    exp.feed_usb_in(IN_BUF_PTR, chunk.byteLength);
  }
})().catch(e => { if (!abortCtl.signal.aborted) console.error('pump error:', e); });

// ─── Hello ───────────────────────────────────────────────────────────

console.log('Sending hello...');
{
  const reqId = exp.request_hello();
  const bytes = takeOutBytes();
  const waiter = awaitResponse(reqId);
  await usbSend(bytes);
  await waiter;
  console.log('Hello done.');
}

// ─── Enable raw columns + subscribe to gaze ──────────────────────────

exp.raw_columns_enable(1);

{
  exp.request_subscribe(0x500);
  await usbSend(takeOutBytes());
  console.log('Subscribed to gaze (0x500) with raw columns enabled.');
}

// ─── Collect data ────────────────────────────────────────────────────

const COLLECT_SECONDS = 5;
console.log(`\nCollecting gaze data for ${COLLECT_SECONDS}s — look around to exercise all columns...\n`);

// Print live frame count every second
const ticker = setInterval(() => {
  process.stdout.write(`  frames: ${frameCount}, columns seen: ${colStats.size}\r`);
}, 500);

await new Promise(r => setTimeout(r, COLLECT_SECONDS * 1000));
clearInterval(ticker);
console.log(`\nCollected ${frameCount} gaze frames.\n`);

// ─── Print raw dump of last few frames ───────────────────────────────

// Print one full frame's columns for reference
console.log('--- Last frame sample values ---');
let sampleDone = false;
const origOnRaw = instance.exports;

// We already have the last values in stats, print those
for (const [colId, s] of [...colStats.entries()].sort((a, b) => a[0] - b[0])) {
  const label = LABELS[colId] ?? `unknown_${colId.toString(16)}`;
  const { last, kind } = s;
  if (kind === 'point2d') {
    console.log(`  0x${colId.toString(16).padStart(2, '0')} ${label.padEnd(30)} [point2d] (${last.v0.toFixed(6)}, ${last.v1.toFixed(6)})`);
  } else if (kind === 'point3d') {
    console.log(`  0x${colId.toString(16).padStart(2, '0')} ${label.padEnd(30)} [point3d] (${last.v0.toFixed(3)}, ${last.v1.toFixed(3)}, ${last.v2.toFixed(3)})`);
  } else if (kind === 'fixed16x16') {
    console.log(`  0x${colId.toString(16).padStart(2, '0')} ${label.padEnd(30)} [fix16]   ${last.v0.toFixed(6)}`);
  } else if (kind === 's64') {
    console.log(`  0x${colId.toString(16).padStart(2, '0')} ${label.padEnd(30)} [s64]     ${last.v0}`);
  } else {
    console.log(`  0x${colId.toString(16).padStart(2, '0')} ${label.padEnd(30)} [u32]     ${last.v0}`);
  }
}

// ─── Print statistics table ──────────────────────────────────────────

console.log('\n--- Column statistics (across all frames) ---\n');

const header = [
  'ID'.padEnd(6),
  'Label'.padEnd(30),
  'Kind'.padEnd(8),
  'Count'.padEnd(7),
  'v0 range'.padEnd(40),
  'v1 range'.padEnd(40),
  'v2 range'.padEnd(40),
  'Distinct v0',
].join(' | ');
console.log(header);
console.log('-'.repeat(header.length));

for (const [colId, s] of [...colStats.entries()].sort((a, b) => a[0] - b[0])) {
  const label = LABELS[colId] ?? `UNKNOWN_${colId.toString(16)}`;
  const id = `0x${colId.toString(16).padStart(2, '0')}`;

  const fmt = (min, max) => {
    if (min === Infinity) return 'n/a'.padEnd(40);
    if (min === max) return `= ${min}`.padEnd(40).slice(0, 40);
    return `${min.toPrecision(6)} … ${max.toPrecision(6)}`.padEnd(40).slice(0, 40);
  };

  const distinct = s.distinctV0.size >= 50 ? '50+' : `${s.distinctV0.size}`;

  console.log([
    id.padEnd(6),
    label.padEnd(30),
    s.kind.padEnd(8),
    String(s.count).padEnd(7),
    fmt(s.v0_min, s.v0_max),
    fmt(s.v1_min, s.v1_max),
    fmt(s.v2_min, s.v2_max),
    distinct,
  ].join(' | '));
}

// ─── Cleanup ─────────────────────────────────────────────────────────

abortCtl.abort();
try { await pumpPromise; } catch {}
try { await device.close(); } catch {}
console.log('\nDone.');
process.exit(0);
