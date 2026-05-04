#ifndef PSI_ESP_RUNTIME_H
#define PSI_ESP_RUNTIME_H

/* Public surface of the ESP-IDF backend. Only the firmware's app_main
 * needs psi_esp_main_run; psi_esp_request_abort is exposed so the
 * WebSocket /abort handler can flip the per-connection abort flag.
 *
 * No part of the desktop build links against this header — it lives
 * here so the firmware component's CMakeLists can include it without
 * reaching into src/backend/esp/. */

#include "psi/common.h"

#ifdef __cplusplus
extern "C" {
#endif

struct psi_abort_signal;

/* Bring up NVS, WiFi STA, mDNS, then the HTTP+WebSocket server task.
 * Returns once the server task has been started; the caller (app_main)
 * is then free to vTaskDelete itself or block forever. */
void psi_esp_main_run(void);

/* Set the abort flag on a connection's signal. Safe to call from any
 * FreeRTOS task; reads the flag use volatile semantics. */
void psi_esp_request_abort(struct psi_abort_signal *abort_signal);

struct psi_agent_observer;

/* Run a single Anthropic turn entirely in C. Builds the JSON request,
 * streams the SSE response, dispatches tool calls inline against
 * psi_esp_tool_table, and forwards text deltas to the observer.
 *
 * `system_prompt` is the system message to send (the cached prompt
 * from psi_esp_get_system_prompt is the typical source); pass NULL
 * to omit the system field entirely.
 *
 * Returns PSI_STATUS_OK on success, PSI_STATUS_ERROR on transport or
 * API failure (in which case *error_message is a heap string the
 * caller must free). The observer's on_turn_end is fired on success;
 * the caller fires the error frame on its own. */
int psi_esp_agent_turn(const char *user_text, const char *system_prompt, const char *model,
    long max_tokens, struct psi_agent_observer *observer,
    const struct psi_abort_signal *abort_signal, char **error_message);

#ifdef __cplusplus
}
#endif

#endif
