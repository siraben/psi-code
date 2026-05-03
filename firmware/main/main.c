#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "psi/esp_runtime.h"

void app_main(void) {
    psi_esp_main_run();
    /* Park the main task. The HTTP server and per-connection workers
     * own real work from this point; app_main returning would let
     * idf-default's task watchdog start counting against us. */
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(60000));
    }
}
