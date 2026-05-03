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

#include "psi/abort.h"
#include "psi/agent_runtime.h"
#include "psi/common.h"
#include "psi/embedded_data.h"
#include "psi/esp_runtime.h"
#include "psi/session.h"
#include "psi/vm.h"

#include "esp_obs_internal.h"

extern const struct psi_embedded_data psi_embedded_html_table[];

static const char *TAG = "psi_ws";

#define PSI_WS_INBOX_DEPTH 4
#define PSI_WS_OUTBOX_DEPTH 32
/* The worker task drives the agent turn through psi_vm_run_agent_turn,
 * which recurses C ↔ Lua several times during streaming. We need
 * generous stack for the recursion plus Lua's parser. */
#define PSI_WS_TURN_TASK_STACK 24576

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

struct psi_ws_session {
    httpd_handle_t server;
    int fd;

    QueueHandle_t inbox;     /* of struct psi_ws_inbound */
    QueueHandle_t outbox;    /* of char * (json text) */
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

#define PSI_WS_BIT_CLOSE 0x01u

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

static esp_err_t psi_ws_health_handler(httpd_req_t *req) {
    static const char body[] = "{\"ok\":true}";
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_send(req, body, (ssize_t)(sizeof(body) - 1u));
}

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
                if (!g_psi_vm_inited) {
                    psi_ws_emit_error(s, "psi VM not initialized");
                    cJSON_Delete(root);
                    continue;
                }
                psi_abort_signal_reset(&g_psi_abort);
                /* Sanity ping: emit an assistant_delta with the
                 * received user text and turn_end, without invoking
                 * the agent loop. Once this round-trip works in QEMU
                 * we'll re-enable the real psi_vm_run_agent_turn. */
                {
                    struct psi_agent_observer *o = &s->observer.base;
                    if (o->on_assistant_text_delta) {
                        char buf[160];
                        int n = snprintf(buf, sizeof(buf), "echo: %s", u);
                        if (n > 0)
                            o->on_assistant_text_delta(o->userdata, buf);
                    }
                    if (o->on_turn_end)
                        o->on_turn_end(o->userdata);
                }
                (void)psi_vm_run_agent_turn;
                (void)response;
                (void)m;
                (void)mx;
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

static esp_err_t psi_ws_handler(httpd_req_t *req) {
    httpd_ws_frame_t frame;
    esp_err_t err;
    if (req->method == HTTP_GET) {
        /* Initial upgrade. Set up the session and spawn worker tasks. */
        if (g_ws_inited) {
            httpd_resp_set_status(req, "503 Service Unavailable");
            return httpd_resp_send(req, "session in use", HTTPD_RESP_USE_STRLEN);
        }
        memset(&g_ws_session, 0, sizeof(g_ws_session));
        g_ws_session.server = req->handle;
        g_ws_session.fd = httpd_req_to_sockfd(req);
        g_ws_session.inbox =
            xQueueCreate(PSI_WS_INBOX_DEPTH, sizeof(struct psi_ws_inbound));
        g_ws_session.outbox = xQueueCreate(PSI_WS_OUTBOX_DEPTH, sizeof(char *));
        g_ws_session.flags = xEventGroupCreate();
        if (g_ws_session.inbox == NULL || g_ws_session.outbox == NULL ||
            g_ws_session.flags == NULL) {
            return ESP_FAIL;
        }
        psi_esp_observer_init(&g_ws_session.observer, g_ws_session.outbox);

        if (xTaskCreate(psi_ws_sender_task, "psi_ws_tx", 4096, &g_ws_session,
                tskIDLE_PRIORITY + 5, &g_ws_session.sender_task) != pdPASS)
            return ESP_FAIL;
        if (xTaskCreate(psi_ws_worker_task, "psi_ws_rx", PSI_WS_TURN_TASK_STACK,
                &g_ws_session, tskIDLE_PRIORITY + 4, &g_ws_session.worker_task) != pdPASS) {
            xEventGroupSetBits(g_ws_session.flags, PSI_WS_BIT_CLOSE);
            return ESP_FAIL;
        }
        g_ws_inited = 1;
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
    httpd_uri_t index_uri = {
        .uri = "/", .method = HTTP_GET, .handler = psi_ws_index_handler, .user_ctx = NULL };
    httpd_uri_t health_uri = {
        .uri = "/healthz", .method = HTTP_GET, .handler = psi_ws_health_handler, .user_ctx = NULL };
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
    httpd_register_uri_handler(server, &index_uri);
    httpd_register_uri_handler(server, &health_uri);
    httpd_register_uri_handler(server, &ws_uri);
    ESP_LOGI(TAG, "psi web chat ready on port 80");
}
