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

All multi-byte values are little-endian. Corners are mm in the tracker frame
(origin front centre of the tracker, x right, y up, z toward the user), in the
order TL.xyz, TR.xyz, BL.xyz.

| Cmd | ID | Payload | Reply (`response`, after the cmd_type byte) |
|---|---|---|---|
| `subscribe` | 0x01 | u32 stream mask | — (gaze stream starts) |
| `get_display_area` | 0x02 | — | 9×f64 corners |
| `set_display_area` | 0x03 | 5×f64 (w,h,ox,oy,z), no tilt | 9×f64 corners the device holds after the set |
| `set_display_area_corners` | 0x04 | 9×f64 corners | 9×f64 corners the device holds after the set |
| `start_calibration` | 0x20 | — | empty |
| `add_calibration_point` | 0x21 | 2×f64 (x,y) normalised display coords; eye_mask fixed at 3 (both eyes) | raw device reply |
| `finish_calibration` | 0x22 | — | calibration blob (~400–640 KB; unix socket only) |
| `cal_apply` | 0x23 | calibration blob | empty |
| `get_calibration_stimulus` | 0x24 | — | points of the active calibration: u32 n, n×8 f64 (x, y, status_L, a_L, b_L, status_R, a_R, b_R), then the raw TTP payload of op 0x460 |
| `cancel_calibration` | 0x25 | — | empty; ends a started session (CALIBRATE_STOP) without computing/applying |
| `disconnect` | 0xFF | — | — |

Every command except `subscribe`/`disconnect` gets exactly one reply: a
`response` or an `err`. Replies carry the cmd_type; the daemon answers commands
of one type in the order they were sent, so clients match replies FIFO per
command type.

Sets: the device acks op 0x5a0 with an empty payload and a status word in the
TTP header (bytes 16..19; 0 = ok, e.g. 0x20000502 when the area is rejected,
in which case the device keeps its previous area). The daemon checks it, then
reads the area back and replies with it. A successful set is persisted (see
below).

Calibration commands (`start_calibration`, `cancel_calibration`, `finish_calibration`, `cal_apply`)
run one at a time on a daemon job thread that owns USB while it runs: gaze
pauses, and any device command sent meanwhile gets `err` busy.

### Daemon → Client events (`Srv`)

| Srv | ID | Payload |
|---|---|---|
| `gaze` | 0x01 | GazeSample (232 bytes) |
| `response` | 0x02 | cmd_type (u8) + reply payload |
| `display_area` | 0x03 | 9×f64 corners (reserved; not sent by tobiifreed today) |
| `err` | 0xFF | cmd_type (u8) + error code (u32) |

Error codes (`daemon_protocol.Err`): 0x01 failed, 0x02 too large for the
transport (WS frames are capped at ~8 KB, so no blobs over WS), 0x03 busy
(calibration job running), 0x04 device timeout (5 s), 0x05 bad payload,
0x06 unknown command, 0x07 USB send failed, 0x08 disconnected (client-side,
SocketSource), 0x09 no device (tracker unplugged; the daemon reconnects). Any other value is the device's non-zero TTP status, passed
through.

### Calibration stimulus (op 0x460)

`get_calibration_stimulus` forwards TTP op 0x460 (named
`get_calibration_stimulus_pts` in the core; empty `[00 00]` request). Probed on
an ET5 (2026-11-19): it is **not** a list of recommended targets. It returns
the points of the calibration currently held by the device, with per-eye data:

```
[00 00]
prolog 0x00070100             array, elements of 7 fields
u32    0x3390                 element type
per point:
  prolog 0x00073390
  prolog 0x031f42 + 3×fixed16x16   target x, y, z (normalised display coords, top-left origin)
  type-1 u32 + 2×fixed16x16        left eye:  status, a, b
  type-1 u32 + 2×fixed16x16        right eye: status, a, b
```

After the person's 6-point calibration (targets ▽ (0.1,0.1) (0.9,0.1) (0.5,0.9)
then △ (0.1,0.9) (0.9,0.9) (0.5,0.1), exactly what the probe used) it listed
those 6 targets in order, status 2 for both eyes, and a/b between 0.004 and
0.07. The layout matches Tobii stream engine's `tobii_calibration_point_data_t`
(point_xy, left_status, left_mapping_xy, right_status, right_mapping_xy; status
2 = valid and used); a/b are small positive values, so they look like per-eye
residuals, not absolute positions. Their exact meaning is unconfirmed. They
could still serve as a quality indicator for the configurator.

- `cal_apply` of a stored blob restores the list (the point data is part of the blob).
- `start_calibration` (CALIBRATE_START + CLEAR) empties it at once (`n = 0`,
  element count 1 in the header), and `cancel_calibration` (CALIBRATE_STOP)
  leaves it empty. Whether the gaze *model* is also reset by START, or only the
  point list, could not be checked (nobody at the tracker). To be safe, the
  configurator should re-apply the stored blob after a cancelled calibration.

## tobiifreed (daemon)

The daemon owns the USB device and its Tracker. It:

1. Opens USB, runs the TTP handshake (hello → realm → display area → subscribe)
2. Pushes the configured display area (see Persistence)
3. Listens on Unix socket + optionally WebSocket (`--ws`)
4. Re-applies the stored calibration, if any
5. Accepts client connections, forwards their commands over TTP and routes
   the replies back
6. Broadcasts gaze samples to subscribed clients

Threads: the USB thread feeds the core and queues gaze samples / responses,
and does (re)connection and the area + calibration restore; the main thread
does all client I/O, request building and persistence; a job thread runs the
client-requested calibration state machines.

### Persistence

- **Display area** — every successful set from a client is written to
  `~/.config/tobii.json` as explicit corners (`"tl"`, `"tr"`, `"bl"` arrays)
  plus the equivalent legacy fields (`w_mm`, `h_mm`, `z_mm`, `tilt`, numeric
  `cx`/`cy`) so the overlay keeps reading it; other top-level keys are kept.
  The hand-written legacy form (`cy: "b - 10"` etc.) is still read. At startup
  the config area is pushed to the device **whenever it differs** from what the
  device reports: the device forgets its area on power-cycle and other tools
  (WebUSB demo, another OS) may change it, so the config, which records the
  last area set through the daemon, is the source of truth.
  `--keep-device-area` restores the old rule (only push when the device looks
  reset). Without a config area, the built-in default is pushed only when the
  device looks reset.
- **Hotplug** — when the tracker goes away (libusb NO_DEVICE / IO error) the
  daemon keeps running: in-flight requests and new device commands get `err`
  0x09, it looks for the tracker every second, and when it is back it redoes
  the handshake, pushes the config's display area and re-applies the stored
  calibration (commands get busy meanwhile), then gaze resumes for the
  still-connected clients. A power-cycled ET5 forgets both its display area
  and its calibration, so this restores it. The daemon also starts without a
  tracker and waits for it.
- **Calibration** — a successful `finish_calibration` saves the blob to
  `$XDG_STATE_HOME/tobiifree/calibration.bin` (default
  `~/.local/state/tobiifree/calibration.bin`). At startup and after every
  reconnect, if the file exists, it is `cal_apply`'d (by the USB thread) after
  the sockets are up: clients can connect immediately, gaze starts when the
  apply ends (~0.3 s for a 272 KB ET5 blob; on failure or after the 120 s
  state-machine timeout the device keeps its current calibration), and device
  commands sent meanwhile get `err` busy (0x03). Timing and result are logged.
  `--no-restore-calibration` skips it. Note the file is only written by
  tobiifreed's `finish_calibration`; a calibration made another way is
  overwritten at the next daemon start while the file exists.

### tobiifree-ctl

`applications/tobiifreed` also builds `tobiifree-ctl`, a CLI over the Zig
`SocketSource` (`get-area`, `set-area`, `stimulus`, `start-calibration`,
`add-point`, `finish-calibration`, `apply`).

### tobiifree-setup

`applications/tobiifree-setup` is the configurator (GTK4 + layer-shell,
fullscreen on the tracker's output): display area from two lines placed over
the ET5's marks, position guide, calibration (cancel + re-apply of the stored
blob on abort), validation. It drives a `SocketSource` from the GLib main
loop (`g_unix_fd_add`) and stores the chosen output as `"output"` in
`~/.config/tobii.json`. See its README.

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
- [x] `SocketSource` — Zig native (Unix socket): gaze + full daemon command set,
      async callbacks driven by `poll()` (GLib: `g_unix_fd_add` on `fd`), `call()` for blocking use
