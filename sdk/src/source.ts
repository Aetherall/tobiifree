// source.ts — consumer-level interface for all eye tracker operations.
//
// Every Source exposes the same methods. The consumer doesn't know whether
// it talks directly to USB (UsbSource) or through a daemon (WsSource).

import type { GazeSample, DisplayArea, DisplayRect } from './protocol';

export type Unsubscribe = () => void;

export interface Source {
  /** Cached display area (read from device on connect). Null if not yet known. */
  readonly displayArea: DisplayArea | null;
  subscribeToGaze(listener: (s: GazeSample) => void): Unsubscribe;
  getDisplayArea(): Promise<DisplayArea>;
  setDisplayArea(rect: DisplayRect): Promise<void>;
  setDisplayAreaCorners(area: DisplayArea): Promise<void>;
  startCalibration(): Promise<void>;
  addCalibrationPoint(x: number, y: number): Promise<void>;
  finishCalibration(): Promise<Uint8Array>;
  calApply(blob: Uint8Array): Promise<void>;
  close(): Promise<void>;
}
