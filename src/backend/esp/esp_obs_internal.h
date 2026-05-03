/* Internal: shared layout for the ESP observer + WS server. Not part
 * of the public psi/ include path. */

#ifndef PSI_ESP_OBS_INTERNAL_H
#define PSI_ESP_OBS_INTERNAL_H

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

#include "psi/agent_runtime.h"

struct psi_esp_observer {
    struct psi_agent_observer base;
    QueueHandle_t outbox; /* of char *; consumer frees */
};

void psi_esp_observer_init(struct psi_esp_observer *obs, QueueHandle_t outbox);
void psi_esp_observer_emit_error(struct psi_esp_observer *obs, const char *message);

/* Accessors for the singleton VM and cached system prompt; defined
 * in esp_ws_server.c and called from esp_main.c at boot. */
struct psi_vm;
struct psi_vm *psi_esp_vm(void);

/* Initialize state the C agent always needs (abort signal). Called
 * from esp_main once before any WS connection. */
void psi_esp_runtime_init(void);
void psi_esp_set_system_prompt(char *prompt); /* takes ownership */
const char *psi_esp_get_system_prompt(void);

/* zForth glue. Builds the agent system prompt at boot by running
 * a tiny Forth program that calls back into C via custom syscalls.
 * Footprint is ~12 KiB total (10 KiB code + 2 KiB dict + 256 B
 * stacks), which sits comfortably alongside mbedTLS handshake
 * buffers. Returns malloc'd string, NULL on error. */
char *psi_esp_forth_build_system_prompt(void);

/* Evaluate Forth source `code` against the persistent zforth
 * context. Captured TELL output is returned as a malloc'd string
 * (caller frees); zf_result is non-zero on Forth-side failure and
 * the function returns NULL. Used by the forth_eval tool. */
int psi_esp_forth_eval(const char *code, char **out);

/* NimBLE bring-up. Idempotent — safe to call from multiple tools.
 * Returns 0 on success, -1 on init/sync failure (logged). */
int psi_esp_ble_init(void);

/* GAP discovery scan. Blocks for `duration_ms` (clamped 500–10000)
 * collecting up to `max_results` unique devices. Returns a malloc'd
 * JSON string {count, devices[{addr, rssi, addr_type, name?}], ...}.
 * NULL on failure. Used by the ble_scan tool. */
char *psi_esp_ble_scan_json(int duration_ms, int max_results);

#endif
