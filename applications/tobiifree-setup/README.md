# tobiifree-setup

Fullscreen configurator for the Tobii ET5, in the spirit of the Windows
setup: display area, position guide, calibration, validation. Zig + GTK4 +
`gtk4-layer-shell`; it talks to `tobiifreed` (which must be running) through
the Zig `SocketSource`.

```sh
just setup                      # or: cd applications/tobiifree-setup && zig build run
tobiifree-setup --output DP-1   # the output the tracker is mounted on
tobiifree-setup --step validate # one step only: display | calibrate | validate
tobiifree-setup --gap 12        # tracker origin -> bottom of the active area, mm (default 10)
```

The window is a layer-shell OVERLAY surface covering the whole output, with
exclusive keyboard. Output: `--output NAME`, else `"output"` in
`~/.config/tobii.json` (written by the tool when step 1 is confirmed;
tobiifreed keeps the key when it rewrites the file), else the focused output
(Hyprland), else the first one. Everything is computed in physical pixels of
that output (logical size × monitor scale, fractional scales included).

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
3. **Calibration** — `start_calibration`, then 3 dots ▽ (0.1,0.1) (0.9,0.1)
   (0.5,0.9) and 3 dots △ (0.1,0.9) (0.9,0.9) (0.5,0.1); the active dot shrinks
   for 1 s, then `add_calibration_point`. A dot the device refuses (no usable
   gaze) is shown again, twice at most. Then `finish_calibration`: the daemon
   stores and applies the blob. On ESC or failure: `cancel_calibration`, then
   `cal_apply` of the stored blob (`$XDG_STATE_HOME/tobiifree/calibration.bin`),
   because starting a calibration clears the device's points.
4. **Validation** — 9 dots (0.9 s settle, 1.2 s of samples each); per-dot error
   and mean/max in degrees (atan of the on-screen error over the eye distance
   `eye_origin` z) and mm. R redo calibration, V validate again, G live gaze
   dot, ENTER done.

Exit status: 0 done, 1 cancelled or error, 2 bad arguments / unknown output.
