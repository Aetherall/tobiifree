// transport.ts — byte-level transport interface for the ET5.
//
// A Transport is just "send bytes, receive chunks, close". WebUSB and
// node-usb (or any future backend) implement this independently of the
// protocol layer.

export interface Transport {
  /** Write a USB-framed TTP packet to the device. */
  send(bytes: Uint8Array): Promise<void>;
  /** Pull inbound chunks until `signal` aborts or the device closes. */
  recv(signal: AbortSignal, onChunk: (chunk: Uint8Array) => void): Promise<void>;
  close(): Promise<void>;
}
