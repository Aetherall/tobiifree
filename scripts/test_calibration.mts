#!/usr/bin/env node --experimental-strip-types
// Test calibration protocol against a live Tobii ET5.
// Usage: node --experimental-strip-types scripts/test_calibration.mts

import { Tobii, Tracker } from '../sdk/src/index.ts';

function hex(buf: Uint8Array): string {
  return [...buf].map(b => b.toString(16).padStart(2, '0')).join(' ');
}

async function main() {
  console.log('Opening tracker...');
  const tracker = await Tobii.createSession({ requestTimeoutMs: 5000 });
  console.log('Connected. Hello handshake done.');

  // Subscribe to gaze so we can see if calibration affects tracking
  let lastGaze = '';
  const unsub = tracker.subscribeToGaze(s => {
    if (s.gaze_point_2d_norm) {
      lastGaze = `gaze=(${s.gaze_point_2d_norm.x.toFixed(3)}, ${s.gaze_point_2d_norm.y.toFixed(3)})`;
    }
  });

  // Log raw TTP frames for debugging
  const unsubFrame = tracker.onFrame(f => {
    const opHex = f.op.toString(16).padStart(4, '0');
    const magicName = f.magic === 0x51 ? 'REQ' : f.magic === 0x52 ? 'RSP' : f.magic === 0x53 ? 'NTF' : `?${f.magic.toString(16)}`;
    // Only log non-gaze frames to avoid flooding
    if (f.op !== 0x500) {
      console.log(`  [${magicName}] seq=${f.seq} op=0x${opHex} plen=${f.payload.byteLength} data=${hex(f.payload.slice(0, 40))}`);
    }
  });

  try {
    // Step 1: Get current display area
    console.log('\n--- Display Area ---');
    const da = await tracker.getDisplayArea();
    console.log(`  TL=(${da.tl.x.toFixed(1)}, ${da.tl.y.toFixed(1)}, ${da.tl.z.toFixed(1)})`);
    console.log(`  TR=(${da.tr.x.toFixed(1)}, ${da.tr.y.toFixed(1)}, ${da.tr.z.toFixed(1)})`);
    console.log(`  BL=(${da.bl.x.toFixed(1)}, ${da.bl.y.toFixed(1)}, ${da.bl.z.toFixed(1)})`);

    // Step 2: Start calibration (unlocks realm internally)
    console.log('\n--- Start Calibration ---');
    await tracker.startCalibration();
    console.log('  Calibration started.');

    // Step 3: Run calibration with 5 standard points
    const points: [number, number][] = [
      [0.5, 0.5],   // center
      [0.1, 0.1],   // top-left
      [0.9, 0.1],   // top-right
      [0.1, 0.9],   // bottom-left
      [0.9, 0.9],   // bottom-right
    ];

    console.log('\n--- Calibrating (5 points) ---');
    console.log('Look at each point when prompted...');
    for (const [x, y] of points) {
      console.log(`\n  Point (${x}, ${y}) — collecting data...`);
      // Give user a moment to look at the point
      await new Promise(r => setTimeout(r, 1500));
      try {
        await tracker.addCalibrationPoint(x, y);
        console.log(`  Point collected.`);
      } catch (e) {
        console.log(`  ERROR: ${e}`);
      }
    }

    // Step 4: Finish calibration (compute + retrieve + close realm)
    console.log('\n--- Finish Calibration ---');
    try {
      const blob = await tracker.finishCalibration();
      console.log(`  Calibration blob: ${blob.byteLength} bytes`);
      console.log(`  First 40 bytes: ${hex(blob.slice(0, 40))}`);
    } catch (e) {
      console.log(`  ERROR: ${e}`);
    }

    // Wait a moment to see gaze data after calibration
    console.log('\n--- Post-calibration gaze ---');
    await new Promise(r => setTimeout(r, 2000));
    console.log(`  ${lastGaze}`);

  } catch (e) {
    console.error('Error:', e);
  } finally {
    unsub();
    unsubFrame();
    await tracker.close();
    console.log('\nDone.');
  }
}

main().catch(e => { console.error(e); process.exit(1); });
