/* HTTP primitives. Provider loops live in Lua; this file is intentionally
 * small libcurl plumbing that can service both model providers and
 * ordinary network tools. */

#include <stdlib.h>
#include <string.h>
#include <curl/curl.h>
#include "psi/abort.h"
#include "psi/common.h"
#include "psi/http_client.h"

static const long PSI_HTTP_DEFAULT_TIMEOUT_MS = 30000l;
static const long PSI_HTTP_DEFAULT_MAX_RESPONSE_BYTES = 1048576l;

struct psi_http_buffer {
    char *data;
    size_t length;
    size_t max_length;
    int overflowed;
};

static size_t psi_http_buffer_callback(void *contents, size_t size, size_t nmemb, void *userp) {
    struct psi_http_buffer *buffer = (struct psi_http_buffer *)userp;
    size_t total = size * nmemb;
    char *next;

    if (buffer->max_length > 0u && buffer->length + total > buffer->max_length) {
        buffer->overflowed = 1;
        return 0u;
    }

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
    void *clientp,
    curl_off_t dltotal, curl_off_t dlnow,
    curl_off_t ultotal, curl_off_t ulnow
) {
    const struct psi_abort_signal *abort_signal = (const struct psi_abort_signal *)clientp;
    PSI_UNUSED(dltotal);
    PSI_UNUSED(dlnow);
    PSI_UNUSED(ultotal);
    PSI_UNUSED(ulnow);
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

static const char *psi_http_method_or_default(const struct psi_http_request_options *request) {
    if (request == NULL || request->method == NULL || request->method[0] == '\0') {
        return (request != NULL && request->body != NULL && request->body_len > 0u) ? "POST" : "GET";
    }
    return request->method;
}

static int psi_http_apply_method(CURL *curl, const char *method, const char *body, size_t body_len) {
    if (strcmp(method, "GET") == 0) {
        curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
        return PSI_STATUS_OK;
    }
    if (strcmp(method, "POST") == 0) {
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body != NULL ? body : "");
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)body_len);
        return PSI_STATUS_OK;
    }

    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
    if (body != NULL && body_len > 0u) {
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)body_len);
    }
    return PSI_STATUS_OK;
}

static CURL *psi_http_build_handle(
    const struct psi_http_request_options *request,
    struct curl_slist **headers_out,
    const struct psi_abort_signal *abort_signal
) {
    CURL *curl;
    struct curl_slist *headers = NULL;
    const char *method;
    long timeout_ms;
    size_t i;

    if (request == NULL || request->url == NULL) return NULL;

    curl = curl_easy_init();
    if (curl == NULL) return NULL;

    for (i = 0; i < request->header_count; i++) {
        headers = curl_slist_append(headers, request->header_lines[i]);
    }
    *headers_out = headers;

    method = psi_http_method_or_default(request);
    timeout_ms = request->timeout_ms > 0l ? request->timeout_ms : PSI_HTTP_DEFAULT_TIMEOUT_MS;

    curl_easy_setopt(curl, CURLOPT_URL, request->url);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, timeout_ms);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, psi_http_xferinfo);
    /* curl stores an arbitrary opaque userdata; the const is safely
     * dropped here because psi_http_xferinfo re-casts to
     * const psi_abort_signal *. */
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, (void *)abort_signal);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "psi/" PSI_VERSION);

    if (psi_http_apply_method(curl, method, request->body, request->body_len) != PSI_STATUS_OK) {
        curl_slist_free_all(headers);
        curl_easy_cleanup(curl);
        *headers_out = NULL;
        return NULL;
    }
    return curl;
}

static char *psi_http_error_message(CURLcode code, const struct psi_http_buffer *buffer) {
    if (buffer != NULL && buffer->overflowed) {
        return psi_strdup("http response exceeded max_response_bytes");
    }
    return psi_strdup(curl_easy_strerror(code));
}

int psi_http_request(
    const struct psi_http_request_options *request,
    const struct psi_abort_signal *abort_signal,
    long *status_code,
    char **response_body
) {
    CURL *curl;
    CURLcode code;
    struct curl_slist *headers;
    struct psi_http_buffer buffer;

    if (status_code != NULL) *status_code = 0l;
    if (response_body != NULL) *response_body = NULL;
    buffer.data = NULL;
    buffer.length = 0u;
    buffer.max_length =
        request != NULL && request->max_response_bytes > 0l
            ? (size_t)request->max_response_bytes
            : (size_t)PSI_HTTP_DEFAULT_MAX_RESPONSE_BYTES;
    buffer.overflowed = 0;

    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) {
        if (response_body != NULL) *response_body = psi_strdup("curl_global_init failed");
        return PSI_STATUS_ERROR;
    }

    headers = NULL;
    curl = psi_http_build_handle(request, &headers, abort_signal);
    if (curl == NULL) {
        curl_global_cleanup();
        if (response_body != NULL) *response_body = psi_strdup("failed to initialize http request");
        return PSI_STATUS_ERROR;
    }

    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, psi_http_buffer_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, (void *)&buffer);

    code = curl_easy_perform(curl);
    if (code == CURLE_OK && status_code != NULL) {
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, status_code);
    }

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    curl_global_cleanup();

    if (code != CURLE_OK) {
        if (response_body != NULL) {
            *response_body = psi_http_error_message(code, &buffer);
        }
        free(buffer.data);
        return PSI_STATUS_ERROR;
    }
    if (response_body != NULL) {
        *response_body = buffer.data != NULL ? buffer.data : psi_strdup("");
    } else {
        free(buffer.data);
    }
    return PSI_STATUS_OK;
}

int psi_http_post_stream(
    const char *url,
    const char *const *header_lines, size_t header_count,
    const char *body, size_t body_len,
    psi_http_chunk_cb on_chunk, void *userdata,
    const struct psi_abort_signal *abort_signal,
    long *status_code
) {
    CURL *curl;
    CURLcode code;
    struct curl_slist *headers;
    struct psi_http_chunk_ctx ctx;
    struct psi_http_request_options request;

    if (status_code != NULL) *status_code = 0l;
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) return PSI_STATUS_ERROR;

    request.method = "POST";
    request.url = url;
    request.header_lines = header_lines;
    request.header_count = header_count;
    request.body = body;
    request.body_len = body_len;
    request.timeout_ms = PSI_HTTP_DEFAULT_TIMEOUT_MS;
    request.max_response_bytes = 0l;

    headers = NULL;
    curl = psi_http_build_handle(&request, &headers, abort_signal);
    if (curl == NULL) {
        curl_global_cleanup();
        return PSI_STATUS_ERROR;
    }

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
    curl_global_cleanup();
    return (code == CURLE_OK) ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

int psi_http_post(
    const char *url,
    const char *const *header_lines, size_t header_count,
    const char *body, size_t body_len,
    const struct psi_abort_signal *abort_signal,
    long *status_code, char **response_body
) {
    struct psi_http_request_options request;

    request.method = "POST";
    request.url = url;
    request.header_lines = header_lines;
    request.header_count = header_count;
    request.body = body;
    request.body_len = body_len;
    request.timeout_ms = PSI_HTTP_DEFAULT_TIMEOUT_MS;
    request.max_response_bytes = PSI_HTTP_DEFAULT_MAX_RESPONSE_BYTES;
    return psi_http_request(&request, abort_signal, status_code, response_body);
}
