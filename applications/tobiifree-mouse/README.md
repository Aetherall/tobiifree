# tobiifree-mouse

This is a Zig client that connects to the `tobiifreed` socket and virtualizes mouse movement and clicks using Linux `uinput`.

It implements a "Dwell Click" mechanism: if your gaze stays within a predefined radius for a set amount of time (e.g., 1000ms), it automatically emits a left mouse click.

## Prerequisites

Because `tobiifree-mouse` creates a virtual mouse at the kernel level, it requires permission to write to `/dev/uinput`.

The simplest way is to ensure you have a `udev` rule to allow your user to access `uinput`.

### Option 1: Temporary (Testing)
Run the application as root. (Note: on some Wayland compositors, running uinput as root while logged in as a normal user might still have issues, but it works in most cases).
```bash
sudo ./zig-out/bin/tobiifree-mouse
```

### Option 2: Udev Rule (Recommended)

1. Create a group for uinput and add your user:
```bash
sudo groupadd uinput
sudo usermod -aG uinput $USER
```
2. Create a rules file at `/etc/udev/rules.d/99-uinput.rules`:
```bash
echo 'KERNEL=="uinput", GROUP="uinput", MODE="0660"' | sudo tee /etc/udev/rules.d/99-uinput.rules
```
3. Reload rules and driver:
```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```
*Note: You may need to log out and log back in for the group change to take effect.*

## Building

From the `tobiifree` workspace root:
```shell
cd applications/tobiifree-mouse
zig build
```

## Running

If you have set up the `uinput` permissions correctly:

```shell
./zig-out/bin/tobiifree-mouse
```

*   Ensure that `tobiifreed` is running before you start.
*   The mouse cursor should jump to wherever you look.
*   Maintain your gaze steadily for ~1 second to trigger a click.
*   (Check `src/main.zig` to change the hardcoded screen resolution if needed)

## Command-line Options

```shell
./zig-out/bin/tobiifree-mouse [options]
```

| Option | Description | Default |
| --- | --- | --- |
| `--click` | Enable dwell clicking (disabled by default; without it the cursor moves but never clicks) | disabled |
| `--click-radius <float>` | Normalized radius (0.0–1.0, relative to screen size) the gaze must stay within to count as a dwell | `0.05` |
| `--click-dwell-ms <int>` | Time in milliseconds the gaze must remain within the radius before a click is emitted | `1000` |
| `--help`, `-h` | Print usage and exit | — |

Example, enabling dwell clicking with a larger radius and a shorter dwell time:

```shell
./zig-out/bin/tobiifree-mouse --click --click-radius 0.08 --click-dwell-ms 700
```

Unknown arguments are logged as a warning and otherwise ignored.
