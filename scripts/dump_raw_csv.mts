#!/usr/bin/env node --experimental-strip-types
// Dump all raw gaze columns to CSV via direct USB.
//
// Usage:
//   node --experimental-strip-types scripts/dump_raw_csv.mts [seconds] [output.csv]
//
// Defaults: 10 seconds, writes to stdout.
// All columns present in the gaze stream are included as CSV columns.
// One row per gaze frame. Columns ordered by ID.

import { Tobii } from '../sdk/src/index.ts';
import type { UsbSource } from '../sdk/src/usb_source.ts';
import { GAZE_COLUMN_LABELS } from '../sdk/src/protocol.ts';
import type { RawGazeColumn } from '../sdk/src/protocol.ts';
import { createWriteStream, readFileSync, type WriteStream } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const seconds = Number(process.argv[2]) || 10;
const outPath = process.argv[3]; // undefined → stdout

const here = dirname(fileURLToPath(import.meta.url));
const calibPath = resolve(here, '..', 'calibrations', 'manual-2026-04-06.json');

// ─── Column layout ───────────────────────────────────────────────────
// Each raw column has a colId and up to 3 values (v0, v1, v2).
// point3d → .x .y .z,  point2d → .x .y,  scalar → (single value)

type ColMeta = { id: number; label: string; suffixes: string[] };

const SCALAR_KINDS = new Set(['u32', 's64', 'fixed16x16']);

function suffixesForKind(kind: string): string[] {
  if (kind === 'point3d') return ['.x', '.y', '.z'];
  if (kind === 'point2d') return ['.x', '.y'];
  return [''];
}

// ─── Connect ─────────────────────────────────────────────────────────

console.error('Connecting to ET5...');
const src = await Tobii.fromUsb({ requestTimeoutMs: 5000 }) as UsbSource;
console.error('Connected. Display area:', JSON.stringify(src.displayArea));

// Ensure a sensible display area is configured — the tracker won't produce
// valid gaze data with a degenerate plane. Use a typical 600×340mm monitor
// centered above the tracker, 50mm in front.
const da = src.displayArea;
const degenerate = da && Math.hypot(da.tr.x - da.tl.x, da.tr.y - da.tl.y, da.tr.z - da.tl.z) < 10;
// Load calibration and apply display area.
const calib = JSON.parse(readFileSync(calibPath, 'utf8'));
const area = calib.display_area as { tl: {x:number,y:number,z:number}, tr: {x:number,y:number,z:number}, bl: {x:number,y:number,z:number} };
console.error('Applying display area from', calibPath);
await src.setDisplayAreaCorners(area);
// Small delay for the device to process, then verify.
await new Promise(r => setTimeout(r, 200));
const readBack = await src.getDisplayArea();
console.error('Display area readback:', JSON.stringify(readBack));

// ─── Collect ─────────────────────────────────────────────────────────
// First pass: collect a few frames to discover which columns are present
// and their kinds, then collect the rest normally.

type Frame = Map<number, RawGazeColumn>;
const frames: Frame[] = [];
let currentFrame: Frame = new Map();

// on_gaze fires once per complete gaze frame; raw columns arrive just before.
const unsubGaze = src.subscribeToGaze(() => {
  if (currentFrame.size > 0) {
    frames.push(currentFrame);
    currentFrame = new Map();
  }
});

const unsubRaw = src.subscribeToRawGaze((cols) => {
  for (const c of cols) {
    currentFrame.set(c.colId, c);
  }
});

console.error(`Collecting ${seconds}s of gaze data...`);
await new Promise(r => setTimeout(r, seconds * 1000));

unsubRaw();
unsubGaze();

console.error(`Collected ${frames.length} frames.`);

if (frames.length === 0) {
  console.error('No frames collected. Is the tracker seeing your eyes?');
  await src.close();
  process.exit(1);
}

// ─── Discover columns ────────────────────────────────────────────────

const colIds = new Set<number>();
const colKinds = new Map<number, string>();
for (const f of frames) {
  for (const [id, col] of f) {
    colIds.add(id);
    if (!colKinds.has(id)) colKinds.set(id, col.kind);
  }
}

const sortedIds = [...colIds].sort((a, b) => a - b);

const colMetas: ColMeta[] = sortedIds.map(id => ({
  id,
  label: GAZE_COLUMN_LABELS[id] ?? `col_0x${id.toString(16).padStart(2, '0')}`,
  suffixes: suffixesForKind(colKinds.get(id)!),
}));

// ─── Write CSV ───────────────────────────────────────────────────────

const out: WriteStream | typeof process.stdout = outPath
  ? createWriteStream(outPath)
  : process.stdout;

// Header
const headerCols: string[] = [];
for (const m of colMetas) {
  for (const s of m.suffixes) {
    headerCols.push(m.label + s);
  }
}
out.write(headerCols.join(',') + '\n');

// Rows
for (const f of frames) {
  const vals: string[] = [];
  for (const m of colMetas) {
    const col = f.get(m.id);
    if (!col) {
      for (const _ of m.suffixes) vals.push('');
    } else if (m.suffixes.length === 3) {
      vals.push(String(col.v0), String(col.v1), String(col.v2));
    } else if (m.suffixes.length === 2) {
      vals.push(String(col.v0), String(col.v1));
    } else {
      vals.push(String(col.v0));
    }
  }
  out.write(vals.join(',') + '\n');
}

if (out !== process.stdout) {
  (out as WriteStream).end();
  console.error(`Wrote ${frames.length} rows to ${outPath}`);
}

await src.close();
process.exit(0);
