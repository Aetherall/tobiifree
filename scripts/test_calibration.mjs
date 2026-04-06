#!/usr/bin/env node
// Test calibration protocol against a live Tobii ET5.
// Usage: node scripts/test_calibration.mjs
//
// Directly instantiates the wasm core and usb transport, avoiding
// the TS SDK import chain (which needs a bundler for extensionless imports).

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');

// ─── USB setup via `usb` package ──────────────────────────────────────

const TOBII_VID = 0x2104;
const TOBII_PID_RUNTIME = 0x0313;
const INTERFACE = 0;
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
  await device.claimInterface(INTERFACE);
} catch (e) {
  console.error(`Cannot claim USB interface: ${e.message}`);
  console.error('Make sure no other process (browser, other driver) has the tracker open.');
  process.exit(1);
}

// Session-open: vendor ctrl 0x41
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

// ─── WASM core setup ──────────────────────────────────────────────────

const wasmPath = resolve(root, 'driver/zig-out/bin/tobiifree_core.wasm');
const wasmBytes = await readFile(wasmPath);

const pending = new Map(); // requestId -> { resolve, reject, timer }
let gazeCount = 0;
let lastGaze = null;

const { instance } = await WebAssembly.instantiate(wasmBytes, {
  env: {
    on_ttp_frame: (magic, seq, op, pptr, plen) => {
      if (op !== 0x500) { // skip gaze notifications
        const magicStr = magic === 0x51 ? 'REQ' : magic === 0x52 ? 'RSP' : magic === 0x53 ? 'NTF' : `?${magic.toString(16)}`;
        const view = new Uint8Array(instance.exports.memory.buffer, pptr, plen);
        console.log(`  [${magicStr}] seq=${seq} op=0x${op.toString(16).padStart(4, '0')} plen=${plen} data=${hex(view.slice(0, 60))}`);
      }
    },
    on_response: (requestId, pptr, plen) => {
      const view = new Uint8Array(instance.exports.memory.buffer, pptr, plen);
      const data = view.slice(); // copy
      const r = pending.get(requestId);
      if (r) { pending.delete(requestId); clearTimeout(r.timer); r.resolve(data); }
    },
    on_gaze: (samplePtr) => {
      gazeCount++;
      // Read gaze_point_2d_norm from the struct (offset depends on GazeSample layout)
      // present_mask(4) + frame_counter(4) + validity_L(4) + validity_R(4) +
      // timestamp_us(8) + pupil_L(8) + pupil_R(8) + gaze_point_2d_norm([2]f64=16)
      const dv = new DataView(instance.exports.memory.buffer, samplePtr);
      const mask = dv.getUint32(0, true);
      if (mask & (1 << 6)) { // GAZE_BIT_GAZE_2D
        const nx = dv.getFloat64(40, true);
        const ny = dv.getFloat64(48, true);
        lastGaze = { x: nx, y: ny };
      }
    },
    on_raw_columns: () => {},
    on_parse_error: (code) => { console.error(`  parse error: ${code}`); },
  },
});

const exp = instance.exports;
exp.session_reset();

// Grow memory for IN buffer
const currentPages = exp.memory.buffer.byteLength / 65536;
exp.memory.grow(2);
const IN_BUF_PTR = currentPages * 65536;
const DECODE_IN_PTR = IN_BUF_PTR + 65536;
const DECODE_OUT_PTR = DECODE_IN_PTR + 32768;
const sessionOutPtr = exp.session_out_ptr();

function takeOutBytes() {
  const n = exp.session_out_len_();
  return new Uint8Array(exp.memory.buffer, sessionOutPtr, n).slice();
}

function awaitResponse(requestId, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(requestId);
      reject(new Error(`request ${requestId} timed out (${timeoutMs}ms)`));
    }, timeoutMs);
    pending.set(requestId, { resolve, reject, timer });
  });
}

function hex(buf) {
  return [...buf].map(b => b.toString(16).padStart(2, '0')).join(' ');
}

// ─── Inbound pump ─────────────────────────────────────────────────────

let logRawUsb = false;
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
    if (logRawUsb) {
      console.log(`  [USB IN ${chunk.byteLength}B] ${hex(chunk.slice(0, 80))}${chunk.byteLength > 80 ? '...' : ''}`);
    }
    const dst = new Uint8Array(exp.memory.buffer, IN_BUF_PTR, chunk.byteLength);
    dst.set(chunk);
    exp.feed_usb_in(IN_BUF_PTR, chunk.byteLength);
  }
})().catch(e => { if (!abortCtl.signal.aborted) console.error('pump error:', e); });

// ─── Hello handshake ──────────────────────────────────────────────────

console.log('Sending hello...');
{
  const reqId = exp.request_hello();
  const bytes = takeOutBytes();
  const waiter = awaitResponse(reqId);
  await usbSend(bytes);
  await waiter;
  console.log('Hello done.\n');
}

// ─── Subscribe to gaze ────────────────────────────────────────────────

{
  exp.request_subscribe(0x500);
  await usbSend(takeOutBytes());
  console.log('Subscribed to gaze (0x500).\n');
}

// Wait a moment for gaze data to flow
await new Promise(r => setTimeout(r, 500));
console.log(`Gaze samples received so far: ${gazeCount}`);
if (lastGaze) console.log(`  Last gaze: (${lastGaze.x.toFixed(3)}, ${lastGaze.y.toFixed(3)})`);

// ─── Get display area ─────────────────────────────────────────────────

console.log('\n--- Display Area ---');
{
  const reqId = exp.request_get_display_area();
  const bytes = takeOutBytes();
  const waiter = awaitResponse(reqId);
  await usbSend(bytes);
  const payload = await waiter;

  // Decode
  const inBuf = new Uint8Array(exp.memory.buffer, DECODE_IN_PTR, payload.byteLength);
  inBuf.set(payload);
  const ok = exp.decode_display_area(DECODE_IN_PTR, payload.byteLength, DECODE_OUT_PTR);
  if (ok) {
    const dv = new DataView(exp.memory.buffer, DECODE_OUT_PTR, 72);
    const tl = { x: dv.getFloat64(0, true), y: dv.getFloat64(8, true), z: dv.getFloat64(16, true) };
    const tr = { x: dv.getFloat64(24, true), y: dv.getFloat64(32, true), z: dv.getFloat64(40, true) };
    const bl = { x: dv.getFloat64(48, true), y: dv.getFloat64(56, true), z: dv.getFloat64(64, true) };
    console.log(`  TL=(${tl.x.toFixed(1)}, ${tl.y.toFixed(1)}, ${tl.z.toFixed(1)})`);
    console.log(`  TR=(${tr.x.toFixed(1)}, ${tr.y.toFixed(1)}, ${tr.z.toFixed(1)})`);
    console.log(`  BL=(${bl.x.toFixed(1)}, ${bl.y.toFixed(1)}, ${bl.z.toFixed(1)})`);
  } else {
    console.log(`  decode failed. Raw: ${hex(payload.slice(0, 60))}`);
  }
}

// ─── Unlock realm ─────────────────────────────────────────────────────

console.log('\n--- Step 1: Query realm (op 0x640) ---');
let realmType;
{
  const reqId = exp.request_query_realm();
  const bytes = takeOutBytes();
  const waiter = awaitResponse(reqId);
  await usbSend(bytes);
  const payload = await waiter;
  console.log(`  Response (${payload.byteLength} bytes): ${hex(payload.slice(0, 80))}`);

  // Parse: scan for TLV type=2 (u32) fields
  const dv = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  let pos = 2;
  const u32s = [];
  while (pos + 5 <= payload.byteLength) {
    const type_ = payload[pos];
    const size = dv.getUint32(pos + 1, false);
    pos += 5;
    if (pos + size > payload.byteLength) break;
    if (type_ === 2 && size === 4) {
      u32s.push(dv.getUint32(pos, false));
    }
    pos += size;
  }
  console.log(`  Parsed u32 fields: [${u32s.join(', ')}]`);
  realmType = u32s[1] ?? u32s[0] ?? 0;
  console.log(`  Using realm_type = ${realmType}`);
}

console.log('\n--- Step 2: Open realm (op 0x76C) ---');
let realmId, field210, challenge;
{
  const reqId = exp.request_open_realm(realmType);
  const bytes = takeOutBytes();
  const waiter = awaitResponse(reqId, 10000);
  await usbSend(bytes);
  const payload = await waiter;
  console.log(`  Response (${payload.byteLength} bytes): ${hex(payload.slice(0, 80))}`);

  // Parse response: u32s and blob
  const dv = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  let pos = 2;
  const u32s = [];
  let blobData = null;
  while (pos + 5 <= payload.byteLength) {
    const type_ = payload[pos];
    const size = dv.getUint32(pos + 1, false);
    pos += 5;
    if (pos + size > payload.byteLength) break;
    if (type_ === 2 && size === 4) {
      u32s.push(dv.getUint32(pos, false));
      console.log(`    TLV u32 at offset ${pos}: ${dv.getUint32(pos, false)}`);
    } else if (size > 0 && type_ !== 5) {
      console.log(`    TLV type=${type_} size=${size} at offset ${pos}: ${hex(payload.slice(pos, pos + Math.min(size, 32)))}`);
      if (!blobData) blobData = payload.slice(pos, pos + size);
    }
    pos += size;
  }
  realmId = u32s[0] ?? 0;
  field210 = u32s[1] ?? 0;
  challenge = blobData;
  console.log(`  realm_id=${realmId} field210=${field210}`);
  if (challenge) {
    console.log(`  challenge (${challenge.byteLength} bytes): ${hex(challenge)}`);
  } else {
    console.log(`  WARNING: no challenge blob found!`);
  }
}

if (challenge) {
  console.log('\n--- Step 3: HMAC-MD5 ---');
  const key = new TextEncoder().encode('aaaaaaaabbbbbbbbccccccccdddddddd');

  // Write key + challenge into wasm memory
  const keyBuf = new Uint8Array(exp.memory.buffer, DECODE_IN_PTR, key.byteLength);
  keyBuf.set(key);
  const msgOff = DECODE_IN_PTR + key.byteLength;
  const msgBuf = new Uint8Array(exp.memory.buffer, msgOff, challenge.byteLength);
  msgBuf.set(challenge);
  exp.compute_hmac_md5(DECODE_IN_PTR, key.byteLength, msgOff, challenge.byteLength, DECODE_OUT_PTR);
  const digest = new Uint8Array(exp.memory.buffer, DECODE_OUT_PTR, 16).slice();
  console.log(`  digest: ${hex(digest)}`);

  console.log('\n--- Step 4: Realm response (op 0x776) ---');
  {
    // Write digest into wasm memory
    const digestBuf = new Uint8Array(exp.memory.buffer, DECODE_IN_PTR, 16);
    digestBuf.set(digest);
    const reqId = exp.request_realm_response(realmId, field210, DECODE_IN_PTR);
    const bytes = takeOutBytes();
    const waiter = awaitResponse(reqId, 10000);
    await usbSend(bytes);
    try {
      const payload = await waiter;
      console.log(`  Response (${payload.byteLength} bytes): ${hex(payload.slice(0, 60))}`);
      console.log('  Realm authenticated!');
    } catch (e) {
      console.log(`  ERROR: ${e.message}`);
      console.log('  Realm auth failed — stopping here.');
      abortCtl.abort();
      await cleanup();
      process.exit(1);
    }
  }
} else {
  console.log('  No challenge — skipping HMAC step.');
}

// ─── Helpers ─────────────────────────────────────────────────────────

async function retrieveCal(label) {
  console.log(`\n  Retrieving calibration (${label})...`);
  const reqId = exp.request_cal_retrieve();
  const bytes = takeOutBytes();
  const waiter = awaitResponse(reqId, 15000);
  await usbSend(bytes);
  const blob = await waiter;
  console.log(`  Got ${blob.byteLength} bytes`);
  return blob;
}

async function runCal(label, points, delayMs = 300) {
  console.log(`\n========== ${label} (${points.length} points) ==========`);
  for (const [x, y] of points) {
    console.log(`  Point (${x}, ${y})...`);
    if (delayMs > 300) {
      console.log(`    (look here for ${(delayMs/1000).toFixed(1)}s...)`);
    }
    await new Promise(r => setTimeout(r, delayMs));
    const reqId = exp.request_cal_add_point(x, y, 0);
    const bytes = takeOutBytes();
    const waiter = awaitResponse(reqId, 10000);
    await usbSend(bytes);
    await waiter;
  }
  console.log('  Computing...');
  {
    const reqId = exp.request_cal_compute();
    const bytes = takeOutBytes();
    const waiter = awaitResponse(reqId, 15000);
    await usbSend(bytes);
    await waiter;
  }
  return retrieveCal(label);
}

// ─── Retrieve factory/current calibration before any changes ─────────

const blobFactory = await retrieveCal('factory (before any cal)');

// ─── Calibration A: 5 points, no eyes ────────────────────────────────

const pts5 = [[0.5,0.5],[0.1,0.1],[0.9,0.1],[0.1,0.9],[0.9,0.9]];
const blobA = await runCal('Cal A (5pt, no eyes)', pts5, 300);

// ─── Calibration B: 5 points, WITH eyes — look at the tracker! ──────

console.log('\n*** LOOK AT THE TRACKER NOW! ***');
console.log('*** Each point will wait 2.5s for your gaze ***\n');
await new Promise(r => setTimeout(r, 2000));
const blobB = await runCal('Cal B (5pt, WITH EYES)', pts5, 2500);

// ─── Diff analysis ───────────────────────────────────────────────────

// ─── Diff helper ─────────────────────────────────────────────────────

function diffBlobs(a, b, labelA, labelB) {
  console.log(`\n  ${labelA}: ${a.byteLength} bytes`);
  console.log(`  ${labelB}: ${b.byteLength} bytes`);

  if (a.byteLength !== b.byteLength) {
    console.log(`  Size difference: ${b.byteLength - a.byteLength} bytes`);
  }

  const minLen = Math.min(a.byteLength, b.byteLength);
  let firstDiff = -1;
  let diffCount = 0;
  const diffRanges = [];
  let inDiff = false;
  let rangeStart = 0;
  for (let i = 0; i < minLen; i++) {
    if (a[i] !== b[i]) {
      diffCount++;
      if (!inDiff) { rangeStart = i; inDiff = true; }
      if (firstDiff === -1) firstDiff = i;
    } else {
      if (inDiff) { diffRanges.push({ start: rangeStart, end: i }); inDiff = false; }
    }
  }
  if (inDiff) diffRanges.push({ start: rangeStart, end: minLen });

  if (firstDiff === -1) {
    console.log('  IDENTICAL (0 bytes differ)');
    return;
  }

  console.log(`  First diff at 0x${firstDiff.toString(16)}, ${diffCount}/${minLen} bytes differ (${(diffCount/minLen*100).toFixed(1)}%)`);
  console.log(`  ${diffRanges.length} contiguous diff regions:`);
  for (const r of diffRanges) {
    console.log(`    0x${r.start.toString(16).padStart(4,'0')} - 0x${r.end.toString(16).padStart(4,'0')}  (${r.end - r.start} bytes)`);
  }

  // Side-by-side for changed regions
  for (const r of diffRanges) {
    const ctxStart = Math.max(0, r.start - 16) & ~0xf;
    const ctxEnd = Math.min(minLen, r.end + 16 + 15) & ~0xf;
    console.log(`\n  --- 0x${r.start.toString(16)}-0x${r.end.toString(16)} (${r.end - r.start}B) ---`);
    for (let off = ctxStart; off < ctxEnd; off += 16) {
      const end = Math.min(off + 16, minLen);
      const lineA = [...a.slice(off, end)].map(b => b.toString(16).padStart(2, '0')).join(' ');
      const lineB = [...b.slice(off, end)].map(b => b.toString(16).padStart(2, '0')).join(' ');
      if (lineA !== lineB) {
        const marks = [...a.slice(off, end)].map((v, i) => b[off+i] !== v ? '^^' : '  ').join(' ');
        console.log(`* ${off.toString(16).padStart(4,'0')} A: ${lineA}`);
        console.log(`* ${off.toString(16).padStart(4,'0')} B: ${lineB}`);
        console.log(`         ${marks}`);
      } else {
        console.log(`  ${off.toString(16).padStart(4,'0')}  : ${lineA}`);
      }
    }
  }
}

// ─── Diff analysis ───────────────────────────────────────────────────

console.log('\n========== DIFF: Factory vs A (no eyes) ==========');
diffBlobs(blobFactory, blobA, 'Factory', 'A');

console.log('\n========== DIFF: A (no eyes) vs B (with eyes) ==========');
diffBlobs(blobA, blobB, 'A', 'B');

console.log('\n========== DIFF: Factory vs B (with eyes) ==========');
diffBlobs(blobFactory, blobB, 'Factory', 'B');

// Header comparison
console.log('\n========== HEADER COMPARISON ==========');
function parseHeader(blob, label) {
  const inner = blob.slice(7);
  const dv2 = new DataView(inner.buffer, inner.byteOffset, inner.byteLength);
  const fields = [
    ['field_00 (BE)', dv2.getUint32(0, false)],
    ['field_04 (LE)', dv2.getUint32(4, true)],
    ['field_08 (LE)', dv2.getUint32(8, true)],
    ['field_0C (LE)', dv2.getUint32(0xc, true)],
    ['field_10 (LE)', dv2.getUint32(0x10, true)],
    ['field_14 (LE)', dv2.getUint32(0x14, true)],
    ['field_18 (LE)', dv2.getUint32(0x18, true)],
    ['field_1C (LE)', dv2.getUint32(0x1c, true)],
  ];
  let nameEnd = 0x20;
  while (nameEnd < inner.byteLength && inner[nameEnd] !== 0) nameEnd++;
  const name = new TextDecoder().decode(inner.slice(0x20, nameEnd));
  fields.push(['name', name]);
  if (inner.byteLength >= 0x68) {
    fields.push(['opaque_00 (LE)', dv2.getUint32(0x60, true)]);
    fields.push(['opaque_04 (LE)', dv2.getUint32(0x64, true)]);
  }
  fields.push(['last_4_bytes', hex(inner.slice(-4))]);
  console.log(`  ${label}:`);
  for (const [k, v] of fields) {
    console.log(`    ${k.toString().padEnd(20)} = ${typeof v === 'number' ? `${v} (0x${v.toString(16)})` : v}`);
  }
}
parseHeader(blobFactory, 'Factory');
parseHeader(blobA, 'A (no eyes)');
parseHeader(blobB, 'B (with eyes)');

// ─── Close realm ──────────────────────────────────────────────────────

console.log('\n--- Close realm ---');
{
  const reqId = exp.request_close_realm(realmId);
  const bytes = takeOutBytes();
  const waiter = awaitResponse(reqId, 5000);
  await usbSend(bytes);
  await waiter;
  console.log('  Realm closed.');
}

// ─── Cleanup ──────────────────────────────────────────────────────────

async function cleanup() {
  abortCtl.abort();
  try { await pumpPromise; } catch {}
  try {
    await device.controlTransferOut({
      requestType: 'vendor', recipient: 'interface',
      request: 0x42, value: 0, index: 0,
    });
  } catch {}
  try { await device.releaseInterface(INTERFACE); } catch {}
  try { await device.close(); } catch {}
}

abortCtl.abort();
await cleanup();
console.log('\nDone.');
