/*
 * extract_firmware: Pull embedded firmware containers from a PE executable
 * that ships device firmware in its .data section.
 *
 * The container format (observed from USB firmware update captures):
 *
 *   +0x00  magic 0x00494143 LE ("CAI\0")
 *   +0x04  uint32             checksum/hash
 *   +0x08  uint32             unknown
 *   +0x0c  uint32             unknown
 *   +0x10  uint32             size-like field
 *   +0x14  uint32             unknown
 *   +0x18  uint16             padding / alignment
 *   +0x1a  char[]             version string (e.g. "component:hexid\0")
 *
 * Each container holds nested archive entries (magic 0xfe07bc98) carrying
 * the actual firmware files. We identify and extract each top-level
 * container by scanning for validated magic + version string patterns.
 *
 * Usage:
 *   extract_firmware <service.exe> <output_dir>
 *
 * Output files:
 *   <output_dir>/cai_<index>_<version>.bin    each extracted container
 *   <output_dir>/manifest.txt                 summary
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ctype.h>
#include <sys/stat.h>
#include <errno.h>

#define CAI_MAGIC     0x00494143u           /* "CAI\0" LE */
#define CAAR_MAGIC    0x98bc07feu           /* inner archive entry magic */
#define CAAR_HDR_SIZE 36                    /* magic+res+sz1+sz2+name(20) */
#define CAI_VERSION_OFFSET   0x1a
#define CAI_VERSION_MAXLEN   32             /* prefix we probe */
#define MIN_CAI_SIZE  0x100                 /* anything smaller is noise */

/* PE parsing */
#define DOS_MAGIC     0x5a4du               /* "MZ" */
#define PE_MAGIC      0x00004550u           /* "PE\0\0" */

struct pe_section {
    char     name[9];
    uint32_t virt_size;
    uint32_t virt_addr;
    uint32_t raw_size;
    uint32_t raw_offset;
};

static int read_file(const char *path, uint8_t **out_buf, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return -1; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    if (sz < 0) { fclose(f); return -1; }
    fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc((size_t)sz);
    if (!buf) { fclose(f); return -1; }
    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        free(buf); fclose(f); return -1;
    }
    fclose(f);
    *out_buf = buf;
    *out_len = (size_t)sz;
    return 0;
}

static int find_data_section(const uint8_t *buf, size_t len,
                             struct pe_section *out) {
    if (len < 0x40) return -1;
    uint16_t dos_magic = *(const uint16_t *)buf;
    if (dos_magic != DOS_MAGIC) {
        fprintf(stderr, "not a PE (no MZ)\n");
        return -1;
    }
    uint32_t e_lfanew = *(const uint32_t *)(buf + 0x3c);
    if (e_lfanew + 0x18 > len) return -1;
    uint32_t pe_sig = *(const uint32_t *)(buf + e_lfanew);
    if (pe_sig != PE_MAGIC) {
        fprintf(stderr, "not a PE (no PE\\0\\0)\n");
        return -1;
    }
    /* COFF header at e_lfanew+4: Machine(2) NumSections(2) ... SizeOfOpt(2) */
    uint16_t num_sec = *(const uint16_t *)(buf + e_lfanew + 4 + 2);
    uint16_t size_opt = *(const uint16_t *)(buf + e_lfanew + 4 + 16);
    size_t sec_off = e_lfanew + 4 + 20 + size_opt;
    if (sec_off + num_sec * 40UL > len) return -1;

    for (uint16_t i = 0; i < num_sec; i++) {
        const uint8_t *s = buf + sec_off + i * 40UL;
        char name[9] = {0};
        memcpy(name, s, 8);
        if (strcmp(name, ".data") == 0) {
            memcpy(out->name, name, 9);
            out->virt_size   = *(const uint32_t *)(s + 8);
            out->virt_addr   = *(const uint32_t *)(s + 12);
            out->raw_size    = *(const uint32_t *)(s + 16);
            out->raw_offset  = *(const uint32_t *)(s + 20);
            return 0;
        }
    }
    return -1;
}

/* Validate a CAI magic hit by checking version string at +0x14.
 * We expect ASCII ([0x20..0x7e] bytes) followed by a NUL, and the
 * whole thing at most CAI_VERSION_MAXLEN long. We don't require a
 * specific prefix — different firmware components may
 * use different tags — but we do require a colon-separated form
 * like "word:hex_id". */
static int validate_cai(const uint8_t *p, size_t remain,
                        char *ver_out, size_t ver_cap) {
    if (remain < CAI_VERSION_OFFSET + CAI_VERSION_MAXLEN) return 0;
    const uint8_t *v = p + CAI_VERSION_OFFSET;
    int colon_seen = 0;
    size_t i;
    for (i = 0; i < CAI_VERSION_MAXLEN; i++) {
        uint8_t c = v[i];
        if (c == 0) break;                  /* terminator */
        if (c < 0x20 || c > 0x7e) return 0; /* not printable ASCII */
        if (c == ':') colon_seen = 1;
    }
    if (i == 0 || i == CAI_VERSION_MAXLEN) return 0; /* empty or unterm */
    if (!colon_seen) return 0;              /* no "name:id" shape */
    /* Require at least one hex-ish char after colon */
    int saw_post_colon = 0;
    int past_colon = 0;
    for (size_t j = 0; j < i; j++) {
        if (past_colon) { saw_post_colon = 1; break; }
        if (v[j] == ':') past_colon = 1;
    }
    if (!saw_post_colon) return 0;
    size_t copy = i < ver_cap - 1 ? i : ver_cap - 1;
    memcpy(ver_out, v, copy);
    ver_out[copy] = 0;
    return 1;
}

/* Once we know a container's start, trim trailing zero padding so the
 * next container or unrelated .data content isn't swept in if we're at
 * the tail of .data. We leave the .cmg/caar trailer intact; we only
 * shave pure-zero tails. */
static size_t trim_trailing_zeros(const uint8_t *p, size_t max_len) {
    size_t n = max_len;
    while (n > MIN_CAI_SIZE && p[n - 1] == 0) n--;
    return n;
}

static int mkdir_p(const char *path) {
    struct stat st;
    if (stat(path, &st) == 0) {
        return S_ISDIR(st.st_mode) ? 0 : -1;
    }
    if (mkdir(path, 0755) != 0 && errno != EEXIST) {
        perror(path); return -1;
    }
    return 0;
}

/* Walk inner caar entries and print them. A caar entry is:
 *   magic(4) reserved(4) size1(4) size2(4) name[20] payload[size2]
 * We do not trust size1/size2 blindly for navigation (they can encode
 * something slightly different in the embedded copy than on the wire),
 * so we simply scan for the magic and print hits whose name field
 * begins with a printable ASCII char. */
static void dump_caar_entries(FILE *out, const uint8_t *blob, size_t len) {
    for (size_t i = 0; i + CAAR_HDR_SIZE <= len; i += 4) {
        uint32_t m = *(const uint32_t *)(blob + i);
        if (m != CAAR_MAGIC) continue;
        uint32_t sz1 = *(const uint32_t *)(blob + i + 8);
        uint32_t sz2 = *(const uint32_t *)(blob + i + 12);
        const uint8_t *name = blob + i + 16;
        if (!isalpha(name[0])) continue;  /* skip coincidental magic hits */
        char nm[21] = {0};
        for (int k = 0; k < 20 && name[k]; k++) {
            nm[k] = (name[k] >= 0x20 && name[k] <= 0x7e) ? name[k] : '?';
        }
        fprintf(out, "        off=0x%06zx sz1=%u sz2=%u name=%s\n",
                i, sz1, sz2, nm);
    }
}

/* Make a filesystem-safe slug from a version string. */
static void slug(const char *in, char *out, size_t cap) {
    size_t j = 0;
    for (size_t i = 0; in[i] && j + 1 < cap; i++) {
        char c = in[i];
        if (isalnum((unsigned char)c) || c == '_' || c == '-') out[j++] = c;
        else if (c == ':' || c == '.') out[j++] = '_';
    }
    out[j] = 0;
    if (j == 0) { strncpy(out, "unknown", cap); out[cap - 1] = 0; }
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <service.exe> <output_dir>\n", argv[0]);
        return 2;
    }
    const char *exe_path = argv[1];
    const char *out_dir  = argv[2];

    uint8_t *buf = NULL;
    size_t len = 0;
    if (read_file(exe_path, &buf, &len) != 0) return 1;
    printf("loaded %s: %zu bytes\n", exe_path, len);

    struct pe_section data = {0};
    if (find_data_section(buf, len, &data) != 0) {
        fprintf(stderr, "couldn't find .data section\n");
        free(buf); return 1;
    }
    printf(".data: raw_off=0x%x raw_size=0x%x virt_addr=0x%x\n",
           data.raw_offset, data.raw_size, data.virt_addr);

    if ((size_t)data.raw_offset + data.raw_size > len) {
        fprintf(stderr, ".data section overruns file\n");
        free(buf); return 1;
    }

    if (mkdir_p(out_dir) != 0) { free(buf); return 1; }

    /* First pass: find all validated CAI hits. */
    struct hit {
        uint32_t off;               /* file offset of CAI\0 magic */
        char ver[CAI_VERSION_MAXLEN + 1];
    };
    struct hit hits[32];
    int nhits = 0;

    const uint8_t *dp = buf + data.raw_offset;
    for (uint32_t i = 0; i + 4 <= data.raw_size; i += 4) {  /* 4-byte aligned */
        uint32_t magic = *(const uint32_t *)(dp + i);
        if (magic != CAI_MAGIC) continue;
        char ver[CAI_VERSION_MAXLEN + 1] = {0};
        if (!validate_cai(dp + i, data.raw_size - i, ver, sizeof ver))
            continue;
        if (nhits >= (int)(sizeof hits / sizeof hits[0])) break;
        hits[nhits].off = data.raw_offset + i;
        memcpy(hits[nhits].ver, ver, sizeof hits[nhits].ver - 1);
        hits[nhits].ver[sizeof hits[nhits].ver - 1] = 0;
        nhits++;
    }

    if (nhits == 0) {
        fprintf(stderr, "no CAI containers found\n");
        free(buf); return 1;
    }
    printf("found %d CAI container(s)\n", nhits);

    /* Write manifest and extract each container. */
    char manifest_path[1024];
    snprintf(manifest_path, sizeof manifest_path, "%s/manifest.txt", out_dir);
    FILE *mf = fopen(manifest_path, "w");
    if (!mf) { perror(manifest_path); free(buf); return 1; }
    fprintf(mf, "# Extracted from: %s\n", exe_path);
    fprintf(mf, "# .data raw_offset=0x%x raw_size=0x%x\n",
            data.raw_offset, data.raw_size);
    fprintf(mf, "# idx  file_offset  size        version           filename\n");

    uint32_t data_end = data.raw_offset + data.raw_size;
    for (int k = 0; k < nhits; k++) {
        uint32_t start = hits[k].off;
        uint32_t next = (k + 1 < nhits) ? hits[k + 1].off : data_end;
        size_t raw_span = next - start;
        size_t span = trim_trailing_zeros(buf + start, raw_span);

        char verslug[64];
        slug(hits[k].ver, verslug, sizeof verslug);
        char outpath[1024];
        snprintf(outpath, sizeof outpath, "%s/cai_%d_%s.bin",
                 out_dir, k, verslug);
        FILE *of = fopen(outpath, "wb");
        if (!of) { perror(outpath); continue; }
        if (fwrite(buf + start, 1, span, of) != span) {
            perror(outpath);
            fclose(of); continue;
        }
        fclose(of);
        printf("  [%d] off=0x%x size=%zu version=%s -> %s\n",
               k, start, span, hits[k].ver, outpath);
        fprintf(mf, "  %-3d  0x%08x   %-10zu  %-16s  cai_%d_%s.bin\n",
                k, start, span, hits[k].ver, k, verslug);
        fprintf(mf, "        inner caar entries:\n");
        dump_caar_entries(mf, buf + start, span);
    }
    fclose(mf);
    free(buf);
    return 0;
}
