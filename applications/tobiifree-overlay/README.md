# Gaze Overlay

Native transparent overlay that renders the ET5 gaze dot on screen. Written in Zig, uses GTK4 + `gtk4-layer-shell` for the overlay surface and `libusb` for direct tracker communication.

## Architecture

```
tobiifree_core.zig (native, linked directly)
  ├── TTP frame builders (hello, subscribe, set_display_area)
  └── tobiifree_decode_payload (TLV → column values)
       ↓
main.zig
  ├── libusb → USB bulk I/O to ET5
  ├── TTP accumulator + frame parser
  ├── GTK4 + gtk4-layer-shell → transparent OVERLAY layer surface
  └── GLib timeout @ 60Hz → poll USB, move dot
```

Single binary, no runtime dependencies beyond GTK4 and libusb.

## Usage

```sh
just overlay          # build + run
just build-overlay    # build only (zig-out/bin/tobiifree-overlay)
```

Or directly:
```sh
cd applications/tobiifree-overlay
zig build run
```

## Wayland / X11

- **Wayland**: uses `gtk4-layer-shell` OVERLAY layer. Click-through via empty input region.
- **X11**: falls back to GTK4's native windowing with transparent background.
