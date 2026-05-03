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
void psi_esp_set_system_prompt(char *prompt); /* takes ownership */
const char *psi_esp_get_system_prompt(void);

#endif
