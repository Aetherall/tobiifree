# python-mouse

Drives the mouse cursor from **tobiifreed**'s gaze stream using a virtual
`uinput` absolute pointer device.  Includes an interactive gaze-correction
window, optional head assist (eye-origin head-movement compensation), and a
runtime command interface via a named pipe (FIFO).

## Files

| File | Purpose |
|---|---|
| `gaze_mouse.py` | Main application |
| `gaze_correction.py` | Calibration point store and correction math |
| `gaze-ctl` | Companion script for sending runtime commands |
| `calib_points.json` | Persisted correction points (auto-created) |

## Requirements

```
pip install evdev pygame
```

Read/write access to `/dev/uinput` is required.  Either run as root, add
yourself to the `input` group, or create a udev rule:

```
KERNEL=="uinput", MODE="0660", GROUP="input"
```

`tobiifreed` must be running and its Unix socket must be accessible (default:
`$XDG_RUNTIME_DIR/tobiifreed/gaze.sock`).

## Usage

```
python gaze_mouse.py [options]
```

Screen size is detected automatically via `xrandr`.  Pass `--width` and
`--height` explicitly if auto-detection fails.

### Options

| Option | Default | Description |
|---|---|---|
| `--socket PATH` | `$XDG_RUNTIME_DIR/tobiifreed/gaze.sock` | tobiifreed Unix socket |
| `--fifo PATH` | `/run/user/<uid>/gaze_mouse.fifo` | Runtime command FIFO |
| `--width PX` | auto | Screen width in pixels |
| `--height PX` | auto | Screen height in pixels |
| `--eye` | `either` | Which eye to require valid: `left`, `right`, `both`, `either` |
| `--smoothing F` | `0.5` | EMA smoothing factor (0–1]; `0` disables |
| `--calib-file PATH` | `calib_points.json` | Correction point file |
| `--radius PX` | `300` | Initial correction point influence radius |
| `--head-gain F` | `10.0` | Gain for head assist |
| `--head-reset-radius PX` | `100` | Gaze-jump threshold that suspends head assist (0 = off) |
| `--head-settle-radius PX` | `40` | Gaze must stay within this radius to be considered settled |
| `--head-settle-frames N` | `5` | Consecutive frames within settle radius before re-baselining |
| `--retry-delay S` | `2.0` | Reconnect delay after socket loss |
| `--debug` | off | Print parsed gaze samples to stderr |
| `--print-eye-origin` | off | Print eye-origin coordinates to stderr (throttled) |
| `--print-eye-origin-rate HZ` | `5.0` | Max rate for `--print-eye-origin` |

## Runtime commands — `gaze-ctl`

`gaze-ctl` writes newline-terminated commands to the FIFO.  It is a plain
executable with no shell interpretation, so it can be bound directly to
global hotkeys in any desktop environment.

```sh
gaze-ctl toggle_pause              # pause / resume gaze → mouse
gaze-ctl pause
gaze-ctl resume
gaze-ctl toggle_correction_window  # show / hide the correction window
gaze-ctl toggle_head_assist         # enable / disable head assist
gaze-ctl calibrate                 # launch calibrate.py (pauses gaze mouse)

# Tunable parameters (effective immediately, no restart needed)
gaze-ctl smoothing 0.3
gaze-ctl head_gain 20.0
gaze-ctl head_reset_radius 150
```

The FIFO path defaults to `/run/user/<uid>/gaze_mouse.fifo`.  Override with
the `GAZE_MOUSE_FIFO` environment variable, or pass `--fifo` when starting
`gaze_mouse.py`.

## Features

### Gaze → mouse mapping

Normalized (0–1) gaze coordinates from tobiifreed are mapped to absolute
screen pixels and written to a virtual `uinput` absolute pointer device.
An exponential moving average (EMA) smooths the signal; adjust `--smoothing`
or set it to `0` to disable.

Only one eye, both, or either (default) can be required to be valid before a
sample is accepted — see `--eye`.

### Gaze correction window

Send `toggle_correction_window` (or press Escape inside the window) to open a
fullscreen overlay.  While open, gaze-to-mouse emulation is suspended so your
real mouse/touchpad works normally.

- **Red dot** — raw, uncorrected gaze position
- **Green dot** — corrected gaze position
- **Orange circles** — stored correction points and their influence radii
- **Grey circle around cursor** — current influence radius

| Action | Effect |
|---|---|
| Left-click | Add a correction point at the clicked position |
| Right-click | Remove the nearest correction point |
| `+` / `-` | Increase / decrease the influence radius |
| `C` | Clear all correction points |
| Escape | Close the window |

Points are saved to `calib_points.json` immediately and reloaded on the next
run.

#### Correction model

For a given raw gaze position each stored correction point within its
influence radius contributes an offset that is full-strength at distance 0
and fades linearly to zero at the radius boundary.  If multiple points
overlap, their contributions are blended; combined weights above 1 are
normalized to prevent over-correction.

### Head assist

*Head assist* compensates for gaze-mapping drift caused by head movement.
The eye-origin coordinates reported by the tracker (typically in mm, user
coordinate system) serve as a lightweight head-position proxy.  When your
head moves, the offset from a stored baseline is scaled by `--head-gain`
and added to the cursor position, counteracting the drift without requiring
a new calibration.

Toggle with `gaze-ctl toggle_head_assist`.  While enabled, the script
tracks the eye-origin position (a 3D mm coordinate reported by the tracker,
used here as a 2D head-position proxy) and computes an x/y offset as:

```
offset = (current_origin − baseline_origin) × gain
```

This is an **absolute** calculation — nothing accumulates — so isolated
measurement errors (e.g. from eye blinks) have no lasting effect.

#### Blink / saccade protection

When the smoothed gaze position jumps by more than `--head-reset-radius`
pixels in a single frame (blink artefact or deliberate saccade to a new
target), head assist is **suspended** and a settle timer starts:

1. The gaze must stay within `--head-settle-radius` of a stable anchor point.
2. Once it has done so for `--head-settle-frames` consecutive frames, the
   eye-origin baseline is re-established from the now-clean reading and
   head assist resumes.
3. If the gaze drifts out of the settle radius the anchor shifts and the
   counter resets.

This prevents blink-induced eye-origin artefacts from corrupting the
baseline.

The head offset is applied **after** the gaze-correction-point offset:

```
final_x = raw_x + correction_x + head_offset_x
final_y = raw_y + correction_y − head_offset_y   (Y axis inverted)
```

Toggling head assist off and back on always resets the baseline and
clears any pending settling state, so re-enabling never causes a jump.
