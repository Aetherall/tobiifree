"""Integration test of tobiifreed's correction map, without the tracker.

Runs the daemon with --no-device --fake-gaze in isolated HOME / XDG dirs
(never touches USB, nor the real ~/.config or calibration):

    python3 applications/tobiifreed/tests/correction_test.py \
        applications/tobiifreed/zig-out/bin/tobiifreed
"""
import os, sys, json, socket, struct, subprocess, time, hashlib, shutil, math

ROOT = "/tmp/tobiifreed-correction-test"
DAEMON = sys.argv[1]
shutil.rmtree(ROOT, ignore_errors=True)
HOME, STATE, RUN = f"{ROOT}/home", f"{ROOT}/state", f"{ROOT}/run"
for d in (f"{HOME}/.config", f"{STATE}/tobiifree", RUN): os.makedirs(d)
os.chmod(RUN, 0o700)
env = dict(os.environ, HOME=HOME, XDG_STATE_HOME=STATE, XDG_RUNTIME_DIR=RUN)
SOCK = f"{RUN}/tobiifreed/gaze.sock"
CAL = f"{STATE}/tobiifree/calibration.bin"
CORR = f"{STATE}/tobiifree/correction.json"
AREA = [-233.184, 308.741, 0, 297.911, 308.741, 0, -233.184, 10, 0]
W = math.hypot(AREA[3]-AREA[0], AREA[4]-AREA[1]); H = math.hypot(AREA[0]-AREA[6], AREA[1]-AREA[7])

def write_config(area):
    json.dump({"display_area": {"tl": area[0:3], "tr": area[3:6], "bl": area[6:9]}, "output": "DP-1"}, open(f"{HOME}/.config/tobii.json", "w"))

def make_map(blob, area=AREA, lam=0.1):
    g = [0.1, 0.3667, 0.6333, 0.9]; pts = []
    for ty in g:
        for tx in g:
            b = math.exp(-(((tx-0.9)/0.3)**2 + ((ty-0.1)/0.3)**2))
            pts.append({"target": [tx, ty], "gaze": [tx + (3-4*b)/W, ty + (2+17*b)/H], "n": 34})
    return json.dumps({"version": 1, "calibration_sha256": hashlib.sha256(blob).hexdigest(), "display_area": area,
                       "lambda": lam, "cap_mm": 30, "fade_mm": 60, "points": pts}).encode()

class C:
    def __init__(s):
        for _ in range(100):
            try:
                s.s = socket.socket(socket.AF_UNIX); s.s.connect(SOCK); break
            except OSError: time.sleep(0.05)
        s.buf = b""; s.s.settimeout(3)
    def send(s, t, p=b""): s.s.sendall(struct.pack("<BI", t, len(p)) + p)
    def recv(s):
        while True:
            if len(s.buf) >= 5:
                t, n = struct.unpack("<BI", s.buf[:5])
                if len(s.buf) >= 5+n:
                    p = s.buf[5:5+n]; s.buf = s.buf[5+n:]; return t, p
            s.buf += s.s.recv(1 << 16)
    def cmd(s, t, p=b""):
        s.send(t, p)
        while True:
            mt, pl = s.recv()
            if mt in (2, 0xFF) and pl[:1] == bytes([t]): return (mt == 2), pl[1:]
    def gaze(s):
        while True:
            mt, pl = s.recv()
            if mt == 1:
                mask = struct.unpack_from("<I", pl, 0)[0]
                x, y = struct.unpack_from("<2d", pl, 40)
                return mask, x, y

def start(*extra):
    return subprocess.Popen([DAEMON, "--no-device", "--fake-gaze", "0.9,0.1", *extra], env=env,
                            stdout=open(f"{ROOT}/daemon.log", "a"), stderr=subprocess.STDOUT)
def stop(p):
    p.send_signal(2); p.wait(5)

ok = True
def check(name, cond, info=""):
    global ok
    print(("PASS " if cond else "FAIL ") + name, info); ok = ok and cond

blob = b"fake calibration blob A"
open(CAL, "wb").write(blob); write_config(AREA)
d = start()
a = C(); b = C()
a.send(1, struct.pack("<I", 0x500)); b.send(1, struct.pack("<I", 0x500))
r = b.cmd(0x34, b"\x01"); check("set_gaze_raw replies", r == (True, b""))
r = a.cmd(0x31); check("no map at start", r == (True, b"\x00"), r)
r = a.cmd(0x30, make_map(b"other blob")); check("map for another blob refused (mismatch)", r == (False, struct.pack("<I", 0x0A)), r)
area2 = AREA[:]; area2[7] = 30; area2[1] += 20; area2[4] += 20
r = a.cmd(0x30, make_map(blob, area2)); check("map for another area refused (mismatch)", r == (False, struct.pack("<I", 0x0A)), r)
r = a.cmd(0x30, b"{not json"); check("bad json refused (bad_payload)", r == (False, struct.pack("<I", 0x05)), r)
r = a.cmd(0x30, make_map(blob)); check("map accepted", r == (True, b""), r)
check("map saved", os.path.exists(CORR))
r = a.cmd(0x31); check("map active", r[0] and r[1][:1] == b"\x01", r[1][:1])
time.sleep(0.2)
for _ in range(5): a.gaze(); b.gaze()
ma, xa, ya = a.gaze(); mb, xb, yb = b.gaze()
check("normal client: corrected + flagged", (ma >> 22) & 1 == 1 and abs(ya - 0.1) > 0.02, f"({xa:.4f},{ya:.4f}) dy={(ya-0.1)*H:+.1f} mm")
check("raw client: untouched", (mb >> 22) & 1 == 0 and xb == 0.9 and yb == 0.1, f"({xb},{yb})")
r = a.cmd(0x33, b"\x00"); check("disable globally", r == (True, b""))
for _ in range(5): a.gaze()
ma, xa, ya = a.gaze(); check("disabled: raw for everyone", (ma >> 22) & 1 == 0 and ya == 0.1, (xa, ya))
r = a.cmd(0x31); check("state inactive while disabled", r[1][:1] == b"\x02")
a.cmd(0x33, b"\x01")
stop(d)

d = start(); a = C(); r = a.cmd(0x31); check("restart: map reloaded, active", r[1][:1] == b"\x01", r[1][:1]); stop(d)

open(CAL, "wb").write(b"fake calibration blob B")
d = start(); a = C(); r = a.cmd(0x31)
check("new calibration blob: map deleted at startup", r == (True, b"\x00") and not os.path.exists(CORR), r); stop(d)

open(CAL, "wb").write(blob); open(CORR, "wb").write(make_map(blob)); write_config(area2)
d = start(); a = C(); r = a.cmd(0x31)
check("other display area: map deleted at startup", r == (True, b"\x00") and not os.path.exists(CORR), r); stop(d)

write_config(AREA); open(CORR, "wb").write(make_map(blob))
d = start(); a = C(); r = a.cmd(0x32); check("clear", r == (True, b"") and not os.path.exists(CORR)); r = a.cmd(0x31); check("cleared: none", r == (True, b"\x00")); stop(d)
print("ALL PASS" if ok else "SOME FAILED")
sys.exit(0 if ok else 1)
