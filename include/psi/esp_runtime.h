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

#ifdef __cplusplus
}
#endif

#endif
