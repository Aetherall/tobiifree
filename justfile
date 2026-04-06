# tobii — build / dev orchestration
#
# Usage:  just <recipe>          (list with: just --list)
#
# Flow:  wasm  →  bundle  →  demo / overlay

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set dotenv-load := false

# Default: show the list
default:
    @just --list

# -------------------------------------------------------------------
# Zig / wasm
# -------------------------------------------------------------------

# Build the wasm core (driver/zig-out/bin/tobiifree_core.wasm)
wasm:
    cd driver && zig build -Doptimize=ReleaseSmall

# Run the Zig unit tests
test-zig:
    cd driver && zig build test

# Native TLV decoder CLI — pass a captured frame path
tobiifree-decode FRAME:
    cd driver && zig build tobiifree-decode -- "$(realpath --relative-to=driver {{FRAME}})"

# -------------------------------------------------------------------
# TS / wasm bundle
# -------------------------------------------------------------------

# Rebuild wasm and re-embed it as base64 into sdk/src/wasm-bundle.ts
bundle: wasm
    node scripts/bundle-wasm.mjs

# Install JS deps (npm workspaces)
install:
    npm install

# Typecheck the SDK
typecheck-sdk:
    cd sdk && npx tsc --noEmit

# -------------------------------------------------------------------
# Browser demo app
# -------------------------------------------------------------------

# Run the Vite gaze demo with hot-reload (WebUSB, browser)
demo: bundle
    cd applications/tobiifree-demo && npm run dev

# Production build of the gaze demo
build-demo: bundle
    cd applications/tobiifree-demo && npm run build

# -------------------------------------------------------------------
# Native overlay (Zig + GTK4 + libusb)
# -------------------------------------------------------------------

# Build and run the native gaze overlay
overlay:
    cd applications/tobiifree-overlay && zig build run

# Build the overlay binary
build-overlay:
    cd applications/tobiifree-overlay && zig build -Doptimize=ReleaseSafe

# Hot-reload overlay: rebuild + restart on source change
overlay-dev:
    #!/usr/bin/env bash
    DIR=applications/tobiifree-overlay
    SRC="$DIR/src $DIR/build.zig driver/src"
    LOG="$DIR/overlay.log"
    PID=""
    cleanup() { pkill -f 'zig-out/bin/tobiifree-overlay' 2>/dev/null; exit 0; }
    trap cleanup INT TERM EXIT
    while true; do
        echo ":: building..."
        > "$LOG"
        if (cd "$DIR" && zig build) >> "$LOG" 2>&1; then
            pkill -f 'zig-out/bin/tobiifree-overlay' 2>/dev/null; sleep 0.3
            echo ":: starting overlay"
            "$DIR/zig-out/bin/tobiifree-overlay" >> "$LOG" 2>&1 &
            PID=$!
        else
            echo ":: build failed:"
            cat "$LOG"
            PID=""
        fi
        inotifywait -r -e modify,create,delete --exclude '\.(zig-cache|zig-out)' $SRC -qq
    done

# -------------------------------------------------------------------
# Daemon (tobiifreed)
# -------------------------------------------------------------------

# Build and run the gaze daemon (add --ws to enable WebSocket)
tobiifreed *ARGS:
    cd applications/tobiifreed && zig build run -- {{ARGS}}

# Build the daemon binary
build-tobiifreed:
    cd applications/tobiifreed && zig build -Doptimize=ReleaseSafe

# Hot-reload daemon: rebuild + restart on source change
tobiifreed-dev:
    #!/usr/bin/env bash
    DIR=applications/tobiifreed
    SRC="$DIR/src $DIR/build.zig driver/src"
    LOG="$DIR/tobiifreed.log"
    PID=""
    cleanup() { pkill -f 'zig-out/bin/tobiifreed' 2>/dev/null; exit 0; }
    trap cleanup INT TERM EXIT
    while true; do
        echo ":: building..."
        > "$LOG"
        if (cd "$DIR" && zig build) >> "$LOG" 2>&1; then
            pkill -f 'zig-out/bin/tobiifreed' 2>/dev/null; sleep 0.3
            echo ":: starting tobiifreed"
            "$DIR/zig-out/bin/tobiifreed" >> "$LOG" 2>&1 &
            PID=$!
        else
            echo ":: build failed:"
            cat "$LOG"
            PID=""
        fi
        inotifywait -r -e modify,create,delete --exclude '\.(zig-cache|zig-out)' $SRC -qq
    done

# -------------------------------------------------------------------
# Try: build + run with 3s timeout, all output to stdout
# -------------------------------------------------------------------

# Try overlay via direct USB (3s timeout)
try-overlay-usb:
    #!/usr/bin/env bash
    (cd applications/tobiifree-overlay && zig build) 2>&1 || exit 1
    timeout 3 applications/tobiifree-overlay/zig-out/bin/tobiifree-overlay --direct 2>&1; true

# Try overlay via daemon socket (3s timeout, manages daemon lifecycle)
try-overlay-daemon:
    #!/usr/bin/env bash
    (cd applications/tobiifreed && zig build) 2>&1 || exit 1
    (cd applications/tobiifree-overlay && zig build) 2>&1 || exit 1
    # Start daemon in background with prefixed output.
    # Use a FIFO so we get the real daemon PID (not sed's).
    LOGFIFO=$(mktemp -u); mkfifo "$LOGFIFO"
    sed -u 's/^/[daemon] /' < "$LOGFIFO" &
    SED_PID=$!
    applications/tobiifreed/zig-out/bin/tobiifreed > "$LOGFIFO" 2>&1 &
    DAEMON_PID=$!
    rm "$LOGFIFO"
    cleanup() { kill $DAEMON_PID 2>/dev/null; wait $DAEMON_PID 2>/dev/null; kill $SED_PID 2>/dev/null; wait $SED_PID 2>/dev/null; }
    trap 'cleanup; exit 0' EXIT INT TERM
    sleep 0.5  # let daemon start and claim USB
    # Run overlay with timeout, prefix its output
    timeout 3 applications/tobiifree-overlay/zig-out/bin/tobiifree-overlay --socket 2>&1 | sed 's/^/[overlay] /'; true
    cleanup

# Try the daemon (3s timeout, add args after --)
try-daemon *ARGS:
    #!/usr/bin/env bash
    (cd applications/tobiifreed && zig build) 2>&1 || exit 1
    timeout 3 applications/tobiifreed/zig-out/bin/tobiifreed {{ARGS}} 2>&1; true

# -------------------------------------------------------------------
# Native C helpers
# -------------------------------------------------------------------

# Build the DFU flasher (bootloader → runtime)
flash-firmware-bin:
    cc assets/flash_firmware.c -lusb-1.0 -o flash_firmware

# Build the CAI extractor (pulls firmware out of platformservice.exe)
extract-firmware-bin:
    cc assets/extract_firmware.c -o extract_firmware

# -------------------------------------------------------------------
# Meta
# -------------------------------------------------------------------

# Full local bootstrap: wasm + bundle + JS deps
setup: bundle install

# Typecheck + zig tests
check: typecheck-sdk test-zig

# Remove build artifacts
clean:
    rm -rf driver/zig-out driver/.zig-cache
    rm -rf applications/*/dist applications/*/node_modules/.vite
    rm -f flash_firmware extract_firmware
