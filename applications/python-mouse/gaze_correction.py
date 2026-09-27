"""
gaze_correction.py — gaze calibration point storage + correction blending.
(used by gaze_mouse.py)

Calibration points are persisted to calib_points.json (next to this file
by default). Each point records:

    target_x, target_y   — where the user actually clicked (ground truth)
    gaze_x,   gaze_y      — the raw (uncorrected) gaze position at click time
    error_x,  error_y     — target - gaze (the correction needed at this spot)
    radius                — pixel radius of influence for this point

Correction model: for a given raw gaze position, every calibration point
whose gaze_x/gaze_y is within `radius` pixels contributes a correction
that's full strength at distance 0 and fades linearly to zero at the
radius edge. Contributions from multiple nearby points are summed; if
their combined weight exceeds 1 (heavily overlapping influence zones)
the result is normalized down so corrections don't stack past 100%.
"""

import json
import math
import os

DEFAULT_RADIUS = 300
DEFAULT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "calib_points.json")


class CalibrationStore:
    def __init__(self, path: str = DEFAULT_PATH, default_radius: float = DEFAULT_RADIUS):
        self.path = path
        self.default_radius = default_radius
        self.points = []  # list of dicts, see module docstring
        self.load()

    def load(self) -> None:
        try:
            with open(self.path, "r") as f:
                data = json.load(f)
            self.default_radius = data.get("radius", self.default_radius)
            self.points = data.get("points", [])
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            self.points = []

    def save(self) -> None:
        data = {"radius": self.default_radius, "points": self.points}
        tmp_path = self.path + ".tmp"
        with open(tmp_path, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp_path, self.path)  # atomic on POSIX, avoids a torn write on crash

    def add_point(self, target_x: float, target_y: float, gaze_x: float, gaze_y: float, radius=None) -> dict:
        point = {
            "target_x": target_x,
            "target_y": target_y,
            "gaze_x": gaze_x,
            "gaze_y": gaze_y,
            "error_x": target_x - gaze_x,
            "error_y": target_y - gaze_y,
            "radius": radius if radius is not None else self.default_radius,
        }
        self.points.append(point)
        self.save()
        return point

    def remove_nearest(self, x: float, y: float, max_dist: float = 30) -> bool:
        """Remove the calibration point (by target position) nearest to
        (x, y), if it's within max_dist pixels. Returns True if removed."""
        if not self.points:
            return False
        best_i, best_d = None, None
        for i, p in enumerate(self.points):
            d = math.hypot(p["target_x"] - x, p["target_y"] - y)
            if best_d is None or d < best_d:
                best_i, best_d = i, d
        if best_i is not None and best_d <= max_dist:
            del self.points[best_i]
            self.save()
            return True
        return False

    def clear(self) -> None:
        self.points = []
        self.save()

    def compute_correction(self, raw_x: float, raw_y: float) -> tuple[float, float]:
        """Return (corr_x, corr_y) to add to a raw gaze pixel position."""
        if not self.points:
            return 0.0, 0.0

        corr_x = corr_y = 0.0
        total_weight = 0.0
        for p in self.points:
            r = p.get("radius", self.default_radius)
            if r <= 0:
                continue
            dist = math.hypot(raw_x - p["gaze_x"], raw_y - p["gaze_y"])
            if dist >= r:
                continue
            weight = 1.0 - dist / r  # 1.0 at the point itself, 0.0 at the radius edge
            corr_x += weight * p["error_x"]
            corr_y += weight * p["error_y"]
            total_weight += weight

        if total_weight > 1.0:
            # Overlapping influence zones — blend instead of stacking corrections.
            corr_x /= total_weight
            corr_y /= total_weight
        return corr_x, corr_y
