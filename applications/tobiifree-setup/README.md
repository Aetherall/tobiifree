# tobiifree-setup

Fullscreen configurator for the Tobii ET5, in the spirit of the Windows
setup: display area, position guide, calibration, validation. Zig + GTK4 +
`gtk4-layer-shell`; it talks to `tobiifreed` (which must be running) through
the Zig `SocketSource`.

```sh
just setup                      # or: cd applications/tobiifree-setup && zig build run
tobiifree-setup --output DP-1   # the output the tracker is mounted on
tobiifree-setup --step validate # one step only: display | calibrate | validate
```

The window is a layer-shell OVERLAY surface covering the whole output, with
exclusive keyboard. Output: `--output NAME|desc:DESC`, else `"output_desc"`
then `"output"` in `~/.config/tobii.json` (both written by the tool when
step 1 is confirmed; tobiifreed keeps the keys when it rewrites the file),
else the focused output (Hyprland), else the first one. Everything is
computed in physical pixels of that output (logical size × monitor scale,
fractional scales included).

Connector names can swap across reboots (DP-1 ↔ DP-2), so tobiifree-setup
saves the monitor's identity too (`"output_desc"`, make model serial as in
Hyprland's `desc:` rules, e.g. `"BNQ BenQ XL2430T R9F02179SL0"`). The
description is matched first, then the connector; the log says which one
matched and warns when the saved connector now names another screen.
`--output` takes a connector or `desc:<description>`.

Without `--output`, step 1 starts with a **screen picker**: a drop-down of
the outputs (connector, model/description, logical size, scale; the saved one
marked "saved", the one showing the picker "this screen"), preselected with
that default. The picker is shown on the *focused* output (Hyprland's
focused monitor; elsewhere the compositor's choice, normally the focused
one), not on the saved output: that is where the person is looking and
typing, and the saved output may be the wrong one (that is why they would
pick). ↑/↓ or the mouse choose, ENTER (or "Use this screen") moves the
surface to that output and step 1 continues there; the choice is saved with
step 1. `--step calibrate|validate` use the default output without a picker.

The gap g is the y of the screen's bottom edge in the tracker's frame, in mm.
It is an offset of the ET5's coordinate frame, **not a ruler distance**: the
frame origin is not the camera centre. On an ET5 under a 24" BenQ, the
measured 30 mm (bottom lit row to camera centre) validated worse (0.74° and
0.87° mean, with a 7–9 mm downward bias) than the default 10 mm (0.58° mean,
2 mm bias). 10 mm is therefore the default. For experiments, `--gap MM`
or `"gap_mm"` in `tobii.json` override it; it is saved there (with `"output"`)
when step 1 is confirmed.

ESC cancels at any time; nothing on the device changes until a step is
confirmed.

1. **Display setup** — two plain vertical lines at the bottom of the screen;
   put each one exactly above one of the two marks on the top edge of the
   tracker (184.5 mm apart, centred on it). Drag with the mouse, TAB switches
   line, ←/→ 1 px, SHIFT+←/→ 10 px. Readout: distance, mm/px, screen size, and
   the monitor's EDID size (warning above 3 % difference). With
   `p = 184.5 / d_px`, `xc` the centre of the lines and `g` the gap:
   `TL = (-xc·p, g+H, 0)`, `TR = ((W_px-xc)·p, g+H, 0)`, `BL = (-xc·p, g, 0)`,
   `H = H_px·p`. ENTER sends `set_display_area_corners`; the daemon persists it.
   The lines start from the current device area when it matches this output.
2. **Position** — both eyes in the track box (mirror view, from
   `trackbox_eye_pos`), distance from `eye_origin` z (50–85 cm is green),
   hints. SPACE continues.
3. **Calibration** — `start_calibration`, then 9 dots, 3×3 inset from the
   edges: (0.2,0.1) (0.5,0.08) (0.8,0.1), (0.15,0.5) (0.5,0.5) (0.85,0.5),
   (0.15,0.85) (0.5,0.85) (0.85,0.85). Each dot is added
   (`add_calibration_point`) as soon as the eyes land on it: the first
   fixation that lies entirely after the dot appeared and has moved at least
   half the way from where the eyes were towards the dot. There is no
   distance-to-dot gate, because the uncalibrated gaze is 5–10° off (more at
   the top of tall screens): a radius either waits forever or, with a
   fallback, records points the person was not looking at. After 1.2 s
   without a landing the point is added anyway. The dots avoid the corners:
   before calibration the tracker loses the eyes there on large screens, and
   one bad point degrades the whole calibration. About 1 s per dot. A dot
   the device refuses (no usable gaze) is shown again, twice at most. Then
   `finish_calibration`: the daemon stores and applies the blob. On ESC or failure: `cancel_calibration`, then
   `cal_apply` of the stored blob (`$XDG_STATE_HOME/tobiifree/calibration.bin`),
   because starting a calibration clears the device's points.
4. **Validation and correction map** — 16 dots (4×4 at 0.1, 0.3667, 0.6333,
   0.9), gaze-contingent too: samples are collected only while the person
   fixates within 5° of the dot, until 0.5 s of them (after 5 s any stable
   fixation counts and the dot is flagged `*`; after 12 s the dot keeps what
   it has if ≥ 0.2 s, else "no fixation"). About 1–1.4 s per dot. Gaze is collected raw
   (`set_gaze_raw`: the daemon's correction map is not applied), and each
   dot's gaze is the median of its samples. Errors in degrees (atan of the
   on-screen error over the eye distance `eye_origin` z) and mm, computed
   from the same samples three ways:
   - **uncorrected** (the device calibration alone);
   - **current map**, if the daemon holds an active one;
   - **new map, leave-one-out**: each dot corrected by a map fitted on the
     other positions (λ chosen inside each fold), an honest estimate on gaze
     the map was not fitted on.

   **Runs are pooled.** Each run's per-dot raw medians are added to
   `$XDG_STATE_HOME/tobiifree/correction_runs.json` as soon as its results
   are computed (so V or ESC don't lose it), for the calibration in use (blob
   SHA-256 + display area; a history for another one is replaced, at most 20
   runs). The new map is fitted on the per-position pool of all runs (mean,
   or median from 3 runs on), and the leave-one-out leaves a dot's *position*
   out of every run; the numbers shown are for the run just made. The results
   show "runs pooled: N"; X resets the history to the current run.
   tobiifreed deletes the history with the map when the calibration blob or
   the display area changes.

   The new map (fitted on the pool, fallback dots excluded, see `driver/src/correction.zig`)
   is proposed only if its leave-one-out mean beats both the uncorrected and
   the current-map mean by at least 0.02°; a current map that does worse than
   no map is proposed for removal. The results show, per dot, a grey arrow to
   the raw gaze and a coloured one to the leave-one-out corrected gaze
   ("raw° → corrected°"), the three summaries and the decision. ENTER
   applies it (saves the map / removes it / nothing) and finishes, V
   validates again (this run stays in the history), X resets the history,
   R redoes the calibration, G shows the live gaze (green raw, blue through
   the new map), ESC quits without touching the map (the run stays in the
   history). The analysis
   takes ~10 ms in release builds (a few seconds in Debug).

Dots are orange while waiting for the gaze and blue while the gaze is on them
(shrinking / collecting); they turn orange again when the fixation breaks. The
colour fades over 0.1 s (`DOT_FADE_S`) both ways.

A fixation is 0.15 s of valid gaze with a dispersion (x range + y range) under
1°; all thresholds are constants at the top of `src/main.zig`, the detector is
`src/fixation.zig`. Fixation times per dot are logged.

Tested on an ET5 under a BenQ XL2430T (1920×1080): lines 667 px apart give a
531 mm wide area (EDID 530 mm); validation after calibration 0.56–0.68° mean
over several runs, last run 0.58° mean / 0.91° max at 71 cm.

On an ET5 under an Acer X34 (34" 3440×1440, 1900R curved, 801×335 mm area
from the marks, eyes at 70–75 cm level with the screen centre): calibration
in about 13 s, validation 0.82–1.04° uncorrected and 0.54–0.70°
leave-one-out with the correction map (0.49° with two pooled runs). Two
limits seen there:
- With the eyes below the screen centre, the gaze saturates near the top
  centre (targets 3 cm apart read the same). Lowering the screen until the
  eyes are level with its centre fixed most of it.
- `start_calibration` appears to reset the device's gaze model, not just its
  point list: a quick calibration made before it does not help to detect
  fixations on the dots that follow.

`--simulate-gaze` (testing) replaces the tracker's gaze by a synthetic
viewer who looks at the active dot with a fixed drift field;
`tests/headless_validation.sh` runs the validation end to end in a headless
sway against `tobiifreed --no-device --fake-gaze` (nothing real touched).

Exit status: 0 done, 1 cancelled or error, 2 bad arguments / unknown output.
