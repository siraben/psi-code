/* Minimal C-native agent turn driver.
 *
 * The Lua agent loop (provider_loop + agent_session + anthropic) is
 * the right design on the desktop, but on ESP32 it allocates a lot
 * during the turn — reading messages, building JSON, parsing SSE,
 * accumulating tool-call args — and Lua's GC (especially across
 * PSRAM) has been unstable in QEMU. For embedded targets we want a
 * smaller, allocation-light path.
 *
 * This file implements `psi_esp_agent_turn()`:
 *
 *   1. Build a minimal Anthropic /v1/messages JSON request from the
 *      user text + model + max_tokens (no tools, no system prompt
 *      yet — those can grow later).
 *   2. POST it via esp_http_client with SSE streaming.
 *   3. Parse SSE event/data lines on the fly, never buffering more
 *      than one event payload.
 *   4. For each `content_block_delta` with `type:text_delta`, push
 *      the text to the WebSocket observer.
 *   5. On `message_stop` (or stream end), fire `on_turn_end`.
 *
 * cJSON is the only allocator we lean on for the per-event parse. No
 * intermediate Lua state, no heap-resident message history beyond
 * the single JSON body we send.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "esp_crt_bundle.h"
#include "esp_err.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"

#include "psi/abort.h"
#include "psi/agent_runtime.h"
#include "psi/common.h"

static const char *TAG = "psi_agent";

/* ------------------------------------------------------------------ */
/* SSE line parser                                                     */
/* ------------------------------------------------------------------ */

struct sse_state {
    char event[64];
    char *data;       /* growable; one frame's worth */
    size_t data_len;
    size_t data_cap;
    char line[1024];  /* current line buffer */
    size_t line_len;
    /* Saved across chunks: a partial line at the end of one chunk
     * has to merge with the start of the next. */
};

static void sse_init(struct sse_state *s) {
    memset(s, 0, sizeof(*s));
}

static void sse_reset(struct sse_state *s) {
    free(s->data);
    s->data = NULL;
    s->data_len = 0;
    s->data_cap = 0;
    s->event[0] = '\0';
}

static void sse_destroy(struct sse_state *s) {
    sse_reset(s);
}

static int sse_data_append(struct sse_state *s, const char *bytes, size_t len) {
    size_t need = s->data_len + len + 1u;
    if (need > s->data_cap) {
        size_t cap = s->data_cap ? s->data_cap * 2u : 256u;
        char *n;
        while (cap < need)
            cap *= 2u;
        n = (char *)realloc(s->data, cap);
        if (n == NULL)
            return -1;
        s->data = n;
        s->data_cap = cap;
    }
    memcpy(s->data + s->data_len, bytes, len);
    s->data_len += len;
    s->data[s->data_len] = '\0';
    return 0;
}

/* Process one SSE frame: dispatch to the agent observer based on the
 * `event:` and `data:` accumulated so far. Returns 0 normally, 1 on
 * message_stop (stream complete). */
static int sse_dispatch(struct sse_state *s, struct psi_agent_observer *obs) {
    cJSON *root;
    cJSON *type_node;
    const char *type_str;

    if (s->data_len == 0u) {
        sse_reset(s);
        return 0;
    }
    root = cJSON_Parse(s->data);
    if (root == NULL) {
        ESP_LOGW(TAG, "failed to parse sse data: %.80s", s->data);
        sse_reset(s);
        return 0;
    }

    type_node = cJSON_GetObjectItemCaseSensitive(root, "type");
    type_str = (cJSON_IsString(type_node) && type_node->valuestring) ? type_node->valuestring : "";

    if (strcmp(type_str, "content_block_delta") == 0) {
        cJSON *delta = cJSON_GetObjectItemCaseSensitive(root, "delta");
        cJSON *delta_type = cJSON_GetObjectItemCaseSensitive(delta, "type");
        if (cJSON_IsString(delta_type) && delta_type->valuestring &&
            strcmp(delta_type->valuestring, "text_delta") == 0) {
            cJSON *text = cJSON_GetObjectItemCaseSensitive(delta, "text");
            if (cJSON_IsString(text) && text->valuestring && obs != NULL &&
                obs->on_assistant_text_delta != NULL) {
                obs->on_assistant_text_delta(obs->userdata, text->valuestring);
            }
        } else if (cJSON_IsString(delta_type) && delta_type->valuestring &&
                   strcmp(delta_type->valuestring, "thinking_delta") == 0) {
            cJSON *text = cJSON_GetObjectItemCaseSensitive(delta, "thinking");
            if (cJSON_IsString(text) && text->valuestring && obs != NULL &&
                obs->on_thinking_delta != NULL) {
                obs->on_thinking_delta(obs->userdata, text->valuestring);
            }
        }
    } else if (strcmp(type_str, "message_stop") == 0) {
        cJSON_Delete(root);
        sse_reset(s);
        return 1;
    } else if (strcmp(type_str, "error") == 0) {
        cJSON *err = cJSON_GetObjectItemCaseSensitive(root, "error");
        cJSON *msg = cJSON_GetObjectItemCaseSensitive(err, "message");
        const char *m = (cJSON_IsString(msg) && msg->valuestring) ? msg->valuestring
                                                                  : "anthropic error";
        if (obs != NULL && obs->on_assistant_text_delta != NULL) {
            char buf[256];
            int n = snprintf(buf, sizeof(buf), "\n[error] %s\n", m);
            (void)n;
            obs->on_assistant_text_delta(obs->userdata, buf);
        }
    }

    cJSON_Delete(root);
    sse_reset(s);
    return 0;
}

/* Consume one logical line. */
static int sse_handle_line(struct sse_state *s, struct psi_agent_observer *obs) {
    char *line = s->line;
    size_t len = s->line_len;
    /* Strip trailing \r if present. */
    if (len > 0u && line[len - 1u] == '\r') {
        line[len - 1u] = '\0';
        len--;
    }
    line[len] = '\0';

    if (len == 0u) {
        /* Blank line dispatches the accumulated frame. */
        int done = sse_dispatch(s, obs);
        s->line_len = 0u;
        return done;
    }
    if (len >= 7u && memcmp(line, "event: ", 7u) == 0) {
        size_t n = len - 7u;
        if (n >= sizeof(s->event))
            n = sizeof(s->event) - 1u;
        memcpy(s->event, line + 7u, n);
        s->event[n] = '\0';
    } else if (len >= 6u && memcmp(line, "data: ", 6u) == 0) {
        if (s->data_len > 0u) {
            (void)sse_data_append(s, "\n", 1u);
        }
        (void)sse_data_append(s, line + 6u, len - 6u);
    } else if (len >= 5u && memcmp(line, "data:", 5u) == 0) {
        const char *p = line + 5u;
        size_t n = len - 5u;
        if (n > 0u && p[0] == ' ') {
            p++;
            n--;
        }
        if (s->data_len > 0u) {
            (void)sse_data_append(s, "\n", 1u);
        }
        (void)sse_data_append(s, p, n);
    }
    /* Unknown line types (id:, retry:, comments) are ignored. */
    s->line_len = 0u;
    return 0;
}

static void sse_feed(struct sse_state *s, const char *bytes, size_t len,
    struct psi_agent_observer *obs, int *done_out) {
    size_t i;
    for (i = 0u; i < len; i++) {
        char c = bytes[i];
        if (c == '\n') {
            int done = sse_handle_line(s, obs);
            if (done && done_out)
                *done_out = 1;
        } else {
            if (s->line_len + 1u >= sizeof(s->line)) {
                /* Line too long; reset and drop. */
                s->line_len = 0u;
                continue;
            }
            s->line[s->line_len++] = c;
        }
    }
}

/* ------------------------------------------------------------------ */
/* esp_http_client event glue                                          */
/* ------------------------------------------------------------------ */

struct agent_ctx {
    struct sse_state sse;
    struct psi_agent_observer *observer;
    const struct psi_abort_signal *abort_signal;
    int aborted;
    int sse_done;
};

static esp_err_t agent_http_event_cb(esp_http_client_event_t *evt) {
    struct agent_ctx *ctx = (struct agent_ctx *)evt->user_data;
    if (ctx == NULL)
        return ESP_OK;
    if (evt->event_id != HTTP_EVENT_ON_DATA)
        return ESP_OK;
    if (ctx->abort_signal != NULL && psi_abort_signal_is_triggered(ctx->abort_signal)) {
        ctx->aborted = 1;
        return ESP_FAIL;
    }
    if (evt->data_len <= 0)
        return ESP_OK;
    sse_feed(&ctx->sse, (const char *)evt->data, (size_t)evt->data_len, ctx->observer,
        &ctx->sse_done);
    return ESP_OK;
}

/* ------------------------------------------------------------------ */
/* Public entrypoint                                                   */
/* ------------------------------------------------------------------ */

int psi_esp_agent_turn(const char *user_text, const char *system_prompt, const char *model,
    long max_tokens, struct psi_agent_observer *observer,
    struct psi_abort_signal *abort_signal, char **error_message) {
    cJSON *root;
    cJSON *messages;
    cJSON *user_msg;
    char *body = NULL;
    int body_len = 0;
    esp_http_client_config_t cfg;
    esp_http_client_handle_t cli;
    esp_err_t err;
    struct agent_ctx ctx;
    const char *api_key = getenv("ANTHROPIC_API_KEY");
    char auth_header[256];
    int rc = PSI_STATUS_ERROR;

    if (error_message != NULL)
        *error_message = NULL;
    if (api_key == NULL || *api_key == '\0') {
        if (error_message != NULL)
            *error_message = psi_strdup("ANTHROPIC_API_KEY not set");
        return PSI_STATUS_ERROR;
    }

    /* ---- Build request JSON ---- */
    root = cJSON_CreateObject();
    if (root == NULL)
        return PSI_STATUS_ERROR;
    cJSON_AddStringToObject(root, "model", model != NULL ? model : "claude-haiku-4-5");
    cJSON_AddNumberToObject(root, "max_tokens", (double)max_tokens);
    cJSON_AddTrueToObject(root, "stream");
    if (system_prompt != NULL && *system_prompt != '\0') {
        cJSON_AddStringToObject(root, "system", system_prompt);
    }
    messages = cJSON_AddArrayToObject(root, "messages");
    user_msg = cJSON_CreateObject();
    cJSON_AddStringToObject(user_msg, "role", "user");
    cJSON_AddStringToObject(user_msg, "content", user_text != NULL ? user_text : "");
    cJSON_AddItemToArray(messages, user_msg);

    body = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    if (body == NULL) {
        if (error_message != NULL)
            *error_message = psi_strdup("failed to encode request");
        return PSI_STATUS_ERROR;
    }
    body_len = (int)strlen(body);

    /* ---- Set up streaming HTTP client ---- */
    sse_init(&ctx.sse);
    ctx.observer = observer;
    ctx.abort_signal = abort_signal;
    ctx.aborted = 0;
    ctx.sse_done = 0;

    memset(&cfg, 0, sizeof(cfg));
    cfg.url = "https://api.anthropic.com/v1/messages";
    cfg.method = HTTP_METHOD_POST;
    cfg.event_handler = agent_http_event_cb;
    cfg.user_data = &ctx;
    cfg.timeout_ms = 60000;
    cfg.crt_bundle_attach = esp_crt_bundle_attach;
    cfg.buffer_size = 4096;
    cfg.buffer_size_tx = 4096;

    cli = esp_http_client_init(&cfg);
    if (cli == NULL) {
        free(body);
        sse_destroy(&ctx.sse);
        if (error_message != NULL)
            *error_message = psi_strdup("esp_http_client_init failed");
        return PSI_STATUS_ERROR;
    }

    snprintf(auth_header, sizeof(auth_header), "%s", api_key);
    esp_http_client_set_header(cli, "x-api-key", auth_header);
    esp_http_client_set_header(cli, "anthropic-version", "2023-06-01");
    esp_http_client_set_header(cli, "content-type", "application/json");
    esp_http_client_set_header(cli, "accept", "text/event-stream");
    esp_http_client_set_post_field(cli, body, body_len);

    err = esp_http_client_perform(cli);
    {
        int status = esp_http_client_get_status_code(cli);
        ESP_LOGI(TAG, "anthropic response: err=%s status=%d", esp_err_to_name(err), status);
        if (err != ESP_OK || status < 200 || status >= 300) {
            if (error_message != NULL) {
                char buf[128];
                snprintf(buf, sizeof(buf), "anthropic %s status=%d",
                    esp_err_to_name(err), status);
                *error_message = psi_strdup(buf);
            }
            rc = PSI_STATUS_ERROR;
        } else {
            rc = PSI_STATUS_OK;
        }
    }

    esp_http_client_cleanup(cli);
    free(body);
    sse_destroy(&ctx.sse);

    if (rc == PSI_STATUS_OK && observer != NULL && observer->on_turn_end != NULL) {
        observer->on_turn_end(observer->userdata);
    }
    return rc;
}
