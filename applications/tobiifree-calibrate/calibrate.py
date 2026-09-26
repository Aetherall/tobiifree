#!/usr/bin/env python3
"""
calibrate.py [--blob <path>]

Connects to the tobiifreed unix socket, and performs a 5-point calibration.
A calibration blob is generated and applied to the daemon, which will then
correct gaze data for the current user.

The calibration process is as follows:
1. Connect to the tobiifreed daemon via its unix socket.
2. Subscribe to the gaze stream (so we can show a live gaze dot afterwards).
3. Send a CMD_START_CALIBRATION command to the daemon.
4. For each of the 5 calibration points:
   a. Display a dot on the screen at the calibration point.
   b. Wait for the user to press ENTER while looking at the dot.
   c. Send a CMD_ADD_CALIBRATION_POINT command to the daemon with the normalized
      coordinates of the calibration point.
5. After all points are captured, send a CMD_FINISH_CALIBRATION command to the
   daemon to compute the calibration blob.
6. Send a CMD_CAL_APPLY command to the daemon with the calibration blob to apply
   the calibration, and save the blob to calib_blob.bin.
7. Show a live view of the current gaze point. SPACE re-runs calibration,
   ESC quits.

Every time a calibration completes successfully, the resulting blob is
written to "calib_blob.bin" in the current directory (overwriting any
previous file).

After calibration finishes, the script stays in fullscreen mode and shows a
live dot tracking the current (corrected) gaze position, read from the
daemon's gaze stream.

In case a previous calibration blob is available, it can be applied at startup using
the --blob <path> argument, skipping the initial 5-point calibration.

This is a standalone script, but it can also be imported as a module and the
`main()` function can be called to run the calibration process.

The script uses pygame to display the calibration points, the live gaze dot,
and to capture user input.
"""

import os
import socket
import struct
import sys
import threading
import time
import argparse
from pathlib import Path

try:
    import pygame
except ImportError:
    print("Pygame is not installed. Please install it using: pip install pygame")
    sys.exit(1)

# Command IDs from daemon_protocol.zig
CMD_SUBSCRIBE = 0x01
CMD_START_CALIBRATION = 0x20
CMD_ADD_CALIBRATION_POINT = 0x21
CMD_FINISH_CALIBRATION = 0x22
CMD_CAL_APPLY = 0x23

# Server message types
SRV_GAZE = 0x01
SRV_RESPONSE = 0x02
SRV_ERR = 0xFF

HEADER_SIZE = 5

# Layout of core.GazeSample (tobiifree_core.zig), matching gaze_mouse.py.
GAZE_STRUCT_FMT = (
    "<"
    "IIII"    # present_mask, frame_counter, validity_L, validity_R
    "q"       # timestamp_us
    "dd"      # pupil_L_mm, pupil_R_mm
    "2d2d2d"  # gaze_point_2d_norm, gaze_point_2d_L_norm, gaze_point_2d_R_norm
    "3d3d3d3d3d3d3d3d3d3d3d3d"  # 12 f64x3 blocks (eye origins, trackbox pos, 3D gaze, display-space variants)
    "2d"      # gaze_point_2d_unfiltered
)
GAZE_STRUCT_SIZE = struct.calcsize(GAZE_STRUCT_FMT)  # 392 bytes

VALID = 0   # validity_L/validity_R: 0 == valid, 4 == not detected

CALIB_BLOB_PATH = Path("calib_blob.bin")

# The dot radii / font sizes / margins below were tuned for a display with
# roughly this height in physical pixels. Actual sizes are scaled relative
# to the real screen height at runtime (see get_ui_scale()) so the UI looks
# the same physical size regardless of monitor resolution or desktop-level
# display scaling (e.g. 150% scaling on Linux/Wayland/X11).
REFERENCE_HEIGHT = 1080

# 5-point calibration grid 
pts = [
    (0.5, 0.5),
    (0.1, 0.1),
    (0.9, 0.1),
    (0.1, 0.9),
    (0.9, 0.9),
]


def get_socket_path():
    runtime_dir = os.environ.get('XDG_RUNTIME_DIR', '/tmp')
    return Path(runtime_dir) / 'tobiifreed' / 'gaze.sock'


def get_ui_scale(screen):
    """
    Returns a scale factor for UI element sizes (dot radii, fonts, margins),
    relative to REFERENCE_HEIGHT, based on the actual screen height in
    pixels. This keeps the calibration UI at a consistent physical size
    whether running on a small/large monitor or with OS-level display
    scaling applied.
    """
    _, h = screen.get_size()
    return max(h, 1) / REFERENCE_HEIGHT


def create_fullscreen_display():
    """
    Creates a fullscreen pygame display, explicitly sized to the current
    desktop resolution and marked as high-DPI aware.

    On Linux desktops using fractional display scaling (e.g. 150% scaling
    on GNOME/KDE under Wayland or X11), SDL/pygame can otherwise end up
    using a 'logical' (scaled) resolution that doesn't match the physical
    screen, causing the fullscreen window to be mis-sized relative to the
    real display. Requesting the desktop's own size together with
    pygame.SCALED makes SDL treat the window as high-DPI aware, so the
    calibration dots and gaze dot line up correctly with the physical
    screen regardless of the configured scaling factor.
    """
    desktop_sizes = pygame.display.get_desktop_sizes()
    if desktop_sizes:
        size = desktop_sizes[0]
        return pygame.display.set_mode(size, pygame.FULLSCREEN | pygame.SCALED)
    return pygame.display.set_mode((0, 0), pygame.FULLSCREEN)


def encode_header(msg_type, payload_len):
    return struct.pack('<BI', msg_type, payload_len)


def decode_header(header_bytes):
    if len(header_bytes) != HEADER_SIZE:
        raise EOFError("Incomplete header")
    msg_type, payload_len = struct.unpack('<BI', header_bytes)
    return msg_type, payload_len


def recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("Disconnected from daemon")
        buf.extend(chunk)
    return bytes(buf)


class SharedGaze:
    """Thread-safe holder for the most recent gaze sample."""

    def __init__(self):
        self._lock = threading.Lock()
        self.x_norm = 0.5
        self.y_norm = 0.5
        self.valid = False

    def update(self, x, y, valid):
        with self._lock:
            self.x_norm, self.y_norm, self.valid = x, y, valid

    def get(self):
        with self._lock:
            return self.x_norm, self.y_norm, self.valid


class DaemonConnection:
    """
    Owns the unix socket to tobiifreed and multiplexes it between:
      - a background reader thread that continuously drains the socket,
        updating `gaze` with every SRV_GAZE frame it sees, and
      - synchronous `request()` calls made from the main thread, which
        block waiting for the SRV_RESPONSE/SRV_ERR belonging to the
        command they just sent.

    This assumes at most one `request()` is in flight at a time, which
    matches how this script uses it (calibration steps are sent one after
    another, waiting for each response before sending the next).
    """

    def __init__(self, sock):
        self.sock = sock
        self.gaze = SharedGaze()

        self._pending_cmd = None
        self._pending_event = threading.Event()
        self._pending_payload = None
        self._pending_error = None
        self._lock = threading.Lock()

        self._stop = threading.Event()
        self._disconnected_exc = None
        self._thread = threading.Thread(target=self._reader_loop, daemon=True)
        self._thread.start()

    def _reader_loop(self):
        try:
            while not self._stop.is_set():
                header_bytes = recv_exact(self.sock, HEADER_SIZE)
                msg_type, payload_len = decode_header(header_bytes)
                payload = recv_exact(self.sock, payload_len) if payload_len else b''

                if msg_type == SRV_GAZE:
                    self._handle_gaze(payload)
                elif msg_type == SRV_RESPONSE:
                    self._handle_response(payload)
                elif msg_type == SRV_ERR:
                    self._handle_error(payload)
                # Unknown message types are ignored.
        except (EOFError, OSError) as exc:
            self._disconnected_exc = exc
            # Wake up anyone waiting on a response; they'll see the error.
            with self._lock:
                if self._pending_cmd is not None:
                    self._pending_error = f"Disconnected from daemon: {exc}"
                    self._pending_event.set()

    def _handle_gaze(self, payload):
        if len(payload) < GAZE_STRUCT_SIZE:
            return
        vals = struct.unpack(GAZE_STRUCT_FMT, payload[:GAZE_STRUCT_SIZE])
        validity_L, validity_R = vals[2], vals[3]
        x_norm, y_norm = vals[7], vals[8]
        valid = (validity_L == VALID) or (validity_R == VALID)
        self.gaze.update(x_norm, y_norm, valid)

    def _handle_response(self, payload):
        with self._lock:
            if self._pending_cmd is not None and len(payload) > 0 and payload[0] == self._pending_cmd:
                self._pending_payload = payload[1:]
                self._pending_event.set()

    def _handle_error(self, payload):
        with self._lock:
            if self._pending_cmd is not None:
                self._pending_error = f"Daemon Error for cmd 0x{self._pending_cmd:02x}"
                self._pending_event.set()

    def send_only(self, cmd_type, payload=b''):
        """Fire-and-forget send, no response wait (for commands like SUBSCRIBE
        that don't produce an SRV_RESPONSE — success is observed via SRV_GAZE frames)."""
        with self._lock:
            if self._disconnected_exc is not None:
                raise EOFError(f"Disconnected from daemon: {self._disconnected_exc}")
            header = encode_header(cmd_type, len(payload))
            self.sock.sendall(header + payload)

    def request(self, cmd_type, payload=b'', timeout=30.0):
        with self._lock:
            if self._disconnected_exc is not None:
                raise EOFError(f"Disconnected from daemon: {self._disconnected_exc}")
            self._pending_cmd = cmd_type
            self._pending_payload = None
            self._pending_error = None
            self._pending_event.clear()

        header = encode_header(cmd_type, len(payload))
        self.sock.sendall(header + payload)

        if not self._pending_event.wait(timeout):
            with self._lock:
                self._pending_cmd = None
            raise TimeoutError(f"Timed out waiting for response to cmd 0x{cmd_type:02x}")

        with self._lock:
            error = self._pending_error
            result = self._pending_payload
            self._pending_cmd = None

        if error:
            raise RuntimeError(error)
        return result

    def close(self):
        self._stop.set()
        try:
            self.sock.close()
        except OSError:
            pass


def request_with_retries(conn, cmd_type, payload=b'', timeout=30.0, max_attempts=5, retry_delay=0.5):
    """
    Like DaemonConnection.request(), but retries on failure (RuntimeError from
    an SRV_ERR response, or TimeoutError from no response at all) up to
    `max_attempts` times before giving up.

    This works around an intermittent issue where the daemon occasionally
    fails to acknowledge a command (e.g. "cal_start: no response").
    """
    last_exc = None
    for attempt in range(1, max_attempts + 1):
        try:
            return conn.request(cmd_type, payload, timeout=timeout)
        except (RuntimeError, TimeoutError) as exc:
            last_exc = exc
            print(f"Command 0x{cmd_type:02x} failed (attempt {attempt}/{max_attempts}): {exc}")
            if attempt < max_attempts:
                time.sleep(retry_delay)
    raise last_exc


def run_calibration(conn, screen, font, big_font):
    """
    Runs a single 5-point calibration sequence.
    Returns the calibration blob (bytes) on success, or None if the user
    cancelled by pressing ESC.
    """
    w, h = screen.get_size()
    ui_scale = get_ui_scale(screen)
    dot_radius = max(1, round(15 * ui_scale))
    bottom_margin = round(100 * ui_scale)

    current_idx = 0
    capturing = False

    print("Starting calibration...")
    request_with_retries(conn, CMD_START_CALIBRATION)

    def draw_state():
        screen.fill((0, 0, 0))
        if current_idx < len(pts):
            x_norm, y_norm = pts[current_idx]
            px, py = int(x_norm * w), int(y_norm * h)

            color = (255, 255, 0) if capturing else (0, 255, 0)
            pygame.draw.circle(screen, color, (px, py), dot_radius)

            msg = f"Point {current_idx + 1}/{len(pts)}: Look at the dot and press ENTER. (Esc to cancel)"
            if capturing:
                msg = f"Capturing point {current_idx + 1}... hold your gaze!"

            text_surf = font.render(msg, True, (255, 255, 255))
            screen.blit(text_surf, (w // 2 - text_surf.get_width() // 2, h - bottom_margin))
        else:
            msg = "Computing calibration..."
            text_surf = big_font.render(msg, True, (255, 255, 255))
            screen.blit(text_surf, (w // 2 - text_surf.get_width() // 2, h // 2 - text_surf.get_height() // 2))

        pygame.display.flip()

    while True:
        draw_state()
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                return None
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    return None
                elif event.key == pygame.K_RETURN:
                    if current_idx < len(pts) and not capturing:
                        capturing = True
                        draw_state()

                        # Process events to show the "Capturing" UI update immediately
                        pygame.event.pump()

                        x, y = pts[current_idx]
                        print(f">> Capturing point {current_idx + 1} at ({x:.1f}, {y:.1f})...")
                        payload = struct.pack('<dd', x, y)
                        conn.request(CMD_ADD_CALIBRATION_POINT, payload)

                        current_idx += 1
                        capturing = False

                        if current_idx >= len(pts):
                            draw_state()

                            print("Computing calibration...")
                            blob = conn.request(CMD_FINISH_CALIBRATION)
                            print(f"Got calibration blob of {len(blob)} bytes.")

                            print("Applying calibration...")
                            conn.request(CMD_CAL_APPLY, blob)
                            print("Calibration applied successfully!")

                            return blob

        time.sleep(0.01)


def run_live_view(conn, screen, font):
    """
    Shows a live view of the current (corrected) gaze position,
    with the five calibration points shown as small grey circles
    in the background.
    Returns 'calibrate' if the user pressed SPACE, or 'quit' if they
    pressed ESC / closed the window.
    """
    w, h = screen.get_size()
    ui_scale = get_ui_scale(screen)
    marker_radius = max(1, round(5 * ui_scale))
    gaze_radius = max(1, round(18 * ui_scale))
    gaze_ring_width = max(1, round(2 * ui_scale))
    line_bottom_margin = round(60 * ui_scale)
    line_spacing = round(26 * ui_scale)

    while True:
        screen.fill((0, 0, 0))

        # Draw calibration points first so they remain in the background.
        for x_norm, y_norm in pts:
            px, py = int(x_norm * w), int(y_norm * h)
            pygame.draw.circle(screen, (100, 100, 100), (px, py), marker_radius)

        x_norm, y_norm, valid = conn.gaze.get()
        if valid:
            px, py = int(x_norm * w), int(y_norm * h)
            pygame.draw.circle(screen, (0, 200, 255), (px, py), gaze_radius)
            pygame.draw.circle(screen, (255, 255, 255), (px, py), gaze_radius, width=gaze_ring_width)
        else:
            msg = "waiting for valid gaze data..."
            text_surf = font.render(msg, True, (200, 60, 60))
            screen.blit(text_surf, (w // 2 - text_surf.get_width() // 2, h // 2))

        lines = [
            "SPACE: recalibrate      ESC: quit",
        ]
        for i, line in enumerate(lines):
            text_surf = font.render(line, True, (255, 255, 255))
            screen.blit(text_surf, (w // 2 - text_surf.get_width() // 2, h - line_bottom_margin + i * line_spacing))

        pygame.display.flip()

        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                return 'quit'
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    return 'quit'
                elif event.key == pygame.K_SPACE:
                    return 'calibrate'

        time.sleep(0.01)

def parse_args():
    parser = argparse.ArgumentParser(description="Tobii calibration with live feedback.")
    parser.add_argument(
        "-b", "--blob",
        type=Path,
        default=None,
        help="Path to a previously saved calibration blob to apply at startup, "
             "skipping the initial 5-point calibration.",
    )
    return parser.parse_args()
    
    
def main():
    args = parse_args()
    
    sock_path = get_socket_path()
    print(f"Connecting to tobiifreed at {sock_path}...")

    if not sock_path.exists():
        print("Error: Socket does not exist. Make sure tobiifreed is running.")
        sys.exit(1)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(str(sock_path))
    except Exception as e:
        print(f"Failed to connect: {e}")
        sys.exit(1)

    print("Connected to daemon socket.")

    try:
        conn = DaemonConnection(sock)

        # Subscribe so gaze frames start flowing (used by the live view later).
        conn.send_only(CMD_SUBSCRIBE)

        # Wait briefly for the first gaze frame as confirmation instead of an ack.
        deadline = time.time() + 5.0
        while time.time() < deadline:
            _, _, valid_seen = conn.gaze.get()
            if conn.gaze.get() != (0.5, 0.5, False):  # any update at all, valid or not
                break
            time.sleep(0.05)
        else:
            print("Warning: no gaze data received yet after subscribing; continuing anyway.")

    except (TimeoutError, RuntimeError, EOFError, OSError) as e:
        print(f"Warning: failed to subscribe to gaze stream: {e}")
        print("Continuing without live gaze feedback where possible.")

    pygame.init()
    screen = create_fullscreen_display()
    pygame.mouse.set_visible(False)

    ui_scale = get_ui_scale(screen)
    font = pygame.font.Font(None, max(1, round(36 * ui_scale)))
    big_font = pygame.font.Font(None, max(1, round(48 * ui_scale)))

    try:
        blob = None
        if args.blob is not None:
            if args.blob.exists():
                try:
                    blob = args.blob.read_bytes()
                    conn.request(CMD_CAL_APPLY, blob)
                    print(f"Applied calibration blob from {args.blob}")
                except (RuntimeError, TimeoutError, OSError) as e:
                    print(f"Failed to apply blob '{args.blob}': {e}")
                    blob = None
            else:
                print(f"Blob file not found: {args.blob}")

        if blob is None:
            # No blob given, or applying it failed — fall back to calibrating.
            blob = run_calibration(conn, screen, font, big_font)
            if blob is None:
                print("Calibration cancelled.")
                return

        while True:
            CALIB_BLOB_PATH.write_bytes(blob)
            print(f"Saved calibration blob to {CALIB_BLOB_PATH.resolve()}")

            action = run_live_view(conn, screen, font)
            if action == 'quit':
                break
            elif action == 'calibrate':
                blob = run_calibration(conn, screen, font, big_font)
                if blob is None:
                    print("Calibration cancelled, returning to live view.")
                    # Re-enter live view with whatever blob was last saved.
                    blob = CALIB_BLOB_PATH.read_bytes() if CALIB_BLOB_PATH.exists() else blob
                    if blob is None:
                        # Nothing to fall back to; quit gracefully.
                        break
    finally:
        pygame.quit()
        conn.close()


if __name__ == '__main__':
    main()