/* Agent observer adapter for the ESP backend.
 *
 * Implements every callback in struct psi_agent_observer by JSON-
 * encoding the event into a heap string and pushing it to the
 * connection's outbox queue. The WS server task drains the outbox and
 * sends each frame as a WebSocket text message.
 *
 * Why a queue: the agent loop runs in the per-connection worker task,
 * but ESP-IDF's esp_http_server has its own internal accept thread
 * and uses async-send semantics on the WS client. Passing frames
 * through a FreeRTOS queue keeps the producer (agent) decoupled from
 * the consumer (WS sender) without sharing state across tasks.
 *
 * cJSON is the encoder; it ships with ESP-IDF so we don't pull in a
 * second JSON library. */

#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

#include "psi/agent_runtime.h"
#include "psi/common.h"

#include "esp_obs_internal.h"

static int psi_obs_push(struct psi_esp_observer *obs, cJSON *root) {
    char *txt;
    if (root == NULL || obs == NULL || obs->outbox == NULL)
        return -1;
    txt = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    if (txt == NULL)
        return -1;
    /* Hand ownership of the heap string to the queue. The WS sender
     * task frees it after sending. */
    if (xQueueSend(obs->outbox, &txt, pdMS_TO_TICKS(2000)) != pdTRUE) {
        free(txt);
        return -1;
    }
    return 0;
}

static cJSON *psi_obs_obj(const char *type) {
    cJSON *root = cJSON_CreateObject();
    if (root == NULL)
        return NULL;
    cJSON_AddStringToObject(root, "type", type);
    return root;
}

static void on_assistant_text_delta(void *userdata, const char *text) {
    struct psi_esp_observer *o = (struct psi_esp_observer *)userdata;
    cJSON *root = psi_obs_obj("assistant_delta");
    if (root == NULL)
        return;
    cJSON_AddStringToObject(root, "text", text != NULL ? text : "");
    psi_obs_push(o, root);
}

static void on_thinking_delta(void *userdata, const char *text) {
    struct psi_esp_observer *o = (struct psi_esp_observer *)userdata;
    cJSON *root = psi_obs_obj("thinking_delta");
    if (root == NULL)
        return;
    cJSON_AddStringToObject(root, "text", text != NULL ? text : "");
    psi_obs_push(o, root);
}

static void on_tool_call(void *userdata, const char *id, const char *name, const char *input_json) {
    struct psi_esp_observer *o = (struct psi_esp_observer *)userdata;
    cJSON *root = psi_obs_obj("tool_call");
    cJSON *input;
    if (root == NULL)
        return;
    cJSON_AddStringToObject(root, "id", id != NULL ? id : "");
    cJSON_AddStringToObject(root, "name", name != NULL ? name : "");
    /* input_json is already JSON; parse-and-attach so the SPA receives
     * an object, not a string. Fall back to the raw string on parse
     * failure so we never drop the frame entirely. */
    input = (input_json != NULL) ? cJSON_Parse(input_json) : NULL;
    if (input != NULL) {
        cJSON_AddItemToObject(root, "input", input);
    } else if (input_json != NULL) {
        cJSON_AddStringToObject(root, "input", input_json);
    }
    psi_obs_push(o, root);
}

static void on_tool_call_delta(void *userdata, const char *id, const char *partial_json) {
    struct psi_esp_observer *o = (struct psi_esp_observer *)userdata;
    cJSON *root = psi_obs_obj("tool_call_delta");
    if (root == NULL)
        return;
    cJSON_AddStringToObject(root, "id", id != NULL ? id : "");
    cJSON_AddStringToObject(root, "partial", partial_json != NULL ? partial_json : "");
    psi_obs_push(o, root);
}

static void on_tool_result(
    void *userdata, const char *id, const char *name, const char *output_json) {
    struct psi_esp_observer *o = (struct psi_esp_observer *)userdata;
    cJSON *root = psi_obs_obj("tool_result");
    cJSON *parsed;
    int ok = 1;
    if (root == NULL)
        return;
    cJSON_AddStringToObject(root, "id", id != NULL ? id : "");
    cJSON_AddStringToObject(root, "name", name != NULL ? name : "");
    parsed = (output_json != NULL) ? cJSON_Parse(output_json) : NULL;
    if (parsed != NULL && cJSON_IsObject(parsed)) {
        cJSON *ok_node = cJSON_GetObjectItemCaseSensitive(parsed, "ok");
        if (cJSON_IsBool(ok_node))
            ok = cJSON_IsTrue(ok_node);
        cJSON_AddItemToObject(root, "output", parsed);
    } else {
        if (parsed != NULL)
            cJSON_Delete(parsed);
        cJSON_AddStringToObject(root, "output", output_json != NULL ? output_json : "");
    }
    cJSON_AddBoolToObject(root, "ok", ok);
    psi_obs_push(o, root);
}

static void on_tool_progress(void *userdata, const char *id, const char *chunk, size_t len) {
    struct psi_esp_observer *o = (struct psi_esp_observer *)userdata;
    cJSON *root = psi_obs_obj("tool_progress");
    if (root == NULL)
        return;
    cJSON_AddStringToObject(root, "id", id != NULL ? id : "");
    if (chunk != NULL && len > 0u) {
        char *copy = (char *)malloc(len + 1u);
        if (copy != NULL) {
            memcpy(copy, chunk, len);
            copy[len] = '\0';
            cJSON_AddStringToObject(root, "chunk", copy);
            free(copy);
        }
    }
    psi_obs_push(o, root);
}

static void on_turn_start(void *userdata) {
    struct psi_esp_observer *o = (struct psi_esp_observer *)userdata;
    cJSON *root = psi_obs_obj("turn_start");
    if (root == NULL)
        return;
    psi_obs_push(o, root);
}

static void on_turn_end(void *userdata) {
    struct psi_esp_observer *o = (struct psi_esp_observer *)userdata;
    cJSON *root = psi_obs_obj("turn_end");
    if (root == NULL)
        return;
    psi_obs_push(o, root);
}

void psi_esp_observer_init(struct psi_esp_observer *obs, QueueHandle_t outbox) {
    if (obs == NULL)
        return;
    memset(obs, 0, sizeof(*obs));
    obs->outbox = outbox;
    obs->base.userdata = obs;
    obs->base.on_assistant_text_delta = on_assistant_text_delta;
    obs->base.on_thinking_delta = on_thinking_delta;
    obs->base.on_tool_call = on_tool_call;
    obs->base.on_tool_call_delta = on_tool_call_delta;
    obs->base.on_tool_result = on_tool_result;
    obs->base.on_tool_progress = on_tool_progress;
    obs->base.on_turn_start = on_turn_start;
    obs->base.on_turn_end = on_turn_end;
}

void psi_esp_observer_emit_error(struct psi_esp_observer *obs, const char *message) {
    cJSON *root;
    if (obs == NULL)
        return;
    root = psi_obs_obj("error");
    if (root == NULL)
        return;
    cJSON_AddStringToObject(root, "message", message != NULL ? message : "error");
    psi_obs_push(obs, root);
}
