#!/usr/bin/env bash
# Headless end-to-end test of the setup tool's validation + correction map,
# with nothing real involved: a headless sway (own XDG_RUNTIME_DIR), tobiifreed
# --no-device --fake-gaze (no USB) in isolated HOME/XDG dirs, and the setup
# tool with --simulate-gaze. Runs the 16-dot validation, takes screenshots,
# runs it 3 times (V, X resets the history, V), presses G then ENTER (saves the map) and prints the daemon's map state.
#
#   nix shell nixpkgs#sway nixpkgs#grim nixpkgs#wtype -c \
#       applications/tobiifree-setup/tests/headless_validation.sh
# (build both apps first; screenshots and logs in /tmp/tobiifree-setup-headless-test)
set -u
R=/tmp/tobiifree-setup-headless-test; rm -rf $R; mkdir -p $R/home/.config $R/state/tobiifree $R/run $R/shots; chmod 700 $R/run
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
export HOME=$R/home XDG_STATE_HOME=$R/state XDG_RUNTIME_DIR=$R/run
unset WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY SWAYSOCK
printf 'fake calibration blob A' > $R/state/tobiifree/calibration.bin
cat > $R/home/.config/tobii.json <<J
{"display_area": {"tl": [-233.184, 308.741, 0], "tr": [297.911, 308.741, 0], "bl": [-233.184, 10, 0]}, "output": "HEADLESS-1", "gap_mm": 10}
J
echo 'output HEADLESS-1 resolution 1920x1080' > $R/sway.conf
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 sway -c $R/sway.conf > $R/sway.log 2>&1 &
SWAY=$!
for i in $(seq 50); do ls $R/run/wayland-* >/dev/null 2>&1 && break; sleep 0.1; done
export WAYLAND_DISPLAY=$(basename $(ls $R/run/wayland-? | head -1))
$REPO/applications/tobiifreed/zig-out/bin/tobiifreed --no-device --fake-gaze 0.5,0.5 > $R/daemon.log 2>&1 &
D=$!
sleep 0.5
GSK_RENDERER=cairo $REPO/applications/tobiifree-setup/zig-out/bin/tobiifree-setup --step validate --simulate-gaze > $R/setup.log 2>&1 &
S=$!
sleep 4; grim $R/shots/dot.png
# wait for the Nth analysis
wait_runs() { for i in $(seq 120); do [ "$(grep -c "decision" $R/setup.log)" -ge "$1" ] && return; sleep 0.5; done; }
key() { wtype -s 400 -k "$1"; sleep 0.6; }
wait_runs 1; sleep 0.5; grim $R/shots/results-run1.png
key v                        # run 2: run 1 must be kept
wait_runs 2; sleep 0.5; grim $R/shots/results-run2.png
key x; wait_runs 3              # history reset to run 2 (re-analysis)
key v                        # run 3: pooled with run 2
wait_runs 4; sleep 0.5; grim $R/shots/results.png
key g; grim $R/shots/results-gaze.png
key Return; sleep 2.5; grim $R/shots/after-enter.png
kill $S 2>/dev/null
$REPO/applications/tobiifreed/zig-out/bin/tobiifree-ctl correction | head -3 > $R/ctl.txt
kill -INT $D; sleep 0.5; kill $SWAY
cat $R/ctl.txt
grep "run(s) pooled" $R/setup.log | sed 's/.*mm mean); //'
ok=1
grep -q "correction map: active" $R/ctl.txt || { echo "FAIL: no active map"; ok=0; }
[ "$(grep -o '[0-9]* run(s) pooled' $R/setup.log | cut -d' ' -f1 | tr '\n' ' ')" = "1 2 1 2 " ] || { echo "FAIL: pooled runs sequence"; ok=0; }
python3 -c "import json,sys; h=json.load(open('$R/state/tobiifree/correction_runs.json')); c=json.load(open('$R/state/tobiifree/correction.json')); sys.exit(0 if len(h['runs'])==2 and c['stats']['runs']==2 else 1)" || { echo "FAIL: history/map run counts"; ok=0; }
[ $ok = 1 ] && echo PASS || exit 1
