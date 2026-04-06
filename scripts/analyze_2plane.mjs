#!/usr/bin/env node
// Offline analysis of a two-plane gaze collection dataset.
// Usage: node scripts/analyze_2plane.mjs <path>

import fs from 'fs';

const path = process.argv[2];
if (!path) { console.error('usage: analyze_2plane.mjs <file.json>'); process.exit(1); }
const data = JSON.parse(fs.readFileSync(path, 'utf8'));
console.log(`loaded ${data.samples.length} samples from ${data.captured_at}`);
console.log(`plane_A.z=${data.plane_A.tl.z}  plane_B.z=${data.plane_B.tl.z}`);

const S = data.samples.filter(r => r.sample.validity_L === 0 && r.sample.validity_R === 0);
console.log(`valid: ${S.length}`);

// Drop samples too close to a plane switch (150ms settle).
// The plane-tag ground-truth is which plane was active at capture time,
// so we need to identify the first sample of each plane-run and drop
// the first ~150ms.
const settled = [];
let lastPlane = null, runStart = 0;
for (const r of S) {
  if (r.plane !== lastPlane) { lastPlane = r.plane; runStart = r.t_ms; }
  if (r.t_ms - runStart >= 150) settled.push(r);
}
console.log(`after 150ms settle-drop: ${settled.length}`);

// --- Bin samples by cursor position to pair A and B ---
// For each cursor position (bin), collect the gaze_point_3d means on
// plane A and plane B. Pair-wise: the line through the two means is
// (approximately) the device's internal gaze ray — invariant to which
// plane is configured.

function binKey(cx, cy, gridN) {
  return `${Math.floor(cx*gridN)},${Math.floor(cy*gridN)}`;
}

const GRID = 8; // 8x8 cells of the viewport
const bins = new Map();
for (const r of settled) {
  const [cx, cy] = r.cursor_norm;
  const k = binKey(cx, cy, GRID);
  if (!bins.has(k)) bins.set(k, { A: [], B: [] });
  bins.get(k)[r.plane].push(r);
}

// Summarize: bins with both A and B samples, averaged.
// Use per-eye midpoint of gaze_point_3d.
const triangulated = [];
for (const [k, b] of bins) {
  if (b.A.length < 3 || b.B.length < 3) continue;
  const avg = (arr) => {
    const sum = { cx:0, cy:0, x:0, y:0, z:0 };
    for (const r of arr) {
      sum.cx += r.cursor_norm[0]; sum.cy += r.cursor_norm[1];
      sum.x += (r.sample.gaze_point_3d_L_mm.x + r.sample.gaze_point_3d_R_mm.x)*0.5;
      sum.y += (r.sample.gaze_point_3d_L_mm.y + r.sample.gaze_point_3d_R_mm.y)*0.5;
      sum.z += (r.sample.gaze_point_3d_L_mm.z + r.sample.gaze_point_3d_R_mm.z)*0.5;
    }
    const n = arr.length;
    return { cx: sum.cx/n, cy: sum.cy/n, x: sum.x/n, y: sum.y/n, z: sum.z/n, n };
  };
  const A = avg(b.A), B = avg(b.B);
  // Cursor should be the same; average them.
  const cx = (A.cx*A.n + B.cx*B.n) / (A.n + B.n);
  const cy = (A.cy*A.n + B.cy*B.n) / (A.n + B.n);
  triangulated.push({ key: k, cx, cy, nA: A.n, nB: B.n, WA: A, WB: B });
}
console.log(`\npaired bins: ${triangulated.length}`);

// Each triangulated bin gives us:
//   WA on plane A (z=0), WB on plane B (z=300). The true ray passes
//   through both. We know the user was looking at cursor (cx, cy),
//   which (in fullscreen) is the display-normalized position on the
//   REAL monitor. So we have (cursor, ray) pairs.
// Fit display_area P* = (tl, u=tr-tl, v=bl-tl) such that for each i:
//   WA_i + t_i · dir_i  lies at  tl + cx_i·u + cy_i·v  for some t_i > 0.
// 3k equations, 9+k unknowns.

// Build normal equations.
function fitPlane(tris) {
  const k = tris.length;
  if (k < 5) return null;
  const N = 9 + k;
  const AtA = new Float64Array(N*N);
  const Atb = new Float64Array(N);
  for (let i = 0; i < k; i++) {
    const { cx, cy, WA, WB } = tris[i];
    const dx = WB.x - WA.x, dy = WB.y - WA.y, dz = WB.z - WA.z;
    const dl = Math.hypot(dx, dy, dz);
    const d = [dx/dl, dy/dl, dz/dl];
    const O = [WA.x, WA.y, WA.z];
    for (let a = 0; a < 3; a++) {
      // row[a]=1, row[3+a]=cx, row[6+a]=cy, row[9+i]=-d[a]; rhs=O[a]
      const cols = [a, 3+a, 6+a, 9+i];
      const vals = [1, cx, cy, -d[a]];
      const rhs = O[a];
      for (let p = 0; p < 4; p++) {
        Atb[cols[p]] += vals[p] * rhs;
        for (let q = 0; q < 4; q++) {
          AtA[cols[p]*N + cols[q]] += vals[p] * vals[q];
        }
      }
    }
  }
  // Gaussian elimination.
  const M = new Float64Array(N*(N+1));
  for (let r = 0; r < N; r++) {
    for (let c = 0; c < N; c++) M[r*(N+1)+c] = AtA[r*N+c];
    M[r*(N+1)+N] = Atb[r];
  }
  for (let col = 0; col < N; col++) {
    let piv = col, best = Math.abs(M[col*(N+1)+col]);
    for (let r = col+1; r < N; r++) {
      const v = Math.abs(M[r*(N+1)+col]);
      if (v > best) { best = v; piv = r; }
    }
    if (best < 1e-9) return null;
    if (piv !== col) for (let c = 0; c <= N; c++) { const t = M[col*(N+1)+c]; M[col*(N+1)+c] = M[piv*(N+1)+c]; M[piv*(N+1)+c] = t; }
    const inv = 1 / M[col*(N+1)+col];
    for (let r = 0; r < N; r++) {
      if (r === col) continue;
      const f = M[r*(N+1)+col] * inv;
      if (f === 0) continue;
      for (let c = col; c <= N; c++) M[r*(N+1)+c] -= f * M[col*(N+1)+c];
    }
  }
  const x = new Array(N);
  for (let r = 0; r < N; r++) x[r] = M[r*(N+1)+N] / M[r*(N+1)+r];
  return {
    tl: { x: x[0], y: x[1], z: x[2] },
    u:  { x: x[3], y: x[4], z: x[5] },
    v:  { x: x[6], y: x[7], z: x[8] },
    ts: x.slice(9),
  };
}

const fit = fitPlane(triangulated);
if (!fit) { console.log('fit failed'); process.exit(1); }
const tr = { x: fit.tl.x+fit.u.x, y: fit.tl.y+fit.u.y, z: fit.tl.z+fit.u.z };
const bl = { x: fit.tl.x+fit.v.x, y: fit.tl.y+fit.v.y, z: fit.tl.z+fit.v.z };
const br = { x: tr.x+fit.v.x, y: tr.y+fit.v.y, z: tr.z+fit.v.z };
console.log('\nfitted display_area:');
console.log(`  tl = (${fit.tl.x.toFixed(1)}, ${fit.tl.y.toFixed(1)}, ${fit.tl.z.toFixed(1)})`);
console.log(`  tr = (${tr.x.toFixed(1)}, ${tr.y.toFixed(1)}, ${tr.z.toFixed(1)})`);
console.log(`  bl = (${bl.x.toFixed(1)}, ${bl.y.toFixed(1)}, ${bl.z.toFixed(1)})`);
console.log(`  br = (${br.x.toFixed(1)}, ${br.y.toFixed(1)}, ${br.z.toFixed(1)})`);
console.log(`  width  (tr−tl) = ${Math.hypot(fit.u.x,fit.u.y,fit.u.z).toFixed(1)} mm`);
console.log(`  height (bl−tl) = ${Math.hypot(fit.v.x,fit.v.y,fit.v.z).toFixed(1)} mm`);
// Angle u·v (should be ~90° for rectangular)
const dotuv = fit.u.x*fit.v.x+fit.u.y*fit.v.y+fit.u.z*fit.v.z;
const ulen = Math.hypot(fit.u.x,fit.u.y,fit.u.z);
const vlen = Math.hypot(fit.v.x,fit.v.y,fit.v.z);
console.log(`  u·v angle = ${(Math.acos(dotuv/(ulen*vlen))*180/Math.PI).toFixed(1)}°`);
// Normal & orientation
const nx = fit.u.y*fit.v.z-fit.u.z*fit.v.y;
const ny = fit.u.z*fit.v.x-fit.u.x*fit.v.z;
const nz = fit.u.x*fit.v.y-fit.u.y*fit.v.x;
const nl = Math.hypot(nx,ny,nz);
console.log(`  normal = (${(nx/nl).toFixed(3)}, ${(ny/nl).toFixed(3)}, ${(nz/nl).toFixed(3)})`);

// Residuals: for each pair, compute distance from ray to target-point-on-fitted-plane.
let rss = 0;
for (let i = 0; i < triangulated.length; i++) {
  const { cx, cy, WA, WB } = triangulated[i];
  const Tp = {
    x: fit.tl.x + cx*fit.u.x + cy*fit.v.x,
    y: fit.tl.y + cx*fit.u.y + cy*fit.v.y,
    z: fit.tl.z + cx*fit.u.z + cy*fit.v.z,
  };
  const dx = WB.x-WA.x, dy = WB.y-WA.y, dz = WB.z-WA.z;
  const dl = Math.hypot(dx,dy,dz);
  const d = {x:dx/dl,y:dy/dl,z:dz/dl};
  const rx = Tp.x-WA.x, ry = Tp.y-WA.y, rz = Tp.z-WA.z;
  const cx2 = ry*d.z-rz*d.y, cy2=rz*d.x-rx*d.z, cz2=rx*d.y-ry*d.x;
  rss += cx2*cx2+cy2*cy2+cz2*cz2;
}
const rmse = Math.sqrt(rss/triangulated.length);
console.log(`\nray→target-on-plane RMSE = ${rmse.toFixed(1)} mm`);

// Report depths t_i distribution.
const ts = fit.ts;
console.log(`t_i (depth from WA): min=${Math.min(...ts).toFixed(1)} max=${Math.max(...ts).toFixed(1)} mean=${(ts.reduce((a,b)=>a+b)/ts.length).toFixed(1)}`);

// Show a few triangulation examples.
console.log('\nsample rays:');
for (let i = 0; i < Math.min(10, triangulated.length); i++) {
  const { cx, cy, WA, WB, nA, nB } = triangulated[i];
  const dx = WB.x-WA.x, dy = WB.y-WA.y, dz = WB.z-WA.z;
  console.log(`  cursor=(${cx.toFixed(2)},${cy.toFixed(2)}) n=${nA}/${nB}  WA=(${WA.x.toFixed(0)},${WA.y.toFixed(0)},${WA.z.toFixed(0)}) WB=(${WB.x.toFixed(0)},${WB.y.toFixed(0)},${WB.z.toFixed(0)}) dz=${dz.toFixed(0)}`);
}
