/* HTTP primitives. The agent turn loop used to live here; it's now in
 * lua/psi/anthropic.lua. This file is intentionally minimal — just
 * libcurl plumbing for the HTTP operations Lua needs: a streamed POST
 * (for SSE Messages endpoint), buffered POST (one-shot completion),
 * and buffered GET (metadata refresh). The abort_signal hook is wired via curl's transfer-info
 * callback so UI cancellation bypasses any network stall. */

#include <stdlib.h>
#include <string.h>
#include <curl/curl.h>
#include "psi/abort.h"
#include "psi/http_buffered.h"
#include "psi/common.h"
#include "psi/http_async.h"

/* curl_slist_append returns NULL on failure without freeing the
 * prior list; this wrapper assigns through only on success. */
static int psi_http_slist_append_safe(struct curl_slist **list, const char *line) {
    struct curl_slist *next = curl_slist_append(*list, line);
    if (next == NULL)
        return PSI_STATUS_ERROR;
    *list = next;
    return PSI_STATUS_OK;
}

struct psi_http_buffer {
    char *data;
    size_t length;
};

static size_t psi_http_buffer_callback(void *contents, size_t size, size_t nmemb, void *userp) {
    struct psi_http_buffer *buffer = (struct psi_http_buffer *)userp;
    size_t total = size * nmemb;
    char *next;

    next = (char *)realloc(buffer->data, buffer->length + total + 1u);
    if (next == NULL) {
        return 0u;
    }
    buffer->data = next;
    memcpy(buffer->data + buffer->length, contents, total);
    buffer->length += total;
    buffer->data[buffer->length] = '\0';
    return total;
}

static int psi_http_xferinfo(
    void *clientp, curl_off_t dltotal, curl_off_t dlnow, curl_off_t ultotal, curl_off_t ulnow) {
    const struct psi_abort_signal *abort_signal = (const struct psi_abort_signal *)clientp;
    (void)dltotal;
    (void)dlnow;
    (void)ultotal;
    (void)ulnow;
    return psi_abort_signal_is_triggered(abort_signal) ? 1 : 0;
}

struct psi_http_chunk_ctx {
    psi_http_chunk_cb cb;
    void *userdata;
};

static size_t psi_http_chunk_forward(void *data, size_t size, size_t nmemb, void *userdata) {
    struct psi_http_chunk_ctx *ctx = (struct psi_http_chunk_ctx *)userdata;
    size_t total = size * nmemb;
    if (ctx->cb != NULL) {
        ctx->cb(ctx->userdata, (const char *)data, total);
    }
    return total;
}

static CURL *psi_http_build_handle(const char *url, const char *const *header_lines,
    size_t header_count, const char *body, size_t body_len, struct curl_slist **headers_out,
    const struct psi_abort_signal *abort_signal) {
    CURL *curl;
    struct curl_slist *headers = NULL;
    size_t i;

    curl = curl_easy_init();
    if (curl == NULL)
        return NULL;

    for (i = 0; i < header_count; i++) {
        if (psi_http_slist_append_safe(&headers, header_lines[i]) != PSI_STATUS_OK) {
            curl_slist_free_all(headers);
            curl_easy_cleanup(curl);
            return NULL;
        }
    }
    *headers_out = headers;

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    if (body != NULL) {
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)body_len);
    }
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, psi_http_xferinfo);
    /* curl stores an arbitrary opaque userdata; the const is safely
     * dropped here because psi_http_xferinfo re-casts to
     * const psi_abort_signal *. */
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, (void *)abort_signal);
    return curl;
}

int psi_http_post_stream(const char *url, const char *const *header_lines, size_t header_count,
    const char *body, size_t body_len, psi_http_chunk_cb on_chunk, void *userdata,
    const struct psi_abort_signal *abort_signal, long *status_code) {
    CURL *curl;
    CURLcode code;
    struct curl_slist *headers;
    struct psi_http_chunk_ctx ctx;

    if (status_code != NULL)
        *status_code = 0l;
    if (psi_http_global_init() != PSI_STATUS_OK)
        return PSI_STATUS_ERROR;
    curl = psi_http_build_handle(
        url, header_lines, header_count, body, body_len, &headers, abort_signal);
    if (curl == NULL)
        return PSI_STATUS_ERROR;

    ctx.cb = on_chunk;
    ctx.userdata = userdata;
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, psi_http_chunk_forward);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, (void *)&ctx);

    code = curl_easy_perform(curl);
    if (code == CURLE_OK && status_code != NULL) {
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, status_code);
    }

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    return (code == CURLE_OK) ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

int psi_http_post(const char *url, const char *const *header_lines, size_t header_count,
    const char *body, size_t body_len, const struct psi_abort_signal *abort_signal,
    long *status_code, char **response_body) {
    CURL *curl;
    CURLcode code;
    struct curl_slist *headers;
    struct psi_http_buffer buffer;

    if (status_code != NULL)
        *status_code = 0l;
    if (response_body != NULL)
        *response_body = NULL;
    buffer.data = NULL;
    buffer.length = 0u;

    if (psi_http_global_init() != PSI_STATUS_OK)
        return PSI_STATUS_ERROR;
    curl = psi_http_build_handle(
        url, header_lines, header_count, body, body_len, &headers, abort_signal);
    if (curl == NULL)
        return PSI_STATUS_ERROR;

    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, psi_http_buffer_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, (void *)&buffer);

    code = curl_easy_perform(curl);
    if (code == CURLE_OK && status_code != NULL) {
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, status_code);
    }

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);

    if (code != CURLE_OK) {
        free(buffer.data);
        return PSI_STATUS_ERROR;
    }
    if (response_body != NULL) {
        if (buffer.data != NULL) {
            *response_body = buffer.data;
        } else {
            *response_body = psi_strdup("");
            if (*response_body == NULL)
                return PSI_STATUS_ERROR;
        }
    } else {
        free(buffer.data);
    }
    return PSI_STATUS_OK;
}

int psi_http_get(const char *url, const char *const *header_lines, size_t header_count,
    const struct psi_abort_signal *abort_signal, long *status_code, char **response_body) {
    CURL *curl;
    CURLcode code;
    struct curl_slist *headers;
    struct psi_http_buffer buffer;

    if (status_code != NULL)
        *status_code = 0l;
    if (response_body != NULL)
        *response_body = NULL;
    buffer.data = NULL;
    buffer.length = 0u;

    if (psi_http_global_init() != PSI_STATUS_OK)
        return PSI_STATUS_ERROR;
    curl = psi_http_build_handle(url, header_lines, header_count, NULL, 0u, &headers, abort_signal);
    if (curl == NULL)
        return PSI_STATUS_ERROR;

    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, psi_http_buffer_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, (void *)&buffer);

    code = curl_easy_perform(curl);
    if (code == CURLE_OK && status_code != NULL) {
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, status_code);
    }

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);

    if (code != CURLE_OK) {
        free(buffer.data);
        return PSI_STATUS_ERROR;
    }
    if (response_body != NULL) {
        if (buffer.data != NULL) {
            *response_body = buffer.data;
        } else {
            *response_body = psi_strdup("");
            if (*response_body == NULL)
                return PSI_STATUS_ERROR;
        }
    } else {
        free(buffer.data);
    }
    return PSI_STATUS_OK;
}
