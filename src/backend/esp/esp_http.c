/* ESP-IDF HTTP backend.
 *
 * Implements the same psi_http_buffered.h and psi_http_async.h public
 * interfaces as the libcurl backend in src/core/http_*.c, but on top
 * of esp_http_client + ESP-IDF's mbedTLS. The Lua provider loop is
 * portable across both — it only sees the headers in include/psi/.
 *
 * Buffered POST/GET: blocking, runs on the calling task. Streaming
 * uses one FreeRTOS worker task per stream that drives
 * esp_http_client_perform; chunks are pushed through a per-handle
 * FreeRTOS queue. Cancellation: the abort_signal flag is checked from
 * the HTTP_EVENT_ON_DATA event handler; if set, we return
 * ESP_FAIL which aborts the transfer.
 *
 * This file is compiled with -std=gnu99 by the ESP-IDF component
 * because esp_http_client headers use C99 features. The body still
 * sticks to C89 syntax so the rest of the project keeps the strict
 * dialect.
 */

#ifndef PSI_HTTP_BACKEND_CURL
#define PSI_HTTP_BACKEND_CURL 0
#endif

#if !PSI_HTTP_BACKEND_CURL

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "esp_err.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "esp_tls.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "freertos/event_groups.h"

#include "psi/abort.h"
#include "psi/common.h"
#include "psi/http_async.h"
#include "psi/http_buffered.h"

static const char *TAG = "psi_http";

/* The libcurl backend does a one-shot global init; esp_http_client
 * has no analog. We keep the public API for source compatibility with
 * desktop callers but make it a no-op here. */
int psi_http_global_init(void) {
    return PSI_STATUS_OK;
}

/* ------------------------------------------------------------------ */
/* Buffered helpers                                                    */
/* ------------------------------------------------------------------ */

struct psi_buf_collector {
    char *data;
    size_t len;
    size_t cap;
    int oom;
    const struct psi_abort_signal *abort_signal;
    int aborted;
};

static esp_err_t psi_buf_event_cb(esp_http_client_event_t *evt) {
    struct psi_buf_collector *c = (struct psi_buf_collector *)evt->user_data;
    if (evt->event_id != HTTP_EVENT_ON_DATA)
        return ESP_OK;
    if (c == NULL)
        return ESP_OK;
    if (c->abort_signal != NULL && psi_abort_signal_is_triggered(c->abort_signal)) {
        c->aborted = 1;
        return ESP_FAIL;
    }
    {
        size_t need = c->len + (size_t)evt->data_len + 1u;
        if (need > c->cap) {
            size_t next_cap = c->cap == 0u ? 4096u : c->cap * 2u;
            char *n;
            while (next_cap < need)
                next_cap *= 2u;
            n = (char *)realloc(c->data, next_cap);
            if (n == NULL) {
                c->oom = 1;
                return ESP_FAIL;
            }
            c->data = n;
            c->cap = next_cap;
        }
        memcpy(c->data + c->len, evt->data, (size_t)evt->data_len);
        c->len += (size_t)evt->data_len;
        c->data[c->len] = '\0';
    }
    return ESP_OK;
}

static void psi_apply_headers(esp_http_client_handle_t client,
    const char *const *header_lines, size_t header_count) {
    size_t i;
    for (i = 0u; i < header_count; i++) {
        const char *line = header_lines[i];
        const char *colon;
        char *name;
        const char *value;
        size_t name_len;
        if (line == NULL)
            continue;
        colon = strchr(line, ':');
        if (colon == NULL)
            continue;
        name_len = (size_t)(colon - line);
        name = (char *)malloc(name_len + 1u);
        if (name == NULL)
            continue;
        memcpy(name, line, name_len);
        name[name_len] = '\0';
        value = colon + 1;
        while (*value == ' ' || *value == '\t')
            value++;
        esp_http_client_set_header(client, name, value);
        free(name);
    }
}

static int psi_buffered_perform(esp_http_method_t method, const char *url,
    const char *const *header_lines, size_t header_count, const char *body, size_t body_len,
    const struct psi_abort_signal *abort_signal, long *status_code, char **response_body,
    char **error_message) {
    struct psi_buf_collector collector;
    esp_http_client_config_t cfg;
    esp_http_client_handle_t client;
    esp_err_t err;

    memset(&collector, 0, sizeof(collector));
    collector.abort_signal = abort_signal;

    memset(&cfg, 0, sizeof(cfg));
    cfg.url = url;
    cfg.method = method;
    cfg.event_handler = psi_buf_event_cb;
    cfg.user_data = &collector;
    cfg.timeout_ms = 60000;
    cfg.crt_bundle_attach = esp_crt_bundle_attach;

    client = esp_http_client_init(&cfg);
    if (client == NULL) {
        if (error_message != NULL)
            *error_message = psi_strdup("esp_http_client_init failed");
        return PSI_STATUS_ERROR;
    }

    psi_apply_headers(client, header_lines, header_count);
    if (body != NULL && body_len > 0u) {
        esp_http_client_set_post_field(client, body, (int)body_len);
    }

    err = esp_http_client_perform(client);
    if (status_code != NULL)
        *status_code = (long)esp_http_client_get_status_code(client);
    esp_http_client_cleanup(client);

    if (collector.oom) {
        free(collector.data);
        if (error_message != NULL)
            *error_message = psi_strdup("out of memory while reading response");
        return PSI_STATUS_ERROR;
    }
    if (collector.aborted) {
        free(collector.data);
        if (error_message != NULL)
            *error_message = psi_strdup("aborted");
        return PSI_STATUS_ERROR;
    }
    if (err != ESP_OK) {
        free(collector.data);
        if (error_message != NULL)
            *error_message = psi_strdup(esp_err_to_name(err));
        return PSI_STATUS_ERROR;
    }

    if (response_body != NULL) {
        *response_body = collector.data;
    } else {
        free(collector.data);
    }
    return PSI_STATUS_OK;
}

int psi_http_post(const char *url, const char *const *header_lines, size_t header_count,
    const char *body, size_t body_len, const struct psi_abort_signal *abort_signal,
    long *status_code, char **response_body, char **error_message) {
    return psi_buffered_perform(HTTP_METHOD_POST, url, header_lines, header_count, body, body_len,
        abort_signal, status_code, response_body, error_message);
}

int psi_http_get(const char *url, const char *const *header_lines, size_t header_count,
    const struct psi_abort_signal *abort_signal, long *status_code, char **response_body,
    char **error_message) {
    return psi_buffered_perform(HTTP_METHOD_GET, url, header_lines, header_count, NULL, 0u,
        abort_signal, status_code, response_body, error_message);
}

/* ------------------------------------------------------------------ */
/* Streaming                                                           */
/* ------------------------------------------------------------------ */

struct psi_http_chunk {
    char *bytes;
    size_t len;
};

#define PSI_STREAM_QUEUE_DEPTH 16

#define PSI_STREAM_BIT_DONE 0x01u
#define PSI_STREAM_BIT_CHUNK 0x02u

struct psi_http_stream {
    TaskHandle_t task;
    QueueHandle_t queue;
    EventGroupHandle_t flags;
    const struct psi_abort_signal *abort_signal;
    int aborted;
    int oom;
    char *url;
    char **headers;
    size_t header_count;
    char *body;
    size_t body_len;
    long status;
    char *error_message;
    int finished;
};

static void psi_stream_free_strings(char **arr, size_t n) {
    size_t i;
    if (arr == NULL)
        return;
    for (i = 0u; i < n; i++)
        free(arr[i]);
    free(arr);
}

static esp_err_t psi_stream_event_cb(esp_http_client_event_t *evt) {
    struct psi_http_stream *h = (struct psi_http_stream *)evt->user_data;
    struct psi_http_chunk chunk;
    if (h == NULL)
        return ESP_OK;
    if (evt->event_id != HTTP_EVENT_ON_DATA)
        return ESP_OK;
    if (h->abort_signal != NULL && psi_abort_signal_is_triggered(h->abort_signal)) {
        h->aborted = 1;
        return ESP_FAIL;
    }
    if (evt->data_len <= 0)
        return ESP_OK;
    chunk.bytes = (char *)malloc((size_t)evt->data_len);
    if (chunk.bytes == NULL) {
        h->oom = 1;
        return ESP_FAIL;
    }
    memcpy(chunk.bytes, evt->data, (size_t)evt->data_len);
    chunk.len = (size_t)evt->data_len;
    if (xQueueSend(h->queue, &chunk, portMAX_DELAY) != pdTRUE) {
        free(chunk.bytes);
        h->oom = 1;
        return ESP_FAIL;
    }
    xEventGroupSetBits(h->flags, PSI_STREAM_BIT_CHUNK);
    return ESP_OK;
}

static void psi_stream_worker(void *arg) {
    struct psi_http_stream *h = (struct psi_http_stream *)arg;
    esp_http_client_config_t cfg;
    esp_http_client_handle_t client;
    esp_err_t err;
    size_t i;

    memset(&cfg, 0, sizeof(cfg));
    cfg.url = h->url;
    cfg.method = HTTP_METHOD_POST;
    cfg.event_handler = psi_stream_event_cb;
    cfg.user_data = h;
    cfg.timeout_ms = 0; /* no overall timeout; abort flag handles cancel */
    cfg.crt_bundle_attach = esp_crt_bundle_attach;
    cfg.buffer_size = 4096;
    cfg.buffer_size_tx = 4096;

    client = esp_http_client_init(&cfg);
    if (client == NULL) {
        h->error_message = psi_strdup("esp_http_client_init failed");
        h->status = -1;
        goto done;
    }

    for (i = 0u; i < h->header_count; i++) {
        const char *line = h->headers[i];
        const char *colon;
        char *name;
        const char *value;
        size_t name_len;
        if (line == NULL)
            continue;
        colon = strchr(line, ':');
        if (colon == NULL)
            continue;
        name_len = (size_t)(colon - line);
        name = (char *)malloc(name_len + 1u);
        if (name == NULL)
            continue;
        memcpy(name, line, name_len);
        name[name_len] = '\0';
        value = colon + 1;
        while (*value == ' ' || *value == '\t')
            value++;
        esp_http_client_set_header(client, name, value);
        free(name);
    }
    if (h->body != NULL && h->body_len > 0u) {
        esp_http_client_set_post_field(client, h->body, (int)h->body_len);
    }

    err = esp_http_client_perform(client);
    h->status = (long)esp_http_client_get_status_code(client);
    if (err != ESP_OK && !h->aborted) {
        h->error_message = psi_strdup(esp_err_to_name(err));
        if (h->status == 0)
            h->status = -1;
    }
    if (h->aborted && h->error_message == NULL)
        h->error_message = psi_strdup("aborted");

    esp_http_client_cleanup(client);

done:
    xEventGroupSetBits(h->flags, PSI_STREAM_BIT_DONE);
    vTaskDelete(NULL);
}

int psi_http_stream_begin(const char *url, const char *const *header_lines, size_t header_count,
    const char *body, size_t body_len, const struct psi_abort_signal *abort_signal,
    struct psi_http_stream **out) {
    struct psi_http_stream *h;
    size_t i;
    BaseType_t rc;

    if (out == NULL)
        return PSI_STATUS_ERROR;
    *out = NULL;

    h = (struct psi_http_stream *)calloc(1u, sizeof(*h));
    if (h == NULL)
        return PSI_STATUS_ERROR;
    h->abort_signal = abort_signal;
    h->status = -1;

    h->url = psi_strdup(url);
    if (h->url == NULL)
        goto fail;

    if (header_count > 0u) {
        h->headers = (char **)calloc(header_count, sizeof(char *));
        if (h->headers == NULL)
            goto fail;
        for (i = 0u; i < header_count; i++) {
            h->headers[i] = psi_strdup(header_lines[i] != NULL ? header_lines[i] : "");
            if (h->headers[i] == NULL)
                goto fail;
        }
        h->header_count = header_count;
    }

    if (body != NULL && body_len > 0u) {
        h->body = (char *)malloc(body_len);
        if (h->body == NULL)
            goto fail;
        memcpy(h->body, body, body_len);
        h->body_len = body_len;
    }

    h->queue = xQueueCreate(PSI_STREAM_QUEUE_DEPTH, sizeof(struct psi_http_chunk));
    if (h->queue == NULL)
        goto fail;
    h->flags = xEventGroupCreate();
    if (h->flags == NULL)
        goto fail;

    rc = xTaskCreate(psi_stream_worker, "psi_http", 8192, h, tskIDLE_PRIORITY + 5, &h->task);
    if (rc != pdPASS)
        goto fail;

    *out = h;
    return PSI_STATUS_OK;

fail:
    if (h != NULL) {
        if (h->flags != NULL)
            vEventGroupDelete(h->flags);
        if (h->queue != NULL)
            vQueueDelete(h->queue);
        free(h->body);
        psi_stream_free_strings(h->headers, h->header_count);
        free(h->url);
        free(h);
    }
    return PSI_STATUS_ERROR;
}

int psi_http_stream_poll(
    struct psi_http_stream *h, int timeout_ms, char **chunk, size_t *chunk_len) {
    struct psi_http_chunk c;
    TickType_t wait;
    BaseType_t got;
    EventBits_t bits;

    if (h == NULL)
        return 2;
    if (chunk != NULL)
        *chunk = NULL;
    if (chunk_len != NULL)
        *chunk_len = 0u;

    wait = (timeout_ms < 0)
               ? portMAX_DELAY
               : (TickType_t)(timeout_ms / portTICK_PERIOD_MS) + (timeout_ms > 0 ? 1u : 0u);

    got = xQueueReceive(h->queue, &c, wait);
    if (got == pdTRUE) {
        if (chunk != NULL)
            *chunk = c.bytes;
        else
            free(c.bytes);
        if (chunk_len != NULL)
            *chunk_len = c.len;
        return 1;
    }

    bits = xEventGroupGetBits(h->flags);
    if ((bits & PSI_STREAM_BIT_DONE) != 0u) {
        /* Drain any chunks the producer queued before we observed the
         * done bit so the caller doesn't lose tail bytes. */
        if (xQueueReceive(h->queue, &c, 0) == pdTRUE) {
            if (chunk != NULL)
                *chunk = c.bytes;
            else
                free(c.bytes);
            if (chunk_len != NULL)
                *chunk_len = c.len;
            return 1;
        }
        return 2;
    }
    return 0;
}

long psi_http_stream_finish(struct psi_http_stream *h, char **error_message) {
    long status;
    if (h == NULL) {
        if (error_message != NULL)
            *error_message = NULL;
        return -1;
    }

    /* Wait for the worker to flag completion. The worker self-deletes
     * after setting the bit so we just observe the flag. */
    xEventGroupWaitBits(h->flags, PSI_STREAM_BIT_DONE, pdFALSE, pdTRUE, portMAX_DELAY);

    /* Drain any leftover chunks. */
    {
        struct psi_http_chunk c;
        while (xQueueReceive(h->queue, &c, 0) == pdTRUE) {
            free(c.bytes);
        }
    }

    status = h->status;
    if (error_message != NULL) {
        *error_message = h->error_message;
        h->error_message = NULL;
    } else {
        free(h->error_message);
    }
    free(h->error_message);
    free(h->body);
    psi_stream_free_strings(h->headers, h->header_count);
    free(h->url);
    vQueueDelete(h->queue);
    vEventGroupDelete(h->flags);
    free(h);
    return status;
}

long psi_http_stream_finish_owned(struct psi_http_stream **slot, char **error_message) {
    struct psi_http_stream *h;
    if (slot == NULL || *slot == NULL) {
        if (error_message != NULL)
            *error_message = NULL;
        return 0;
    }
    h = *slot;
    *slot = NULL;
    return psi_http_stream_finish(h, error_message);
}

#endif /* !PSI_HTTP_BACKEND_CURL */
