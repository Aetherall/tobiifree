#!/usr/bin/env node
// Offline analysis of gaze sample collection dumps.
// Usage: node scripts/analyze_samples.mjs <path-to-json>

import fs from 'fs';

const path = process.argv[2];
if (!path) { console.error('usage: analyze_samples.mjs <file.json>'); process.exit(1); }
const data = JSON.parse(fs.readFileSync(path, 'utf8'));
console.log(`loaded ${data.samples.length} samples from ${data.captured_at}`);
console.log(`viewport_px=${data.viewport_px.join('x')}  plane.tl.z=${data.display_area_used.tl.z}`);

// Pull arrays.
const S = data.samples.filter(r => r.sample.validity_L === 0 && r.sample.validity_R === 0);
console.log(`valid samples: ${S.length}`);

// --- Q1: is gaze_point_3d on the configured plane? ---
{
  const area = data.display_area_used;
  // Plane is z=area.tl.z (axis-aligned in the dataset).
  const zs_L = S.map(r => r.sample.gaze_point_3d_L_mm.z - area.tl.z);
  const zs_R = S.map(r => r.sample.gaze_point_3d_R_mm.z - area.tl.z);
  const mx = (a) => Math.max(...a.map(Math.abs));
  console.log(`\nQ1: gaze_point_3d z vs plane.z — max |Δ| L=${mx(zs_L).toExponential(2)} R=${mx(zs_R).toExponential(2)}`);
}

// --- Q2: does eye_origin + k·gaze_direction == gaze_point_3d? ---
// Solve k from z-coord then check x/y residual.
{
  let rssL = 0, rssR = 0, n = 0;
  let kL_min=Infinity, kL_max=-Infinity;
  for (const r of S) {
    const O = r.sample.eye_origin_L_mm, d = r.sample.gaze_direction_L_emc, W = r.sample.gaze_point_3d_L_mm;
    if (Math.abs(d.z) < 1e-6) continue;
    const k = (W.z - O.z) / d.z;
    kL_min=Math.min(kL_min,k); kL_max=Math.max(kL_max,k);
    const px = O.x + k*d.x - W.x, py = O.y + k*d.y - W.y;
    rssL += px*px + py*py;
    const O2 = r.sample.eye_origin_R_mm, d2 = r.sample.gaze_direction_R_emc, W2 = r.sample.gaze_point_3d_R_mm;
    const k2 = (W2.z - O2.z) / d2.z;
    const p2x = O2.x + k2*d2.x - W2.x, p2y = O2.y + k2*d2.y - W2.y;
    rssR += p2x*p2x + p2y*p2y;
    n++;
  }
  console.log(`\nQ2: is O + k·d_unit == gaze_point_3d?`);
  console.log(`  L rmse xy = ${Math.sqrt(rssL/n).toFixed(3)} mm   k ∈ [${kL_min.toFixed(1)}, ${kL_max.toFixed(1)}]`);
  console.log(`  R rmse xy = ${Math.sqrt(rssR/n).toFixed(3)} mm`);
}

// --- Q3: gaze_direction z-sign — is it pointing toward screen (−z convention) or away? ---
{
  const zs = S.map(r => r.sample.gaze_direction_L_emc.z);
  const mean = zs.reduce((a,b)=>a+b,0)/zs.length;
  console.log(`\nQ3: mean gaze_direction_L.z = ${mean.toFixed(3)} (eye.z≈${S[0].sample.eye_origin_L_mm.z.toFixed(0)}, plane.z=${data.display_area_used.tl.z})`);
  console.log(`    positive means ray goes TOWARD larger z (away from plane if plane is at z<eye.z).`);
}

// --- Q4: residual between cursor_norm and gaze_point_2d_norm ---
// If the device's calibration is perfect for *this* plane, the device's
// 2d_norm should equal the user's fixation (the cursor). Any systematic
// offset is the per-user calibration bias.
{
  let sdx = 0, sdy = 0;
  let ssdx = 0, ssdy = 0;
  let n = 0;
  for (const r of S) {
    const [cx, cy] = r.cursor_norm;
    const g = r.sample.gaze_point_2d_norm;
    const dx = g.x - cx, dy = g.y - cy;
    sdx += dx; sdy += dy;
    ssdx += dx*dx; ssdy += dy*dy;
    n++;
  }
  const mx = sdx/n, my = sdy/n;
  const sx = Math.sqrt(ssdx/n - mx*mx), sy = Math.sqrt(ssdy/n - my*my);
  console.log(`\nQ4: gaze_point_2d_norm − cursor_norm (on the huge plane):`);
  console.log(`  mean Δ = (${mx.toFixed(4)}, ${my.toFixed(4)})   [in units of normalized plane coords]`);
  console.log(`  std  Δ = (${sx.toFixed(4)}, ${sy.toFixed(4)})`);
  // Convert to mm using plane dimensions.
  const area = data.display_area_used;
  const W_mm = Math.hypot(area.tr.x-area.tl.x, area.tr.y-area.tl.y, area.tr.z-area.tl.z);
  const H_mm = Math.hypot(area.bl.x-area.tl.x, area.bl.y-area.tl.y, area.bl.z-area.tl.z);
  console.log(`  plane = ${W_mm}mm × ${H_mm}mm`);
  console.log(`  mean Δ (mm) = (${(mx*W_mm).toFixed(1)}, ${(my*H_mm).toFixed(1)})`);
  console.log(`  std  Δ (mm) = (${(sx*W_mm).toFixed(1)}, ${(sy*H_mm).toFixed(1)})`);
}

// --- Q5: is the cursor → 2d_norm relation close to an affine transform? ---
// Fit gaze_2d = A·cursor + b (2x2 A + 2 b). If the user were perfectly
// calibrated this would be identity+0. Deviation hints at homography.
{
  // Build normal equations for [a00 a01 bx ; a10 a11 by].
  // Solve x = (cursor_x, cursor_y, 1), gaze = A*x.
  const rows = S.map(r => ({ cx: r.cursor_norm[0], cy: r.cursor_norm[1], gx: r.sample.gaze_point_2d_norm.x, gy: r.sample.gaze_point_2d_norm.y }));
  // MtM is 3x3.
  let m00=0,m01=0,m02=0,m11=0,m12=0,m22=0;
  let bx0=0,bx1=0,bx2=0,by0=0,by1=0,by2=0;
  for (const r of rows) {
    m00 += r.cx*r.cx; m01 += r.cx*r.cy; m02 += r.cx;
    m11 += r.cy*r.cy; m12 += r.cy;       m22 += 1;
    bx0 += r.cx*r.gx; bx1 += r.cy*r.gx; bx2 += r.gx;
    by0 += r.cx*r.gy; by1 += r.cy*r.gy; by2 += r.gy;
  }
  function solve3(M, b) {
    const [a,b_,c,d,e,f,g,h,i] = M;
    const [p,q,r] = b;
    const det = a*(e*i-f*h) - b_*(d*i-f*g) + c*(d*h-e*g);
    return [
      (p*(e*i-f*h) - b_*(q*i-f*r) + c*(q*h-e*r))/det,
      (a*(q*i-f*r) - p*(d*i-f*g) + c*(d*r-q*g))/det,
      (a*(e*r-q*h) - b_*(d*r-q*g) + p*(d*h-e*g))/det,
    ];
  }
  const M = [m00,m01,m02,m01,m11,m12,m02,m12,m22];
  const ax = solve3(M, [bx0,bx1,bx2]);
  const ay = solve3(M, [by0,by1,by2]);
  console.log(`\nQ5: affine gaze_2d = A·cursor + b`);
  console.log(`  A = [[${ax[0].toFixed(4)}, ${ax[1].toFixed(4)}], [${ay[0].toFixed(4)}, ${ay[1].toFixed(4)}]]`);
  console.log(`  b = [${ax[2].toFixed(4)}, ${ay[2].toFixed(4)}]`);
  // Residuals.
  let rss=0;
  for (const r of rows) {
    const px = ax[0]*r.cx+ax[1]*r.cy+ax[2] - r.gx;
    const py = ay[0]*r.cx+ay[1]*r.cy+ay[2] - r.gy;
    rss += px*px+py*py;
  }
  console.log(`  affine RMSE = ${Math.sqrt(rss/rows.length).toFixed(4)} (normalized) = ${(Math.sqrt(rss/rows.length)*Math.hypot(data.viewport_px[0], data.viewport_px[1])/Math.SQRT2).toFixed(1)}px approx`);
}

// --- Q6: binning — cursor grid → (mean gaze_2d, std) ---
// Visualize what the device reports per region of the screen.
{
  const nx = 5, ny = 3;
  const bins = new Map();
  for (const r of S) {
    const bx = Math.min(nx-1, Math.floor(r.cursor_norm[0]*nx));
    const by = Math.min(ny-1, Math.floor(r.cursor_norm[1]*ny));
    const k = `${bx},${by}`;
    if (!bins.has(k)) bins.set(k, []);
    bins.get(k).push(r);
  }
  console.log(`\nQ6: per-bin mean cursor → mean gaze_2d_norm (${nx}×${ny} grid)`);
  for (let by = 0; by < ny; by++) {
    for (let bx = 0; bx < nx; bx++) {
      const k = `${bx},${by}`;
      const arr = bins.get(k);
      if (!arr || arr.length < 3) { process.stdout.write(`  [${k}] n=${arr?.length??0}   `); continue; }
      const mcx = arr.reduce((s,r)=>s+r.cursor_norm[0],0)/arr.length;
      const mcy = arr.reduce((s,r)=>s+r.cursor_norm[1],0)/arr.length;
      const mgx = arr.reduce((s,r)=>s+r.sample.gaze_point_2d_norm.x,0)/arr.length;
      const mgy = arr.reduce((s,r)=>s+r.sample.gaze_point_2d_norm.y,0)/arr.length;
      process.stdout.write(`  (${mcx.toFixed(2)},${mcy.toFixed(2)})→(${mgx.toFixed(2)},${mgy.toFixed(2)}) Δ(${(mgx-mcx).toFixed(3)},${(mgy-mcy).toFixed(3)}) n=${arr.length}\n`);
    }
  }
}
