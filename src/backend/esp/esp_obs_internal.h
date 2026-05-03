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

#endif
