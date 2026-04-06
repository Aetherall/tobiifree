/*
 * flash_firmware: Upload a firmware blob to the Tobii ET5 in DFU/bootloader
 * mode. Turns the tracker from bootloader (PID 0x0102) into the runtime
 * device (PID 0x0313).
 *
 * Protocol (decoded from USB control + bulk transfer observation):
 *
 *   The firmware blob is a signed archive. It cannot be synthesized —
 *   only replayed from a previously captured update.
 *
 *   Sequence (per slot, sent twice — once for A, once for B):
 *     1. GETSTATUS                         bmReq=0xC1 bReq=0x03 len=10
 *        Expect bState==2 (dfuIDLE) && bStatus==0. If not:
 *          CLRSTATUS                       bmReq=0x41 bReq=0x04 len=0
 *          ABORT                           bmReq=0x41 bReq=0x06 len=0
 *          GETSTATUS again
 *     2. DNLOAD #1 (24 bytes)              bmReq=0x41 bReq=0x01 wValue=8
 *        Payload: 24-byte signed header.
 *     3. GETSTATUS                         expect bState==3 (dfuDNLOAD-SYNC)
 *     4. DNLOAD #2 (4 bytes)               bmReq=0x41 bReq=0x01 wValue=8
 *        Payload: uint32 LE = remaining blob size.
 *     5. Bulk OUT on EP 0x04. Write the rest in 4095-byte chunks (short
 *        packet delimits each USB transfer).
 *     6. GETSTATUS ×2 — expect SYNC then DNLOAD-IDLE.
 *     7. DNLOAD #3 (0 bytes)               triggers manifest.
 *     8. Poll GETSTATUS every 700ms.
 *        - Slot A: device sits in state=6 (MANIFEST-SYNC); we detect
 *          10s of stability and move on.
 *        - Slot B: device transitions 6 → 4 (DNBUSY) → 7 (MANIFEST).
 *     9. Final commit: vendor ctrl bmReq=0x41 bReq=0x10 wValue=0x0004
 *        triggers re-enumeration as runtime PID 0x0313.
 *
 * Usage:
 *   flash_firmware <firmware_blob.bin>
 *
 *   The input file is the wire-format signed archive. If it contains two
 *   concatenated slots, they are auto-detected and split.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>
#include <libusb-1.0/libusb.h>

#define VID          0x2104
#define PID_FBL      0x0102
#define PID_RUNTIME  0x0313
#define TMO          5000
#define CHUNK_SIZE   4095           /* wire uses 4095 (not 4096) so each
                                     * chunk ends with a short USB packet,
                                     * which delimits transfers on the DFU
                                     * bulk pipe. 4096 aligns to 512*8 and
                                     * produces no short packet, leaving
                                     * the device waiting for end-of-xfer. */
#define DNLOAD_HDR_SIZE 24          /* bytes sent via control in DNLOAD #1 */
#define BULK_EP_OUT  0x04           /* bulk pipe for firmware data */

/* Vendor control codes — packed as uint16 LE into {bmReqType, bReq}. */
#define DFU_GETSTATUS   0x03C1      /* 0xC1, 0x03 — IN,  10 bytes */
#define DFU_DNLOAD      0x0141      /* 0x41, 0x01 — OUT, N  bytes */
#define DFU_CLRSTATUS   0x0441      /* 0x41, 0x04 — OUT, 0  bytes */
#define DFU_ABORT       0x0641      /* 0x41, 0x06 — OUT, 0  bytes */

/* wIndex=0 for GETSTATUS and DNLOAD. wValue=download_type (8). */
#define DFU_WVALUE      0x0008
#define GETSTATUS_WINDEX 0x0000

/* Signed 24-byte DFU header (opaque, captured from a USB trace).
 * The device accepts this against the matching firmware blob. */
static const uint8_t DFU_HEADER_24[24] = {
    0xf3, 0x22, 0x6b, 0x5a, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x47, 0x33, 0xdf, 0x4e, 0x94, 0xbe, 0x12, 0x00,
};

#define STATE_DFUIDLE   2
#define STATE_DNLOAD_SYNC 3
#define STATE_DNBUSY    4
#define STATE_DNLOAD_IDLE 5
#define STATE_MANIFEST_SYNC 6
#define STATE_MANIFEST  7
#define STATE_DFUERROR  10

static const char *state_name(uint8_t s) {
    static const char *n[] = {
        "appIDLE","appDETACH","dfuIDLE","dfuDNLOAD-SYNC","dfuDNBUSY",
        "dfuDNLOAD-IDLE","dfuMANIFEST-SYNC","dfuMANIFEST",
        "dfuMANIFEST-WAIT-RESET","dfuUPLOAD-IDLE","dfuERROR"
    };
    return s < 11 ? n[s] : "?";
}

struct dfu_status {
    uint8_t  bStatus;
    uint32_t bwPollTimeout;   /* ms, 24-bit LE */
    uint8_t  bState;
    uint8_t  iString;
    uint32_t bytes_written;   /* Tobii extension, bytes 6..9 */
};

static int read_file(const char *path, uint8_t **out_buf, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return -1; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc((size_t)sz);
    if (!buf || fread(buf, 1, sz, f) != (size_t)sz) {
        free(buf); fclose(f); return -1;
    }
    fclose(f);
    *out_buf = buf;
    *out_len = (size_t)sz;
    return 0;
}

static void hex_dump(const char *tag, const uint8_t *buf, int len) {
    printf("    %s [%d]:", tag, len);
    for (int i = 0; i < len; i++) printf(" %02x", buf[i]);
    printf("\n");
}

static int dfu_getstatus_v(libusb_device_handle *d, struct dfu_status *st, const char *why) {
    uint8_t buf[10] = {0};
    printf("  -> GETSTATUS (%s) bmReq=0xC1 bReq=0x03 wValue=0 wIndex=%u wLen=10\n",
           why, GETSTATUS_WINDEX);
    int r = libusb_control_transfer(d, 0xC1, 0x03, 0, GETSTATUS_WINDEX, buf, 10, TMO);
    if (r < 0) {
        fprintf(stderr, "     GETSTATUS failed: %d (%s)\n", r, libusb_error_name(r));
        return -1;
    }
    hex_dump("<- raw", buf, r);
    if (r < 10) {
        fprintf(stderr, "     GETSTATUS short: %d bytes\n", r);
        return -1;
    }
    st->bStatus        = buf[0];
    st->bwPollTimeout  = buf[1] | (buf[2] << 8) | (buf[3] << 16);
    st->bState         = buf[4];
    st->iString        = buf[5];
    st->bytes_written  = buf[6] | (buf[7] << 8) | (buf[8] << 16) | (buf[9] << 24);
    printf("     bStatus=%u bwPoll=%ums bState=%u (%s) iStr=%u written=%u (0x%x)\n",
           st->bStatus, st->bwPollTimeout, st->bState, state_name(st->bState),
           st->iString, st->bytes_written, st->bytes_written);
    return 0;
}

#define dfu_getstatus(d, st) dfu_getstatus_v((d), (st), __func__)

static int dfu_getstatus_quiet(libusb_device_handle *d, struct dfu_status *st) {
    uint8_t buf[10] = {0};
    int r = libusb_control_transfer(d, 0xC1, 0x03, 0, GETSTATUS_WINDEX, buf, 10, TMO);
    if (r < 10) return -1;
    st->bStatus        = buf[0];
    st->bwPollTimeout  = buf[1] | (buf[2] << 8) | (buf[3] << 16);
    st->bState         = buf[4];
    st->iString        = buf[5];
    st->bytes_written  = buf[6] | (buf[7] << 8) | (buf[8] << 16) | (buf[9] << 24);
    return 0;
}

static int dfu_ctrl_out(libusb_device_handle *d, uint8_t bReq,
                        uint16_t wValue, uint8_t *data, uint16_t len) {
    printf("  -> CTRL OUT bmReq=0x41 bReq=0x%02x wValue=0x%04x wIndex=0 wLen=%u\n",
           bReq, wValue, len);
    if (data && len) hex_dump("   payload", data, len);
    int r = libusb_control_transfer(d, 0x41, bReq, wValue, 0, data, len, TMO);
    if (r < 0 || r != len) {
        fprintf(stderr, "     CTRL OUT failed: %d (%s) (expected %u)\n",
                r, r < 0 ? libusb_error_name(r) : "short", len);
        return -1;
    }
    printf("     OK (%d bytes sent)\n", r);
    return 0;
}

static int dfu_reset_from_error(libusb_device_handle *d) {
    printf("  [reset] CLRSTATUS + ABORT\n");
    dfu_ctrl_out(d, 0x04, 0, NULL, 0);
    dfu_ctrl_out(d, 0x06, 0, NULL, 0);
    struct dfu_status st;
    if (dfu_getstatus(d, &st) < 0) return -1;
    printf("  [reset] now: state=%u (%s) status=%u\n",
           st.bState, state_name(st.bState), st.bStatus);
    return (st.bState == STATE_DFUIDLE && st.bStatus == 0) ? 0 : -1;
}

static int bulk_send(libusb_device_handle *d, const uint8_t *data, size_t len) {
    printf("  -> BULK OUT ep=0x%02x total=%zu bytes chunk=%d\n",
           BULK_EP_OUT, len, CHUNK_SIZE);
    hex_dump("   first16", data, 16);
    hex_dump("   last16 ", data + len - 16, 16);
    size_t sent = 0;
    int nchunks = 0;
    time_t t0 = time(NULL);
    while (sent < len) {
        int chunk = (int)((len - sent) < CHUNK_SIZE ? (len - sent) : CHUNK_SIZE);
        int xfer = 0;
        int r = libusb_bulk_transfer(d, BULK_EP_OUT, (uint8_t *)(data + sent),
                                     chunk, &xfer, TMO);
        if (r != 0 || xfer != chunk) {
            fprintf(stderr, "\n     bulk write failed at %zu/%zu chunk#%d: %d (%s) xfer=%d\n",
                    sent, len, nchunks, r, libusb_error_name(r), xfer);
            return -1;
        }
        sent += (size_t)xfer;
        nchunks++;
        if ((nchunks % 32) == 0 || sent == len) {
            printf("\r     [bulk] %zu / %zu  (%5.1f%%)  chunks=%d ",
                   sent, len, 100.0 * (double)sent / (double)len, nchunks);
            fflush(stdout);
        }
    }
    printf(" done in %lds (%d chunks)\n", (long)(time(NULL) - t0), nchunks);
    return 0;
}

static int wait_manifest_done(libusb_device_handle *d, uint32_t total) {
    struct dfu_status st;
    (void)total;
    /* Poll until the device leaves MANIFEST-SYNC.
     * Slot A: device sits in state=6 for a while (storing image, not
     *   committing). We detect stability and return OK; the caller's
     *   next flash_slot() will CLRSTATUS+ABORT to reset.
     * Slot B: device transitions 6 → 4 (DNBUSY) → 7 (MANIFEST) as
     *   it writes to flash. */
    int last_state = -1;
    int stable_count = 0;
    for (int i = 0; i < 600; i++) {                 /* up to ~7 min */
        usleep(700000);                             /* 700ms like Windows */
        if (dfu_getstatus_quiet(d, &st) < 0) {
            printf("  [post-flash poll %d] GETSTATUS failed — device dropped\n", i);
            return 0;
        }
        if ((int)st.bState != last_state) {
            printf("  [post-flash poll %d t=%.1fs] state=%u (%s) status=%u\n",
                   i, i * 0.7, st.bState, state_name(st.bState), st.bStatus);
            fflush(stdout);
            last_state = st.bState;
            stable_count = 0;
        } else {
            stable_count++;
        }
        if (st.bState == STATE_MANIFEST || st.bState == STATE_DFUIDLE) {
            printf("  [post-flash] slot committed (state=%u)\n", st.bState);
            return 0;
        }
        if (st.bState == STATE_DFUERROR) {
            printf("  [post-flash] device went to ERROR state\n");
            return -1;
        }
        /* State 6 stuck for 10s+ means slot A — return OK, caller resets. */
        if (st.bState == STATE_MANIFEST_SYNC && stable_count >= 14) {
            printf("  [post-flash] state=6 stable %ds — slot A stored, continuing\n",
                   (int)((stable_count * 0.7) + 0.5));
            return 0;
        }
    }
    printf("  [post-flash] timeout (stuck at state=%u)\n", last_state);
    return -1;
}

static int flash_slot(libusb_device_handle *d,
                      const uint8_t *blob, size_t blob_size, int slot_idx) {
    printf("\n=== slot %d: %zu bytes ===\n", slot_idx, blob_size);

    /* Step 1: initial GETSTATUS, recover if not dfuIDLE/OK */
    struct dfu_status st;
    if (dfu_getstatus(d, &st) < 0) return -1;
    printf("  init: state=%u (%s) status=%u\n",
           st.bState, state_name(st.bState), st.bStatus);
    if (st.bState != STATE_DFUIDLE || st.bStatus != 0) {
        if (dfu_reset_from_error(d) < 0) {
            fprintf(stderr, "  cannot recover to dfuIDLE\n");
            return -1;
        }
    }

    /* Step 2: DNLOAD #1 — signed 24-byte DFU header (replay) */
    printf("  DNLOAD header (%d bytes, signed replay)\n", DNLOAD_HDR_SIZE);
    if (dfu_ctrl_out(d, 0x01, DFU_WVALUE,
                     (uint8_t *)DFU_HEADER_24, DNLOAD_HDR_SIZE) < 0)
        return -1;

    /* Step 3: GETSTATUS — expect dfuDNLOAD-SYNC */
    if (dfu_getstatus(d, &st) < 0) return -1;
    printf("  post-hdr:  state=%u (%s) status=%u\n",
           st.bState, state_name(st.bState), st.bStatus);
    if (st.bState != STATE_DNLOAD_SYNC) {
        fprintf(stderr, "  expected dfuDNLOAD-SYNC after header, got %s\n",
                state_name(st.bState));
        return -1;
    }

    /* Step 4: DNLOAD #2 — 4-byte size announcement = full bulk payload size */
    uint32_t bulk_size = (uint32_t)blob_size;
    uint8_t sz_buf[4] = {
        (uint8_t)(bulk_size),
        (uint8_t)(bulk_size >> 8),
        (uint8_t)(bulk_size >> 16),
        (uint8_t)(bulk_size >> 24),
    };
    printf("  DNLOAD size=%u (0x%08x)\n", bulk_size, bulk_size);
    if (dfu_ctrl_out(d, 0x01, DFU_WVALUE, sz_buf, 4) < 0) return -1;

    /* Step 5: bulk OUT EP 4 — full blob */
    if (bulk_send(d, blob, bulk_size) < 0) return -1;

    /* Step 6: GETSTATUS ×2 — expect SYNC then DNLOAD-IDLE */
    if (dfu_getstatus(d, &st) < 0) return -1;
    printf("  post-bulk: state=%u (%s)\n", st.bState, state_name(st.bState));
    if (dfu_getstatus(d, &st) < 0) return -1;
    printf("  post-bulk: state=%u (%s)\n", st.bState, state_name(st.bState));

    /* Step 7: DNLOAD #3 — zero-length triggers manifest */
    printf("  DNLOAD 0 (manifest trigger)\n");
    if (dfu_ctrl_out(d, 0x01, DFU_WVALUE, NULL, 0) < 0) return -1;

    /* Step 8: poll until MANIFEST/IDLE */
    if (wait_manifest_done(d, bulk_size) < 0) return -1;

    return 0;
}

/* Auto-detect whether the file is one slot or two concatenated slots by
 * looking for a second caar magic at half-length. The caar magic is
 * 0xfe07bc98 LE. */
static int split_slots(const uint8_t *buf, size_t len,
                       size_t *slot_sizes, int max_slots) {
    const uint32_t CAAR_MAGIC = 0x98bc07feu;
    if (len < 4 || *(const uint32_t *)buf != CAAR_MAGIC) {
        fprintf(stderr, "input doesn't start with caar magic\n");
        return -1;
    }
    /* Simple case: single slot */
    if (len % 2) {
        slot_sizes[0] = len;
        return 1;
    }
    size_t half = len / 2;
    if (*(const uint32_t *)(buf + half) == CAAR_MAGIC) {
        if (max_slots < 2) return -1;
        slot_sizes[0] = half;
        slot_sizes[1] = half;
        return 2;
    }
    slot_sizes[0] = len;
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr,
                "usage: %s <firmware_blob.bin>\n"
                "\n"
                "  Expects a signed firmware archive as captured from a\n"
                "  USB firmware update session.\n", argv[0]);
        return 2;
    }

    uint8_t *buf = NULL;
    size_t len = 0;
    if (read_file(argv[1], &buf, &len) != 0) return 1;
    printf("loaded %s: %zu bytes\n", argv[1], len);

    size_t slot_sizes[4] = {0};
    int nslots = split_slots(buf, len, slot_sizes, 4);
    if (nslots <= 0) { free(buf); return 1; }
    printf("detected %d slot(s)\n", nslots);

    libusb_init(NULL);

    /* If device is in runtime mode, kick it into bootloader first.
     * Vendor ctrl bmReq=0x41 bReq=0x10 wValue=0x0003 causes the tracker
     * to re-enumerate from PID 0x0313 to PID 0x0102. */
    libusb_device_handle *d_rt =
        libusb_open_device_with_vid_pid(NULL, VID, PID_RUNTIME);
    if (d_rt) {
        printf("device is in runtime mode (%04x:%04x) — switching to FBL\n",
               VID, PID_RUNTIME);
        if (libusb_kernel_driver_active(d_rt, 0) == 1)
            libusb_detach_kernel_driver(d_rt, 0);
        libusb_claim_interface(d_rt, 0);
        int r = libusb_control_transfer(d_rt, 0x41, 0x10, 0x0003, 0, NULL, 0, TMO);
        /* Device typically replies with NO_DEVICE because it drops off the
         * bus immediately after accepting the command — that's success. */
        printf("  enter-FBL ctrl: %d (%s) — device dropped, expected\n", r,
               r >= 0 ? "OK" : libusb_error_name(r));
        libusb_close(d_rt);  /* no release: device is already gone */
        /* Wait for device to re-enumerate as FBL. */
        printf("  waiting for re-enumeration as %04x:%04x ", VID, PID_FBL);
        fflush(stdout);
        libusb_device_handle *probe = NULL;
        for (int i = 0; i < 30; i++) {
            usleep(500000);
            printf("."); fflush(stdout);
            probe = libusb_open_device_with_vid_pid(NULL, VID, PID_FBL);
            if (probe) { libusb_close(probe); break; }
        }
        printf("\n");
        if (!probe) {
            fprintf(stderr, "  device never appeared as FBL\n");
            libusb_exit(NULL); free(buf); return 1;
        }
        /* Give kernel a moment to settle after enumeration. */
        usleep(500000);
    }

    libusb_device_handle *d =
        libusb_open_device_with_vid_pid(NULL, VID, PID_FBL);
    if (!d) {
        fprintf(stderr, "cannot open device %04x:%04x\n", VID, PID_FBL);
        fprintf(stderr, "  is the tracker plugged in?\n");
        libusb_exit(NULL); free(buf); return 1;
    }
    if (libusb_kernel_driver_active(d, 0) == 1)
        libusb_detach_kernel_driver(d, 0);
    /* USB reset to clear any residual DFU state (e.g. stuck in dfuMANIFEST
     * from a previous aborted flash). Without this, the device can linger
     * in state 6 across sessions and never re-accept a DNLOAD sequence. */
    printf("  libusb_reset_device() ... ");
    int rr = libusb_reset_device(d);
    printf("%s\n", libusb_error_name(rr));
    int r = libusb_claim_interface(d, 0);
    if (r != 0) {
        fprintf(stderr, "claim iface failed: %s\n", libusb_error_name(r));
        libusb_close(d); libusb_exit(NULL); free(buf); return 1;
    }

    const uint8_t *cur = buf;
    int rc = 0;
    for (int i = 0; i < nslots; i++) {
        if (flash_slot(d, cur, slot_sizes[i], i) < 0) {
            fprintf(stderr, "slot %d failed, aborting\n", i);
            rc = 1;
            break;
        }
        cur += slot_sizes[i];
    }

    if (rc == 0) {
        /* Post-flash commit: vendor ctrl bmReq=0x41 bReq=0x10 wValue=0x0004
         * triggers the device to exit bootloader and re-enumerate as runtime
         * (PID 0x0313). Without this the device sits in MANIFEST forever. */
        printf("\nsending post-flash commit (0x10 wValue=0x0004)...\n");
        int tc = libusb_control_transfer(d, 0x41, 0x10, 0x0004, 0, NULL, 0, TMO);
        printf("  commit ctrl: %d (%s)\n", tc,
               tc >= 0 ? "OK" : libusb_error_name(tc));
        printf("\n*** flash complete — device should re-enumerate as %04x:0313 ***\n",
               VID);
    }

    libusb_release_interface(d, 0);
    libusb_close(d);
    libusb_exit(NULL);
    free(buf);
    return rc;
}
