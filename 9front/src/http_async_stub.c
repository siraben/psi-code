/* Synchronous "async" HTTP stream for APE on 9front.
 *
 * APE has no pthreads. We buffer the entire stream into a linked list
 * of chunks synchronously in psi_http_stream_begin, then dispense them
 * one at a time from psi_http_stream_poll. The caller contract (poll
 * returns 1 with owned chunk / 0 continue / 2 done) is preserved.
 *
 * Trade-off: the UI loop blocks for the duration of the request, so
 * abort during transfer is best-effort — the underlying webfs call
 * observes the abort signal only between chunks. Upgrade to libthread
 * later if needed.
 */

#include <stdlib.h>
#include <string.h>
#include "psi/abort.h"
#include "psi/anthropic.h"
#include "psi/common.h"
#include "psi/http_async.h"

struct psi_http_chunk_node {
    char *data;
    size_t len;
    struct psi_http_chunk_node *next;
};

struct psi_http_stream {
    struct psi_http_chunk_node *head;
    struct psi_http_chunk_node *tail;
    long http_status;
    int ok;
    int done;
};

static void
append_chunk(void *userdata, const char *chunk, size_t len)
{
    struct psi_http_stream *s = (struct psi_http_stream *)userdata;
    struct psi_http_chunk_node *n;
    if (len == 0) return;
    n = (struct psi_http_chunk_node *)malloc(sizeof *n);
    if (n == NULL) return;
    n->data = (char *)malloc(len);
    if (n->data == NULL) { free(n); return; }
    memcpy(n->data, chunk, len);
    n->len = len;
    n->next = NULL;
    if (s->tail == NULL) s->head = n;
    else s->tail->next = n;
    s->tail = n;
}

int
psi_http_stream_begin(
    const char *url,
    const char *const *header_lines, size_t header_count,
    const char *body, size_t body_len,
    const struct psi_abort_signal *abort_signal,
    struct psi_http_stream **out)
{
    struct psi_http_stream *s;
    int rc;

    if (out != NULL) *out = NULL;
    s = (struct psi_http_stream *)calloc(1, sizeof *s);
    if (s == NULL) return PSI_STATUS_ERROR;

    rc = psi_http_post_stream(url, header_lines, header_count,
                              body, body_len,
                              append_chunk, s,
                              abort_signal, &s->http_status);
    s->ok = (rc == PSI_STATUS_OK) ? 1 : 0;
    s->done = 1;
    if (out != NULL) *out = s;
    return PSI_STATUS_OK;
}

int
psi_http_stream_poll(
    struct psi_http_stream *s,
    int timeout_ms,
    char **chunk, size_t *chunk_len)
{
    struct psi_http_chunk_node *n;
    PSI_UNUSED(timeout_ms);
    if (chunk != NULL) *chunk = NULL;
    if (chunk_len != NULL) *chunk_len = 0;
    if (s == NULL) return 2;

    n = s->head;
    if (n == NULL) return 2;
    s->head = n->next;
    if (s->head == NULL) s->tail = NULL;
    if (chunk != NULL) *chunk = n->data; else free(n->data);
    if (chunk_len != NULL) *chunk_len = n->len;
    free(n);
    return 1;
}

long
psi_http_stream_finish(struct psi_http_stream *s)
{
    long status;
    struct psi_http_chunk_node *n;
    if (s == NULL) return -1;
    status = s->ok ? s->http_status : -1;
    n = s->head;
    while (n != NULL) {
        struct psi_http_chunk_node *next = n->next;
        free(n->data);
        free(n);
        n = next;
    }
    free(s);
    return status;
}
