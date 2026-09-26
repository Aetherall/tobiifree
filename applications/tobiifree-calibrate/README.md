# tobiifree-calibrate

A standalone Python script that connects to the `tobiifreed` unix socket and runs a 5-point gaze calibration, producing a calibration blob that the daemon uses to correct gaze data for the current user.

## Prerequisites

* `tobiifreed` must be running (the script connects to its unix socket at `$XDG_RUNTIME_DIR/tobiifreed/gaze.sock`).
* Python 3 with [pygame](https://www.pygame.org/) installed:
  ```bash
  pip install pygame
  ```

## Running

```bash
python3 calibrate.py
```

This will:
1. Connect to `tobiifreed` and subscribe to the gaze stream.
2. Enter fullscreen and show 5 calibration points, one at a time — look at each dot and press **ENTER** to capture it (**ESC** cancels).
3. Send the captured points to the daemon, which computes a calibration blob.
4. Apply the blob and save it to `calib_blob.bin` in the current directory (overwriting any previous file).
5. Show a live view of the current (corrected) gaze position. Press **SPACE** to re-calibrate, or **ESC** to quit.

### Reusing a previous calibration

To skip the 5-point calibration and apply a previously saved blob at startup:

```bash
python3 calibrate.py --blob calib_blob.bin
```

If applying the blob fails, the script falls back to running a full calibration.

## Notes

* Starting calibration (`CMD_START_CALIBRATION`) is retried automatically up to 5 times if the daemon doesn't acknowledge it.
* The fullscreen display is sized to the desktop's real resolution and marked high-DPI aware, and UI element sizes (dots, fonts, margins) are scaled relative to screen height, so the calibration UI still looks correct on Linux desktops using display scaling (e.g. 150%).
* Can also be imported as a module — see `main()` in `calibrate.py`.
