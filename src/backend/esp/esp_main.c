/* ESP-IDF entrypoint shim.
 *
 * Brings up NVS (for WiFi creds + Anthropic API key storage), the
 * WiFi station, mDNS (so the SPA URL is reachable as
 * http://psi.local), then starts the HTTP+WebSocket server. WiFi
 * credentials come from sdkconfig (PSI_WIFI_SSID / PSI_WIFI_PASS) so
 * they aren't baked into the source. The Anthropic API key is read
 * from NVS at agent-turn time by lua/psi/providers/anthropic.lua via
 * psi.env_get; the QEMU integration test seeds NVS with the key.
 *
 * On failure we log loudly and return; ESP-IDF's app_main is the
 * caller and will hang the system if we just return without parking
 * the task, so the firmware's main.c parks itself in a vTaskDelay
 * loop after this returns.
 */

#include <string.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/task.h"
#include "nvs_flash.h"

#include "psi/esp_runtime.h"

static const char *TAG = "psi_main";

#ifndef CONFIG_PSI_WIFI_SSID
#define CONFIG_PSI_WIFI_SSID ""
#endif
#ifndef CONFIG_PSI_WIFI_PASS
#define CONFIG_PSI_WIFI_PASS ""
#endif
#ifndef CONFIG_PSI_MDNS_HOSTNAME
#define CONFIG_PSI_MDNS_HOSTNAME "psi"
#endif

#define PSI_WIFI_BIT_CONNECTED BIT0
#define PSI_WIFI_BIT_FAIL BIT1

void psi_ws_server_start(void);

static EventGroupHandle_t g_wifi_events = NULL;

static void psi_wifi_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data) {
    (void)arg;
    (void)data;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        ESP_LOGW(TAG, "wifi disconnected, retrying");
        esp_wifi_connect();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ESP_LOGI(TAG, "wifi connected, got IP");
        if (g_wifi_events != NULL)
            xEventGroupSetBits(g_wifi_events, PSI_WIFI_BIT_CONNECTED);
    }
}

static int psi_wifi_init_sta(void) {
    wifi_init_config_t init_cfg = WIFI_INIT_CONFIG_DEFAULT();
    wifi_config_t wifi_cfg;
    esp_event_handler_instance_t any_id;
    esp_event_handler_instance_t got_ip;

    g_wifi_events = xEventGroupCreate();
    if (g_wifi_events == NULL)
        return -1;

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    ESP_ERROR_CHECK(esp_wifi_init(&init_cfg));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        WIFI_EVENT, ESP_EVENT_ANY_ID, &psi_wifi_event_handler, NULL, &any_id));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        IP_EVENT, IP_EVENT_STA_GOT_IP, &psi_wifi_event_handler, NULL, &got_ip));

    memset(&wifi_cfg, 0, sizeof(wifi_cfg));
    strncpy((char *)wifi_cfg.sta.ssid, CONFIG_PSI_WIFI_SSID, sizeof(wifi_cfg.sta.ssid) - 1u);
    strncpy((char *)wifi_cfg.sta.password, CONFIG_PSI_WIFI_PASS,
        sizeof(wifi_cfg.sta.password) - 1u);
    wifi_cfg.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi_cfg));
    ESP_ERROR_CHECK(esp_wifi_start());

    /* Wait up to 30s for an IP — the QEMU smoke test relies on
     * /healthz being reachable shortly after firmware boot. */
    {
        EventBits_t bits = xEventGroupWaitBits(g_wifi_events,
            PSI_WIFI_BIT_CONNECTED | PSI_WIFI_BIT_FAIL, pdFALSE, pdFALSE,
            pdMS_TO_TICKS(30000));
        if ((bits & PSI_WIFI_BIT_CONNECTED) == 0u) {
            ESP_LOGE(TAG, "wifi failed to associate");
            return -1;
        }
    }
    return 0;
}

/* mDNS is a managed ESP-IDF component (espressif/mdns) and not
 * available inside the Nix sandbox without network access. The
 * firmware reaches its SPA via raw IP — fine for QEMU test rigs and
 * any DHCP-known hostname on real hardware. */

void psi_esp_main_run(void) {
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    if (psi_wifi_init_sta() != 0) {
        ESP_LOGE(TAG, "wifi init failed; refusing to start server");
        return;
    }
    psi_ws_server_start();
}
