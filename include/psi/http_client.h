#ifndef PSI_HTTP_CLIENT_H
#define PSI_HTTP_CLIENT_H

#include "psi/common.h"

struct psi_abort_signal;

/* Generic HTTP primitives exposed to Lua. The agent turn loop lives
 * in Lua; this header is the small libcurl-backed transport surface
 * the embedded runtime can reuse for providers and network tools. */

typedef void (*psi_http_chunk_cb)(void *userdata, const char *chunk, size_t len);

struct psi_http_request_options {
    const char *method;
    const char *url;
    const char *const *header_lines;
    size_t header_count;
    const char *body;
    size_t body_len;
    long timeout_ms;
    long max_response_bytes;
};

int psi_http_request(
    const struct psi_http_request_options *request,
    const struct psi_abort_signal *abort_signal,
    long *status_code,
    char **response_body
);

/* Compatibility helpers used by the existing provider code. */
int psi_http_post_stream(
    const char *url,
    const char *const *header_lines,
    size_t header_count,
    const char *body,
    size_t body_len,
    psi_http_chunk_cb on_chunk,
    void *userdata,
    const struct psi_abort_signal *abort_signal,
    long *status_code
);

int psi_http_post(
    const char *url,
    const char *const *header_lines,
    size_t header_count,
    const char *body,
    size_t body_len,
    const struct psi_abort_signal *abort_signal,
    long *status_code,
    char **response_body
);

#endif
