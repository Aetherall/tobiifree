// tobii.ts — top-level entry point.
//
// `Tobii.fromUsb()` — direct USB (browser or Node), returns UsbSource.
// `Tobii.fromDaemon()` — WebSocket to tobiifreed, returns WsSource.

import { UsbSource, type UsbSourceOptions } from './usb_source';
import { WsSource } from './ws_source';
import { WebUsbTransport, TOBII_VID, TOBII_PID_RUNTIME } from './webusb';
import { wasmBytes } from './wasm-bundle';
import type { Source } from './source';

export type UsbOptions = {
  /** Pre-selected USBDevice. If omitted, auto-picks (browser prompt or node scan). */
  device?: USBDevice;
  requestTimeoutMs?: number;
};

export type DaemonOptions = {
  /** WebSocket URL, e.g. "ws://localhost:7081". */
  url: string;
  requestTimeoutMs?: number;
};

async function pickDevice(): Promise<USBDevice> {
  if (typeof navigator !== 'undefined' && 'usb' in navigator) {
    return navigator.usb.requestDevice({
      filters: [{ vendorId: TOBII_VID, productId: TOBII_PID_RUNTIME }],
    });
  }
  const usbModName = 'usb';
  const mod = await import(/* @vite-ignore */ usbModName).catch(() => {
    throw new Error(
      'WebUSB not available and the `usb` package is not installed. ' +
      'In Node, add `usb` as a dependency or pass `device` explicitly.',
    );
  });
  const WebUSB = (mod as { WebUSB: new (opts: { allowAllDevices: boolean }) => { getDevices(): Promise<USBDevice[]> } }).WebUSB;
  const webusb = new WebUSB({ allowAllDevices: true });
  const devices = await webusb.getDevices();
  const device = devices.find(
    (d) => d.vendorId === TOBII_VID && d.productId === TOBII_PID_RUNTIME,
  );
  if (!device) {
    throw new Error(`ET5 not found (vid=0x${TOBII_VID.toString(16)} pid=0x${TOBII_PID_RUNTIME.toString(16)})`);
  }
  return device;
}

export const Tobii = {
  /** Direct USB connection (browser WebUSB or Node usb package). */
  async fromUsb(opts: UsbOptions = {}): Promise<UsbSource> {
    const device = opts.device ?? await pickDevice();
    const transport = await WebUsbTransport.fromDevice(device);
    return UsbSource.create({
      transport,
      wasmBytes: wasmBytes(),
      requestTimeoutMs: opts.requestTimeoutMs,
    });
  },

  /** Connect to tobiifreed daemon via WebSocket. */
  async fromDaemon(opts: DaemonOptions): Promise<WsSource> {
    return WsSource.connect(opts.url, opts.requestTimeoutMs);
  },

  /** @deprecated Use `Tobii.fromUsb()` instead. */
  async createSession(opts: UsbOptions = {}): Promise<Source> {
    return Tobii.fromUsb(opts);
  },
};
