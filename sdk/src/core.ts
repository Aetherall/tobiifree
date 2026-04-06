// core.ts — thin WASM wrapper. The wasm owns seq counters, request-id
// tracking, frame dispatch, and typed GazeSample assembly. TS only
// shuffles bytes and forwards typed events.

import type { DisplayArea, GazeSample, RawGazeColumn, GazeColumnKind, TtpFrame } from './protocol';
import { readGazeSample } from './gaze_view';

const KIND_NAMES: GazeColumnKind[] = ['s64', 'u32', 'point2d', 'point3d', 'fixed16x16'];

type Exports = {
  memory: WebAssembly.Memory;
  session_reset: () => void;
  session_out_ptr: () => number;
  session_out_len_: () => number;
  request_subscribe: (stream_id: number) => number;
  request_get_display_area: () => number;
  request_set_display_area: (w: number, h: number, ox: number, oy: number, z: number) => number;
  request_set_display_area_corners: (
    tlx: number, tly: number, tlz: number,
    trx: number, try_: number, trz: number,
    blx: number, bly: number, blz: number,
  ) => number;
  request_cal_add_point: (x: number, y: number, eye_choice: number) => number;
  scratch_ptr: () => number;
  feed_usb_in: (src: number, len: number) => void;
  decode_display_area: (src: number, len: number, out: number) => number;
  raw_columns_enable: (on: number) => void;
  handshake_init: (stream_id: number) => void;
  handshake_poll: () => number;
  cal_start_init: () => void;
  cal_start_poll: () => number;
  cal_finish_init: () => void;
  cal_finish_poll: () => number;
  cal_finish_blob_ptr: () => number;
  cal_finish_blob_len: () => number;
  cal_apply_init: (blob_len: number) => void;
  cal_apply_poll: () => number;
};


export type CoreEvents = {
  onFrame: (f: TtpFrame) => void;
  onResponse: (requestId: number, payload: Uint8Array) => void;
  onGaze: (sample: GazeSample) => void;
  onRawColumns: (cols: RawGazeColumn[]) => void;
  onParseError: (code: number) => void;
};

export type TobiiCore = {
  /** Reset seq counters + parser + pending table. Call after reconnect. */
  reset(): void;
  /** Build subscribe into the session out buffer. No response expected. */
  requestSubscribe(streamId: number): Uint8Array;
  /** Build get_display_area. Returns request_id. */
  requestGetDisplayArea(): { requestId: number; bytes: Uint8Array };
  /** Build set_display_area. No response expected. */
  requestSetDisplayArea(w: number, h: number, ox: number, oy: number, z: number): Uint8Array;
  /** Build set_display_area from 9 corner coordinates (tl/tr/bl × xyz). No response expected. */
  requestSetDisplayAreaCorners(
    tl: { x: number; y: number; z: number },
    tr: { x: number; y: number; z: number },
    bl: { x: number; y: number; z: number },
  ): Uint8Array;
  /** Feed a raw USB inbound chunk. Triggers events for complete frames. */
  feedUsbIn(chunk: Uint8Array): void;
  /** Decode a get_display_area response payload. */
  decodeDisplayArea(payload: Uint8Array): DisplayArea | null;
  /** Enable/disable the on_raw_columns callback. */
  setRawColumnsEnabled(on: boolean): void;
  /** Add calibration point. x/y normalized, eyeChoice: 0=both,1=L,2=R. Returns request_id. */
  requestCalAddPoint(x: number, y: number, eyeChoice: number): { requestId: number; bytes: Uint8Array };

  // --- State machines (all use same action codes: 1=send, 2=recv, 3=done, 4=error) ---

  handshakeInit(streamId: number): void;
  handshakePoll(): number;
  /** Get the current session_out bytes (for state machine send steps). */
  takeSessionOutBytes(): Uint8Array;

  calStartInit(): void;
  calStartPoll(): number;

  calFinishInit(): void;
  calFinishPoll(): number;
  /** After calFinishPoll returns done, the retrieved calibration blob. */
  calFinishBlob(): Uint8Array;

  /** Write a blob into the wasm scratch buffer (for calApply). */
  writeScratch(blob: Uint8Array): void;
  calApplyInit(blobLen: number): void;
  calApplyPoll(): number;
};

/** Rebuild the 24-byte TTP header + payload for storage/replay. */
export function buildTtpFrameBytes(f: TtpFrame): Uint8Array {
  const out = new Uint8Array(24 + f.payload.byteLength);
  const dv = new DataView(out.buffer);
  dv.setUint32(0, f.magic, false);
  dv.setUint32(4, f.seq, false);
  dv.setUint32(8, 0, false);
  dv.setUint32(12, f.op, false);
  dv.setUint32(16, 0, false);
  dv.setUint32(20, f.payload.byteLength, false);
  out.set(f.payload, 24);
  return out;
}

export async function loadCore(
  wasmBytes: BufferSource,
  events: CoreEvents,
): Promise<TobiiCore> {
  let instance: WebAssembly.Instance;

  const { instance: inst } = await WebAssembly.instantiate(wasmBytes, {
    env: {
      on_ttp_frame: (magic: number, seq: number, op: number,
                     pptr: number, plen: number) => {
        const exp = instance.exports as unknown as Exports;
        const view = new Uint8Array(exp.memory.buffer, pptr, plen);
        events.onFrame({ magic, seq, op, payload: view });
      },
      on_response: (requestId: number, pptr: number, plen: number) => {
        const exp = instance.exports as unknown as Exports;
        const view = new Uint8Array(exp.memory.buffer, pptr, plen);
        // Copy so callers can await freely.
        events.onResponse(requestId, view.slice());
      },
      on_gaze: (samplePtr: number) => {
        const exp = instance.exports as unknown as Exports;
        events.onGaze(readGazeSample(exp.memory.buffer, samplePtr));
      },
      on_raw_columns: (ptr: number, n: number) => {
        const exp = instance.exports as unknown as Exports;
        const view = new DataView(exp.memory.buffer, ptr, n * 32);
        const cols: RawGazeColumn[] = [];
        for (let i = 0; i < n; i++) {
          const off = i * 32;
          cols.push({
            colId: view.getUint32(off, true),
            kind: KIND_NAMES[view.getUint32(off + 4, true)] ?? 'u32',
            v0: view.getFloat64(off + 8, true),
            v1: view.getFloat64(off + 16, true),
            v2: view.getFloat64(off + 24, true),
          });
        }
        events.onRawColumns(cols);
      },
      on_parse_error: (code: number) => events.onParseError(code),
    },
  });
  instance = inst;
  const exp = instance.exports as unknown as Exports;

  // Growable IN_BUF for JS → wasm byte transfers + a tiny DECODE_IN/OUT
  // pair used by decodeDisplayArea (response payloads are ~150B).
  const currentPages = exp.memory.buffer.byteLength / 65536;
  exp.memory.grow(2);
  const IN_BUF_PTR = currentPages * 65536;
  const IN_BUF_SIZE = 65536;
  const DECODE_IN_PTR = IN_BUF_PTR + IN_BUF_SIZE;
  const DECODE_IN_SIZE = 32768;
  const DECODE_OUT_PTR = DECODE_IN_PTR + DECODE_IN_SIZE;

  const sessionOutPtr = exp.session_out_ptr();

  function takeOutBytes(): Uint8Array {
    const n = exp.session_out_len_();
    return new Uint8Array(exp.memory.buffer, sessionOutPtr, n).slice();
  }

  return {
    reset() { exp.session_reset(); },
    requestSubscribe(streamId) {
      exp.request_subscribe(streamId);
      return takeOutBytes();
    },
    requestGetDisplayArea() {
      const requestId = exp.request_get_display_area();
      return { requestId, bytes: takeOutBytes() };
    },
    requestSetDisplayArea(w, h, ox, oy, z) {
      exp.request_set_display_area(w, h, ox, oy, z);
      return takeOutBytes();
    },
    requestSetDisplayAreaCorners(tl, tr, bl) {
      exp.request_set_display_area_corners(
        tl.x, tl.y, tl.z,
        tr.x, tr.y, tr.z,
        bl.x, bl.y, bl.z,
      );
      return takeOutBytes();
    },
    feedUsbIn(chunk) {
      if (chunk.byteLength > IN_BUF_SIZE) {
        throw new Error(`chunk ${chunk.byteLength} > IN_BUF_SIZE ${IN_BUF_SIZE}`);
      }
      const dst = new Uint8Array(exp.memory.buffer, IN_BUF_PTR, chunk.byteLength);
      dst.set(chunk);
      exp.feed_usb_in(IN_BUF_PTR, chunk.byteLength);
    },
    setRawColumnsEnabled(on) { exp.raw_columns_enable(on ? 1 : 0); },

    requestCalAddPoint(x, y, eyeChoice) {
      const requestId = exp.request_cal_add_point(x, y, eyeChoice);
      return { requestId, bytes: takeOutBytes() };
    },

    // --- State machines ---

    handshakeInit(streamId) {
      exp.handshake_init(streamId);
    },
    handshakePoll() {
      return exp.handshake_poll();
    },
    takeSessionOutBytes() {
      return takeOutBytes();
    },

    calStartInit() {
      exp.cal_start_init();
    },
    calStartPoll() {
      return exp.cal_start_poll();
    },

    calFinishInit() {
      exp.cal_finish_init();
    },
    calFinishPoll() {
      return exp.cal_finish_poll();
    },
    calFinishBlob() {
      const ptr = exp.cal_finish_blob_ptr();
      const len = exp.cal_finish_blob_len();
      return new Uint8Array(exp.memory.buffer, ptr, len).slice();
    },

    calApplyInit(blobLen) {
      exp.cal_apply_init(blobLen);
    },
    calApplyPoll() {
      return exp.cal_apply_poll();
    },
    writeScratch(blob) {
      const scratchPtr = exp.scratch_ptr();
      const dst = new Uint8Array(exp.memory.buffer, scratchPtr, blob.byteLength);
      dst.set(blob);
    },

    decodeDisplayArea(payload) {
      if (payload.byteLength > DECODE_IN_SIZE) return null;
      const inBuf = new Uint8Array(exp.memory.buffer, DECODE_IN_PTR, payload.byteLength);
      inBuf.set(payload);
      const ok = exp.decode_display_area(DECODE_IN_PTR, payload.byteLength, DECODE_OUT_PTR);
      if (ok === 0) return null;
      const dv = new DataView(exp.memory.buffer, DECODE_OUT_PTR, 72);
      return {
        tl: { x: dv.getFloat64(0,  true), y: dv.getFloat64(8,  true), z: dv.getFloat64(16, true) },
        tr: { x: dv.getFloat64(24, true), y: dv.getFloat64(32, true), z: dv.getFloat64(40, true) },
        bl: { x: dv.getFloat64(48, true), y: dv.getFloat64(56, true), z: dv.getFloat64(64, true) },
      };
    },
  };
}

/** Convenience wrapper used by Tracker. */
export function decodeDisplayArea(core: TobiiCore, payload: Uint8Array): DisplayArea | null {
  return core.decodeDisplayArea(payload);
}
