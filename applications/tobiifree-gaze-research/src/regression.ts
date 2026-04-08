// Ridge regression with polynomial feature expansion.
// All matrices stored as flat Float64Arrays in row-major order.

export type TrainedModel = {
  featureNames: string[];
  polyDegree: number;
  lambda: number;
  // Weights: [n_poly_features+1, 2] — column 0 = x, column 1 = y.
  // Last row is bias.
  weights: number[][];
  // Normalization: subtract inputMean, divide by inputStd before poly expansion.
  inputMean: number[];
  inputStd: number[];
  // The display area active during data collection. Needed to reproject
  // predictions onto a different live display area.
  trainingDisplayArea?: { tl: { x: number; y: number; z: number }; tr: { x: number; y: number; z: number }; bl: { x: number; y: number; z: number } };
};

export type TrainResult = {
  model: TrainedModel;
  trainRmse: [number, number];
  testRmse: [number, number];
  trainPredictions: number[][];
  testPredictions: number[][];
  trainIndices: number[];
  testIndices: number[];
};

// ── Feature extraction ──────────────────────────────────────────────

type V2 = { x: number; y: number };
type V3 = { x: number; y: number; z: number };
type Sample = {
  validity_L?: number; validity_R?: number;
  pupil_diameter_L_mm?: number; pupil_diameter_R_mm?: number;
  eye_origin_L_mm?: V3; eye_origin_R_mm?: V3;
  eye_origin_raw_L_mm?: V3; eye_origin_raw_R_mm?: V3;
  eye_origin_L_display_mm?: V3; eye_origin_R_display_mm?: V3;
  trackbox_eye_pos_L?: V3; trackbox_eye_pos_R?: V3;
  trackbox_eye_pos_L_display?: V3; trackbox_eye_pos_R_display?: V3;
  gaze_point_3d_L_mm?: V3; gaze_point_3d_R_mm?: V3;
  gaze_point_2d_norm?: V2;
  gaze_point_2d_L_norm?: V2; gaze_point_2d_R_norm?: V2;
  gaze_point_2d_unfiltered?: V2;
};

type Record = {
  cursor_norm: [number, number];
  sample: Sample;
};

const v3 = (v: V3 | undefined): [number, number, number] =>
  v ? [v.x, v.y, v.z] : [0, 0, 0];

export type FeatureSet =
  | 'eye_origins' | 'eye_origins_raw' | 'trackbox'
  | 'all_positions' | 'kitchen_sink'
  | 'gaze_correct'       // device 2D gaze + eye origins → learn correction
  | 'gaze_correct_full'; // device 2D gaze + all positions + pupils

export function featureNames(set: FeatureSet): string[] {
  const eo = ['eo_L.x', 'eo_L.y', 'eo_L.z', 'eo_R.x', 'eo_R.y', 'eo_R.z'];
  const er = ['er_L.x', 'er_L.y', 'er_L.z', 'er_R.x', 'er_R.y', 'er_R.z'];
  const tb = ['tb_L.x', 'tb_L.y', 'tb_L.z', 'tb_R.x', 'tb_R.y', 'tb_R.z'];
  const pp = ['pupil_L', 'pupil_R'];
  const g2d = ['gaze_2d.x', 'gaze_2d.y'];
  const g2dL = ['gaze_2d_L.x', 'gaze_2d_L.y'];
  const g2dR = ['gaze_2d_R.x', 'gaze_2d_R.y'];
  const g2du = ['gaze_2d_unfilt.x', 'gaze_2d_unfilt.y'];
  switch (set) {
    case 'eye_origins': return eo;
    case 'eye_origins_raw': return er;
    case 'trackbox': return tb;
    case 'all_positions': return [...eo, ...er, ...tb];
    case 'kitchen_sink': return [...eo, ...er, ...tb, ...pp];
    case 'gaze_correct': return [...g2d, ...g2dL, ...g2dR, ...eo];
    case 'gaze_correct_full': return [...g2d, ...g2dL, ...g2dR, ...g2du, ...eo, ...er, ...tb, ...pp];
  }
}

const v2 = (v: V2 | undefined): [number, number] =>
  v ? [v.x, v.y] : [0, 0];

export function extractFeatures(s: Sample, set: FeatureSet): number[] {
  const eo = [...v3(s.eye_origin_L_mm), ...v3(s.eye_origin_R_mm)];
  const er = [...v3(s.eye_origin_raw_L_mm), ...v3(s.eye_origin_raw_R_mm)];
  const tb = [...v3(s.trackbox_eye_pos_L), ...v3(s.trackbox_eye_pos_R)];
  const g2d = v2(s.gaze_point_2d_norm);
  const g2dL = v2(s.gaze_point_2d_L_norm);
  const g2dR = v2(s.gaze_point_2d_R_norm);
  const g2du = v2(s.gaze_point_2d_unfiltered);
  switch (set) {
    case 'eye_origins': return eo;
    case 'eye_origins_raw': return er;
    case 'trackbox': return tb;
    case 'all_positions': return [...eo, ...er, ...tb];
    case 'kitchen_sink': return [...eo, ...er, ...tb, s.pupil_diameter_L_mm ?? -1, s.pupil_diameter_R_mm ?? -1];
    case 'gaze_correct': return [...g2d, ...g2dL, ...g2dR, ...eo];
    case 'gaze_correct_full': return [...g2d, ...g2dL, ...g2dR, ...g2du, ...eo, ...er, ...tb, s.pupil_diameter_L_mm ?? -1, s.pupil_diameter_R_mm ?? -1];
  }
}

// ── Polynomial expansion ────────────────────────────────────────────

function polyExpand(x: number[], degree: number): number[] {
  if (degree === 1) return [...x, 1]; // + bias
  const out = [...x];
  if (degree >= 2) {
    for (let i = 0; i < x.length; i++) {
      for (let j = i; j < x.length; j++) {
        out.push(x[i]! * x[j]!);
      }
    }
  }
  if (degree >= 3) {
    for (let i = 0; i < x.length; i++) {
      for (let j = i; j < x.length; j++) {
        for (let k = j; k < x.length; k++) {
          out.push(x[i]! * x[j]! * x[k]!);
        }
      }
    }
  }
  out.push(1); // bias
  return out;
}

export function polyFeatureCount(nRaw: number, degree: number): number {
  let n = nRaw;
  if (degree >= 2) n += nRaw * (nRaw + 1) / 2;
  if (degree >= 3) n += nRaw * (nRaw + 1) * (nRaw + 2) / 6;
  return n + 1; // +1 for bias
}

// ── Matrix ops (small dense, row-major) ─────────────────────────────

function matMul(A: Float64Array, aRows: number, aCols: number, B: Float64Array, bCols: number): Float64Array {
  const C = new Float64Array(aRows * bCols);
  for (let i = 0; i < aRows; i++) {
    for (let k = 0; k < aCols; k++) {
      const a = A[i * aCols + k]!;
      for (let j = 0; j < bCols; j++) {
        C[i * bCols + j] = C[i * bCols + j]! + a * B[k * bCols + j]!;
      }
    }
  }
  return C;
}

function matTranspose(A: Float64Array, rows: number, cols: number): Float64Array {
  const T = new Float64Array(cols * rows);
  for (let i = 0; i < rows; i++)
    for (let j = 0; j < cols; j++)
      T[j * rows + i] = A[i * cols + j]!;
  return T;
}

// Solve (A^T A + lambda I) w = A^T y  via Cholesky.
function ridgeSolve(X: Float64Array, nRows: number, nCols: number, Y: Float64Array, yCols: number, lambda: number): Float64Array {
  const Xt = matTranspose(X, nRows, nCols);
  const XtX = matMul(Xt, nCols, nRows, X, nCols);
  // Add ridge
  for (let i = 0; i < nCols; i++) XtX[i * nCols + i] = XtX[i * nCols + i]! + lambda;
  const XtY = matMul(Xt, nCols, nRows, Y, yCols);
  // Cholesky decomposition: XtX = L L^T
  const L = new Float64Array(nCols * nCols);
  for (let i = 0; i < nCols; i++) {
    for (let j = 0; j <= i; j++) {
      let sum = 0;
      for (let k = 0; k < j; k++) sum += L[i * nCols + k]! * L[j * nCols + k]!;
      if (i === j) {
        L[i * nCols + j] = Math.sqrt(XtX[i * nCols + i]! - sum);
      } else {
        L[i * nCols + j] = (XtX[i * nCols + j]! - sum) / L[j * nCols + j]!;
      }
    }
  }
  // Solve L z = XtY (forward)
  const Z = new Float64Array(nCols * yCols);
  for (let i = 0; i < nCols; i++) {
    for (let c = 0; c < yCols; c++) {
      let sum = 0;
      for (let k = 0; k < i; k++) sum += L[i * nCols + k]! * Z[k * yCols + c]!;
      Z[i * yCols + c] = (XtY[i * yCols + c]! - sum) / L[i * nCols + i]!;
    }
  }
  // Solve L^T w = z (backward)
  const W = new Float64Array(nCols * yCols);
  for (let i = nCols - 1; i >= 0; i--) {
    for (let c = 0; c < yCols; c++) {
      let sum = 0;
      for (let k = i + 1; k < nCols; k++) sum += L[k * nCols + i]! * W[k * yCols + c]!;
      W[i * yCols + c] = (Z[i * yCols + c]! - sum) / L[i * nCols + i]!;
    }
  }
  return W;
}

// ── Training ────────────────────────────────────────────────────────

// Simple seeded PRNG (mulberry32)
function mulberry32(seed: number) {
  let s = seed | 0;
  return () => {
    s = s + 0x6D2B79F5 | 0;
    let t = Math.imul(s ^ s >>> 15, 1 | s);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}

export function train(
  records: Record[],
  featureSet: FeatureSet,
  polyDegree: number,
  lambda: number,
  testFraction: number,
  seed = 42,
): TrainResult {
  // Filter valid binocular samples
  const valid = records.filter(r => r.sample.validity_L === 0 && r.sample.validity_R === 0);
  if (valid.length < 10) throw new Error(`Only ${valid.length} valid samples — need at least 10`);

  // Shuffle deterministically
  const rng = mulberry32(seed);
  const indices = valid.map((_, i) => i);
  for (let i = indices.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [indices[i], indices[j]] = [indices[j]!, indices[i]!];
  }

  const nTest = Math.max(1, Math.floor(valid.length * testFraction));
  const nTrain = valid.length - nTest;
  const trainIdx = indices.slice(0, nTrain);
  const testIdx = indices.slice(nTrain);

  // Extract raw features
  const names = featureNames(featureSet);
  const nRaw = names.length;
  const allFeats = valid.map(r => extractFeatures(r.sample, featureSet));

  // Normalize
  const inputMean = new Array(nRaw).fill(0) as number[];
  const inputStd = new Array(nRaw).fill(0) as number[];
  for (const i of trainIdx) {
    const f = allFeats[i]!;
    for (let j = 0; j < nRaw; j++) inputMean[j] = inputMean[j]! + f[j]!;
  }
  for (let j = 0; j < nRaw; j++) inputMean[j] = inputMean[j]! / nTrain;
  for (const i of trainIdx) {
    const f = allFeats[i]!;
    for (let j = 0; j < nRaw; j++) inputStd[j] = inputStd[j]! + (f[j]! - inputMean[j]!) ** 2;
  }
  for (let j = 0; j < nRaw; j++) inputStd[j] = Math.sqrt(inputStd[j]! / nTrain) || 1;

  const normalize = (f: number[]) => f.map((v, j) => (v - inputMean[j]!) / inputStd[j]!);

  // Build design matrix and target
  const nPoly = polyFeatureCount(nRaw, polyDegree);
  const Xtrain = new Float64Array(nTrain * nPoly);
  const Ytrain = new Float64Array(nTrain * 2);
  for (let i = 0; i < nTrain; i++) {
    const idx = trainIdx[i]!;
    const expanded = polyExpand(normalize(allFeats[idx]!), polyDegree);
    for (let j = 0; j < nPoly; j++) Xtrain[i * nPoly + j] = expanded[j]!;
    Ytrain[i * 2] = valid[idx]!.cursor_norm[0];
    Ytrain[i * 2 + 1] = valid[idx]!.cursor_norm[1];
  }

  const W = ridgeSolve(Xtrain, nTrain, nPoly, Ytrain, 2, lambda);

  // Convert W to 2D array
  const weights: number[][] = [];
  for (let i = 0; i < nPoly; i++) {
    weights.push([W[i * 2]!, W[i * 2 + 1]!]);
  }

  const model: TrainedModel = { featureNames: names, polyDegree, lambda, weights, inputMean, inputStd };

  // Predict
  const predict = (feats: number[]): [number, number] => {
    const expanded = polyExpand(normalize(feats), polyDegree);
    let px = 0, py = 0;
    for (let j = 0; j < nPoly; j++) {
      px += expanded[j]! * weights[j]![0]!;
      py += expanded[j]! * weights[j]![1]!;
    }
    return [px, py];
  };

  const trainPredictions: number[][] = [];
  let trainErrX = 0, trainErrY = 0;
  for (const i of trainIdx) {
    const pred = predict(allFeats[i]!);
    trainPredictions.push(pred);
    trainErrX += (pred[0] - valid[i]!.cursor_norm[0]) ** 2;
    trainErrY += (pred[1] - valid[i]!.cursor_norm[1]) ** 2;
  }

  const testPredictions: number[][] = [];
  let testErrX = 0, testErrY = 0;
  for (const i of testIdx) {
    const pred = predict(allFeats[i]!);
    testPredictions.push(pred);
    testErrX += (pred[0] - valid[i]!.cursor_norm[0]) ** 2;
    testErrY += (pred[1] - valid[i]!.cursor_norm[1]) ** 2;
  }

  return {
    model,
    trainRmse: [Math.sqrt(trainErrX / nTrain), Math.sqrt(trainErrY / nTrain)],
    testRmse: [Math.sqrt(testErrX / nTest), Math.sqrt(testErrY / nTest)],
    trainPredictions,
    testPredictions,
    trainIndices: trainIdx,
    testIndices: testIdx,
  };
}
