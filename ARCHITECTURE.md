# Architecture

## Overview

```
┌──────────────────────────────────────────────────┐
│                    Source                         │
│  subscribeToGaze()      getDisplayArea()          │
│  setDisplayArea()       setDisplayAreaCorners()   │
│  startCalibration()     addCalibrationPoint()     │
│  finishCalibration()    calApply()                │
│  close()                                          │
└──────────┬────────────────────┬───────────────────┘
           │                    │
     ┌─────┴──────┐     ┌──────┴──────────┐
     │ UsbSource  │     │ WsSource        │
     │ (has Tracker)    │ SocketSource    │
     │            │     │ (daemon clients)│
     └─────┬──────┘     └──────┬──────────┘
           │                    │
    wasm + WebUSB        daemon protocol
           │                    │
       ┌───┴───┐         ┌─────┴─────┐
       │  ET5  │         │  tobiifreed   │──usb──▶ ET5
       └───────┘         └───────────┘
```

## Source (consumer API)

A `Source` is the public interface for all eye tracker operations.
Every Source exposes the same methods — the consumer doesn't know
whether it talks directly to USB or through a daemon.

### Interface

**TypeScript:**
```ts
interface Source {
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
```

`UsbSource` additionally exposes `calRetrieve()` (re-read the calibration blob
without recomputing), `subscribeToRawGaze()`, `onFrame()`, and `onParseError()`.
These are wasm-only extras, not part of the `Source` contract — the daemon
protocol has no matching commands, so `WsSource` can't implement them.

### All Source flavors

| Source | Lang | Contains | Talks to |
|---|---|---|---|
| `UsbSource` | TS | wasm Tracker + WebUSB/node-usb Transport | ET5 directly |
| `WsSource` | TS | WebSocket client | tobiifreed daemon |
| `UsbSource` | Zig | native Tracker + LibusbTransport | ET5 directly |
| `SocketSource` | Zig | Unix socket client | tobiifreed daemon |

Sources with a Tracker run the TTP handshake and own protocol state.
Sources without a Tracker speak daemon protocol — the daemon's Tracker does the work.

## Tracker (Zig, protocol engine)

The Tracker is **not** a consumer API. It is the Zig protocol engine
that owns TTP framing, the handshake state machine, and request/response
routing. It lives in `driver/src/` and compiles to both native and wasm.

Sources that talk directly to USB hardware contain a Tracker.
Sources that talk to a daemon do not — the daemon's Tracker handles it.

**Who has a Tracker:**
- `UsbSource` (TS) — via wasm
- `tobiifreed` daemon (Zig) — native
- `tobiifree-overlay --direct` (Zig) — native

**Who does not:**
- `WsSource` (TS) — daemon has the Tracker
- `SocketSource` (Zig) — daemon has the Tracker
- `tobiifree-overlay --socket` (Zig) — daemon has the Tracker

### Tracker interface (Zig)

```zig
pub const Tracker = struct {
    send_fn: *const fn ([]const u8) bool,
    recv_fn: *const fn ([]u8) ?usize,

    pub fn init(opts: InitOptions) !Tracker;  // runs handshake
    pub fn poll(self: *Tracker) void;          // drives recv + gaze dispatch
    pub fn onGaze(self: *Tracker, cb: GazeFn) void;
    pub fn deinit(self: *Tracker) void;
};
```

## Daemon Protocol

Sources that connect through a daemon (WsSource, SocketSource) speak
daemon protocol. This is the framing between daemon clients and tobiifreed:

```
[u8 msg_type] [u32 LE payload_len] [payload...]
```

### Client → Daemon commands (`Cmd`)

| Cmd | ID | Payload | Response |
|---|---|---|---|
| `subscribe` | 0x01 | u32 stream mask | gaze stream starts |
| `get_display_area` | 0x02 | — | display_area response (9×f64 corners) |
| `set_display_area` | 0x03 | 5×f64 (w,h,ox,oy,z) | ack response |
| `set_display_area_corners` | 0x04 | 9×f64 (tl,tr,bl) | ack response |
| `start_calibration` | 0x20 | — | ack response |
| `add_calibration_point` | 0x21 | 2×f64 (x,y); eye_mask fixed at 3 (both eyes) | ack response |
| `finish_calibration` | 0x22 | — | calibration blob response |
| `cal_apply` | 0x23 | calibration blob | ack response |
| `disconnect` | 0xFF | — | — |

### Daemon → Client events (`Srv`)

| Srv | ID | Payload |
|---|---|---|
| `gaze` | 0x01 | GazeSample (232 bytes) |
| `response` | 0x02 | cmd_type (u8) + response payload |
| `display_area` | 0x03 | 9×f64 corners |
| `err` | 0xFF | error code (u32) |

## tobiifreed (daemon)

The daemon owns the USB device and its Tracker. It:

1. Opens USB, runs the TTP handshake (hello → realm → display area → subscribe)
2. Listens on Unix socket + optionally WebSocket (`--ws`)
3. Accepts client connections
4. Forwards client commands to the Tracker over TTP
5. Broadcasts gaze samples and command responses to subscribed clients

```
┌─────────┐      ┌─────────┐      ┌──────────┐
│ Browser  │─ws──▶│         │      │          │
│          │      │ tobiifreed  │─usb──▶  ET5     │
│ App      │─sock▶│         │      │          │
└─────────┘      └─────────┘      └──────────┘
```

## Implementation Status

- [x] `UsbSource` — TS (WebUSB + wasm), implements `Source`
- [x] `WsSource` — TS (WebSocket client), implements `Source`
- [x] `Tobii.fromUsb()` / `Tobii.fromDaemon()` return `Source`; `Tobii.createSession()` is a deprecated alias for `fromUsb()`
- [x] `WsServer` in tobiifreed (gaze + command forwarding)
- [x] Daemon protocol: command forwarding (display area, calibration)
- [x] `SocketSource` — Zig native (Unix socket, gaze only)
- [ ] `SocketSource` — full daemon protocol on Zig side (currently gaze only)
