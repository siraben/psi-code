#ifndef PSI_HTTP_ASYNC_H
#define PSI_HTTP_ASYNC_H

#include "psi/common.h"

struct psi_abort_signal;

/* Async streamed HTTP POST.
 *
 * psi_http_stream_begin starts a helper pthread that runs
 * curl_easy_perform on the given request; chunks are enqueued as
 * they arrive so the caller can pull them from the event loop
 * without blocking on the network. The helper thread never touches
 * the caller's lua_State or any other non-thread-safe resource.
 *
 * Typical use (from the Lua turn coroutine, via the psi.sched
 * trampoline):
 *
 *     struct psi_http_stream *h;
 *     psi_http_stream_begin(url, headers, n, body, body_len,
 *                           abort, &h);
 *     for (;;) {
 *         char *chunk; size_t len;
 *         int r = psi_http_stream_poll(h, 50, &chunk, &len);
 *         if (r == 1) { feed(chunk, len); free(chunk); }
 *         if (r == 2) break;
 *     }
 *     long status = psi_http_stream_finish(h);
 *
 * Return codes:
 *   PSI_STATUS_OK on successful begin; *out owns the handle.
 *   PSI_STATUS_ERROR otherwise; *out is left NULL.
 */

struct psi_http_stream;

int psi_http_stream_begin(
    const char *url,
    const char *const *header_lines,
    size_t header_count,
    const char *body,
    size_t body_len,
    const struct psi_abort_signal *abort_signal,
    struct psi_http_stream **out
);

/* Poll the stream for the next chunk.
 *
 * Waits up to timeout_ms (0 = non-blocking, negative = wait forever
 * but not past stream completion). The returned chunk buffer is
 * owned by the caller and must be free()d. chunk_len is the byte
 * length (no trailing NUL included; the helper does not NUL-terminate).
 *
 * Returns:
 *   1  a chunk is available; *chunk / *chunk_len are set.
 *   0  timeout elapsed with no chunk and the stream is still
 *      running; caller may continue the loop.
 *   2  the stream is done (no more chunks will arrive).
 *         - *chunk is NULL, *chunk_len is 0.
 *         - call psi_http_stream_finish next to reap exit status.
 */
int psi_http_stream_poll(
    struct psi_http_stream *h,
    int timeout_ms,
    char **chunk,
    size_t *chunk_len
);

/* Join the helper thread, free the handle, and return the HTTP
 * status code. Returns -1 on transport error (curl_easy_perform
 * failed). Must only be called after poll has returned 2, or after
 * the caller has decided to abandon the transfer (abort signal). */
long psi_http_stream_finish(struct psi_http_stream *h);

#endif
