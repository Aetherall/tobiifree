// nodeusb.ts — Node entry point. Uses the `usb` package's WebUSB polyfill
// so the same WebUsbTransport logic works without a browser.
//
// Requires `usb` (npm: usb) as a peer dependency. The caller installs it.

import { WebUsbTransport, TOBII_VID, TOBII_PIDS } from './webusb';

/**
 * Open the first connected supported tracker via the node-usb WebUSB polyfill.
 * Dynamically imports `usb` so browser bundles don't try to resolve it.
 */
type UsbMod = {
  WebUSB: new (opts: { allowAllDevices: boolean }) => {
    getDevices(): Promise<USBDevice[]>;
  };
};

export async function openNodeTracker(): Promise<WebUsbTransport> {
  const usbModName = 'usb';
  const mod = (await import(/* @vite-ignore */ usbModName)) as UsbMod;
  const webusb = new mod.WebUSB({ allowAllDevices: true });
  const devices = await webusb.getDevices();
  const device = devices.find(
    (d: USBDevice) => d.vendorId === TOBII_VID && TOBII_PIDS.includes(d.productId as (typeof TOBII_PIDS)[number]),
  );
  if (!device) {
    const pids = TOBII_PIDS.map(pid => `0x${pid.toString(16).padStart(4, '0')}`).join(', ');
    throw new Error(`No supported tracker found (vid=0x${TOBII_VID.toString(16)}, pids=${pids})`);
  }
  return WebUsbTransport.fromDevice(device);
}


/** Read the wasm module from disk. Pass the result to `Tracker.open`. */
export async function loadWasmFromFile(path: string): Promise<Uint8Array> {
  const { readFile } = await import('node:fs/promises');
  return readFile(path);
}

export { WebUsbTransport };
