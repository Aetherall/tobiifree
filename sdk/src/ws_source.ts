// ws_source.ts — Source implementation over WebSocket to tobiifreed.
//
// Speaks daemon protocol. No wasm, no handshake — the daemon's Tracker
// already connected to the hardware and handles TTP framing.

import type { Source, Unsubscribe } from './source';
import type { DisplayArea, DisplayRect, GazeSample } from './protocol';
import { readGazeSample } from './gaze_view';

const log = (...args: unknown[]) => console.log('[ws-source]', ...args);
const logErr = (...args: unknown[]) => console.error('[ws-source]', ...args);

// Daemon protocol constants (must match daemon_protocol.zig).
const HEADER_SIZE = 5;

const SRV = { GAZE: 0x01, RESPONSE: 0x02, DISPLAY_AREA: 0x03, ERR: 0xFF } as const;

const CMD = {
  SUBSCRIBE: 0x01,
  GET_DISPLAY_AREA: 0x02,
  SET_DISPLAY_AREA: 0x03,
  SET_DISPLAY_AREA_CORNERS: 0x04,
  START_CALIBRATION: 0x20,
  ADD_CALIBRATION_POINT: 0x21,
  FINISH_CALIBRATION: 0x22,
  CAL_APPLY: 0x23,
} as const;

type Resolver = { resolve: (payload: Uint8Array) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> };

export class WsSource implements Source {
  private ws: WebSocket;
  private gazeListeners = new Set<(s: GazeSample) => void>();
  private pending = new Map<number, Resolver>();
  private recvBuf = new Uint8Array(0);
  private requestTimeoutMs: number;
  private closed = false;
  private _displayArea: DisplayArea | null = null;

  private constructor(ws: WebSocket, requestTimeoutMs: number) {
    this.ws = ws;
    this.requestTimeoutMs = requestTimeoutMs;

    ws.onmessage = (ev) => {
      if (ev.data instanceof ArrayBuffer) {
        this.onBinary(new Uint8Array(ev.data));
      }
    };
    ws.onclose = () => { log('disconnected'); };
    ws.onerror = (e) => { logErr('ws error', e); };
  }

  static async connect(url: string, requestTimeoutMs = 2000): Promise<WsSource> {
    log('connecting to', url);
    const ws = await new Promise<WebSocket>((resolve, reject) => {
      const s = new WebSocket(url);
      s.binaryType = 'arraybuffer';
      s.onopen = () => { s.onerror = null; s.onclose = null; resolve(s); };
      s.onclose = (e) => reject(new Error(`WebSocket closed during connect (${url}, code=${e.code}, reason=${e.reason || 'none'})`));
      s.onerror = () => {}; // onclose always fires after onerror, reject there for better info
    });
    log('connected');
    const src = new WsSource(ws, requestTimeoutMs);
    // Read display area from device (device is source of truth).
    try {
      src._displayArea = await src.getDisplayArea();
      log('device display_area', src._displayArea);
    } catch (e) {
      log('warning: could not read display_area from device', e);
    }
    return src;
  }

  // ── Source interface ──────────────────────────────────────────────

  get displayArea(): DisplayArea | null { return this._displayArea; }

  subscribeToGaze(listener: (s: GazeSample) => void): Unsubscribe {
    const first = this.gazeListeners.size === 0;
    this.gazeListeners.add(listener);
    if (first) {
      log('subscribing to gaze');
      this.sendCmd(CMD.SUBSCRIBE);
    }
    return () => { this.gazeListeners.delete(listener); };
  }

  async getDisplayArea(): Promise<DisplayArea> {
    const payload = await this.request(CMD.GET_DISPLAY_AREA);
    if (payload.byteLength < 72) {
      throw new Error(`display_area response too short: ${payload.byteLength}`);
    }
    const dv = new DataView(payload.buffer, payload.byteOffset, 72);
    const da: DisplayArea = {
      tl: { x: dv.getFloat64(0, true), y: dv.getFloat64(8, true), z: dv.getFloat64(16, true) },
      tr: { x: dv.getFloat64(24, true), y: dv.getFloat64(32, true), z: dv.getFloat64(40, true) },
      bl: { x: dv.getFloat64(48, true), y: dv.getFloat64(56, true), z: dv.getFloat64(64, true) },
    };
    this._displayArea = da;
    return da;
  }

  async setDisplayArea(rect: DisplayRect): Promise<void> {
    this.sendCmd(CMD.SET_DISPLAY_AREA, encodeF64s(rect.w, rect.h, rect.ox, rect.oy, rect.z));
    try { await this.getDisplayArea(); } catch {}
  }

  async setDisplayAreaCorners(area: DisplayArea): Promise<void> {
    this.sendCmd(CMD.SET_DISPLAY_AREA_CORNERS, encodeF64s(
      area.tl.x, area.tl.y, area.tl.z,
      area.tr.x, area.tr.y, area.tr.z,
      area.bl.x, area.bl.y, area.bl.z,
    ));
    try { await this.getDisplayArea(); } catch {}
  }

  async startCalibration(): Promise<void> {
    await this.request(CMD.START_CALIBRATION, undefined, 10_000);
  }

  async addCalibrationPoint(x: number, y: number): Promise<void> {
    const payload = new ArrayBuffer(16);
    const dv = new DataView(payload);
    dv.setFloat64(0, x, true);
    dv.setFloat64(8, y, true);
    await this.request(CMD.ADD_CALIBRATION_POINT, new Uint8Array(payload), 10_000);
  }

  async finishCalibration(): Promise<Uint8Array> {
    return this.request(CMD.FINISH_CALIBRATION, undefined, 30_000);
  }

  async calApply(blob: Uint8Array): Promise<void> {
    await this.request(CMD.CAL_APPLY, blob, 15_000);
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    log('closing');
    this.ws.close();
    for (const [, r] of this.pending) { clearTimeout(r.timer); r.reject(new Error('source closed')); }
    this.pending.clear();
    this.gazeListeners.clear();
  }

  // ── Daemon protocol send/receive ──────────────────────────────────

  private sendCmd(cmdType: number, payload?: Uint8Array): void {
    const payloadLen = payload?.byteLength ?? 0;
    const buf = new Uint8Array(HEADER_SIZE + payloadLen);
    buf[0] = cmdType;
    new DataView(buf.buffer).setUint32(1, payloadLen, true);
    if (payload) buf.set(payload, HEADER_SIZE);
    this.ws.send(buf);
  }

  private request(cmdType: number, payload?: Uint8Array, timeoutMs?: number): Promise<Uint8Array> {
    const ms = timeoutMs ?? this.requestTimeoutMs;
    const waiter = new Promise<Uint8Array>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(cmdType);
        reject(new Error(`Daemon cmd 0x${cmdType.toString(16)} timed out`));
      }, ms);
      this.pending.set(cmdType, { resolve, reject, timer });
    });
    this.sendCmd(cmdType, payload);
    return waiter;
  }

  // ── Inbound message parsing ───────────────────────────────────────

  private onBinary(data: Uint8Array): void {
    // Ensure we work with a plain ArrayBuffer (not SharedArrayBuffer).
    const chunk = new Uint8Array(data);
    if (this.recvBuf.byteLength === 0) {
      this.recvBuf = chunk;
    } else {
      const combined = new Uint8Array(this.recvBuf.byteLength + chunk.byteLength);
      combined.set(this.recvBuf);
      combined.set(chunk, this.recvBuf.byteLength);
      this.recvBuf = combined;
    }

    let pos = 0;
    while (pos + HEADER_SIZE <= this.recvBuf.byteLength) {
      const msgType = this.recvBuf[pos]!;
      const payloadLen = new DataView(
        this.recvBuf.buffer, this.recvBuf.byteOffset + pos + 1, 4,
      ).getUint32(0, true);
      const msgEnd = pos + HEADER_SIZE + payloadLen;
      if (msgEnd > this.recvBuf.byteLength) break;

      const payload = this.recvBuf.slice(pos + HEADER_SIZE, msgEnd);
      this.dispatch(msgType, payload);
      pos = msgEnd;
    }
    if (pos > 0) this.recvBuf = this.recvBuf.slice(pos);
  }

  private dispatch(msgType: number, payload: Uint8Array<ArrayBuffer>): void {
    switch (msgType) {
      case SRV.GAZE: {
        if (payload.byteLength >= 232) {
          const sample = readGazeSample(payload.buffer, payload.byteOffset);
          for (const l of this.gazeListeners) l(sample);
        }
        break;
      }
      case SRV.RESPONSE: {
        if (payload.byteLength >= 1) {
          const cmdType = payload[0]!;
          const data = payload.slice(1);
          const r = this.pending.get(cmdType);
          if (r) {
            this.pending.delete(cmdType);
            clearTimeout(r.timer);
            r.resolve(data);
          }
        }
        break;
      }
      case SRV.DISPLAY_AREA: {
        const r = this.pending.get(CMD.GET_DISPLAY_AREA);
        if (r) {
          this.pending.delete(CMD.GET_DISPLAY_AREA);
          clearTimeout(r.timer);
          r.resolve(payload);
        }
        break;
      }
      case SRV.ERR: {
        logErr('daemon error', payload.byteLength >= 4
          ? '0x' + new DataView(payload.buffer, payload.byteOffset, 4).getUint32(0, true).toString(16)
          : 'unknown');
        break;
      }
    }
  }
}

// ── Encoding helpers ──────────────────────────────────────────────

function encodeF64s(...values: number[]): Uint8Array {
  const buf = new ArrayBuffer(values.length * 8);
  const dv = new DataView(buf);
  for (let i = 0; i < values.length; i++) dv.setFloat64(i * 8, values[i]!, true);
  return new Uint8Array(buf);
}
