/* Async HTTP streaming: a helper thread runs curl_easy_perform; the
 * caller (always on the host's main thread, always the sole lua_State
 * owner after the coroutine rewrite) polls for chunks via a
 * condition variable. This is the minimum-invasive way to decouple
 * "the network is blocking" from "the UI loop needs to run".
 *
 * The helper pthread is intentionally small and owns nothing but the
 * curl handle and the chunk queue. It never calls into Lua; it never
 * touches the abort_signal except to read the volatile flag. Cleanup
 * on abort: curl aborts the transfer via the xferinfo callback, the
 * helper thread returns, the main thread joins it during finish.
 */

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <curl/curl.h>
#include "psi/abort.h"
#include "psi/common.h"
#include "psi/http_async.h"
#include "psi/http_tls.h"

#define PSI_HTTP_STREAM_TOTAL_MAX_BYTES (64u * 1024u * 1024u)
#define PSI_HTTP_STREAM_QUEUE_MAX_BYTES (4u * 1024u * 1024u)

static pthread_once_t psi_http_init_once = PTHREAD_ONCE_INIT;
static int psi_http_init_status = 1; /* non-zero = unattempted/failed */

/* Process-wide share: TLS session cache + connection pool. Handles run
 * on the caller's thread and stream threads, so lock callbacks are
 * required. Never destroyed: must outlive every easy handle. */
static CURLSH *psi_http_share = NULL;
static pthread_mutex_t psi_http_share_locks[CURL_LOCK_DATA_LAST];

static void psi_http_share_lock_cb(
    CURL *handle, curl_lock_data data, curl_lock_access access, void *userptr) {
    (void)handle;
    (void)access;
    (void)userptr;
    if ((int)data >= 0 && (int)data < (int)CURL_LOCK_DATA_LAST)
        pthread_mutex_lock(&psi_http_share_locks[(int)data]);
}

static void psi_http_share_unlock_cb(CURL *handle, curl_lock_data data, void *userptr) {
    (void)handle;
    (void)userptr;
    if ((int)data >= 0 && (int)data < (int)CURL_LOCK_DATA_LAST)
        pthread_mutex_unlock(&psi_http_share_locks[(int)data]);
}

static void psi_http_share_init(void) {
    CURLSH *share;
    int i;

    for (i = 0; i < (int)CURL_LOCK_DATA_LAST; i++) {
        if (pthread_mutex_init(&psi_http_share_locks[i], NULL) != 0) {
            while (i > 0) {
                i--;
                pthread_mutex_destroy(&psi_http_share_locks[i]);
            }
            return;
        }
    }
    share = curl_share_init();
    if (share == NULL)
        return;
    if (curl_share_setopt(share, CURLSHOPT_LOCKFUNC, psi_http_share_lock_cb) != CURLSHE_OK ||
        curl_share_setopt(share, CURLSHOPT_UNLOCKFUNC, psi_http_share_unlock_cb) != CURLSHE_OK ||
        curl_share_setopt(share, CURLSHOPT_SHARE, CURL_LOCK_DATA_SSL_SESSION) != CURLSHE_OK ||
        curl_share_setopt(share, CURLSHOPT_SHARE, CURL_LOCK_DATA_CONNECT) != CURLSHE_OK) {
        curl_share_cleanup(share);
        return;
    }
    psi_http_share = share;
}

static void psi_http_init_cb(void) {
    psi_http_init_status = (curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK) ? 0 : 1;
    if (psi_http_init_status == 0)
        psi_http_share_init();
}

int psi_http_global_init(void) {
    pthread_once(&psi_http_init_once, psi_http_init_cb);
    return psi_http_init_status == 0 ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

void *psi_http_share_handle(void) {
    if (psi_http_global_init() != PSI_STATUS_OK)
        return NULL;
    return (void *)psi_http_share;
}

/* curl_slist_append returns NULL on failure without freeing the
 * prior list; this wrapper assigns through only on success. */
static int psi_http_slist_append_safe(struct curl_slist **list, const char *line) {
    struct curl_slist *next = curl_slist_append(*list, line);
    if (next == NULL)
        return PSI_STATUS_ERROR;
    *list = next;
    return PSI_STATUS_OK;
}

struct psi_http_chunk_node {
    char *data;
    size_t len;
    struct psi_http_chunk_node *next;
};

struct psi_http_stream {
    /* Writer (helper thread) side. */
    pthread_t thread;
    int thread_started;

    /* Request state — owned by the helper thread for the duration
     * of curl_easy_perform. Freed in finish. */
    char *url;
    struct curl_slist *headers;
    char *body;
    size_t body_len;
    const struct psi_abort_signal *abort_signal;

    /* Chunk queue, guarded by `mu`. */
    pthread_mutex_t mu;
    pthread_cond_t cond;
    struct psi_http_chunk_node *queue_head;
    struct psi_http_chunk_node *queue_tail;
    size_t queue_bytes;
    size_t total_bytes;

    /* Terminal state: set by helper when curl_easy_perform returns.
     * Main thread reads under `mu`. */
    int done;
    long http_status; /* HTTP response code (only meaningful when done) */
    CURLcode curl_code; /* CURLE_OK on success */
    char curl_error[CURL_ERROR_SIZE];

    /* Latch set under `mu` if the helper thread's write callback
     * fails to enqueue a chunk (OOM). When set, the next callback
     * invocation returns 0 to curl, which aborts the transfer as a
     * short-write error so the caller sees a clean transport
     * failure instead of silently losing bytes. */
    int write_failed;
};

static void psi_http_stream_free_request(struct psi_http_stream *h) {
    if (h == NULL)
        return;
    curl_slist_free_all(h->headers);
    free(h->url);
    free(h->body);
    free(h);
}

/* ------------------------------------------------------------------
 * Queue management — all under `mu`.
 * ------------------------------------------------------------------ */

/* Enqueue a copy of `data[0..len)`. Returns 1 on success, 0 if
 * either allocation fails. On failure, `write_failed` is latched
 * under `mu` so the write callback can abort curl rather than
 * silently lose streamed bytes. */
static void psi_http_queue_push_fail(struct psi_http_stream *h) {
    pthread_mutex_lock(&h->mu);
    h->write_failed = 1;
    pthread_cond_broadcast(&h->cond);
    pthread_mutex_unlock(&h->mu);
}

static int psi_http_queue_would_exceed_limits(const struct psi_http_stream *h, size_t len) {
    if (len > PSI_HTTP_STREAM_TOTAL_MAX_BYTES)
        return 1;
    if (h->total_bytes > PSI_HTTP_STREAM_TOTAL_MAX_BYTES - len)
        return 1;
    if (len > PSI_HTTP_STREAM_QUEUE_MAX_BYTES)
        return 1;
    if (h->queue_bytes > PSI_HTTP_STREAM_QUEUE_MAX_BYTES - len)
        return 1;
    return 0;
}

static int psi_http_queue_push(struct psi_http_stream *h, const char *data, size_t len) {
    struct psi_http_chunk_node *node;

    if (len == 0u)
        return 1;

    pthread_mutex_lock(&h->mu);
    if (h->write_failed || psi_http_queue_would_exceed_limits(h, len)) {
        h->write_failed = 1;
        pthread_cond_broadcast(&h->cond);
        pthread_mutex_unlock(&h->mu);
        return 0;
    }
    h->total_bytes += len;
    h->queue_bytes += len;
    pthread_mutex_unlock(&h->mu);

    node = (struct psi_http_chunk_node *)malloc(sizeof(*node));
    if (node == NULL) {
        psi_http_queue_push_fail(h);
        return 0;
    }
    node->data = (char *)malloc(len);
    if (node->data == NULL) {
        free(node);
        psi_http_queue_push_fail(h);
        return 0;
    }
    memcpy(node->data, data, len);
    node->len = len;
    node->next = NULL;

    pthread_mutex_lock(&h->mu);
    if (h->queue_tail == NULL) {
        h->queue_head = node;
    } else {
        h->queue_tail->next = node;
    }
    h->queue_tail = node;
    pthread_cond_signal(&h->cond);
    pthread_mutex_unlock(&h->mu);
    return 1;
}

/* Detach the entire queued list under `mu`, zeroing the queue
 * accounting so the producer's back-pressure check
 * (queue_bytes vs PSI_HTTP_STREAM_QUEUE_MAX_BYTES) sees the drain. */
static struct psi_http_chunk_node *psi_http_queue_detach_locked(struct psi_http_stream *h) {
    struct psi_http_chunk_node *node;

    node = h->queue_head;
    h->queue_head = NULL;
    h->queue_tail = NULL;
    h->queue_bytes = 0u;
    return node;
}

static void psi_http_chunk_list_free(struct psi_http_chunk_node *node) {
    struct psi_http_chunk_node *next;

    while (node != NULL) {
        next = node->next;
        free(node->data);
        free(node);
        node = next;
    }
}

/* Re-attach a detached sublist at the front of the queue, restoring
 * its byte accounting. Used only on the poll-side OOM fallback. */
static void psi_http_queue_requeue_front(
    struct psi_http_stream *h, struct psi_http_chunk_node *head, size_t bytes) {
    struct psi_http_chunk_node *tail;

    if (head == NULL)
        return;
    tail = head;
    while (tail->next != NULL)
        tail = tail->next;
    pthread_mutex_lock(&h->mu);
    tail->next = h->queue_head;
    h->queue_head = head;
    if (h->queue_tail == NULL)
        h->queue_tail = tail;
    h->queue_bytes += bytes;
    pthread_mutex_unlock(&h->mu);
}

static void psi_http_queue_free_all(struct psi_http_stream *h) {
    psi_http_chunk_list_free(psi_http_queue_detach_locked(h));
}

/* ------------------------------------------------------------------
 * curl callbacks (run on helper thread).
 * ------------------------------------------------------------------ */

static size_t psi_http_stream_write_cb(void *data, size_t size, size_t nmemb, void *userdata) {
    struct psi_http_stream *h = (struct psi_http_stream *)userdata;
    size_t total;
    if (size != 0u && nmemb > ((size_t)-1) / size) {
        psi_http_queue_push_fail(h);
        return 0u;
    }
    total = size * nmemb;
    if (!psi_http_queue_push(h, (const char *)data, total)) {
        /* Returning a short count tells curl the write failed;
         * curl_easy_perform unwinds with CURLE_WRITE_ERROR, the
         * helper thread exits, and the caller's finish() observes
         * the transport failure (returns -1). No bytes are
         * silently dropped. */
        return 0u;
    }
    return total;
}

static int psi_http_stream_xferinfo(
    void *clientp, curl_off_t dltotal, curl_off_t dlnow, curl_off_t ultotal, curl_off_t ulnow) {
    const struct psi_abort_signal *s = (const struct psi_abort_signal *)clientp;
    (void)dltotal;
    (void)dlnow;
    (void)ultotal;
    (void)ulnow;
    return (s != NULL && psi_abort_signal_is_triggered(s)) ? 1 : 0;
}

/* ------------------------------------------------------------------
 * Helper-thread entry.
 * ------------------------------------------------------------------ */

static void *psi_http_stream_thread(void *arg) {
    struct psi_http_stream *h = (struct psi_http_stream *)arg;
    CURL *curl;
    CURLcode code;
    long status;

    status = 0l;
    curl = curl_easy_init();
    if (curl == NULL) {
        pthread_mutex_lock(&h->mu);
        h->curl_code = CURLE_OUT_OF_MEMORY;
        h->done = 1;
        pthread_cond_broadcast(&h->cond);
        pthread_mutex_unlock(&h->mu);
        return NULL;
    }

    curl_easy_setopt(curl, CURLOPT_URL, h->url);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, h->headers);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, h->body);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)h->body_len);
    h->curl_error[0] = '\0';
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, h->curl_error);
    if (psi_http_share != NULL)
        curl_easy_setopt(curl, CURLOPT_SHARE, psi_http_share);
    psi_http_configure_tls(curl);
    psi_http_configure_resilience(curl);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, psi_http_stream_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, (void *)h);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, psi_http_stream_xferinfo);
    /* See psi_http_build_handle in anthropic.c for the const-cast story. */
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, (void *)h->abort_signal);

    code = curl_easy_perform(curl);
    if (code == CURLE_OK) {
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    }
    curl_easy_cleanup(curl);

    pthread_mutex_lock(&h->mu);
    h->curl_code = code;
    h->http_status = status;
    h->done = 1;
    pthread_cond_broadcast(&h->cond);
    pthread_mutex_unlock(&h->mu);
    return NULL;
}

/* ------------------------------------------------------------------
 * Public API.
 * ------------------------------------------------------------------ */

int psi_http_stream_begin(const char *url, const char *const *header_lines, size_t header_count,
    const char *body, size_t body_len, const struct psi_abort_signal *abort_signal,
    struct psi_http_stream **out) {
    struct psi_http_stream *h;
    size_t i;
    int rc;

    if (out == NULL)
        return PSI_STATUS_ERROR;
    *out = NULL;
    if (url == NULL)
        return PSI_STATUS_ERROR;

    if (psi_http_global_init() != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    h = (struct psi_http_stream *)calloc(1u, sizeof(*h));
    if (h == NULL) {
        return PSI_STATUS_ERROR;
    }

    h->url = psi_strdup(url);
    h->body_len = body_len;
    if (body != NULL && body_len > 0u) {
        h->body = (char *)malloc(body_len);
        if (h->body != NULL)
            memcpy(h->body, body, body_len);
    } else {
        h->body = psi_strdup("");
    }
    if (h->url == NULL || h->body == NULL) {
        psi_http_stream_free_request(h);
        return PSI_STATUS_ERROR;
    }

    for (i = 0u; i < header_count; i++) {
        if (psi_http_slist_append_safe(&h->headers, header_lines[i]) != PSI_STATUS_OK) {
            psi_http_stream_free_request(h);
            return PSI_STATUS_ERROR;
        }
    }
    h->abort_signal = abort_signal;
    h->curl_code = CURLE_OK;
    h->curl_error[0] = '\0';
    h->http_status = 0l;

    if (pthread_mutex_init(&h->mu, NULL) != 0) {
        psi_http_stream_free_request(h);
        return PSI_STATUS_ERROR;
    }
    if (pthread_cond_init(&h->cond, NULL) != 0) {
        pthread_mutex_destroy(&h->mu);
        psi_http_stream_free_request(h);
        return PSI_STATUS_ERROR;
    }

    rc = pthread_create(&h->thread, NULL, psi_http_stream_thread, h);
    if (rc != 0) {
        pthread_cond_destroy(&h->cond);
        pthread_mutex_destroy(&h->mu);
        psi_http_stream_free_request(h);
        return PSI_STATUS_ERROR;
    }
    h->thread_started = 1;

    *out = h;
    return PSI_STATUS_OK;
}

/* Join a detached chunk list into one buffer. On allocation failure,
 * hand off the first node as-is and re-queue the rest: no bytes lost. */
static void psi_http_chunk_list_join(
    struct psi_http_stream *h, struct psi_http_chunk_node *head, char **out, size_t *out_len) {
    struct psi_http_chunk_node *node;
    size_t total;
    char *joined;
    size_t off;

    if (head->next == NULL) {
        /* Single chunk: hand off the buffer without copying. */
        *out = head->data;
        *out_len = head->len;
        free(head);
        return;
    }

    total = 0u;
    for (node = head; node != NULL; node = node->next)
        total += node->len;

    joined = (char *)malloc(total);
    if (joined == NULL) {
        size_t rest_bytes;

        rest_bytes = total - head->len;
        *out = head->data;
        *out_len = head->len;
        node = head->next;
        free(head);
        psi_http_queue_requeue_front(h, node, rest_bytes);
        return;
    }

    off = 0u;
    node = head;
    while (node != NULL) {
        struct psi_http_chunk_node *next = node->next;
        memcpy(joined + off, node->data, node->len);
        off += node->len;
        free(node->data);
        free(node);
        node = next;
    }
    *out = joined;
    *out_len = off;
}

int psi_http_stream_poll(
    struct psi_http_stream *h, int timeout_ms, char **chunk, size_t *chunk_len) {
    struct psi_http_chunk_node *node;
    int result;

    if (chunk != NULL)
        *chunk = NULL;
    if (chunk_len != NULL)
        *chunk_len = 0u;
    if (h == NULL)
        return 2;

    pthread_mutex_lock(&h->mu);

    if (h->queue_head == NULL && !h->done && timeout_ms != 0) {
        if (timeout_ms < 0) {
            pthread_cond_wait(&h->cond, &h->mu);
        } else {
            struct timespec ts;
            struct timeval now;
            long sec, nsec;

            gettimeofday(&now, NULL);
            sec = (long)now.tv_sec + (long)(timeout_ms / 1000);
            nsec = (long)(now.tv_usec) * 1000l + (long)(timeout_ms % 1000) * 1000000l;
            if (nsec >= 1000000000l) {
                sec += 1l;
                nsec -= 1000000000l;
            }
            ts.tv_sec = (time_t)sec;
            ts.tv_nsec = nsec;
            pthread_cond_timedwait(&h->cond, &h->mu, &ts);
        }
    }

    node = psi_http_queue_detach_locked(h);
    if (node != NULL) {
        result = 1;
    } else if (h->done) {
        result = 2;
    } else {
        result = 0;
    }
    pthread_mutex_unlock(&h->mu);

    if (node != NULL) {
        if (chunk != NULL) {
            char *joined = NULL;
            size_t joined_len = 0u;
            psi_http_chunk_list_join(h, node, &joined, &joined_len);
            *chunk = joined;
            if (chunk_len != NULL)
                *chunk_len = joined_len;
        } else {
            psi_http_chunk_list_free(node);
        }
    }
    return result;
}

static long psi_http_stream_finish_live(struct psi_http_stream *h, char **error_message) {
    long status;
    CURLcode code;

    if (h->thread_started) {
        pthread_join(h->thread, NULL);
        h->thread_started = 0;
    }

    status = h->http_status;
    code = h->curl_code;
    if (code != CURLE_OK && error_message != NULL) {
        const char *message;
        message = h->curl_error[0] != '\0' ? h->curl_error : curl_easy_strerror(code);
        *error_message = psi_strdup(message);
    }

    psi_http_queue_free_all(h);
    pthread_cond_destroy(&h->cond);
    pthread_mutex_destroy(&h->mu);
    curl_slist_free_all(h->headers);
    free(h->url);
    free(h->body);
    free(h);

    return (code == CURLE_OK) ? status : -1l;
}

long psi_http_stream_finish(struct psi_http_stream *h, char **error_message) {
    if (error_message != NULL)
        *error_message = NULL;
    if (h == NULL)
        return -1l;
    return psi_http_stream_finish_live(h, error_message);
}

long psi_http_stream_finish_owned(struct psi_http_stream **slot, char **error_message) {
    struct psi_http_stream *h;

    if (error_message != NULL)
        *error_message = NULL;
    if (slot == NULL || *slot == NULL)
        return 0l;
    h = *slot;
    *slot = NULL;
    return psi_http_stream_finish_live(h, error_message);
}
