/* C-native Anthropic agent loop with tool-use support.
 *
 * The architecture mirrors what `lua/psi/provider_loop.lua` does on
 * the desktop, but in ~600 lines of C with no Lua state on the hot
 * path:
 *
 *   1. Build a /v1/messages JSON request from the user text + model
 *      + cached system prompt + accumulated history. The `tools`
 *      field is populated from psi_esp_tool_table.
 *   2. POST via esp_http_client with SSE streaming. As each frame
 *      arrives, route content_block_start / delta / stop into a
 *      per-block accumulator (text, thinking, or tool_use).
 *   3. On message_stop: collect the assistant message's blocks. If
 *      any are tool_use, dispatch each via psi_esp_tool_find, build
 *      a tool_result content array, append both messages to the
 *      history, and POST again. Loop until no tool_use blocks remain
 *      (or stop_reason != "tool_use").
 *   4. Forward text_delta / thinking_delta to the observer as they
 *      stream so the SPA renders progressively.
 *   5. Fire on_turn_end once the model returns without requesting
 *      more tools.
 *
 * cJSON is the only allocator beyond per-frame buffers. The history
 * lives as a cJSON array we extend turn-by-turn; we delete it once
 * the loop terminates.
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

#include "esp_tools.h"

static const char *TAG = "psi_agent";

/* Hard cap on tool-use round-trips per user turn. Anthropic doesn't
 * loop on its own but a model that keeps requesting tools could; we
 * stop after this many follow-ups and tell the SPA to look at the
 * partial reply. */
#define PSI_AGENT_MAX_ROUNDS 8

/* ------------------------------------------------------------------ */
/* growable byte buffer                                                 */
/* ------------------------------------------------------------------ */

struct buf {
    char *data;
    size_t len;
    size_t cap;
};

static int buf_append(struct buf *b, const char *bytes, size_t n) {
    size_t need = b->len + n + 1u;
    if (need > b->cap) {
        size_t cap = b->cap ? b->cap * 2u : 256u;
        char *p;
        while (cap < need)
            cap *= 2u;
        p = (char *)realloc(b->data, cap);
        if (p == NULL)
            return -1;
        b->data = p;
        b->cap = cap;
    }
    memcpy(b->data + b->len, bytes, n);
    b->len += n;
    b->data[b->len] = '\0';
    return 0;
}

static void buf_free(struct buf *b) {
    free(b->data);
    b->data = NULL;
    b->len = b->cap = 0u;
}

/* ------------------------------------------------------------------ */
/* per-message accumulator                                              */
/* ------------------------------------------------------------------ */

enum block_kind {
    BLK_NONE,
    BLK_TEXT,
    BLK_THINKING,
    BLK_TOOL_USE
};

struct content_block {
    enum block_kind kind;
    /* For BLK_TEXT / BLK_THINKING: the streamed text. */
    struct buf text;
    /* For BLK_TOOL_USE: the tool_use_id, name, and the streamed
     * input_json fragments concatenated into a JSON string. */
    char *tool_id;
    char *tool_name;
    struct buf tool_input;
};

struct turn_state {
    struct content_block *blocks;
    int n_blocks;
    int cap;
    int current; /* index of the block being streamed; -1 if none */
    char *stop_reason;
    /* Set by the SSE event handler when a fatal error frame appears. */
    char *server_error;
};

static void turn_init(struct turn_state *t) {
    memset(t, 0, sizeof(*t));
    t->current = -1;
}

static void turn_free(struct turn_state *t) {
    int i;
    for (i = 0; i < t->n_blocks; i++) {
        buf_free(&t->blocks[i].text);
        buf_free(&t->blocks[i].tool_input);
        free(t->blocks[i].tool_id);
        free(t->blocks[i].tool_name);
    }
    free(t->blocks);
    free(t->stop_reason);
    free(t->server_error);
    memset(t, 0, sizeof(*t));
    t->current = -1;
}

static struct content_block *turn_open(struct turn_state *t, enum block_kind kind) {
    struct content_block *b;
    if (t->n_blocks >= t->cap) {
        int cap = t->cap ? t->cap * 2 : 4;
        struct content_block *p =
            (struct content_block *)realloc(t->blocks, (size_t)cap * sizeof(*p));
        if (p == NULL)
            return NULL;
        t->blocks = p;
        t->cap = cap;
    }
    b = &t->blocks[t->n_blocks];
    memset(b, 0, sizeof(*b));
    b->kind = kind;
    t->current = t->n_blocks;
    t->n_blocks++;
    return b;
}

/* ------------------------------------------------------------------ */
/* SSE line parser                                                      */
/* ------------------------------------------------------------------ */

struct sse_state {
    char event[64];
    struct buf data;
    char line[2048];
    size_t line_len;
};

static void sse_init(struct sse_state *s) {
    memset(s, 0, sizeof(*s));
}

static void sse_reset_event(struct sse_state *s) {
    s->event[0] = '\0';
    buf_free(&s->data);
}

static void sse_destroy(struct sse_state *s) {
    sse_reset_event(s);
}

/* dispatch_event runs after a blank line completes a frame; it
 * routes each Anthropic event type into the turn state and observer. */
static void dispatch_event(
    struct sse_state *s, struct turn_state *turn, struct psi_agent_observer *obs) {
    cJSON *root;
    cJSON *type_node;
    const char *type_str;

    if (s->data.len == 0u) {
        sse_reset_event(s);
        return;
    }
    root = cJSON_Parse(s->data.data);
    if (root == NULL) {
        ESP_LOGW(TAG, "sse parse failed: %.80s", s->data.data);
        sse_reset_event(s);
        return;
    }
    type_node = cJSON_GetObjectItemCaseSensitive(root, "type");
    type_str = (cJSON_IsString(type_node) && type_node->valuestring) ? type_node->valuestring : "";

    if (strcmp(type_str, "content_block_start") == 0) {
        cJSON *cb = cJSON_GetObjectItemCaseSensitive(root, "content_block");
        cJSON *cb_type = cJSON_GetObjectItemCaseSensitive(cb, "type");
        const char *kind_str =
            (cJSON_IsString(cb_type) && cb_type->valuestring) ? cb_type->valuestring : "text";
        enum block_kind kind = BLK_TEXT;
        struct content_block *b;
        if (strcmp(kind_str, "thinking") == 0)
            kind = BLK_THINKING;
        else if (strcmp(kind_str, "tool_use") == 0)
            kind = BLK_TOOL_USE;
        b = turn_open(turn, kind);
        if (b != NULL && kind == BLK_TOOL_USE) {
            cJSON *id = cJSON_GetObjectItemCaseSensitive(cb, "id");
            cJSON *name = cJSON_GetObjectItemCaseSensitive(cb, "name");
            if (cJSON_IsString(id) && id->valuestring)
                b->tool_id = psi_strdup(id->valuestring);
            if (cJSON_IsString(name) && name->valuestring)
                b->tool_name = psi_strdup(name->valuestring);
        }
    } else if (strcmp(type_str, "content_block_delta") == 0) {
        cJSON *delta = cJSON_GetObjectItemCaseSensitive(root, "delta");
        cJSON *delta_type = cJSON_GetObjectItemCaseSensitive(delta, "type");
        const char *dt =
            (cJSON_IsString(delta_type) && delta_type->valuestring) ? delta_type->valuestring : "";
        if (turn->current >= 0 && turn->current < turn->n_blocks) {
            struct content_block *b = &turn->blocks[turn->current];
            if (strcmp(dt, "text_delta") == 0) {
                cJSON *t = cJSON_GetObjectItemCaseSensitive(delta, "text");
                if (cJSON_IsString(t) && t->valuestring) {
                    (void)buf_append(&b->text, t->valuestring, strlen(t->valuestring));
                    if (obs != NULL && obs->on_assistant_text_delta != NULL)
                        obs->on_assistant_text_delta(obs->userdata, t->valuestring);
                }
            } else if (strcmp(dt, "thinking_delta") == 0) {
                cJSON *t = cJSON_GetObjectItemCaseSensitive(delta, "thinking");
                if (cJSON_IsString(t) && t->valuestring) {
                    (void)buf_append(&b->text, t->valuestring, strlen(t->valuestring));
                    if (obs != NULL && obs->on_thinking_delta != NULL)
                        obs->on_thinking_delta(obs->userdata, t->valuestring);
                }
            } else if (strcmp(dt, "input_json_delta") == 0) {
                cJSON *p = cJSON_GetObjectItemCaseSensitive(delta, "partial_json");
                if (cJSON_IsString(p) && p->valuestring) {
                    (void)buf_append(&b->tool_input, p->valuestring, strlen(p->valuestring));
                }
            }
        }
    } else if (strcmp(type_str, "content_block_stop") == 0) {
        turn->current = -1;
    } else if (strcmp(type_str, "message_delta") == 0) {
        cJSON *delta = cJSON_GetObjectItemCaseSensitive(root, "delta");
        cJSON *sr = cJSON_GetObjectItemCaseSensitive(delta, "stop_reason");
        if (cJSON_IsString(sr) && sr->valuestring) {
            free(turn->stop_reason);
            turn->stop_reason = psi_strdup(sr->valuestring);
        }
    } else if (strcmp(type_str, "error") == 0) {
        cJSON *err = cJSON_GetObjectItemCaseSensitive(root, "error");
        cJSON *msg = cJSON_GetObjectItemCaseSensitive(err, "message");
        const char *m =
            (cJSON_IsString(msg) && msg->valuestring) ? msg->valuestring : "anthropic error";
        free(turn->server_error);
        turn->server_error = psi_strdup(m);
    }
    /* message_start, message_stop, ping: nothing to do. */

    cJSON_Delete(root);
    sse_reset_event(s);
}

static void handle_line(
    struct sse_state *s, struct turn_state *turn, struct psi_agent_observer *obs) {
    char *line = s->line;
    size_t len = s->line_len;
    if (len > 0u && line[len - 1u] == '\r') {
        line[len - 1u] = '\0';
        len--;
    }
    line[len] = '\0';

    if (len == 0u) {
        dispatch_event(s, turn, obs);
        s->line_len = 0u;
        return;
    }
    if (len >= 7u && memcmp(line, "event: ", 7u) == 0) {
        size_t n = len - 7u;
        if (n >= sizeof(s->event))
            n = sizeof(s->event) - 1u;
        memcpy(s->event, line + 7u, n);
        s->event[n] = '\0';
    } else if (len >= 6u && memcmp(line, "data: ", 6u) == 0) {
        if (s->data.len > 0u)
            (void)buf_append(&s->data, "\n", 1u);
        (void)buf_append(&s->data, line + 6u, len - 6u);
    } else if (len >= 5u && memcmp(line, "data:", 5u) == 0) {
        const char *p = line + 5u;
        size_t n = len - 5u;
        if (n > 0u && p[0] == ' ') {
            p++;
            n--;
        }
        if (s->data.len > 0u)
            (void)buf_append(&s->data, "\n", 1u);
        (void)buf_append(&s->data, p, n);
    }
    s->line_len = 0u;
}

static void sse_feed(struct sse_state *s, const char *bytes, size_t len, struct turn_state *turn,
    struct psi_agent_observer *obs) {
    size_t i;
    for (i = 0u; i < len; i++) {
        char c = bytes[i];
        if (c == '\n') {
            handle_line(s, turn, obs);
        } else {
            if (s->line_len + 1u >= sizeof(s->line)) {
                /* Pathological line; drop it. */
                s->line_len = 0u;
                continue;
            }
            s->line[s->line_len++] = c;
        }
    }
}

/* ------------------------------------------------------------------ */
/* esp_http_client callback glue                                        */
/* ------------------------------------------------------------------ */

struct round_ctx {
    struct sse_state sse;
    struct turn_state *turn;
    struct psi_agent_observer *observer;
    const struct psi_abort_signal *abort_signal;
    int aborted;
};

static esp_err_t round_event_cb(esp_http_client_event_t *evt) {
    struct round_ctx *ctx = (struct round_ctx *)evt->user_data;
    if (ctx == NULL || evt->event_id != HTTP_EVENT_ON_DATA)
        return ESP_OK;
    if (ctx->abort_signal != NULL && psi_abort_signal_is_triggered(ctx->abort_signal)) {
        ctx->aborted = 1;
        return ESP_FAIL;
    }
    if (evt->data_len <= 0)
        return ESP_OK;
    sse_feed(&ctx->sse, (const char *)evt->data, (size_t)evt->data_len, ctx->turn, ctx->observer);
    return ESP_OK;
}

/* ------------------------------------------------------------------ */
/* request building                                                     */
/* ------------------------------------------------------------------ */

static cJSON *build_tools_array(void) {
    const struct psi_esp_tool *t;
    cJSON *arr = cJSON_CreateArray();
    for (t = psi_esp_tool_table; t->name != NULL; t++) {
        cJSON *desc = cJSON_CreateObject();
        cJSON *schema;
        cJSON_AddStringToObject(desc, "name", t->name);
        cJSON_AddStringToObject(desc, "description", t->description);
        schema = cJSON_Parse(t->input_schema_json);
        if (schema == NULL)
            schema = cJSON_CreateObject();
        cJSON_AddItemToObject(desc, "input_schema", schema);
        cJSON_AddItemToArray(arr, desc);
    }
    return arr;
}

/* Convert a finished assistant turn_state into the content array
 * Anthropic expects in the assistant message of the next request. */
static cJSON *assistant_content_from_turn(const struct turn_state *turn) {
    cJSON *arr = cJSON_CreateArray();
    int i;
    for (i = 0; i < turn->n_blocks; i++) {
        const struct content_block *b = &turn->blocks[i];
        cJSON *blk = cJSON_CreateObject();
        if (b->kind == BLK_TEXT) {
            cJSON_AddStringToObject(blk, "type", "text");
            cJSON_AddStringToObject(blk, "text", b->text.data ? b->text.data : "");
        } else if (b->kind == BLK_THINKING) {
            cJSON_AddStringToObject(blk, "type", "thinking");
            cJSON_AddStringToObject(blk, "thinking", b->text.data ? b->text.data : "");
        } else if (b->kind == BLK_TOOL_USE) {
            cJSON *input;
            cJSON_AddStringToObject(blk, "type", "tool_use");
            cJSON_AddStringToObject(blk, "id", b->tool_id ? b->tool_id : "");
            cJSON_AddStringToObject(blk, "name", b->tool_name ? b->tool_name : "");
            input = (b->tool_input.data != NULL) ? cJSON_Parse(b->tool_input.data) : NULL;
            if (input == NULL)
                input = cJSON_CreateObject();
            cJSON_AddItemToObject(blk, "input", input);
        }
        cJSON_AddItemToArray(arr, blk);
    }
    return arr;
}

/* Run every tool_use block through the registry; returns a cJSON
 * array of tool_result content blocks suitable for the user message. */
static cJSON *run_tools(struct turn_state *turn, struct psi_agent_observer *obs) {
    cJSON *arr = cJSON_CreateArray();
    int i;
    for (i = 0; i < turn->n_blocks; i++) {
        struct content_block *b = &turn->blocks[i];
        const struct psi_esp_tool *tool;
        cJSON *input = NULL;
        char *out = NULL;
        char *err = NULL;
        cJSON *result;
        if (b->kind != BLK_TOOL_USE)
            continue;
        if (obs != NULL && obs->on_tool_call != NULL) {
            obs->on_tool_call(obs->userdata, b->tool_id ? b->tool_id : "",
                b->tool_name ? b->tool_name : "", b->tool_input.data ? b->tool_input.data : "{}");
        }
        if (b->tool_input.data != NULL && b->tool_input.len > 0u)
            input = cJSON_Parse(b->tool_input.data);
        if (input == NULL)
            input = cJSON_CreateObject();
        tool = psi_esp_tool_find(b->tool_name);
        if (tool == NULL) {
            err = psi_strdup("unknown tool");
        } else {
            out = tool->handler(input, &err);
        }
        cJSON_Delete(input);

        result = cJSON_CreateObject();
        cJSON_AddStringToObject(result, "type", "tool_result");
        cJSON_AddStringToObject(result, "tool_use_id", b->tool_id ? b->tool_id : "");
        if (out != NULL) {
            cJSON_AddStringToObject(result, "content", out);
            if (obs != NULL && obs->on_tool_result != NULL) {
                obs->on_tool_result(obs->userdata, b->tool_id ? b->tool_id : "",
                    b->tool_name ? b->tool_name : "", out);
            }
            free(out);
        } else {
            cJSON_AddStringToObject(result, "content", err != NULL ? err : "tool failed");
            cJSON_AddBoolToObject(result, "is_error", 1);
            if (obs != NULL && obs->on_tool_result != NULL) {
                obs->on_tool_result(obs->userdata, b->tool_id ? b->tool_id : "",
                    b->tool_name ? b->tool_name : "", err != NULL ? err : "tool failed");
            }
            free(err);
        }
        cJSON_AddItemToArray(arr, result);
    }
    return arr;
}

/* ------------------------------------------------------------------ */
/* one HTTP round                                                       */
/* ------------------------------------------------------------------ */

/* Send the current `messages` array to Anthropic, parse the streamed
 * response, populate `turn`. Returns PSI_STATUS_OK on a clean turn,
 * PSI_STATUS_ERROR otherwise (fills *err_out). */
static int run_round(const char *system_prompt, const char *model, long max_tokens, cJSON *messages,
    struct turn_state *turn, struct psi_agent_observer *observer,
    const struct psi_abort_signal *abort_signal, char **err_out) {
    cJSON *root = cJSON_CreateObject();
    cJSON *tools;
    char *body = NULL;
    int body_len;
    esp_http_client_config_t cfg;
    esp_http_client_handle_t cli;
    esp_err_t err;
    struct round_ctx ctx;
    const char *api_key = getenv("ANTHROPIC_API_KEY");
    int rc = PSI_STATUS_ERROR;

    if (root == NULL)
        return PSI_STATUS_ERROR;
    cJSON_AddStringToObject(root, "model", model != NULL ? model : "claude-haiku-4-5");
    cJSON_AddNumberToObject(root, "max_tokens", (double)max_tokens);
    cJSON_AddTrueToObject(root, "stream");
    if (system_prompt != NULL && *system_prompt != '\0')
        cJSON_AddStringToObject(root, "system", system_prompt);
    /* Attach messages without duplicating; we detach before deleting
     * root so the caller's history survives the round. cJSON_Duplicate
     * across PSRAM has been observed to hang on the ESP32 with deep
     * trees, and we own messages anyway. */
    cJSON_AddItemToObject(root, "messages", messages);
    /* Tools are optional. With them, Anthropic may return tool_use
     * blocks that we dispatch through psi_esp_tool_table. */
#ifndef PSI_DISABLE_TOOLS
    tools = build_tools_array();
    cJSON_AddItemToObject(root, "tools", tools);
#endif
    (void)tools;

    body = cJSON_PrintUnformatted(root);
    /* Detach messages before deleting root so the caller's history
     * isn't recursively freed. */
    cJSON_DetachItemFromObjectCaseSensitive(root, "messages");
    cJSON_Delete(root);
    if (body == NULL) {
        if (err_out != NULL)
            *err_out = psi_strdup("encode failed");
        return PSI_STATUS_ERROR;
    }
    body_len = (int)strlen(body);

    sse_init(&ctx.sse);
    ctx.turn = turn;
    ctx.observer = observer;
    ctx.abort_signal = abort_signal;
    ctx.aborted = 0;

    memset(&cfg, 0, sizeof(cfg));
    cfg.url = "https://api.anthropic.com/v1/messages";
    cfg.method = HTTP_METHOD_POST;
    cfg.event_handler = round_event_cb;
    cfg.user_data = &ctx;
    cfg.timeout_ms = 60000;
    cfg.crt_bundle_attach = esp_crt_bundle_attach;
    cfg.buffer_size = 4096;
    /* tx buffer must hold the entire request body in one chunk for
     * esp_http_client. With system prompt + tools list + history the
     * body can run 8-16 KiB; 32 KiB gives headroom for multi-round
     * tool-use turns. */
    cfg.buffer_size_tx = 32768;

    cli = esp_http_client_init(&cfg);
    if (cli == NULL) {
        free(body);
        sse_destroy(&ctx.sse);
        if (err_out != NULL)
            *err_out = psi_strdup("esp_http_client_init failed");
        return PSI_STATUS_ERROR;
    }
    esp_http_client_set_header(cli, "x-api-key", api_key != NULL ? api_key : "");
    esp_http_client_set_header(cli, "anthropic-version", "2023-06-01");
    esp_http_client_set_header(cli, "content-type", "application/json");
    esp_http_client_set_header(cli, "accept", "text/event-stream");
    esp_http_client_set_post_field(cli, body, body_len);

    err = esp_http_client_perform(cli);
    {
        int status = esp_http_client_get_status_code(cli);
        ESP_LOGI(TAG, "anthropic round: err=%s status=%d", esp_err_to_name(err), status);
        if (turn->server_error != NULL) {
            if (err_out != NULL) {
                *err_out = turn->server_error;
                turn->server_error = NULL;
            }
            rc = PSI_STATUS_ERROR;
        } else if (err != ESP_OK || status < 200 || status >= 300) {
            if (err_out != NULL) {
                char buf[160];
                snprintf(buf, sizeof(buf), "anthropic %s status=%d", esp_err_to_name(err), status);
                *err_out = psi_strdup(buf);
            }
            rc = PSI_STATUS_ERROR;
        } else {
            rc = PSI_STATUS_OK;
        }
    }

    esp_http_client_cleanup(cli);
    free(body);
    sse_destroy(&ctx.sse);
    return rc;
}

/* ------------------------------------------------------------------ */
/* public entrypoint                                                    */
/* ------------------------------------------------------------------ */

int psi_esp_agent_turn(const char *user_text, const char *system_prompt, const char *model,
    long max_tokens, struct psi_agent_observer *observer,
    const struct psi_abort_signal *abort_signal, char **error_message) {
    cJSON *messages;
    cJSON *user_msg;
    int round;
    int rc = PSI_STATUS_ERROR;
    int has_text = 0;
    const char *api_key = getenv("ANTHROPIC_API_KEY");

    if (error_message != NULL)
        *error_message = NULL;
    if (api_key == NULL || *api_key == '\0') {
        if (error_message != NULL)
            *error_message = psi_strdup("ANTHROPIC_API_KEY not set");
        return PSI_STATUS_ERROR;
    }

    messages = cJSON_CreateArray();
    user_msg = cJSON_CreateObject();
    cJSON_AddStringToObject(user_msg, "role", "user");
    cJSON_AddStringToObject(user_msg, "content", user_text != NULL ? user_text : "");
    cJSON_AddItemToArray(messages, user_msg);

    for (round = 0; round < PSI_AGENT_MAX_ROUNDS; round++) {
        struct turn_state turn;
        char *err = NULL;
        int has_tool_use = 0;
        int prc;
        cJSON *assistant_msg;
        cJSON *assistant_content;
        cJSON *tool_results;
        cJSON *user_followup;
        int i;

        turn_init(&turn);
        prc = run_round(
            system_prompt, model, max_tokens, messages, &turn, observer, abort_signal, &err);
        if (prc != PSI_STATUS_OK) {
            if (error_message != NULL)
                *error_message = err != NULL ? err : psi_strdup("agent round failed");
            else
                free(err);
            turn_free(&turn);
            rc = PSI_STATUS_ERROR;
            goto done;
        }

        for (i = 0; i < turn.n_blocks; i++) {
            if (turn.blocks[i].kind == BLK_TOOL_USE)
                has_tool_use = 1;
            if (turn.blocks[i].kind == BLK_TEXT && turn.blocks[i].text.len > 0u)
                has_text = 1;
        }

        /* No tools requested → final assistant message; emit turn_end. */
        if (!has_tool_use) {
            turn_free(&turn);
            rc = PSI_STATUS_OK;
            goto done;
        }

        /* Append the assistant message verbatim, then a user message
         * carrying tool_result blocks. */
        assistant_msg = cJSON_CreateObject();
        cJSON_AddStringToObject(assistant_msg, "role", "assistant");
        assistant_content = assistant_content_from_turn(&turn);
        cJSON_AddItemToObject(assistant_msg, "content", assistant_content);
        cJSON_AddItemToArray(messages, assistant_msg);

        tool_results = run_tools(&turn, observer);
        user_followup = cJSON_CreateObject();
        cJSON_AddStringToObject(user_followup, "role", "user");
        cJSON_AddItemToObject(user_followup, "content", tool_results);
        cJSON_AddItemToArray(messages, user_followup);

        turn_free(&turn);
    }

    /* Hit the round cap. Return success but let the SPA know. */
    if (observer != NULL && observer->on_assistant_text_delta != NULL) {
        observer->on_assistant_text_delta(
            observer->userdata, "\n[agent: tool-use round cap reached]\n");
    }
    rc = PSI_STATUS_OK;

done:
    cJSON_Delete(messages);
    if (rc == PSI_STATUS_OK && observer != NULL && observer->on_turn_end != NULL)
        observer->on_turn_end(observer->userdata);
    (void)has_text;
    return rc;
}
