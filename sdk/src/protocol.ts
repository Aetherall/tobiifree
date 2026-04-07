// protocol.ts — public types and a few TTP constants callers may want.
// All wire-format logic lives in the Zig wasm module.

export const STREAM_GAZE = 0x500;

export type Vec2 = { x: number; y: number };
export type Vec3 = { x: number; y: number; z: number };

/**
 * Decoded 0x500 gaze notification. Any field absent from this frame is
 * left undefined — check individual fields before using them.
 *
 * ## Coordinate spaces
 *
 * - **tracker-space** (mm): origin at the tracker's IR sensor array.
 *   X = horizontal (right positive), Y = vertical (up positive),
 *   Z = depth away from the tracker (positive toward user).
 *
 * - **display-space** (mm): tracker-space translated by the display_area
 *   position. For axis-aligned flat planes this is a pure Z offset;
 *   for tilted planes a rotation is also applied.
 *
 * ## Validity
 *
 * `validity_L` / `validity_R`: 0 = valid, 4 = eye not detected.
 * When invalid, all associated vectors are zeroed and scalars are -1.
 */
export type GazeSample = {
  /** Device µs clock. */
  timestamp_us?: number;
  /** Monotonic frame index. */
  frame_counter?: number;

  /** 0 = valid, 4 = eye not detected. */
  validity_L?: number;
  /** 0 = valid, 4 = eye not detected. */
  validity_R?: number;

  /** Pupil diameter in mm; -1 when eye not detected. */
  pupil_diameter_L_mm?: number;
  /** Pupil diameter in mm; -1 when eye not detected. */
  pupil_diameter_R_mm?: number;

  /** Combined binocular 2D gaze on display_area [0,1]², temporally filtered. */
  gaze_point_2d_norm?: Vec2;
  /** Per-eye left 2D projection on display_area [0,1]². */
  gaze_point_2d_L_norm?: Vec2;
  /** Per-eye right 2D projection on display_area [0,1]². */
  gaze_point_2d_R_norm?: Vec2;

  /** Calibrated left eye position in tracker-space (mm). */
  eye_origin_L_mm?: Vec3;
  /** Calibrated right eye position in tracker-space (mm). */
  eye_origin_R_mm?: Vec3;
  /**
   * Left "gaze direction" — **NOT a direction vector at all**. Despite the
   * column name, this encodes the eye's normalized position in the track box:
   *   d.x ≈ 0.5 − eye.x/457,  d.y ≈ 0.5 − eye.y/463,  d.z ≈ eye.z/503 − 0.78
   * Reconstruction error vs eye_origin is ~4mm. This is a redundant copy
   * of eye position in a per-eye-model scale. Not useful for gaze —
   * use gaze_point_3d_L_mm or gaze_point_2d_L_norm instead.
   */
  trackbox_eye_pos_L?: Vec3;
  /**
   * Right "gaze direction" — same as left: normalized track-box position,
   * not a direction. Coefficients differ per eye.
   */
  trackbox_eye_pos_R?: Vec3;
  /** Left ray–plane intersection in tracker-space (mm). */
  gaze_point_3d_L_mm?: Vec3;
  /** Right ray–plane intersection in tracker-space (mm). */
  gaze_point_3d_R_mm?: Vec3;
};

export type DisplayArea = {
  tl: Vec3;
  tr: Vec3;
  bl: Vec3;
};

export type DisplayRect = {
  w: number;   // mm
  h: number;   // mm
  ox: number;  // BL.x in mm (tracker-relative)
  oy: number;  // BL.y in mm
  z: number;   // plane depth in mm
};

export type GazeColumnKind = 's64' | 'u32' | 'point2d' | 'point3d' | 'fixed16x16';

/**
 * Raw gaze column — one per TLV field in the 0x500 payload. Opt-in via
 * `Tracker.subscribeToRawGaze()`; useful for protocol RE and for
 * surfacing columns that aren't in the curated GazeSample yet.
 */
export type RawGazeColumn = {
  colId: number;
  kind: GazeColumnKind;
  v0: number;
  v1: number;
  v2: number;
};

/**
 * Semantic name for each known 0x500 gaze stream column ID.
 *
 * The gaze pipeline has three coordinate spaces:
 *  - **tracker-space**: origin at the tracker's IR sensor array.
 *  - **display-space**: tracker-space translated by the display_area offset
 *    (dx=0, dy=0, dz=display_area.z). No rotation for flat planes.
 *  - **normalized 2D**: ray→plane intersection on the display_area, in [0,1]².
 *
 * Eye origins come in three variants:
 *  - **raw** (0x17/0x18): pre-calibration eye position from IR pupil/glint detection.
 *  - **calibrated** (0x02/0x08): after per-user onboard calibration model correction
 *    (systematic offset of ~1–5mm from raw).
 *  - **display-relative** (0x22/0x24): calibrated origin shifted into display_area frame.
 *
 * "Gaze directions" — **misleading column name**: these are NOT direction
 * vectors. They encode the eye's normalized position in the track box
 * (d ≈ linear_transform(eye_origin), reconstruction error ~4mm).
 *  - **eye-model coords** (0x03/0x09): normalized track-box position, per eye.
 *  - **display-space** (0x25/0x27): same in display_area frame
 *    (observed as zeros/invalid on tested firmware; may be unused).
 *
 * 2D gaze points:
 *  - **per-eye** (0x05/0x0b): ray→plane intersection per eye.
 *  - **combined raw** (0x20): binocular average before temporal filtering.
 *  - **combined filtered** (0x1c): final output after smoothing (what apps render).
 *
 * Validity flags follow data columns. 0=valid, 4=invalid (eye not detected).
 * Status flags (0x15/0x16/etc.) are per-eye booleans: 1=eye present, 0=absent.
 */
export const GAZE_COLUMN_LABELS: Record<number, string> = {
  // ── Timestamp & frame ──────────────────────────────────────────────
  0x01: 'timestamp_us',               // [s64]     device µs clock
  0x14: 'frame_counter',              // [u32]     monotonic frame index

  // ── Left eye (calibrated, tracker-space) ───────────────────────────
  0x02: 'eye_origin_L_mm',            // [point3d] calibrated eye position (mm, tracker-space)
  0x03: 'trackbox_eye_pos_L',       // [point3d] gaze direction in eye-model coords (NOT tracker-space)
  0x04: 'gaze_point_3d_L_mm',         // [point3d] ray–plane intersection (mm, tracker-space)
  0x05: 'gaze_point_2d_L_norm',       // [point2d] per-eye 2D projection on display_area [0,1]²
  0x06: 'pupil_diameter_L_mm',        // [fix16]   pupil diameter; -1 when invalid
  0x07: 'validity_L',                 // [u32]     0=valid, 4=not detected

  // ── Right eye (calibrated, tracker-space) ──────────────────────────
  0x08: 'eye_origin_R_mm',            // [point3d] calibrated eye position (mm, tracker-space)
  0x09: 'trackbox_eye_pos_R',       // [point3d] gaze direction in eye-model coords (NOT tracker-space)
  0x0a: 'gaze_point_3d_R_mm',        // [point3d] ray–plane intersection (mm, tracker-space)
  0x0b: 'gaze_point_2d_R_norm',      // [point2d] per-eye 2D projection on display_area [0,1]²
  0x0c: 'pupil_diameter_R_mm',       // [fix16]   pupil diameter; -1 when invalid
  0x0d: 'validity_R',                // [u32]     0=valid, 4=not detected

  // ── Tracking status ────────────────────────────────────────────────
  0x0e: 'tracking_status_0e',         // [u32]     unknown — always observed as 0 or 4
  0x11: 'tracking_mode',              // [u32]     always 4 — likely tracking mode/config
  0x15: 'eye_present_L',              // [u32]     1=left eye detected, 0=absent
  0x16: 'eye_present_R',              // [u32]     1=right eye detected, 0=absent
  0x1b: 'binocular_flag',             // [u32]     1=both eyes detected, 0=monocular/none

  // ── Raw / uncalibrated eye origins ─────────────────────────────────
  0x17: 'eye_origin_raw_L_mm',        // [point3d] pre-calibration left eye position (tracker-space)
  0x18: 'eye_origin_raw_R_mm',        // [point3d] pre-calibration right eye position (tracker-space)

  // ── Combined 2D gaze output ────────────────────────────────────────
  0x19: 'gaze_point_2d_unused_19',    // [point2d] always (-1,-1) — unused output slot
  0x1a: 'gaze_point_2d_unused_1a',    // [point2d] always (-1,-1) — unused output slot
  0x1c: 'gaze_point_2d_norm',         // [point2d] combined binocular 2D gaze, temporally filtered
  0x1d: 'gaze_2d_valid',              // [u32]     1=combined 2D gaze valid, 0=invalid
  0x1e: 'gaze_2d_L_valid',            // [u32]     1=left per-eye 2D valid, 0=invalid
  0x1f: 'gaze_2d_R_valid',            // [u32]     1=right per-eye 2D valid, 0=invalid
  0x20: 'gaze_point_2d_unfiltered',   // [point2d] combined 2D gaze before temporal smoothing
  0x21: 'gaze_2d_unfiltered_valid',   // [u32]     1=unfiltered 2D valid, 0=invalid

  // ── Display-space eye data ─────────────────────────────────────────
  0x22: 'eye_origin_L_display_mm',    // [point3d] calibrated left eye in display_area frame
  0x23: 'eye_origin_L_display_valid', // [u32]     1=valid, 0=invalid
  0x24: 'eye_origin_R_display_mm',    // [point3d] calibrated right eye in display_area frame
  0x25: 'gaze_direction_L_display',   // [point3d] left gaze direction in display_area frame
  0x26: 'gaze_dir_L_display_valid',   // [u32]     1=valid, 0=invalid
  0x27: 'gaze_direction_R_display',   // [point3d] right gaze direction in display_area frame
  0x28: 'gaze_dir_R_display_valid',   // [u32]     1=valid, 0=invalid

  // ── Unknown scalars (always -1 / 0) ────────────────────────────────
  0x29: 'scalar_unused_29',           // [fix16]   always -1 — reserved/unused
  0x2a: 'scalar_unused_29_valid',     // [u32]     always 0
  0x2b: 'scalar_unused_2b',           // [fix16]   always -1 — reserved/unused
  0x2c: 'scalar_unused_2b_valid',     // [u32]     always 0
};

export type TtpFrame = {
  magic: number;
  seq: number;
  op: number;
  /** View into wasm memory — copy if you need to retain across awaits. */
  payload: Uint8Array;
};
