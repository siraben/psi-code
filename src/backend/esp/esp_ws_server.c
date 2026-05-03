/* HTTP + WebSocket server bridging the SPA to the agent loop.
 *
 * Routes:
 *   GET  /          → embedded SPA (HTML+JS in psi_embedded_html_table)
 *   GET  /healthz   → liveness probe used by tests
 *   GET  /ws        → upgraded to a WebSocket; one agent session per connection
 *
 * Every WebSocket connection spawns a worker task that owns its own
 * psi_vm + psi_session pair. The agent observer feeds JSON frames to a
 * per-connection outbox queue; the WS sender drains that queue and
 * writes WS_TEXT frames back to the client. Inbound frames are parsed
 * inline; "user" enqueues a turn, "abort" sets the connection's
 * abort signal.
 *
 * This file uses ESP-IDF C99 features through the included headers,
 * so its CMake target sets -std=gnu99. The body deliberately stays in
 * C89 syntax to match the rest of psi.
 */

#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "esp_err.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "lua.h"
#include "lauxlib.h"

#include "psi/abort.h"
#include "psi/agent_runtime.h"
#include "psi/common.h"
#include "psi/embedded_data.h"
#include "psi/esp_runtime.h"
#include "psi/session.h"
#include "psi/vm.h"

#include "esp_obs_internal.h"
#include "esp_tools.h"

/* PSI_INCLUDE_SPA / PSI_GPIO_INTROSPECTION fallbacks come from
 * esp_tools.h. Both gate features the host frontend can replace
 * (chat SPA, GPIO snapshot endpoint) — see CMakeLists.txt. */
#if PSI_INCLUDE_SPA
extern const struct psi_embedded_data psi_embedded_html_table[];
#endif

static const char *TAG = "psi_ws";

#define PSI_WS_INBOX_DEPTH 4
#define PSI_WS_OUTBOX_DEPTH 32
/* The worker task drives the agent turn through psi_vm_run_agent_turn,
 * which recurses C ↔ Lua several times during streaming. mbedTLS's
 * handshake nests deep too; 32 KiB has been reliable so far. */
#define PSI_WS_TURN_TASK_STACK 32768

struct psi_ws_inbound {
    char *json; /* owned; receiver frees */
};

/* The agent VM and session are process-wide singletons: ESP32's
 * heap is too small to host a Lua state per WS connection, and the
 * agent is single-threaded by design (one turn at a time). The
 * connection just owns the queues and observer. */
static struct psi_vm g_psi_vm;
static struct psi_session g_psi_session;
static struct psi_abort_signal g_psi_abort;
static int g_psi_vm_inited = 0;

/* Cached system prompt built from psi.prompt.system_prompt() in Lua
 * at boot. The C agent injects it as the Anthropic `system` field
 * for every turn so embedded chat sees the same context bundle the
 * desktop CLI/TUI agents do (tool list, guidelines, date, embedded
 * docs reference). NULL means we never built one — the turn still
 * runs, the model just gets a default-empty system. */
static char *g_psi_system_prompt = NULL;

/* Accessor used by app_main after psi_esp_vm_bootstrap. */
struct psi_vm *psi_esp_vm(void) {
    return g_psi_vm_inited ? &g_psi_vm : NULL;
}

void psi_esp_set_system_prompt(char *prompt) {
    free(g_psi_system_prompt);
    g_psi_system_prompt = prompt;
}

struct psi_ws_session {
    httpd_handle_t server;
    int fd;

    QueueHandle_t inbox; /* of struct psi_ws_inbound */
    QueueHandle_t outbox; /* of char * (json text) */
    EventGroupHandle_t flags;

    struct psi_esp_observer observer;

    TaskHandle_t worker_task;
    TaskHandle_t sender_task;
    int closed;
};

int psi_esp_vm_bootstrap(void) {
    if (g_psi_vm_inited)
        return 0;
    psi_session_init(&g_psi_session);
    psi_abort_signal_init(&g_psi_abort);
    if (psi_vm_init(&g_psi_vm, NULL, NULL, NULL, NULL) != PSI_STATUS_OK)
        return -1;
    psi_vm_bind_session(&g_psi_vm, &g_psi_session);
    g_psi_vm_inited = 1;
    return 0;
}

/* Call psi.prompt.system_prompt() in the given VM and return a
 * heap-allocated copy. The Lua side knows about the active tool set,
 * the embedded docs reference, the current date, and any context
 * files that happened to land in @mem/ — same shape as the desktop
 * --system-prompt mode. The C agent injects this as the Anthropic
 * `system` field so embedded chat behaves consistently with the CLI.
 *
 * Touches the Lua state and is therefore not safe to call from a
 * task other than the one that owns the VM. We invoke this once at
 * boot from app_main; the cached result feeds every WS turn. */
char *psi_esp_build_system_prompt(struct psi_vm *vm) {
    lua_State *L;
    int top;
    const char *result;
    size_t result_len;
    char *copy = NULL;

    if (vm == NULL || vm->L == NULL)
        return NULL;
    L = vm->L;
    top = lua_gettop(L);

    lua_getglobal(L, "psi");
    if (lua_type(L, -1) != LUA_TTABLE)
        goto out;
    lua_getfield(L, -1, "prompt");
    if (lua_type(L, -1) != LUA_TTABLE)
        goto out;
    lua_getfield(L, -1, "system_prompt");
    if (lua_type(L, -1) != LUA_TFUNCTION)
        goto out;
    if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
        ESP_LOGW(TAG, "system_prompt error: %s",
            lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : "?");
        goto out;
    }
    result = lua_tolstring(L, -1, &result_len);
    if (result == NULL)
        goto out;
    copy = (char *)malloc(result_len + 1u);
    if (copy != NULL) {
        memcpy(copy, result, result_len);
        copy[result_len] = '\0';
    }

out:
    lua_settop(L, top);
    return copy;
}

#define PSI_WS_BIT_CLOSE 0x01u

#if PSI_INCLUDE_SPA
static char *psi_ws_inflate_html(size_t *len_out) {
    const struct psi_embedded_data *e = &psi_embedded_html_table[0];
    unsigned char *buf;
    size_t raw_len;
    if (e->name == NULL || e->raw_len == 0u)
        return NULL;
    buf = (unsigned char *)malloc(e->raw_len + 1u);
    if (buf == NULL)
        return NULL;
    raw_len = e->raw_len;
    if (psi_embedded_inflate(e, buf, raw_len) != PSI_STATUS_OK) {
        free(buf);
        return NULL;
    }
    buf[raw_len] = '\0';
    if (len_out != NULL)
        *len_out = raw_len;
    return (char *)buf;
}

static esp_err_t psi_ws_index_handler(httpd_req_t *req) {
    size_t len = 0u;
    char *html = psi_ws_inflate_html(&len);
    esp_err_t err;
    if (html == NULL) {
        return httpd_resp_send_500(req);
    }
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    err = httpd_resp_send(req, html, (ssize_t)len);
    free(html);
    return err;
}
#endif /* PSI_INCLUDE_SPA */

static esp_err_t psi_ws_health_handler(httpd_req_t *req) {
    static const char body[] = "{\"ok\":true}";
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_send(req, body, (ssize_t)(sizeof(body) - 1u));
}

#if PSI_GPIO_INTROSPECTION
/* Snapshot of every GPIO's configured mode + level for the host
 * dashboard's pin grid. Polled at 2 Hz from esp_frontend.py. */
static esp_err_t psi_ws_gpio_handler(httpd_req_t *req) {
    char *json = psi_esp_gpio_snapshot_json();
    esp_err_t err;
    if (json == NULL)
        return httpd_resp_send_500(req);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    /* Allow polls from the host dashboard regardless of origin —
     * everything's on localhost, but the dashboard binds 0.0.0.0 so
     * a different LAN host could be the client. */
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    err = httpd_resp_send(req, json, (ssize_t)strlen(json));
    free(json);
    return err;
}
#endif

/* ------------------------------------------------------------------ */
/* Per-connection worker + sender                                      */
/* ------------------------------------------------------------------ */

static void psi_ws_emit_error(struct psi_ws_session *s, const char *msg) {
    psi_esp_observer_emit_error(&s->observer, msg);
}

static void psi_ws_sender_task(void *arg) {
    struct psi_ws_session *s = (struct psi_ws_session *)arg;
    char *json;
    httpd_ws_frame_t frame;
    EventBits_t bits;

    while (1) {
        if (xQueueReceive(s->outbox, &json, pdMS_TO_TICKS(200)) != pdTRUE) {
            bits = xEventGroupGetBits(s->flags);
            if ((bits & PSI_WS_BIT_CLOSE) != 0u)
                break;
            continue;
        }
        memset(&frame, 0, sizeof(frame));
        frame.type = HTTPD_WS_TYPE_TEXT;
        frame.payload = (uint8_t *)json;
        frame.len = strlen(json);
        (void)httpd_ws_send_frame_async(s->server, s->fd, &frame);
        free(json);
    }
    /* Drain remaining frames and free them. */
    while (xQueueReceive(s->outbox, &json, 0) == pdTRUE)
        free(json);
    s->sender_task = NULL;
    vTaskDelete(NULL);
}

static void psi_ws_worker_task(void *arg) {
    struct psi_ws_session *s = (struct psi_ws_session *)arg;
    struct psi_ws_inbound msg;
    cJSON *root;

    while (1) {
        if (xQueueReceive(s->inbox, &msg, pdMS_TO_TICKS(500)) != pdTRUE) {
            EventBits_t bits = xEventGroupGetBits(s->flags);
            if ((bits & PSI_WS_BIT_CLOSE) != 0u)
                break;
            continue;
        }
        ESP_LOGI(TAG, "worker got frame: %.80s", msg.json);
        root = cJSON_Parse(msg.json);
        free(msg.json);
        if (root == NULL) {
            psi_ws_emit_error(s, "invalid JSON");
            continue;
        }
        {
            cJSON *type = cJSON_GetObjectItemCaseSensitive(root, "type");
            if (cJSON_IsString(type) && strcmp(type->valuestring, "user") == 0) {
                cJSON *text = cJSON_GetObjectItemCaseSensitive(root, "text");
                cJSON *model = cJSON_GetObjectItemCaseSensitive(root, "model");
                cJSON *max = cJSON_GetObjectItemCaseSensitive(root, "max_tokens");
                const char *u = (cJSON_IsString(text) ? text->valuestring : "");
                const char *m = (cJSON_IsString(model) ? model->valuestring : "claude-haiku-4-5");
                long mx = (cJSON_IsNumber(max) ? (long)max->valuedouble : 1024L);
                char *response = NULL;
                psi_abort_signal_reset(&g_psi_abort);
                /* C-native agent path: bypasses the Lua VM entirely.
                 * The Lua machinery (anthropic.lua + provider_loop +
                 * stream_parser + transform_messages...) allocates
                 * far more than ESP32's heap can give us reliably,
                 * even with PSRAM. The C path streams Anthropic SSE
                 * straight to the WS observer with one cJSON parse
                 * per event, no GC, no per-turn module loads. */
                {
                    char *err_msg = NULL;
                    int prc = psi_esp_agent_turn(
                        u, g_psi_system_prompt, m, mx, &s->observer.base, &g_psi_abort, &err_msg);
                    if (prc != PSI_STATUS_OK) {
                        psi_ws_emit_error(s, err_msg != NULL ? err_msg : "agent turn failed");
                    }
                    free(err_msg);
                }
                (void)psi_vm_run_agent_turn;
                (void)response;
                (void)g_psi_vm_inited;
            } else if (cJSON_IsString(type) && strcmp(type->valuestring, "abort") == 0) {
                psi_esp_request_abort(&g_psi_abort);
            } else {
                psi_ws_emit_error(s, "unknown frame type");
            }
        }
        cJSON_Delete(root);
    }

    /* The VM is a process-wide singleton; we don't tear it down here. */
    s->worker_task = NULL;
    vTaskDelete(NULL);
}

/* ------------------------------------------------------------------ */
/* WebSocket upgrade + frame routing                                   */
/* ------------------------------------------------------------------ */

/* esp_http_server stores per-handler context as session ctx; we use
 * sock-fd-keyed lookup to find the right psi_ws_session for incoming
 * frames since the per-handler ctx isn't connection-specific. For
 * simplicity, we cap to one in-flight session and store it globally.
 * Production would want a fd→session map; the firmware ships with a
 * single SPA tab so one session is enough. */
static struct psi_ws_session g_ws_session;
static int g_ws_inited = 0;

/* Tear down the current WS session: signal close, wait briefly for
 * the worker + sender tasks to exit, drain queues, and free their
 * FreeRTOS objects. After this returns, g_ws_inited is 0 and a
 * fresh session can be set up safely.
 *
 * Used when the user reloads the page: the old TCP socket has gone
 * away (the new GET on /ws is from a fresh socket fd), but the old
 * worker / sender / queues are still allocated and try to write to
 * a dead fd. Resetting cleanly is much simpler than trying to detect
 * the disconnect via httpd's close callback. */
static void psi_ws_session_teardown(void) {
    int waited = 0;
    if (!g_ws_inited)
        return;
    if (g_ws_session.flags != NULL)
        xEventGroupSetBits(g_ws_session.flags, PSI_WS_BIT_CLOSE);
    /* Wait up to 2 s for the tasks to exit. They poll their inbox
     * with a 200/500 ms timeout, so this lands quickly. */
    while (
        (g_ws_session.worker_task != NULL || g_ws_session.sender_task != NULL) && waited < 2000) {
        vTaskDelay(pdMS_TO_TICKS(50));
        waited += 50;
    }
    if (g_ws_session.outbox != NULL) {
        char *json;
        while (xQueueReceive(g_ws_session.outbox, &json, 0) == pdTRUE)
            free(json);
        vQueueDelete(g_ws_session.outbox);
    }
    if (g_ws_session.inbox != NULL) {
        struct psi_ws_inbound m;
        while (xQueueReceive(g_ws_session.inbox, &m, 0) == pdTRUE)
            free(m.json);
        vQueueDelete(g_ws_session.inbox);
    }
    if (g_ws_session.flags != NULL)
        vEventGroupDelete(g_ws_session.flags);
    memset(&g_ws_session, 0, sizeof(g_ws_session));
    g_ws_inited = 0;
}

static esp_err_t psi_ws_handler(httpd_req_t *req) {
    httpd_ws_frame_t frame;
    esp_err_t err;
    if (req->method == HTTP_GET) {
        /* Initial upgrade. Tear down any prior session (a page reload
         * leaves the old worker/sender alive on a dead socket); the
         * fresh GET always wins. Single-tab semantics; if we ever want
         * concurrent sessions we'd key by sock-fd here. */
        if (g_ws_inited)
            psi_ws_session_teardown();
        memset(&g_ws_session, 0, sizeof(g_ws_session));
        g_ws_session.server = req->handle;
        g_ws_session.fd = httpd_req_to_sockfd(req);
        g_ws_session.inbox = xQueueCreate(PSI_WS_INBOX_DEPTH, sizeof(struct psi_ws_inbound));
        g_ws_session.outbox = xQueueCreate(PSI_WS_OUTBOX_DEPTH, sizeof(char *));
        g_ws_session.flags = xEventGroupCreate();
        if (g_ws_session.inbox == NULL || g_ws_session.outbox == NULL ||
            g_ws_session.flags == NULL) {
            return ESP_FAIL;
        }
        psi_esp_observer_init(&g_ws_session.observer, g_ws_session.outbox);

        if (xTaskCreate(psi_ws_sender_task, "psi_ws_tx", 4096, &g_ws_session, tskIDLE_PRIORITY + 5,
                &g_ws_session.sender_task) != pdPASS)
            return ESP_FAIL;
        if (xTaskCreate(psi_ws_worker_task, "psi_ws_rx", PSI_WS_TURN_TASK_STACK, &g_ws_session,
                tskIDLE_PRIORITY + 4, &g_ws_session.worker_task) != pdPASS) {
            xEventGroupSetBits(g_ws_session.flags, PSI_WS_BIT_CLOSE);
            return ESP_FAIL;
        }
        g_ws_inited = 1;
        ESP_LOGI(TAG, "ws session opened (fd=%d)", g_ws_session.fd);
        return ESP_OK;
    }

    /* Subsequent frames. Read length, then payload. */
    memset(&frame, 0, sizeof(frame));
    frame.type = HTTPD_WS_TYPE_TEXT;
    err = httpd_ws_recv_frame(req, &frame, 0);
    if (err != ESP_OK)
        return err;
    if (frame.len == 0u || frame.type != HTTPD_WS_TYPE_TEXT) {
        return ESP_OK;
    }
    {
        struct psi_ws_inbound m;
        m.json = (char *)malloc(frame.len + 1u);
        if (m.json == NULL)
            return ESP_ERR_NO_MEM;
        frame.payload = (uint8_t *)m.json;
        err = httpd_ws_recv_frame(req, &frame, frame.len);
        if (err != ESP_OK) {
            free(m.json);
            return err;
        }
        m.json[frame.len] = '\0';
        ESP_LOGI(TAG, "rx frame, %u bytes", (unsigned)frame.len);
        if (xQueueSend(g_ws_session.inbox, &m, 0) != pdTRUE) {
            free(m.json);
            ESP_LOGE(TAG, "inbox send failed");
            return ESP_ERR_NO_MEM;
        }
    }
    return ESP_OK;
}

void psi_ws_server_start(void) {
    httpd_handle_t server = NULL;
    httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
#if PSI_INCLUDE_SPA
    httpd_uri_t index_uri = {
        .uri = "/", .method = HTTP_GET, .handler = psi_ws_index_handler, .user_ctx = NULL};
#endif
    httpd_uri_t health_uri = {
        .uri = "/healthz", .method = HTTP_GET, .handler = psi_ws_health_handler, .user_ctx = NULL};
#if PSI_GPIO_INTROSPECTION
    httpd_uri_t gpio_uri = {
        .uri = "/gpio", .method = HTTP_GET, .handler = psi_ws_gpio_handler, .user_ctx = NULL};
#endif
    httpd_uri_t ws_uri = {
        .uri = "/ws",
        .method = HTTP_GET,
        .handler = psi_ws_handler,
        .user_ctx = NULL,
        .is_websocket = true,
        .handle_ws_control_frames = false,
    };
    cfg.lru_purge_enable = true;
    cfg.max_open_sockets = 4;
    /* The WS upgrade handler spawns FreeRTOS queues and event groups,
     * which call deep into the kernel; 8 KiB of stack on this task
     * was not enough and triggered an InstrFetchProhibited at PC=0
     * (stack chain corruption). 16 KiB is comfortable. */
    cfg.stack_size = 16384;

    if (httpd_start(&server, &cfg) != ESP_OK) {
        ESP_LOGE(TAG, "httpd_start failed");
        return;
    }
#if PSI_INCLUDE_SPA
    httpd_register_uri_handler(server, &index_uri);
#endif
    httpd_register_uri_handler(server, &health_uri);
#if PSI_GPIO_INTROSPECTION
    httpd_register_uri_handler(server, &gpio_uri);
#endif
    httpd_register_uri_handler(server, &ws_uri);
    ESP_LOGI(TAG, "psi web chat ready on port 80");
}
