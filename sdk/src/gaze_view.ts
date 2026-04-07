// gaze_view.ts — reads the wasm-side extern GazeSample struct into TS.
//
// Layout MUST match tobiifree_core.zig : GazeSample (see @offsetOf probe).
// Present-mask bits mirror GAZE_BIT_* constants.
//
// All eye origins and trackbox positions here are post-calibration.
// Tracker-space fields use mm with origin at the IR sensor array.
// Display-space fields are shifted into the display_area frame.
// Raw/uncalibrated origins (cols 0x17/0x18) are only available via
// the raw column API (subscribeToRawGaze).

import type { GazeSample } from './protocol';

// Offsets (bytes) — do not reorder without updating tobiifree_core.zig.
const OFF_PRESENT            = 0;   // u32: bitmask of GAZE_BIT_* flags
const OFF_FRAME_COUNTER      = 4;   // u32: monotonic frame index
const OFF_VALIDITY_L         = 8;   // u32: 0=valid, 4=not detected
const OFF_VALIDITY_R         = 12;  // u32: 0=valid, 4=not detected
const OFF_TIMESTAMP_US       = 16;  // i64: device µs clock
const OFF_PUPIL_L            = 24;  // f64: pupil diameter mm, -1 if invalid
const OFF_PUPIL_R            = 32;  // f64: pupil diameter mm, -1 if invalid
const OFF_GAZE_2D            = 40;  // [2]f64: combined binocular 2D [0,1]², filtered
const OFF_GAZE_2D_L          = 56;  // [2]f64: left per-eye 2D projection
const OFF_GAZE_2D_R          = 72;  // [2]f64: right per-eye 2D projection
const OFF_EYE_ORIGIN_L       = 88;  // [3]f64: calibrated left eye pos (tracker-space mm)
const OFF_EYE_ORIGIN_R       = 112; // [3]f64: calibrated right eye pos (tracker-space mm)
const OFF_GAZE_DIR_L         = 136; // [3]f64: normalized track-box position, left eye
const OFF_GAZE_DIR_R         = 160; // [3]f64: normalized track-box position, right eye
const OFF_GAZE_3D_L          = 184; // [3]f64: left ray–plane intersection (tracker-space mm)
const OFF_GAZE_3D_R          = 208; // [3]f64: right ray–plane intersection (tracker-space mm)
const OFF_EYE_ORIGIN_L_DISP  = 232; // [3]f64: calibrated left eye pos (display-space mm)
const OFF_EYE_ORIGIN_R_DISP  = 256; // [3]f64: calibrated right eye pos (display-space mm)
const OFF_TRACKBOX_L_DISP    = 280; // [3]f64: normalized track-box position, left (display-space)
const OFF_TRACKBOX_R_DISP    = 304; // [3]f64: normalized track-box position, right (display-space)
const OFF_EYE_ORIGIN_RAW_L  = 328; // [3]f64: pre-calibration left eye pos (tracker-space mm)
const OFF_EYE_ORIGIN_RAW_R  = 352; // [3]f64: pre-calibration right eye pos (tracker-space mm)
const OFF_GAZE_2D_UNFILT    = 376; // [2]f64: combined 2D gaze before temporal smoothing

const BIT_TIMESTAMP     = 1 << 0;
const BIT_FRAME_COUNTER = 1 << 1;
const BIT_VALIDITY_L    = 1 << 2;
const BIT_VALIDITY_R    = 1 << 3;
const BIT_PUPIL_L       = 1 << 4;
const BIT_PUPIL_R       = 1 << 5;
const BIT_GAZE_2D       = 1 << 6;
const BIT_GAZE_2D_L     = 1 << 7;
const BIT_GAZE_2D_R     = 1 << 8;
const BIT_EYE_ORIGIN_L  = 1 << 9;
const BIT_EYE_ORIGIN_R  = 1 << 10;
const BIT_GAZE_DIR_L    = 1 << 11;
const BIT_GAZE_DIR_R    = 1 << 12;
const BIT_GAZE_3D_L     = 1 << 13;
const BIT_GAZE_3D_R     = 1 << 14;
const BIT_EYE_ORIGIN_L_DISP = 1 << 15;
const BIT_EYE_ORIGIN_R_DISP = 1 << 16;
const BIT_TRACKBOX_L_DISP   = 1 << 17;
const BIT_TRACKBOX_R_DISP   = 1 << 18;
const BIT_EYE_ORIGIN_RAW_L  = 1 << 19;
const BIT_EYE_ORIGIN_RAW_R  = 1 << 20;
const BIT_GAZE_2D_UNFILT    = 1 << 21;

export function readGazeSample(buffer: ArrayBuffer, ptr: number): GazeSample {
  const dv = new DataView(buffer, ptr, 392);
  const mask = dv.getUint32(OFF_PRESENT, true);
  const s: GazeSample = {};
  if (mask & BIT_TIMESTAMP) {
    // i64 read as two u32s; timestamps fit well within Number precision (μs since boot).
    const lo = dv.getUint32(OFF_TIMESTAMP_US, true);
    const hi = dv.getInt32(OFF_TIMESTAMP_US + 4, true);
    s.timestamp_us = hi * 0x1_0000_0000 + lo;
  }
  if (mask & BIT_FRAME_COUNTER) s.frame_counter = dv.getUint32(OFF_FRAME_COUNTER, true);
  if (mask & BIT_VALIDITY_L)    s.validity_L = dv.getUint32(OFF_VALIDITY_L, true);
  if (mask & BIT_VALIDITY_R)    s.validity_R = dv.getUint32(OFF_VALIDITY_R, true);
  if (mask & BIT_PUPIL_L)       s.pupil_diameter_L_mm = dv.getFloat64(OFF_PUPIL_L, true);
  if (mask & BIT_PUPIL_R)       s.pupil_diameter_R_mm = dv.getFloat64(OFF_PUPIL_R, true);
  if (mask & BIT_GAZE_2D) {
    s.gaze_point_2d_norm = { x: dv.getFloat64(OFF_GAZE_2D, true), y: dv.getFloat64(OFF_GAZE_2D + 8, true) };
  }
  if (mask & BIT_GAZE_2D_L) {
    s.gaze_point_2d_L_norm = { x: dv.getFloat64(OFF_GAZE_2D_L, true), y: dv.getFloat64(OFF_GAZE_2D_L + 8, true) };
  }
  if (mask & BIT_GAZE_2D_R) {
    s.gaze_point_2d_R_norm = { x: dv.getFloat64(OFF_GAZE_2D_R, true), y: dv.getFloat64(OFF_GAZE_2D_R + 8, true) };
  }
  if (mask & BIT_EYE_ORIGIN_L) s.eye_origin_L_mm = readV3(dv, OFF_EYE_ORIGIN_L);
  if (mask & BIT_EYE_ORIGIN_R) s.eye_origin_R_mm = readV3(dv, OFF_EYE_ORIGIN_R);
  if (mask & BIT_GAZE_DIR_L)   s.trackbox_eye_pos_L = readV3(dv, OFF_GAZE_DIR_L);
  if (mask & BIT_GAZE_DIR_R)   s.trackbox_eye_pos_R = readV3(dv, OFF_GAZE_DIR_R);
  if (mask & BIT_GAZE_3D_L)    s.gaze_point_3d_L_mm = readV3(dv, OFF_GAZE_3D_L);
  if (mask & BIT_GAZE_3D_R)    s.gaze_point_3d_R_mm = readV3(dv, OFF_GAZE_3D_R);
  if (mask & BIT_EYE_ORIGIN_L_DISP) s.eye_origin_L_display_mm = readV3(dv, OFF_EYE_ORIGIN_L_DISP);
  if (mask & BIT_EYE_ORIGIN_R_DISP) s.eye_origin_R_display_mm = readV3(dv, OFF_EYE_ORIGIN_R_DISP);
  if (mask & BIT_TRACKBOX_L_DISP)   s.trackbox_eye_pos_L_display = readV3(dv, OFF_TRACKBOX_L_DISP);
  if (mask & BIT_TRACKBOX_R_DISP)   s.trackbox_eye_pos_R_display = readV3(dv, OFF_TRACKBOX_R_DISP);
  if (mask & BIT_EYE_ORIGIN_RAW_L)  s.eye_origin_raw_L_mm = readV3(dv, OFF_EYE_ORIGIN_RAW_L);
  if (mask & BIT_EYE_ORIGIN_RAW_R)  s.eye_origin_raw_R_mm = readV3(dv, OFF_EYE_ORIGIN_RAW_R);
  if (mask & BIT_GAZE_2D_UNFILT) {
    s.gaze_point_2d_unfiltered = { x: dv.getFloat64(OFF_GAZE_2D_UNFILT, true), y: dv.getFloat64(OFF_GAZE_2D_UNFILT + 8, true) };
  }
  return s;
}

function readV3(dv: DataView, off: number) {
  return {
    x: dv.getFloat64(off, true),
    y: dv.getFloat64(off + 8, true),
    z: dv.getFloat64(off + 16, true),
  };
}
