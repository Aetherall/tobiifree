#!/usr/bin/env node --experimental-strip-types
// Train a gaze prediction model from a collected dataset JSON.
//
// Usage:
//   node --experimental-strip-types src/cli.ts <dataset.json> [options]
//
// Options:
//   --features <set>     eye_origins | eye_origins_raw | trackbox | all_positions | kitchen_sink  (default: all_positions)
//   --degree <n>         Polynomial degree 1-3  (default: 2)
//   --lambda <n>         Ridge regularization   (default: 1)
//   --test-split <n>     Test fraction 0-1      (default: 0.2)
//   --out <path>         Output model JSON       (default: stdout)
//   --seed <n>           RNG seed               (default: 42)

import { readFileSync, writeFileSync } from 'node:fs';
import { train, featureNames, polyFeatureCount, type FeatureSet, type TrainResult } from './regression.ts';

// ── Parse args ──────────────────────────────────────────────────────

const args = process.argv.slice(2);

function flag(name: string, def: string): string {
  const i = args.indexOf(`--${name}`);
  if (i === -1) return def;
  const v = args[i + 1];
  args.splice(i, 2);
  return v ?? def;
}

const featureSet = flag('features', 'all_positions') as FeatureSet;
const degree = parseInt(flag('degree', '2'));
const lambda = parseFloat(flag('lambda', '1'));
const testSplit = parseFloat(flag('test-split', '0.2'));
const outPath = flag('out', '');
const seed = parseInt(flag('seed', '42'));

// First positional arg is the input file
const inputFile = args.find(a => !a.startsWith('--'));
if (!inputFile) {
  console.error('Usage: node --experimental-strip-types src/cli.ts <dataset.json> [--features ...] [--degree ...] [--lambda ...] [--test-split ...] [--out ...] [--seed ...]');
  process.exit(1);
}

// ── Load dataset ────────────────────────────────────────────────────

type V3 = { x: number; y: number; z: number };
type DisplayArea = { tl: V3; tr: V3; bl: V3 };

type Dataset = {
  version: number;
  display_area_used?: DisplayArea;
  samples: Array<{
    cursor_norm: [number, number];
    cursor_px: [number, number];
    sample: Record<string, unknown>;
  }>;
};

const raw = readFileSync(inputFile, 'utf-8');
const dataset = JSON.parse(raw) as Dataset;

if (!dataset.samples?.length) {
  console.error('No samples in dataset');
  process.exit(1);
}

const all = dataset.samples;
const valid = all.filter(r => {
  const s = r.sample as { validity_L?: number; validity_R?: number };
  return s.validity_L === 0 && s.validity_R === 0;
});

console.error(`Dataset: ${all.length} total, ${valid.length} valid binocular`);

// Cursor coverage
const xs = valid.map(r => r.cursor_norm[0]);
const ys = valid.map(r => r.cursor_norm[1]);
console.error(`Cursor X: ${Math.min(...xs).toFixed(3)}–${Math.max(...xs).toFixed(3)}`);
console.error(`Cursor Y: ${Math.min(...ys).toFixed(3)}–${Math.max(...ys).toFixed(3)}`);

// Feature info
const nRaw = featureNames(featureSet).length;
const nPoly = polyFeatureCount(nRaw, degree);
console.error(`Features: ${featureSet} (${nRaw} raw -> ${nPoly} poly${degree})`);
console.error(`Lambda: ${lambda}, test split: ${testSplit}, seed: ${seed}`);

if (nPoly > valid.length) {
  console.error(`ERROR: ${nPoly} features > ${valid.length} samples. Reduce degree or features.`);
  process.exit(1);
}

// ── Train ───────────────────────────────────────────────────────────

console.error('Training...');
const t0 = performance.now();
const result = train(dataset.samples as any, featureSet, degree, lambda, testSplit, seed);
const dt = performance.now() - t0;
console.error(`Done in ${dt.toFixed(0)}ms`);

// ── Evaluate ────────────────────────────────────────────────────────

// Device RMSE on test set for comparison
let devErrX = 0, devErrY = 0;
for (const i of result.testIndices) {
  const rec = valid[i]!;
  const g = rec.sample as { gaze_point_2d_norm?: { x: number; y: number } };
  const px = g.gaze_point_2d_norm?.x ?? 0;
  const py = g.gaze_point_2d_norm?.y ?? 0;
  devErrX += (px - rec.cursor_norm[0]) ** 2;
  devErrY += (py - rec.cursor_norm[1]) ** 2;
}
const nTest = result.testIndices.length;
const devRmse = Math.sqrt((devErrX + devErrY) / nTest);
const modelRmse = Math.sqrt(result.testRmse[0] ** 2 + result.testRmse[1] ** 2);
const improvement = ((1 - modelRmse / devRmse) * 100).toFixed(1);

// Error percentiles on test set
const testErrors: number[] = [];
for (let i = 0; i < result.testIndices.length; i++) {
  const idx = result.testIndices[i]!;
  const pred = result.testPredictions[i]!;
  const t = valid[idx]!.cursor_norm;
  testErrors.push(Math.hypot(pred[0]! - t[0], pred[1]! - t[1]));
}
testErrors.sort((a, b) => a - b);
const pct = (p: number) => testErrors[Math.floor(testErrors.length * p)]!;

const deviceErrors: number[] = [];
for (const i of result.testIndices) {
  const rec = valid[i]!;
  const g = rec.sample as { gaze_point_2d_norm?: { x: number; y: number } };
  const px = g.gaze_point_2d_norm?.x ?? 0;
  const py = g.gaze_point_2d_norm?.y ?? 0;
  deviceErrors.push(Math.hypot(px - rec.cursor_norm[0], py - rec.cursor_norm[1]));
}
deviceErrors.sort((a, b) => a - b);
const dpct = (p: number) => deviceErrors[Math.floor(deviceErrors.length * p)]!;

console.error('');
console.error('=== Results ===');
console.error(`Train: ${result.trainIndices.length} samples | Test: ${nTest} samples`);
console.error('');
console.error(`          RMSE-x    RMSE-y    RMSE     p50      p90      p95`);
console.error(`Device    ${fmtCol(Math.sqrt(devErrX / nTest))} ${fmtCol(Math.sqrt(devErrY / nTest))} ${fmtCol(devRmse)} ${fmtCol(dpct(0.5))} ${fmtCol(dpct(0.9))} ${fmtCol(dpct(0.95))}`);
console.error(`Model     ${fmtCol(result.testRmse[0])} ${fmtCol(result.testRmse[1])} ${fmtCol(modelRmse)} ${fmtCol(pct(0.5))} ${fmtCol(pct(0.9))} ${fmtCol(pct(0.95))}`);
console.error('');
console.error(`Improvement: ${improvement}%`);

function fmtCol(v: number): string {
  return v.toFixed(5).padStart(9);
}

// ── Output model ────────────────────────────────────────────────────

// Only store trainingDisplayArea for feature sets that include display-area-
// dependent gaze_2d features. For eye_origins/trackbox/etc the model output
// is viewport-normalized directly and needs no reprojection.
const gazeDependent = featureSet === 'gaze_correct' || featureSet === 'gaze_correct_full';
if (dataset.display_area_used && gazeDependent) {
  result.model.trainingDisplayArea = dataset.display_area_used;
  console.error(`Training display area: ${JSON.stringify(dataset.display_area_used)}`);
}
const output = JSON.stringify(result.model, null, 2);
if (outPath) {
  writeFileSync(outPath, output);
  console.error(`Model written to ${outPath}`);
} else {
  console.log(output);
}
