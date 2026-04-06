// webusb.ts — Transport implementation over the WebUSB API.
//
// Works in browsers (navigator.usb) and in Node via the `usb` package's
// WebUSB polyfill (`new WebUSB(...)`), since both expose the same USBDevice
// shape. The Node caller constructs a USBDevice and passes it in;
// browser callers use WebUsbTransport.request().

import type { Transport } from './transport';

const log = (...args: unknown[]) => console.log('[webusb]', ...args);
const logErr = (...args: unknown[]) => console.error('[webusb]', ...args);

export const TOBII_VID = 0x2104;
export const TOBII_PID_RUNTIME = 0x0313;
const INTERFACE = 0;
const EP_IN = 3;   // hw 0x83
const EP_OUT = 5;  // hw 0x05
const IN_CHUNK_SIZE = 16384;

export class WebUsbTransport implements Transport {
  readonly device: USBDevice;

  private constructor(device: USBDevice) {
    this.device = device;
  }

  /** Browser-only: prompt user to pick a tracker, open, claim, session-open. */
  static async request(): Promise<WebUsbTransport> {
    if (typeof navigator === 'undefined' || !('usb' in navigator)) {
      throw new Error('WebUSB not available in this environment');
    }
    const device = await navigator.usb.requestDevice({
      filters: [{ vendorId: TOBII_VID, productId: TOBII_PID_RUNTIME }],
    });
    return WebUsbTransport.fromDevice(device);
  }

  /** Env-agnostic: take an already-chosen USBDevice, open + claim + session. */
  static async fromDevice(device: USBDevice): Promise<WebUsbTransport> {
    log('opening device', device.vendorId.toString(16), device.productId.toString(16));
    await device.open();
    log('device opened');
    if (device.configuration === null) {
      log('selecting configuration 1');
      await device.selectConfiguration(1);
    }
    log('claiming interface', INTERFACE);
    await device.claimInterface(INTERFACE);
    log('interface claimed');

    // Mandatory session-open: vendor ctrl, interface recipient, request 0x41.
    log('session-open (ctrl 0x41)');
    const r = await device.controlTransferOut({
      requestType: 'vendor', recipient: 'interface',
      request: 0x41, value: 0x0000, index: 0x0000,
    });
    if (r.status !== 'ok') throw new Error(`session-open failed: ${r.status}`);
    log('session opened');

    return new WebUsbTransport(device);
  }

  async send(bytes: Uint8Array): Promise<void> {
    log('send', bytes.byteLength, 'bytes');
    const buf = new ArrayBuffer(bytes.byteLength);
    new Uint8Array(buf).set(bytes);
    const r = await this.device.transferOut(EP_OUT, buf);
    if (r.status !== 'ok' || r.bytesWritten !== bytes.byteLength) {
      throw new Error(`bulk OUT: ${r.status} (${r.bytesWritten}/${bytes.byteLength})`);
    }
  }

  async recv(signal: AbortSignal, onChunk: (chunk: Uint8Array) => void): Promise<void> {
    log('recv pump started');
    let chunks = 0;
    while (!signal.aborted) {
      let r: USBInTransferResult;
      try {
        r = await this.device.transferIn(EP_IN, IN_CHUNK_SIZE);
      } catch (e) {
        if (signal.aborted) return;
        logErr('recv error', e);
        throw e;
      }
      if (signal.aborted) return;
      if (r.status !== 'ok' || !r.data) throw new Error(`bulk IN: ${r.status}`);
      chunks++;
      if (chunks <= 5 || chunks % 100 === 0) {
        log('recv chunk', chunks, r.data.byteLength, 'bytes');
      }
      onChunk(new Uint8Array(r.data.buffer, r.data.byteOffset, r.data.byteLength));
    }
    log('recv pump stopped after', chunks, 'chunks');
  }

  async close(): Promise<void> {
    log('closing');
    try {
      await this.device.controlTransferOut({
        requestType: 'vendor', recipient: 'interface',
        request: 0x42, value: 0, index: 0,
      });
    } catch {}
    try { await this.device.releaseInterface(INTERFACE); } catch {}
    try { await this.device.close(); } catch {}
    log('closed');
  }
}
