// usb_source.ts — Source implementation over direct USB.
//
// Owns the WebUSB/node-usb Transport and the wasm core (Zig Tracker).
// Runs the TTP handshake internally, then exposes the consumer API.

import { loadCore, decodeDisplayArea, type TobiiCore } from './core';
import type { Transport } from './transport';
import type { Source, Unsubscribe } from './source';
import type { DisplayArea, DisplayRect, GazeSample, RawGazeColumn, TtpFrame } from './protocol';

const log = (...args: unknown[]) => console.log('[usb-source]', ...args);
const logErr = (...args: unknown[]) => console.error('[usb-source]', ...args);

export type UsbSourceOptions = {
  transport: Transport;
  wasmBytes: BufferSource;
  /** Request timeout in ms (default 2000). */
  requestTimeoutMs?: number;
};

type Resolver = { resolve: (payload: Uint8Array) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> };

export class UsbSource implements Source {
  private core!: TobiiCore;
  private transport: Transport;
  private abort = new AbortController();
  private pumpPromise!: Promise<void>;
  private pending = new Map<number, Resolver>();
  private gazeListeners = new Set<(s: GazeSample) => void>();
  private rawGazeListeners = new Set<(cols: RawGazeColumn[]) => void>();
  private frameListeners = new Set<(f: TtpFrame) => void>();
  private parseErrorListeners = new Set<(code: number) => void>();
  private requestTimeoutMs: number;
  private closed = false;
  private _displayArea: DisplayArea | null = null;

  /** Resolves when the next response arrives (used by driveHandshake). */
  private responseSignal: (() => void) | null = null;

  private constructor(transport: Transport, requestTimeoutMs: number) {
    this.transport = transport;
    this.requestTimeoutMs = requestTimeoutMs;
  }

  static async create(opts: UsbSourceOptions): Promise<UsbSource> {
    const { transport, wasmBytes, requestTimeoutMs = 2000 } = opts;

    const src = new UsbSource(transport, requestTimeoutMs);

    log('loading wasm core');
    src.core = await loadCore(wasmBytes, {
      onFrame: (f) => {
        for (const l of src.frameListeners) l(f);
        if (src.responseSignal) { src.responseSignal(); src.responseSignal = null; }
      },
      onGaze: (s) => { for (const l of src.gazeListeners) l(s); },
      onRawColumns: (c) => { for (const l of src.rawGazeListeners) l(c); },
      onResponse: (id, payload) => {
        log('response', id, payload.byteLength, 'bytes');
        const r = src.pending.get(id);
        if (r) { src.pending.delete(id); clearTimeout(r.timer); r.resolve(payload); }
        if (src.responseSignal) { src.responseSignal(); src.responseSignal = null; }
      },
      onParseError: (code) => {
        logErr('parse error', '0x' + code.toString(16));
        for (const l of src.parseErrorListeners) l(code);
      },
    });
    log('wasm core loaded');

    // Start recv pump.
    log('starting recv pump');
    src.pumpPromise = transport.recv(src.abort.signal, (chunk) => src.core.feedUsbIn(chunk))
      .catch((e) => { if (!src.abort.signal.aborted) logErr('recv pump error', e); });

    // Drive handshake (hello → realm → subscribe; no display area override).
    src.core.handshakeInit(0x500);
    await src.driveStateMachine(() => src.core.handshakePoll(), 'handshake');

    // Read the display area from the device (device is source of truth).
    try {
      src._displayArea = await src.getDisplayArea();
      log('device display_area', src._displayArea);
    } catch (e) {
      log('warning: could not read display_area from device', e);
    }

    return src;
  }

  // ── State machine driver (shared by handshake + cal_start) ─────────

  private async driveStateMachine(poll: () => number, label = 'state-machine'): Promise<void> {
    const SEND = 1, RECV = 2, DONE = 3, ERR = 4;
    for (let step = 0; step < 200; step++) {
      const action = poll();
      if (action === DONE) { log(label, 'complete in', step, 'steps'); return; }
      if (action === ERR) throw new Error(`${label} failed`);
      if (action === SEND) {
        const bytes = this.core.takeSessionOutBytes();
        log(label, 'step', step, 'send', bytes.byteLength, 'bytes');
        await this.transport.send(bytes);
      }
      if (action === RECV) {
        log(label, 'step', step, 'recv');
        await new Promise<void>((resolve) => {
          this.responseSignal = resolve;
          setTimeout(() => {
            if (this.responseSignal === resolve) {
              log(label, 'recv timeout (2s), continuing');
              this.responseSignal = null;
              resolve();
            }
          }, 2000);
        });
      }
    }
    throw new Error(`${label} timed out (too many steps)`);
  }

  // ── Request helpers ───────────────────────────────────────────────

  private awaitResponse(requestId: number, timeoutMs?: number): Promise<Uint8Array> {
    const ms = timeoutMs ?? this.requestTimeoutMs;
    return new Promise<Uint8Array>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(requestId);
        reject(new Error(`TTP request ${requestId} timed out`));
      }, ms);
      this.pending.set(requestId, { resolve, reject, timer });
    });
  }

  // ── Source interface ──────────────────────────────────────────────

  subscribeToGaze(listener: (s: GazeSample) => void): Unsubscribe {
    const first = this.gazeListeners.size === 0;
    this.gazeListeners.add(listener);
    if (first) {
      const bytes = this.core.requestSubscribe(0x500);
      void this.transport.send(bytes);
    }
    return () => { this.gazeListeners.delete(listener); };
  }

  /** Return the cached display area (read from device at connect time). */
  get displayArea(): DisplayArea | null { return this._displayArea; }

  async getDisplayArea(): Promise<DisplayArea> {
    const { requestId, bytes } = this.core.requestGetDisplayArea();
    const waiter = this.awaitResponse(requestId);
    await this.transport.send(bytes);
    const payload = await waiter;
    const da = decodeDisplayArea(this.core, payload);
    if (!da) throw new Error(`get_display_area: could not decode (plen=${payload.byteLength})`);
    this._displayArea = da;
    return da;
  }

  async setDisplayArea(rect: DisplayRect): Promise<void> {
    const bytes = this.core.requestSetDisplayArea(rect.w, rect.h, rect.ox, rect.oy, rect.z);
    await this.transport.send(bytes);
    // Re-read from device to update cache.
    try { await this.getDisplayArea(); } catch {}
  }

  async setDisplayAreaCorners(area: DisplayArea): Promise<void> {
    const bytes = this.core.requestSetDisplayAreaCorners(area.tl, area.tr, area.bl);
    await this.transport.send(bytes);
    // Re-read from device to update cache.
    try { await this.getDisplayArea(); } catch {}
  }

  async startCalibration(): Promise<void> {
    log('startCalibration');
    this.core.calStartInit();
    await this.driveStateMachine(() => this.core.calStartPoll(), 'cal_start');
  }

  async addCalibrationPoint(x: number, y: number): Promise<void> {
    const { requestId, bytes } = this.core.requestCalAddPoint(x, y, 0);
    const waiter = this.awaitResponse(requestId, 10_000);
    await this.transport.send(bytes);
    await waiter;
  }

  async finishCalibration(): Promise<Uint8Array> {
    log('finishCalibration');
    this.core.calFinishInit();
    await this.driveStateMachine(() => this.core.calFinishPoll(), 'cal_finish');
    return this.core.calFinishBlob();
  }

  async calApply(blob: Uint8Array): Promise<void> {
    log('calApply', blob.byteLength, 'bytes');
    this.core.writeScratch(blob);
    this.core.calApplyInit(blob.byteLength);
    await this.driveStateMachine(() => this.core.calApplyPoll(), 'cal_apply');
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.abort.abort();
    try { await this.pumpPromise; } catch {}
    try { await this.transport.close(); } catch {}
    for (const [, r] of this.pending) { clearTimeout(r.timer); r.reject(new Error('source closed')); }
    this.pending.clear();
    this.gazeListeners.clear();
    this.rawGazeListeners.clear();
    this.frameListeners.clear();
    this.parseErrorListeners.clear();
  }

  // ── UsbSource-only extras ─────────────────────────────────────────

  /** Raw-column gaze listener (wasm-only, not part of Source interface). */
  subscribeToRawGaze(listener: (cols: RawGazeColumn[]) => void): Unsubscribe {
    const firstRaw = this.rawGazeListeners.size === 0;
    const firstAnyGaze = this.gazeListeners.size === 0 && firstRaw;
    this.rawGazeListeners.add(listener);
    if (firstRaw) this.core.setRawColumnsEnabled(true);
    if (firstAnyGaze) {
      const bytes = this.core.requestSubscribe(0x500);
      void this.transport.send(bytes);
    }
    return () => {
      this.rawGazeListeners.delete(listener);
      if (this.rawGazeListeners.size === 0) this.core.setRawColumnsEnabled(false);
    };
  }

  /** Raw TTP frame listener (wasm-only, not part of Source interface). */
  onFrame(listener: (f: TtpFrame) => void): Unsubscribe {
    this.frameListeners.add(listener);
    return () => { this.frameListeners.delete(listener); };
  }

  /** Parse error listener (wasm-only, not part of Source interface). */
  onParseError(listener: (code: number) => void): Unsubscribe {
    this.parseErrorListeners.add(listener);
    return () => { this.parseErrorListeners.delete(listener); };
  }
}
