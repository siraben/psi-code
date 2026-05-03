/* Generate DEFLATE-compressed embedded-data tables.
 *
 * Usage:
 *   embed [--table=NAME] [--key=NAME] [--raw-keys] <file1> [<file2> ...] > out.c
 *
 * Default behavior (Lua modules): strip the leading "lua/" segment
 * but otherwise preserve the source path verbatim. Embedded keys
 * therefore look like real paths and match what scripts/embed.c sees
 * on disk:
 *   lua/boot.lua             -> "boot.lua"
 *   lua/psi/prelude.lua      -> "psi/prelude.lua"
 *   lua/psi/tools/read.lua   -> "psi/tools/read.lua"
 *
 * The Lua require() searcher in src/lua/vm.c translates dotted
 * module names ("psi.tools.read") to this slash form on lookup.
 *
 * --raw-keys uses the input path verbatim. --key=NAME sets one key
 * explicitly and is only valid with one input file. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static void derive_modname(const char *path, char *out, size_t out_size) {
    const char *start = path;
    size_t prefix_len = 4;
    size_t len;

    if (strncmp(start, "lua/", prefix_len) == 0) {
        start += prefix_len;
    }
    len = strlen(start);
    if (len >= out_size)
        len = out_size - 1;
    memcpy(out, start, len);
    out[len] = '\0';
}

static void sanitize_symbol(const char *in, char *out, size_t out_size) {
    size_t i;
    char c;
    int ok;

    for (i = 0; i + 1 < out_size && in[i]; i++) {
        c = in[i];
        ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
        out[i] = ok ? c : '_';
    }
    out[i] = '\0';
}

static char *embed_strdup(const char *text) {
    size_t len;
    char *copy;

    len = strlen(text);
    copy = malloc(len + 1u);
    if (copy == NULL)
        return NULL;
    memcpy(copy, text, len + 1u);
    return copy;
}

static unsigned char *slurp(const char *path, size_t *len_out) {
    FILE *f;
    long size;
    unsigned char *buf;
    size_t got;

    f = fopen(path, "rb");
    if (!f) {
        perror(path);
        return NULL;
    }
    if (fseek(f, 0, SEEK_END) != 0)
        goto out_close;
    size = ftell(f);
    if (size < 0)
        goto out_close;
    if (fseek(f, 0, SEEK_SET) != 0)
        goto out_close;
    buf = malloc((size_t)size + 1u);
    if (!buf)
        goto out_close;
    got = fread(buf, 1u, (size_t)size, f);
    fclose(f);
    if (got != (size_t)size)
        goto out_free;
    buf[(size_t)size] = 0;
    *len_out = (size_t)size;
    return buf;

out_free:
    free(buf);
    return NULL;
out_close:
    fclose(f);
    return NULL;
}

static long deflate_bytes(const unsigned char *in, size_t in_len, unsigned char **out_buf) {
    unsigned char *out;
    uLongf bound;
    int rc;

    bound = compressBound((uLong)in_len);
    out = malloc(bound);
    if (!out)
        return -1;
    rc = compress2(out, &bound, in, (uLong)in_len, 9);
    if (rc != Z_OK) {
        free(out);
        fprintf(stderr, "deflate: %d\n", rc);
        return -1;
    }
    *out_buf = out;
    return (long)bound;
}

static void emit_bytes(const unsigned char *bytes, size_t n) {
    size_t i;
    for (i = 0; i < n; i++) {
        if (i > 0) {
            fputc(',', stdout);
            if (i % 16 == 0)
                fputs("\n    ", stdout);
        } else {
            fputs("\n    ", stdout);
        }
        printf("0x%02x", bytes[i]);
    }
}

int main(int argc, char **argv) {
    const char *table_name = "psi_embedded_lua_table";
    const char *fixed_key = NULL;
    int raw_keys = 0;
    int no_compress = 0;
    int i;
    int first_file;
    int status;
    size_t count;
    size_t k;
    size_t *raw_lens;
    size_t *zlen;
    char **syms;
    char **keys;
    const char *arg;
    char buf[512];
    char symbuf[256];
    size_t raw_len;
    unsigned char *raw;
    unsigned char *compressed;
    long clen;

    first_file = 1;
    while (first_file < argc) {
        arg = argv[first_file];
        if (strncmp(arg, "--table=", 8) == 0) {
            table_name = arg + 8;
            first_file++;
        } else if (strncmp(arg, "--key=", 6) == 0) {
            fixed_key = arg + 6;
            first_file++;
        } else if (strcmp(arg, "--raw-keys") == 0) {
            raw_keys = 1;
            first_file++;
        } else if (strcmp(arg, "--no-compress") == 0) {
            /* Emit entries with len == raw_len holding the original
             * bytes verbatim. The runtime inflater detects this and
             * skips zlib entirely — saves ~9 KiB inflate state, the
             * intermediate decompress buffer, and the zlib component
             * itself. Trades flash space for a much simpler load
             * path; the embedded ESP build prefers it. */
            no_compress = 1;
            first_file++;
        } else if (arg[0] == '-' && arg[1] == '-') {
            fprintf(stderr, "unknown option: %s\n", arg);
            return 1;
        } else {
            break;
        }
    }
    if (first_file >= argc) {
        fprintf(stderr,
            "usage: %s [--table=NAME] [--key=NAME] [--raw-keys] <file1> [<file2> ...]\n", argv[0]);
        return 1;
    }
    if (fixed_key != NULL && argc - first_file != 1) {
        fprintf(stderr, "embed: --key requires exactly one input file\n");
        return 1;
    }

    printf("/* Auto-generated by scripts/embed.c; do not edit. */\n");
    printf("#include <stddef.h>\n");
    printf("#include \"psi/embedded_data.h\"\n\n");

    status = 1;
    raw_lens = NULL;
    zlen = NULL;
    syms = NULL;
    keys = NULL;
    count = (size_t)(argc - first_file);
    raw_lens = calloc(count, sizeof(*raw_lens));
    zlen = calloc(count, sizeof(*zlen));
    syms = calloc(count, sizeof(*syms));
    keys = calloc(count, sizeof(*keys));
    if (!raw_lens || !zlen || !syms || !keys) {
        fprintf(stderr, "embed: out of memory\n");
        goto out;
    }

    for (i = first_file; i < argc; i++) {
        k = (size_t)(i - first_file);
        if (fixed_key != NULL) {
            snprintf(buf, sizeof(buf), "%s", fixed_key);
        } else if (raw_keys) {
            snprintf(buf, sizeof(buf), "%s", argv[i]);
        } else {
            derive_modname(argv[i], buf, sizeof(buf));
        }
        sanitize_symbol(buf, symbuf, sizeof(symbuf));
        keys[k] = embed_strdup(buf);
        syms[k] = embed_strdup(symbuf);
        if (!keys[k] || !syms[k]) {
            fprintf(stderr, "embed: out of memory\n");
            goto out;
        }

        raw_len = 0u;
        raw = slurp(argv[i], &raw_len);
        if (!raw)
            goto out;

        if (no_compress) {
            /* Sentinel: equal len/raw_len signals "raw payload" to
             * the runtime, which then skips zlib and memcpys. */
            raw_lens[k] = raw_len;
            zlen[k] = raw_len;
            printf("static const unsigned char emb_%s_src[] = {", syms[k]);
            emit_bytes(raw, raw_len);
            printf("\n};\n\n");
            free(raw);
        } else {
            compressed = NULL;
            clen = deflate_bytes(raw, raw_len, &compressed);
            free(raw);
            if (clen < 0)
                goto out;

            raw_lens[k] = raw_len;
            zlen[k] = (size_t)clen;

            printf("static const unsigned char emb_%s_src[] = {", syms[k]);
            emit_bytes(compressed, (size_t)clen);
            printf("\n};\n\n");
            free(compressed);
        }
    }

    printf("const struct psi_embedded_data %s[] = {\n", table_name);
    for (i = 0; i < (int)count; i++) {
        printf("    { \"%s\", emb_%s_src, %zuu, %zuu },\n", keys[i], syms[i], zlen[i], raw_lens[i]);
    }
    printf("    { NULL, NULL, 0u, 0u }\n");
    printf("};\n");
    status = 0;

out:
    if (keys != NULL) {
        for (k = 0u; k < count; k++)
            free(keys[k]);
    }
    if (syms != NULL) {
        for (k = 0u; k < count; k++)
            free(syms[k]);
    }
    free(keys);
    free(syms);
    free(raw_lens);
    free(zlen);
    return status;
}
