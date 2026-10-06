// nodeusb.ts — Node entry point. Uses the `usb` package's WebUSB polyfill
// so the same WebUsbTransport logic works without a browser.
//
// Requires `usb` (npm: usb) as a peer dependency. The caller installs it.

import { WebUsbTransport, isTobiiTracker } from './webusb';

/**
 * Open the first connected ET5 via the node-usb WebUSB polyfill.
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
  const device = devices.find(isTobiiTracker);
  if (!device) throw new Error('Tobii tracker not found (vid=0x2104 pid=0x0313 ET5 / 0x0127 4C)');
  return WebUsbTransport.fromDevice(device);
}


/** Read the wasm module from disk. Pass the result to `Tracker.open`. */
export async function loadWasmFromFile(path: string): Promise<Uint8Array> {
  const { readFile } = await import('node:fs/promises');
  return readFile(path);
}

export { WebUsbTransport };
