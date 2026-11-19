# tobiifree-warp

Teleport the mouse cursor to where you are looking, on a shortcut.

A small background server keeps the last gaze samples from `tobiifreed`;
`tobiifree-warp jump` (bound to a key) asks it to move the cursor to the
current fixation. Hyprland only for now (IPC socket).

```shell
tobiifree-warp                 # server (same as `tobiifree-warp serve`)
tobiifree-warp jump            # move the cursor to the gaze
tobiifree-warp jump --dry-run  # print the target, don't move
tobiifree-warp follow-start / follow-stop   # cursor follows the gaze while a key is held
```

Hyprland binding (hyprland.lua):

```lua
hl.bind("SUPER + G", hl.dsp.exec_cmd("tobiifree-warp jump"))
```

(or `bind = SUPER, G, exec, tobiifree-warp jump` with a hyprlang config).
`kill -USR1 <server pid>` triggers a jump too.

## Follow mode (hold a key)

```shell
tobiifree-warp follow-start   # key press: the cursor follows the gaze...
tobiifree-warp follow-stop    # key release: ...and stays where it is
```

Hyprland binds (hyprland.lua). The release bind ignores modifiers, so it
fires whether SUPER or G is released first; the flag keeps ordinary `g`
key releases from spawning anything:

```lua
local gazeFollowing = false
hl.bind("SUPER + G", function()
	gazeFollowing = true
	hl.exec_cmd("tobiifree-warp follow-start")
end)
hl.bind("G", function()
	if gazeFollowing then
		gazeFollowing = false
		hl.exec_cmd("tobiifree-warp follow-stop")
	end
end, { release = true, ignore_mods = true, non_consuming = true })
```

Safety: follow stops by itself after `--follow-timeout-ms` (10 s; a missed
release), when tobiifreed goes away, or when a move fails. A new
`follow-start` replaces a running follow.

Filter, `--follow-filter`:

- `device` (default): the same processing as tobiifree-overlay. On every
  valid sample the cursor goes straight to the device's temporally filtered
  combined gaze (`gaze_point_2d_norm`, corrected by the daemon; if it is
  invalid: the unfiltered combined point, then the valid eye's own point).
  No dead zone, no confirmation, no easing; a move is skipped only when the
  pixel does not change. Invalid samples (blinks, eyes lost): the cursor
  holds.
- `fixation` (src/follow.zig): a fixation-aware filter. A valid sample
  within `--radius-deg` (1.5°) of the current fixation joins it; the target
  is the median of its last `--fix-window` (12) samples and moves only once
  that median has drifted more than `--deadband-deg` (0.4°). A sample
  outside starts a candidate, adopted once `--confirm` (2) consecutive
  samples agree (a saccade lands ~30 ms after the eye; a spike is ignored).
  The cursor eases at ~120 Hz: `--fix-tau-ms` (80) within a fixation,
  `--saccade-tau-ms` (0) to a new one, `--first-tau-ms` (60) first move.
  Stiller, but the dead zone felt uncomfortable in use.

At follow start the monitor layout is read once (with `fixation`, the
current fixation seeds the filter). The stop reply and the log give a
summary: updates, moves, time to the first move, Hyprland move cost. Live,
`device` at 33 Hz: 33 moves/s, 0.54 ms avg / 0.87 ms max per move, sample
arrival → cursor moved 0.54 ms (Hyprland's socket takes one request per
connection, so it cannot be kept open; at 33 Hz that is ~2 % of one core's
time at most, spent in Hyprland and us).

## How a jump is decided

- Gaze: the daemon's combined 2D point (the unfiltered one; we do our own
  filtering), else the filtered one, else the valid eye's own point when
  only one eye is tracked. It is the *corrected* gaze when the daemon has an
  active correction map (the server logs whether samples carry the
  `CORRECTED` bit); it never asks for raw gaze.
- Window: the valid samples of the last `--window-ms` (150 ms, ~5 samples
  at 33 Hz). Newest valid sample older than `--stale-ms` (300 ms): nothing
  happens.
- Fixation: from the newest sample back, the run grows while every pair of
  samples stays within `--max-dispersion-deg` (1.5°, visual angle at the
  eye's distance from the screen, from the samples' eye position; screen
  size from tobii.json `display_area`). The target is the per-axis median of
  that run.
- Mid-saccade (run shorter than 2 samples): the jump waits for the eye to
  land, up to `--settle-ms` (200 ms), then gives up.
- Mapping: gaze is normalised on the display area = the whole output named
  by `--output` or tobii.json `"output"` (same as tobiifree-overlay/-setup).
  Global logical position = output position + norm × logical size (mode
  size, rotated for 90/270° transforms, divided by the scale), rounded and
  clamped to the output. Monitor geometry is read from Hyprland on every
  jump (`j/monitors`, ~0.3 ms), so layout changes need no restart.
- Move: `dispatch hl.dsp.cursor.move({x = X, y = Y})` on Hyprland's socket
  (Lua dispatch); falls back to the legacy `dispatch movecursor X Y` on
  Hyprland versions without Lua. The backend is an interface
  (`src/backend.zig`) so a wlr-virtual-pointer or uinput backend can be added.

Every failure is a no-op with one log line: no server (the client exits 0
right away), daemon not running, tracker unplugged, eyes not tracked, gaze
not settled, output absent, compositor unreachable. No popups.

## Latency

The client sends its own start time (CLOCK_MONOTONIC, the first thing it
does); the server logs, per jump: total (client start → move acknowledged
by Hyprland), client → server, wait for a fixation, monitor query, move.
Typical: ~1–2 ms total once the client runs (process spawn by the
compositor not included); the gaze itself is ~30 ms old (33 Hz stream).

## Running it as a service

- Needs: `XDG_RUNTIME_DIR` (control socket
  `$XDG_RUNTIME_DIR/tobiifree-warp.sock`, daemon socket
  `$XDG_RUNTIME_DIR/tobiifreed/gaze.sock`), `HOME` (`~/.config/tobii.json`,
  optional). `HYPRLAND_INSTANCE_SIGNATURE` is used if set, otherwise the most
  recent instance under `$XDG_RUNTIME_DIR/hypr/` is found by itself; Hyprland
  is only contacted on a jump, so it may start after the server.
- tobiifreed may be absent at start, stop, restart: the server reconnects
  with backoff (250 ms doubling to 5 s; idle it wakes once per 5 s). A
  tracker unplug leaves the daemon up but silent: jumps are no-ops until
  samples flow again.
- Readiness: the socket is bound before `READY=1` is sent (`Type=notify`
  works; `Type=simple` is fine too).
- SIGTERM/SIGINT/SIGHUP: clean exit, socket removed. A stale socket left by a
  crash is replaced at start; a second server refuses to start.

```ini
[Unit]
Description=tobiifree-warp (gaze cursor jump)
After=tobiifreed.service

[Service]
Type=notify
ExecStart=%h/.nix-profile/bin/tobiifree-warp
Restart=on-failure
```

## Build / test

```shell
nix build .#tobiifree-warp
cd applications/tobiifree-warp && zig build test   # in `nix develop`
```

Tests cover the follow gaze source (filtered point first, fallbacks), the
fixation filter (noisy fixation stays put and converges,
deadband, saccade lands after one confirming sample, spike ignored, drift
followed), the easing, the follow session timeout, the sample selection (window, stale data, saccade rejection,
landing after a saccade, degrees vs viewing distance, median, ring wrap),
gaze extraction (eye validity fallbacks), the norm→global mapping (the
DP-1 / eDP-1 scale 2 / DP-2 portrait layout, fractional scales, clamping) and
parsing Hyprland's monitor JSON.
