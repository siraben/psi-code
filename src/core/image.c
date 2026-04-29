#include "psi/image.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef PSI_ENABLE_SDL_CLIPBOARD
#define PSI_ENABLE_SDL_CLIPBOARD 0
#endif

#if PSI_ENABLE_SDL_CLIPBOARD
#include <SDL3/SDL.h>
#endif

#define PSI_IMAGE_MAX_CLIPBOARD_BYTES (50u * 1024u * 1024u)
#define PSI_KITTY_CHUNK_SIZE 4096u

static void psi_image_set_error(char *error, size_t error_size, const char *message) {
    size_t len;

    if (error == NULL || error_size == 0u) {
        return;
    }
    if (message == NULL) {
        message = "image error";
    }
    len = strlen(message);
    if (len >= error_size) {
        len = error_size - 1u;
    }
    memcpy(error, message, len);
    error[len] = '\0';
}

void psi_image_data_init(struct psi_image_data *image) {
    if (image == NULL) {
        return;
    }
    image->bytes = NULL;
    image->size = 0u;
    image->mime_type[0] = '\0';
    image->width = 0u;
    image->height = 0u;
    image->complete = 0u;
    image->clipboard_chunks = 0u;
    image->clipboard_base64_len = 0u;
}

void psi_image_data_free(struct psi_image_data *image) {
    if (image == NULL) {
        return;
    }
    free(image->bytes);
    psi_image_data_init(image);
}

static unsigned int psi_be16(const unsigned char *p) {
    return ((unsigned int)p[0] << 8) | (unsigned int)p[1];
}

static unsigned int psi_be32(const unsigned char *p) {
    return ((unsigned int)p[0] << 24) |
           ((unsigned int)p[1] << 16) |
           ((unsigned int)p[2] << 8) |
           (unsigned int)p[3];
}

static unsigned int psi_le16(const unsigned char *p) {
    return (unsigned int)p[0] | ((unsigned int)p[1] << 8);
}

static unsigned int psi_le24(const unsigned char *p) {
    return (unsigned int)p[0] | ((unsigned int)p[1] << 8) | ((unsigned int)p[2] << 16);
}

static unsigned int psi_le32(const unsigned char *p) {
    return (unsigned int)p[0] |
           ((unsigned int)p[1] << 8) |
           ((unsigned int)p[2] << 16) |
           ((unsigned int)p[3] << 24);
}

static int psi_copy_mime(char *dest, size_t dest_size, const char *mime) {
    size_t len;

    if (dest == NULL || dest_size == 0u || mime == NULL || mime[0] == '\0') {
        return 0;
    }
    len = strlen(mime);
    if (len >= dest_size) {
        len = dest_size - 1u;
    }
    memcpy(dest, mime, len);
    dest[len] = '\0';
    return 1;
}

static int psi_probe_png(const unsigned char *bytes, size_t size, unsigned int *width, unsigned int *height) {
    static const unsigned char sig[8] = { 0x89u, 'P', 'N', 'G', 0x0du, 0x0au, 0x1au, 0x0au };

    if (
        size < 24u ||
        memcmp(bytes, sig, sizeof(sig)) != 0 ||
        psi_be32(bytes + 8u) != 13u ||
        memcmp(bytes + 12u, "IHDR", 4u) != 0
    ) {
        return 0;
    }
    *width = psi_be32(bytes + 16u);
    *height = psi_be32(bytes + 20u);
    return *width > 0u && *height > 0u;
}

static int psi_png_is_complete(const unsigned char *bytes, size_t size) {
    static const unsigned char iend[12] = {
        0x00u, 0x00u, 0x00u, 0x00u, 'I', 'E', 'N', 'D', 0xaeu, 0x42u, 0x60u, 0x82u
    };
    if (bytes == NULL || size < sizeof(iend)) {
        return 0;
    }
    return memcmp(bytes + size - sizeof(iend), iend, sizeof(iend)) == 0;
}

static int psi_probe_gif(const unsigned char *bytes, size_t size, unsigned int *width, unsigned int *height) {
    if (size < 10u) {
        return 0;
    }
    if (memcmp(bytes, "GIF87a", 6u) != 0 && memcmp(bytes, "GIF89a", 6u) != 0) {
        return 0;
    }
    *width = psi_le16(bytes + 6u);
    *height = psi_le16(bytes + 8u);
    return *width > 0u && *height > 0u;
}

static int psi_probe_jpeg(const unsigned char *bytes, size_t size, unsigned int *width, unsigned int *height) {
    size_t offset;

    if (size < 4u || bytes[0] != 0xffu || bytes[1] != 0xd8u) {
        return 0;
    }
    offset = 2u;
    while (offset + 9u < size) {
        unsigned char marker;
        unsigned int length;

        if (bytes[offset] != 0xffu) {
            offset++;
            continue;
        }
        marker = bytes[offset + 1u];
        if (marker >= 0xc0u && marker <= 0xc2u) {
            *height = psi_be16(bytes + offset + 5u);
            *width = psi_be16(bytes + offset + 7u);
            return *width > 0u && *height > 0u;
        }
        if (offset + 3u >= size) {
            return 0;
        }
        length = psi_be16(bytes + offset + 2u);
        if (length < 2u) {
            return 0;
        }
        offset += 2u + (size_t)length;
    }
    return 0;
}

static int psi_probe_webp(const unsigned char *bytes, size_t size, unsigned int *width, unsigned int *height) {
    const unsigned char *chunk;
    unsigned int bits;

    if (size < 30u || memcmp(bytes, "RIFF", 4u) != 0 || memcmp(bytes + 8u, "WEBP", 4u) != 0) {
        return 0;
    }
    chunk = bytes + 12u;
    if (memcmp(chunk, "VP8 ", 4u) == 0 && size >= 30u) {
        *width = psi_le16(bytes + 26u) & 0x3fffu;
        *height = psi_le16(bytes + 28u) & 0x3fffu;
        return *width > 0u && *height > 0u;
    }
    if (memcmp(chunk, "VP8L", 4u) == 0 && size >= 25u) {
        bits = psi_le32(bytes + 21u);
        *width = (bits & 0x3fffu) + 1u;
        *height = ((bits >> 14) & 0x3fffu) + 1u;
        return 1;
    }
    if (memcmp(chunk, "VP8X", 4u) == 0 && size >= 30u) {
        *width = psi_le24(bytes + 24u) + 1u;
        *height = psi_le24(bytes + 27u) + 1u;
        return 1;
    }
    return 0;
}

int psi_image_probe(
    const unsigned char *bytes,
    size_t size,
    const char *mime_hint,
    char *mime_type,
    size_t mime_type_size,
    unsigned int *width,
    unsigned int *height
) {
    unsigned int w;
    unsigned int h;

    if (width != NULL) {
        *width = 0u;
    }
    if (height != NULL) {
        *height = 0u;
    }
    if (mime_type != NULL && mime_type_size > 0u) {
        mime_type[0] = '\0';
    }
    if (bytes == NULL || size == 0u) {
        return 0;
    }

    w = 0u;
    h = 0u;
    if (psi_probe_png(bytes, size, &w, &h)) {
        psi_copy_mime(mime_type, mime_type_size, "image/png");
    } else if (psi_probe_jpeg(bytes, size, &w, &h)) {
        psi_copy_mime(mime_type, mime_type_size, "image/jpeg");
    } else if (psi_probe_gif(bytes, size, &w, &h)) {
        psi_copy_mime(mime_type, mime_type_size, "image/gif");
    } else if (psi_probe_webp(bytes, size, &w, &h)) {
        psi_copy_mime(mime_type, mime_type_size, "image/webp");
    } else if (mime_hint != NULL && mime_hint[0] != '\0') {
        psi_copy_mime(mime_type, mime_type_size, mime_hint);
    } else {
        return 0;
    }

    if (width != NULL) {
        *width = w;
    }
    if (height != NULL) {
        *height = h;
    }
    return 1;
}

int psi_image_is_complete(const unsigned char *bytes, size_t size, const char *mime_type) {
    if (mime_type != NULL && strcmp(mime_type, "image/png") == 0) {
        return psi_png_is_complete(bytes, size);
    }
    return bytes != NULL && size > 0u;
}

char *psi_image_base64_encode(const unsigned char *bytes, size_t size, size_t *out_len) {
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t encoded_len;
    size_t i;
    size_t o;
    char *out;

    if (out_len != NULL) {
        *out_len = 0u;
    }
    if (bytes == NULL && size != 0u) {
        return NULL;
    }
    if (size > (((size_t)-1) / 4u) * 3u) {
        return NULL;
    }
    encoded_len = ((size + 2u) / 3u) * 4u;
    out = (char *)malloc(encoded_len + 1u);
    if (out == NULL) {
        return NULL;
    }
    i = 0u;
    o = 0u;
    while (i < size) {
        unsigned int a;
        unsigned int b;
        unsigned int c;
        unsigned int triple;
        size_t remaining;

        remaining = size - i;
        a = bytes[i++];
        b = remaining > 1u ? bytes[i++] : 0u;
        c = remaining > 2u ? bytes[i++] : 0u;
        triple = (a << 16) | (b << 8) | c;
        out[o++] = alphabet[(triple >> 18) & 0x3fu];
        out[o++] = alphabet[(triple >> 12) & 0x3fu];
        out[o++] = remaining > 1u ? alphabet[(triple >> 6) & 0x3fu] : '=';
        out[o++] = remaining > 2u ? alphabet[triple & 0x3fu] : '=';
    }
    out[o] = '\0';
    if (out_len != NULL) {
        *out_len = o;
    }
    return out;
}

static int psi_base64_value(unsigned char ch) {
    if (ch >= (unsigned char)'A' && ch <= (unsigned char)'Z') {
        return (int)(ch - (unsigned char)'A');
    }
    if (ch >= (unsigned char)'a' && ch <= (unsigned char)'z') {
        return (int)(ch - (unsigned char)'a') + 26;
    }
    if (ch >= (unsigned char)'0' && ch <= (unsigned char)'9') {
        return (int)(ch - (unsigned char)'0') + 52;
    }
    if (ch == (unsigned char)'+') {
        return 62;
    }
    if (ch == (unsigned char)'/') {
        return 63;
    }
    return -1;
}

static int psi_base64_is_space(unsigned char ch) {
    return ch == (unsigned char)' ' || ch == (unsigned char)'\t' ||
           ch == (unsigned char)'\r' || ch == (unsigned char)'\n';
}

int psi_image_base64_decode_alloc(
    const char *base64,
    size_t base64_len,
    unsigned char **out_bytes,
    size_t *out_len,
    char *error,
    size_t error_size
) {
    size_t capacity;
    size_t i;
    size_t decoded_len;
    unsigned int value;
    int value_bits;

    if (out_bytes == NULL || out_len == NULL) {
        psi_image_set_error(error, error_size, "missing image output");
        return 0;
    }
    *out_bytes = NULL;
    *out_len = 0u;
    if (base64 == NULL || base64_len == 0u) {
        psi_image_set_error(error, error_size, "missing base64 image data");
        return 0;
    }

    capacity = (base64_len / 4u) * 3u + 4u;
    if (capacity > PSI_IMAGE_MAX_CLIPBOARD_BYTES) {
        psi_image_set_error(error, error_size, "image data is too large");
        return 0;
    }
    *out_bytes = (unsigned char *)malloc(capacity);
    if (*out_bytes == NULL) {
        psi_image_set_error(error, error_size, "out of memory");
        return 0;
    }

    value = 0u;
    value_bits = -8;
    decoded_len = 0u;
    for (i = 0u; i < base64_len; i++) {
        unsigned char ch = (unsigned char)base64[i];
        int digit;

        if (psi_base64_is_space(ch)) {
            continue;
        }
        if (ch == (unsigned char)'=') {
            break;
        }
        digit = psi_base64_value(ch);
        if (digit < 0) {
            free(*out_bytes);
            *out_bytes = NULL;
            psi_image_set_error(error, error_size, "invalid base64 image data");
            return 0;
        }
        value = (value << 6) | (unsigned int)digit;
        value_bits += 6;
        if (value_bits >= 0) {
            if (decoded_len >= capacity) {
                free(*out_bytes);
                *out_bytes = NULL;
                psi_image_set_error(error, error_size, "image data is too large");
                return 0;
            }
            (*out_bytes)[decoded_len++] = (unsigned char)((value >> value_bits) & 0xffu);
            value_bits -= 8;
        }
    }

    *out_len = decoded_len;
    return 1;
}

int psi_image_from_base64(
    const char *base64,
    size_t base64_len,
    const char *mime_hint,
    struct psi_image_data *image,
    char *error,
    size_t error_size
) {
    if (image == NULL) {
        psi_image_set_error(error, error_size, "missing image output");
        return 0;
    }
    psi_image_data_init(image);
    if (!psi_image_base64_decode_alloc(
            base64,
            base64_len,
            &image->bytes,
            &image->size,
            error,
            error_size
        )) {
        return 0;
    }

    psi_image_probe(
        image->bytes,
        image->size,
        mime_hint,
        image->mime_type,
        sizeof(image->mime_type),
        &image->width,
        &image->height
    );
    if (image->mime_type[0] == '\0' || strcmp(image->mime_type, "application/octet-stream") == 0) {
        psi_image_data_free(image);
        psi_image_set_error(error, error_size, "unsupported image data");
        return 0;
    }
    image->complete = (unsigned int)psi_image_is_complete(
        image->bytes,
        image->size,
        image->mime_type
    );
    return 1;
}

struct psi_image_buffer {
    char *data;
    size_t len;
    size_t cap;
};

static int psi_buf_reserve(struct psi_image_buffer *buf, size_t extra) {
    size_t need;
    size_t cap;
    char *next;

    if (buf == NULL) {
        return 0;
    }
    if (extra > ((size_t)-1) - buf->len - 1u) {
        return 0;
    }
    need = buf->len + extra + 1u;
    if (need <= buf->cap) {
        return 1;
    }
    cap = buf->cap == 0u ? 256u : buf->cap;
    while (cap < need) {
        if (cap > ((size_t)-1) / 2u) {
            cap = need;
            break;
        }
        cap *= 2u;
    }
    next = (char *)realloc(buf->data, cap);
    if (next == NULL) {
        return 0;
    }
    buf->data = next;
    buf->cap = cap;
    return 1;
}

static int psi_buf_append(struct psi_image_buffer *buf, const char *text, size_t len) {
    if (!psi_buf_reserve(buf, len)) {
        return 0;
    }
    if (len > 0u) {
        memcpy(buf->data + buf->len, text, len);
    }
    buf->len += len;
    buf->data[buf->len] = '\0';
    return 1;
}

static int psi_buf_append_cstr(struct psi_image_buffer *buf, const char *text) {
    return psi_buf_append(buf, text, strlen(text));
}

static int psi_buf_append_escaped_for_tmux(struct psi_image_buffer *buf, const char *text, size_t len) {
    size_t i;

    for (i = 0u; i < len; i++) {
        if ((unsigned char)text[i] == 27u) {
            if (!psi_buf_append(buf, "\033\033", 2u)) {
                return 0;
            }
        } else if (!psi_buf_append(buf, text + i, 1u)) {
            return 0;
        }
    }
    return 1;
}

static int psi_buf_append_tmux_wrapped(struct psi_image_buffer *buf, const char *text, size_t len) {
    if (!psi_buf_append_cstr(buf, "\033Ptmux;")) {
        return 0;
    }
    if (!psi_buf_append_escaped_for_tmux(buf, text, len)) {
        return 0;
    }
    return psi_buf_append_cstr(buf, "\033\\");
}

static int psi_buf_append_utf8(struct psi_image_buffer *buf, unsigned int cp) {
    unsigned char bytes[4];
    size_t len;

    if (cp <= 0x7fu) {
        bytes[0] = (unsigned char)cp;
        len = 1u;
    } else if (cp <= 0x7ffu) {
        bytes[0] = (unsigned char)(0xc0u | (cp >> 6));
        bytes[1] = (unsigned char)(0x80u | (cp & 0x3fu));
        len = 2u;
    } else if (cp <= 0xffffu) {
        bytes[0] = (unsigned char)(0xe0u | (cp >> 12));
        bytes[1] = (unsigned char)(0x80u | ((cp >> 6) & 0x3fu));
        bytes[2] = (unsigned char)(0x80u | (cp & 0x3fu));
        len = 3u;
    } else if (cp <= 0x10ffffu) {
        bytes[0] = (unsigned char)(0xf0u | (cp >> 18));
        bytes[1] = (unsigned char)(0x80u | ((cp >> 12) & 0x3fu));
        bytes[2] = (unsigned char)(0x80u | ((cp >> 6) & 0x3fu));
        bytes[3] = (unsigned char)(0x80u | (cp & 0x3fu));
        len = 4u;
    } else {
        return 0;
    }
    return psi_buf_append(buf, (const char *)bytes, len);
}

static char *psi_image_kitty_sequence_impl(
    const char *base64,
    size_t base64_len,
    unsigned int columns,
    unsigned int rows,
    unsigned int width_pixels,
    unsigned int height_pixels,
    unsigned int image_id,
    int virtual_placement,
    int tmux_passthrough,
    size_t *out_len
) {
    struct psi_image_buffer out;
    char params[128];
    size_t offset;
    int first;

    if (out_len != NULL) {
        *out_len = 0u;
    }
    if (base64 == NULL) {
        return NULL;
    }
    if (columns == 0u) {
        columns = 80u;
    }
    if (rows == 0u) {
        rows = 1u;
    }

    out.data = NULL;
    out.len = 0u;
    out.cap = 0u;
    offset = 0u;
    first = 1;

    while (offset < base64_len || (base64_len == 0u && first)) {
        char chunk_prefix[160];
        char chunk_suffix[] = "\033\\";
        size_t take;
        size_t chunk_len;
        struct psi_image_buffer chunk;

        take = base64_len - offset;
        if (take > PSI_KITTY_CHUNK_SIZE) {
            take = PSI_KITTY_CHUNK_SIZE;
        }
        if (first) {
            if (virtual_placement) {
                if (width_pixels == 0u) {
                    width_pixels = columns;
                }
                if (height_pixels == 0u) {
                    height_pixels = rows;
                }
                snprintf(
                    params,
                    sizeof(params),
                    "a=T,C=1,U=1,q=2,f=100,s=%u,v=%u,c=%u,r=%u,i=%u",
                    width_pixels,
                    height_pixels,
                    columns,
                    rows,
                    image_id
                );
            } else {
                snprintf(params, sizeof(params), "a=T,f=100,q=2,c=%u,r=%u,C=1", columns, rows);
            }
            snprintf(
                chunk_prefix,
                sizeof(chunk_prefix),
                "\033_G%s%s;",
                params,
                (offset + take < base64_len) ? ",m=1" : ""
            );
        } else {
            snprintf(
                chunk_prefix,
                sizeof(chunk_prefix),
                "\033_Gm=%d;",
                (offset + take < base64_len) ? 1 : 0
            );
        }

        chunk.data = NULL;
        chunk.len = 0u;
        chunk.cap = 0u;
        if (!psi_buf_append_cstr(&chunk, chunk_prefix) ||
            !psi_buf_append(&chunk, base64 + offset, take) ||
            !psi_buf_append_cstr(&chunk, chunk_suffix)) {
            free(chunk.data);
            free(out.data);
            return NULL;
        }
        chunk_len = chunk.len;
        if (tmux_passthrough) {
            if (!psi_buf_append_tmux_wrapped(&out, chunk.data, chunk_len)) {
                free(chunk.data);
                free(out.data);
                return NULL;
            }
        } else if (!psi_buf_append(&out, chunk.data, chunk_len)) {
            free(chunk.data);
            free(out.data);
            return NULL;
        }
        free(chunk.data);
        first = 0;
        offset += take;
        if (base64_len == 0u) {
            break;
        }
    }

    if (out_len != NULL) {
        *out_len = out.len;
    }
    return out.data;
}

char *psi_image_kitty_sequence(
    const char *base64,
    size_t base64_len,
    unsigned int columns,
    unsigned int rows,
    int tmux_passthrough,
    size_t *out_len
) {
    return psi_image_kitty_sequence_impl(
        base64,
        base64_len,
        columns,
        rows,
        0u,
        0u,
        0u,
        0,
        tmux_passthrough,
        out_len
    );
}

char *psi_image_kitty_virtual_sequence(
    const char *base64,
    size_t base64_len,
    unsigned int columns,
    unsigned int rows,
    unsigned int width_pixels,
    unsigned int height_pixels,
    unsigned int image_id,
    int tmux_passthrough,
    size_t *out_len
) {
    if (image_id == 0u) {
        image_id = 1u;
    }
    return psi_image_kitty_sequence_impl(
        base64,
        base64_len,
        columns,
        rows,
        width_pixels,
        height_pixels,
        image_id,
        1,
        tmux_passthrough,
        out_len
    );
}

char *psi_image_kitty_placeholder_line(
    unsigned int image_id,
    unsigned int row,
    unsigned int columns,
    size_t *out_len
) {
    static const unsigned int diacritics[] = {
        0x0305, 0x030d, 0x030e, 0x0310, 0x0312, 0x033d, 0x033e, 0x033f,
        0x0346, 0x034a, 0x034b, 0x034c, 0x0350, 0x0351, 0x0352, 0x0357,
        0x035b, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
        0x036a, 0x036b, 0x036c, 0x036d, 0x036e, 0x036f, 0x0483, 0x0484,
        0x0485, 0x0486, 0x0487, 0x0592, 0x0593, 0x0594, 0x0595, 0x0597,
        0x0598, 0x0599, 0x059c, 0x059d, 0x059e, 0x059f, 0x05a0, 0x05a1,
        0x05a8, 0x05a9, 0x05ab, 0x05ac, 0x05af, 0x05c4, 0x0610, 0x0611,
        0x0612, 0x0613, 0x0614, 0x0615, 0x0616, 0x0617, 0x0657, 0x0658,
        0x0659, 0x065a, 0x065b, 0x065d, 0x065e, 0x06d6, 0x06d7, 0x06d8,
        0x06d9, 0x06da, 0x06db, 0x06dc, 0x06df, 0x06e0, 0x06e1, 0x06e2,
        0x06e4, 0x06e7, 0x06e8, 0x06eb, 0x06ec, 0x0730, 0x0732, 0x0733,
        0x0735, 0x0736, 0x073a, 0x073d, 0x073f, 0x0740, 0x0741, 0x0743,
        0x0745, 0x0747, 0x0749, 0x074a, 0x07eb, 0x07ec, 0x07ed, 0x07ee,
        0x07ef, 0x07f0, 0x07f1, 0x07f3, 0x0816, 0x0817, 0x0818, 0x0819,
        0x081b, 0x081c, 0x081d, 0x081e, 0x081f, 0x0820, 0x0821, 0x0822,
        0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082a, 0x082b, 0x082c,
        0x082d, 0x0951, 0x0953, 0x0954, 0x0f82, 0x0f83, 0x0f86, 0x0f87,
        0x135d, 0x135e, 0x135f, 0x17dd, 0x193a, 0x1a17, 0x1a75, 0x1a76,
        0x1a77, 0x1a78, 0x1a79, 0x1a7a, 0x1a7b, 0x1a7c, 0x1b6b, 0x1b6d,
        0x1b6e, 0x1b6f, 0x1b70, 0x1b71, 0x1b72, 0x1b73, 0x1cd0, 0x1cd1,
        0x1cd2, 0x1cda, 0x1cdb, 0x1ce0, 0x1dc0, 0x1dc1, 0x1dc3, 0x1dc4,
        0x1dc5, 0x1dc6, 0x1dc7, 0x1dc8, 0x1dc9, 0x1dcb, 0x1dcc, 0x1dd1,
        0x1dd2, 0x1dd3, 0x1dd4, 0x1dd5, 0x1dd6, 0x1dd7, 0x1dd8, 0x1dd9,
        0x1dda, 0x1ddb, 0x1ddc, 0x1ddd, 0x1dde, 0x1ddf, 0x1de0, 0x1de1,
        0x1de2, 0x1de3, 0x1de4, 0x1de5, 0x1de6, 0x1dfe, 0x20d0, 0x20d1,
        0x20d4, 0x20d5, 0x20d6, 0x20d7, 0x20db, 0x20dc, 0x20e1, 0x20e7,
        0x20e9, 0x20f0, 0x2cef, 0x2cf0, 0x2cf1, 0x2de0, 0x2de1, 0x2de2,
        0x2de3, 0x2de4, 0x2de5, 0x2de6, 0x2de7, 0x2de8, 0x2de9, 0x2dea,
        0x2deb, 0x2dec, 0x2ded, 0x2dee, 0x2def, 0x2df0, 0x2df1, 0x2df2,
        0x2df3, 0x2df4, 0x2df5, 0x2df6, 0x2df7, 0x2df8, 0x2df9, 0x2dfa,
        0x2dfb, 0x2dfc, 0x2dfd, 0x2dfe, 0x2dff, 0xa66f, 0xa67c, 0xa67d,
        0xa6f0, 0xa6f1, 0xa8e0, 0xa8e1, 0xa8e2, 0xa8e3, 0xa8e4, 0xa8e5,
        0xa8e6, 0xa8e7, 0xa8e8, 0xa8e9, 0xa8ea, 0xa8eb, 0xa8ec, 0xa8ed,
        0xa8ee, 0xa8ef, 0xa8f0, 0xa8f1, 0xaab0, 0xaab2, 0xaab3, 0xaab7,
        0xaab8, 0xaabe, 0xaabf, 0xaac1, 0xfe20, 0xfe21, 0xfe22, 0xfe23,
        0xfe24, 0xfe25, 0xfe26, 0x10a0f, 0x10a38, 0x1d185, 0x1d186,
        0x1d187, 0x1d188, 0x1d189, 0x1d1aa, 0x1d1ab, 0x1d1ac, 0x1d1ad,
        0x1d242, 0x1d243, 0x1d244
    };
    enum { diacritic_count = sizeof(diacritics) / sizeof(diacritics[0]) };
    struct psi_image_buffer out;
    char color[64];
    unsigned int r;
    unsigned int g;
    unsigned int b;
    unsigned int col;

    if (out_len != NULL) {
        *out_len = 0u;
    }
    if (columns == 0u) {
        columns = 1u;
    }
    if (row >= diacritic_count) {
        row = diacritic_count - 1u;
    }
    if (columns > diacritic_count) {
        columns = diacritic_count;
    }
    out.data = NULL;
    out.len = 0u;
    out.cap = 0u;
    image_id &= 0xffffffu;
    if (image_id == 0u) {
        image_id = 1u;
    }
    r = (image_id >> 16) & 0xffu;
    g = (image_id >> 8) & 0xffu;
    b = image_id & 0xffu;
    snprintf(color, sizeof(color), "\033[38;2;%u;%u;%um", r, g, b);
    if (!psi_buf_append_cstr(&out, color)) {
        free(out.data);
        return NULL;
    }
    for (col = 0u; col < columns; col++) {
        if (!psi_buf_append_utf8(&out, 0x10eeeeu) ||
            !psi_buf_append_utf8(&out, diacritics[row]) ||
            !psi_buf_append_utf8(&out, diacritics[col])) {
            free(out.data);
            return NULL;
        }
    }
    if (!psi_buf_append_cstr(&out, "\033[39m")) {
        free(out.data);
        return NULL;
    }
    if (out_len != NULL) {
        *out_len = out.len;
    }
    return out.data;
}

char *psi_image_kitty_delete_sequence(int tmux_passthrough, size_t *out_len) {
    static const char sequence[] = "\033_Ga=d,d=A\033\\";
    struct psi_image_buffer out;

    if (out_len != NULL) {
        *out_len = 0u;
    }
    out.data = NULL;
    out.len = 0u;
    out.cap = 0u;
    if (tmux_passthrough) {
        if (!psi_buf_append_tmux_wrapped(&out, sequence, sizeof(sequence) - 1u)) {
            free(out.data);
            return NULL;
        }
    } else if (!psi_buf_append(&out, sequence, sizeof(sequence) - 1u)) {
        free(out.data);
        return NULL;
    }
    if (out_len != NULL) {
        *out_len = out.len;
    }
    return out.data;
}

int psi_image_read_file(
    const char *path,
    struct psi_image_data *image,
    char *error,
    size_t error_size
) {
    FILE *file;
    long size;
    size_t read_count;

    if (image == NULL) {
        psi_image_set_error(error, error_size, "missing image output");
        return 0;
    }
    psi_image_data_init(image);
    if (path == NULL || path[0] == '\0') {
        psi_image_set_error(error, error_size, "missing image path");
        return 0;
    }

    file = fopen(path, "rb");
    if (file == NULL) {
        psi_image_set_error(error, error_size, strerror(errno));
        return 0;
    }
    if (fseek(file, 0l, SEEK_END) != 0) {
        fclose(file);
        psi_image_set_error(error, error_size, "failed to read image file");
        return 0;
    }
    size = ftell(file);
    if (size < 0l) {
        fclose(file);
        psi_image_set_error(error, error_size, "failed to size image file");
        return 0;
    }
    if ((unsigned long)size > (unsigned long)PSI_IMAGE_MAX_CLIPBOARD_BYTES) {
        fclose(file);
        psi_image_set_error(error, error_size, "image file is too large");
        return 0;
    }
    if (fseek(file, 0l, SEEK_SET) != 0) {
        fclose(file);
        psi_image_set_error(error, error_size, "failed to read image file");
        return 0;
    }

    image->bytes = (unsigned char *)malloc((size_t)size);
    if (image->bytes == NULL) {
        fclose(file);
        psi_image_set_error(error, error_size, "out of memory");
        return 0;
    }
    read_count = fread(image->bytes, 1u, (size_t)size, file);
    fclose(file);
    if (read_count != (size_t)size) {
        psi_image_data_free(image);
        psi_image_set_error(error, error_size, "failed to read image file");
        return 0;
    }
    image->size = (size_t)size;
    psi_image_probe(
        image->bytes,
        image->size,
        NULL,
        image->mime_type,
        sizeof(image->mime_type),
        &image->width,
        &image->height
    );
    if (image->mime_type[0] == '\0' || strcmp(image->mime_type, "application/octet-stream") == 0) {
        psi_image_data_free(image);
        psi_image_set_error(error, error_size, "unsupported image file type");
        return 0;
    }
    image->complete = (unsigned int)psi_image_is_complete(
        image->bytes,
        image->size,
        image->mime_type
    );
    return 1;
}

#if PSI_ENABLE_SDL_CLIPBOARD
static int psi_sdl_initialized = 0;

static int psi_sdl_has_likely_unix_video_env(void) {
#if defined(__unix__) || defined(__APPLE__)
    const char *display = getenv("DISPLAY");
    const char *wayland = getenv("WAYLAND_DISPLAY");
    if ((display != NULL && display[0] != '\0') || (wayland != NULL && wayland[0] != '\0')) {
        return 1;
    }
#endif
    return 0;
}

static int psi_clipboard_sdl_init(char *error, size_t error_size) {
    const char *sdl_error;

    if (psi_sdl_initialized) {
        return 1;
    }
    if (!SDL_InitSubSystem(SDL_INIT_VIDEO)) {
        sdl_error = SDL_GetError();
        if (
            sdl_error != NULL
            && strcmp(sdl_error, "No available video device") == 0
            && !psi_sdl_has_likely_unix_video_env()
        ) {
            psi_image_set_error(
                error,
                error_size,
                "image clipboard needs a graphical clipboard; DISPLAY/WAYLAND_DISPLAY is not set"
            );
        } else {
            psi_image_set_error(error, error_size, sdl_error);
        }
        return 0;
    }
    psi_sdl_initialized = 1;
    return 1;
}

int psi_clipboard_read_image(struct psi_image_data *image, char *error, size_t error_size) {
    static const char *MIMES[] = {
        "image/png",
        "image/jpeg",
        "image/webp",
        "image/gif",
        NULL
    };
    int i;

    if (image == NULL) {
        psi_image_set_error(error, error_size, "missing image output");
        return 0;
    }
    psi_image_data_init(image);
    if (!psi_clipboard_sdl_init(error, error_size)) {
        return 0;
    }

    for (i = 0; MIMES[i] != NULL; i++) {
        size_t size;
        void *data;

        if (!SDL_HasClipboardData(MIMES[i])) {
            continue;
        }
        size = 0u;
        data = SDL_GetClipboardData(MIMES[i], &size);
        if (data == NULL || size == 0u) {
            if (data != NULL) {
                SDL_free(data);
            }
            continue;
        }
        if (size > PSI_IMAGE_MAX_CLIPBOARD_BYTES) {
            SDL_free(data);
            psi_image_set_error(error, error_size, "clipboard image is too large");
            return 0;
        }
        image->bytes = (unsigned char *)malloc(size);
        if (image->bytes == NULL) {
            SDL_free(data);
            psi_image_set_error(error, error_size, "out of memory");
            return 0;
        }
        memcpy(image->bytes, data, size);
        SDL_free(data);
        image->size = size;
        psi_image_probe(
            image->bytes,
            image->size,
            MIMES[i],
            image->mime_type,
            sizeof(image->mime_type),
            &image->width,
            &image->height
        );
        if (image->mime_type[0] == '\0') {
            psi_copy_mime(image->mime_type, sizeof(image->mime_type), MIMES[i]);
        }
        image->complete = (unsigned int)psi_image_is_complete(
            image->bytes,
            image->size,
            image->mime_type
        );
        return 1;
    }

    psi_image_set_error(error, error_size, "clipboard does not contain a supported image");
    return 0;
}
#else
int psi_clipboard_read_image(struct psi_image_data *image, char *error, size_t error_size) {
    if (image != NULL) {
        psi_image_data_init(image);
    }
    psi_image_set_error(error, error_size, "SDL clipboard support is not compiled in");
    return 0;
}
#endif
