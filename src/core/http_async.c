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

    /* Terminal state: set by helper when curl_easy_perform returns.
     * Main thread reads under `mu`. */
    int done;
    long http_status;   /* HTTP response code (only meaningful when done) */
    CURLcode curl_code; /* CURLE_OK on success */
};

/* ------------------------------------------------------------------
 * Queue management — all under `mu`.
 * ------------------------------------------------------------------ */

static void psi_http_queue_push(
    struct psi_http_stream *h, const char *data, size_t len
) {
    struct psi_http_chunk_node *node;

    node = (struct psi_http_chunk_node *)malloc(sizeof(*node));
    if (node == NULL) {
        return; /* drop on OOM; helper thread can't do anything better */
    }
    node->data = (char *)malloc(len);
    if (node->data == NULL) {
        free(node);
        return;
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
}

static struct psi_http_chunk_node *psi_http_queue_pop_locked(
    struct psi_http_stream *h
) {
    struct psi_http_chunk_node *node;

    node = h->queue_head;
    if (node != NULL) {
        h->queue_head = node->next;
        if (h->queue_head == NULL) {
            h->queue_tail = NULL;
        }
    }
    return node;
}

static void psi_http_queue_free_all(struct psi_http_stream *h) {
    struct psi_http_chunk_node *node, *next;

    node = h->queue_head;
    h->queue_head = NULL;
    h->queue_tail = NULL;
    while (node != NULL) {
        next = node->next;
        free(node->data);
        free(node);
        node = next;
    }
}

/* ------------------------------------------------------------------
 * curl callbacks (run on helper thread).
 * ------------------------------------------------------------------ */

static size_t psi_http_stream_write_cb(
    void *data, size_t size, size_t nmemb, void *userdata
) {
    struct psi_http_stream *h = (struct psi_http_stream *)userdata;
    size_t total = size * nmemb;
    psi_http_queue_push(h, (const char *)data, total);
    return total;
}

static int psi_http_stream_xferinfo(
    void *clientp,
    curl_off_t dltotal, curl_off_t dlnow,
    curl_off_t ultotal, curl_off_t ulnow
) {
    const struct psi_abort_signal *s = (const struct psi_abort_signal *)clientp;
    (void)dltotal; (void)dlnow; (void)ultotal; (void)ulnow;
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

int psi_http_stream_begin(
    const char *url,
    const char *const *header_lines, size_t header_count,
    const char *body, size_t body_len,
    const struct psi_abort_signal *abort_signal,
    struct psi_http_stream **out
) {
    struct psi_http_stream *h;
    size_t i;
    int rc;

    if (out == NULL) return PSI_STATUS_ERROR;
    *out = NULL;
    if (url == NULL) return PSI_STATUS_ERROR;

    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) {
        return PSI_STATUS_ERROR;
    }

    h = (struct psi_http_stream *)calloc(1u, sizeof(*h));
    if (h == NULL) {
        curl_global_cleanup();
        return PSI_STATUS_ERROR;
    }

    h->url = psi_strdup(url);
    h->body_len = body_len;
    if (body != NULL && body_len > 0u) {
        h->body = (char *)malloc(body_len);
        if (h->body != NULL) memcpy(h->body, body, body_len);
    } else {
        h->body = psi_strdup("");
    }
    if (h->url == NULL || h->body == NULL) {
        free(h->url); free(h->body); free(h);
        curl_global_cleanup();
        return PSI_STATUS_ERROR;
    }

    for (i = 0u; i < header_count; i++) {
        h->headers = curl_slist_append(h->headers, header_lines[i]);
    }
    h->abort_signal = abort_signal;
    h->curl_code = CURLE_OK;
    h->http_status = 0l;

    if (pthread_mutex_init(&h->mu, NULL) != 0) {
        curl_slist_free_all(h->headers);
        free(h->url); free(h->body); free(h);
        curl_global_cleanup();
        return PSI_STATUS_ERROR;
    }
    if (pthread_cond_init(&h->cond, NULL) != 0) {
        pthread_mutex_destroy(&h->mu);
        curl_slist_free_all(h->headers);
        free(h->url); free(h->body); free(h);
        curl_global_cleanup();
        return PSI_STATUS_ERROR;
    }

    rc = pthread_create(&h->thread, NULL, psi_http_stream_thread, h);
    if (rc != 0) {
        pthread_cond_destroy(&h->cond);
        pthread_mutex_destroy(&h->mu);
        curl_slist_free_all(h->headers);
        free(h->url); free(h->body); free(h);
        curl_global_cleanup();
        return PSI_STATUS_ERROR;
    }
    h->thread_started = 1;

    *out = h;
    return PSI_STATUS_OK;
}

int psi_http_stream_poll(
    struct psi_http_stream *h,
    int timeout_ms,
    char **chunk, size_t *chunk_len
) {
    struct psi_http_chunk_node *node;
    int result;

    if (chunk != NULL) *chunk = NULL;
    if (chunk_len != NULL) *chunk_len = 0u;
    if (h == NULL) return 2;

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
            nsec = (long)(now.tv_usec) * 1000l
                 + (long)(timeout_ms % 1000) * 1000000l;
            if (nsec >= 1000000000l) {
                sec += 1l;
                nsec -= 1000000000l;
            }
            ts.tv_sec = (time_t)sec;
            ts.tv_nsec = nsec;
            pthread_cond_timedwait(&h->cond, &h->mu, &ts);
        }
    }

    node = psi_http_queue_pop_locked(h);
    if (node != NULL) {
        result = 1;
    } else if (h->done) {
        result = 2;
    } else {
        result = 0;
    }
    pthread_mutex_unlock(&h->mu);

    if (node != NULL) {
        if (chunk != NULL) *chunk = node->data;
        else free(node->data);
        if (chunk_len != NULL) *chunk_len = node->len;
        free(node);
    }
    return result;
}

long psi_http_stream_finish(struct psi_http_stream *h) {
    long status;
    CURLcode code;

    if (h == NULL) return -1l;
    if (h->thread_started) {
        pthread_join(h->thread, NULL);
        h->thread_started = 0;
    }

    status = h->http_status;
    code = h->curl_code;

    psi_http_queue_free_all(h);
    pthread_cond_destroy(&h->cond);
    pthread_mutex_destroy(&h->mu);
    curl_slist_free_all(h->headers);
    free(h->url);
    free(h->body);
    free(h);
    curl_global_cleanup();

    return (code == CURLE_OK) ? status : -1l;
}
