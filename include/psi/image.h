#ifndef PSI_IMAGE_H
#define PSI_IMAGE_H

#include <stddef.h>

struct psi_image_data {
    unsigned char *bytes;
    size_t size;
    char mime_type[32];
    unsigned int width;
    unsigned int height;
    unsigned int complete;
    unsigned int clipboard_chunks;
    size_t clipboard_base64_len;
};

void psi_image_data_init(struct psi_image_data *image);
void psi_image_data_free(struct psi_image_data *image);

int psi_image_probe(
    const unsigned char *bytes,
    size_t size,
    const char *mime_hint,
    char *mime_type,
    size_t mime_type_size,
    unsigned int *width,
    unsigned int *height
);

int psi_image_is_complete(const unsigned char *bytes, size_t size, const char *mime_type);

char *psi_image_base64_encode(const unsigned char *bytes, size_t size, size_t *out_len);

int psi_image_base64_decode_alloc(
    const char *base64,
    size_t base64_len,
    unsigned char **out_bytes,
    size_t *out_len,
    char *error,
    size_t error_size
);

int psi_image_from_base64(
    const char *base64,
    size_t base64_len,
    const char *mime_hint,
    struct psi_image_data *image,
    char *error,
    size_t error_size
);

char *psi_image_kitty_sequence(
    const char *base64,
    size_t base64_len,
    unsigned int columns,
    unsigned int rows,
    int tmux_passthrough,
    size_t *out_len
);

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
);

char *psi_image_kitty_placeholder_line(
    unsigned int image_id,
    unsigned int row,
    unsigned int columns,
    size_t *out_len
);

char *psi_image_kitty_delete_sequence(int tmux_passthrough, size_t *out_len);

int psi_clipboard_read_image(struct psi_image_data *image, char *error, size_t error_size);

int psi_image_read_file(
    const char *path,
    struct psi_image_data *image,
    char *error,
    size_t error_size
);

#endif
