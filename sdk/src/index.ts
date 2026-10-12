// tobiifree-sdk-ts — TypeScript SDK for the Tobii ET5 eye tracker.

export { Tobii } from './tobii';
export type { UsbOptions, DaemonOptions } from './tobii';

export type { Source, Unsubscribe } from './source';
export { UsbSource } from './usb_source';
export type { UsbSourceOptions } from './usb_source';
export { WsSource } from './ws_source';

export type { Transport } from './transport';
export { TOBII_VID, TOBII_PIDS, TOBII_PID_RUNTIME } from './webusb';

export type {
  Vec2, Vec3, GazeSample, RawGazeColumn, GazeColumnKind,
  DisplayArea, DisplayRect, TtpFrame,
} from './protocol';
export { GAZE_COLUMN_LABELS } from './protocol';
export { buildTtpFrameBytes } from './core';
