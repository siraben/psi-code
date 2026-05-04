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

#include <stdlib.h>
#include <string.h>

#include "esp_event.h"
#include "esp_http_client.h"
#include "esp_crt_bundle.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "freertos/FreeRTOS.h"
#include "esp_heap_caps.h"
#include "freertos/event_groups.h"
#include "freertos/task.h"
#include "nvs.h"
#include "nvs_flash.h"

/* Network choice: WiFi for real hardware, openeth for QEMU. The
 * Espressif QEMU fork models OpenCores Ethernet (`open_eth`) but not
 * the WiFi PHY, so phy_init crashes under emulation. Selected by
 * CONFIG_PSI_NET_OPENETH (default y for QEMU, n on real hardware). */
#ifdef CONFIG_PSI_NET_OPENETH
#include "esp_eth.h"
#include "esp_eth_driver.h"
#else
#include "esp_wifi.h"
#endif

#include "psi/esp_runtime.h"
#include "esp_obs_internal.h"

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

#define PSI_NET_BIT_CONNECTED BIT0
#define PSI_NET_BIT_FAIL BIT1

void psi_ws_server_start(void);

static EventGroupHandle_t g_net_events = NULL;

#ifdef CONFIG_PSI_NET_OPENETH
/* Ethernet path (QEMU). esp-qemu wires a simulated OpenCores
 * Ethernet (open_eth) onto the ESP32. ESP-IDF ships an `openeth`
 * MAC driver for it; no real PHY is involved. DHCP via slirp on
 * the host side hands us an address. */
static void psi_eth_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data) {
    (void)arg;
    (void)data;
    if (base == IP_EVENT && id == IP_EVENT_ETH_GOT_IP) {
        ESP_LOGI(TAG, "ethernet got IP");
        if (g_net_events != NULL)
            xEventGroupSetBits(g_net_events, PSI_NET_BIT_CONNECTED);
    }
}

static int psi_net_init(void) {
    esp_eth_mac_t *mac;
    esp_eth_phy_t *phy;
    esp_eth_handle_t eth_handle = NULL;
    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    esp_eth_config_t eth_cfg;
    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *netif;
    esp_event_handler_instance_t got_ip;

    g_net_events = xEventGroupCreate();
    if (g_net_events == NULL)
        return -1;

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    netif = esp_netif_new(&netif_cfg);

    /* The openeth driver wraps the OpenCores Ethernet device QEMU
     * exposes; ESP-IDF's helper takes the standard eth_mac_config_t. */
    mac = esp_eth_mac_new_openeth(&mac_cfg);
    phy_cfg.phy_addr = 1;
    phy = esp_eth_phy_new_dp83848(&phy_cfg);
    memset(&eth_cfg, 0, sizeof(eth_cfg));
    eth_cfg.mac = mac;
    eth_cfg.phy = phy;
    eth_cfg.check_link_period_ms = 2000;

    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));
    ESP_ERROR_CHECK(esp_netif_attach(netif, esp_eth_new_netif_glue(eth_handle)));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        IP_EVENT, IP_EVENT_ETH_GOT_IP, &psi_eth_event_handler, NULL, &got_ip));
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));

    {
        EventBits_t bits = xEventGroupWaitBits(g_net_events,
            PSI_NET_BIT_CONNECTED | PSI_NET_BIT_FAIL, pdFALSE, pdFALSE, pdMS_TO_TICKS(15000));
        if ((bits & PSI_NET_BIT_CONNECTED) == 0u) {
            ESP_LOGE(TAG, "ethernet failed to acquire IP");
            return -1;
        }
    }
    return 0;
}
#else
/* WiFi path (real hardware). */
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
        if (g_net_events != NULL)
            xEventGroupSetBits(g_net_events, PSI_NET_BIT_CONNECTED);
    }
}

static int psi_net_init(void) {
    wifi_init_config_t init_cfg = WIFI_INIT_CONFIG_DEFAULT();
    wifi_config_t wifi_cfg;
    esp_event_handler_instance_t any_id;
    esp_event_handler_instance_t got_ip;

    g_net_events = xEventGroupCreate();
    if (g_net_events == NULL)
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
    strncpy(
        (char *)wifi_cfg.sta.password, CONFIG_PSI_WIFI_PASS, sizeof(wifi_cfg.sta.password) - 1u);

    /* NVS fallback: when sdkconfig didn't bake in the SSID/password
     * (the committed default), read them from NVS namespace "psi"
     * under keys "wifi_ssid" / "wifi_pass". Lets a fresh build run on
     * any AP without recompiling, mirroring how anthropic_key is
     * shipped. NVS keys are <= 15 chars. */
    {
        nvs_handle_t h;
        if (nvs_open("psi", NVS_READONLY, &h) == ESP_OK) {
            size_t len;
            if (wifi_cfg.sta.ssid[0] == '\0') {
                len = sizeof(wifi_cfg.sta.ssid);
                if (nvs_get_str(h, "wifi_ssid", (char *)wifi_cfg.sta.ssid, &len) == ESP_OK)
                    ESP_LOGI(TAG, "wifi ssid from NVS: %s", (const char *)wifi_cfg.sta.ssid);
            }
            if (wifi_cfg.sta.password[0] == '\0') {
                len = sizeof(wifi_cfg.sta.password);
                if (nvs_get_str(h, "wifi_pass", (char *)wifi_cfg.sta.password, &len) == ESP_OK)
                    ESP_LOGI(TAG, "wifi password from NVS (%u bytes)", (unsigned)len);
            }
            nvs_close(h);
        }
    }
    wifi_cfg.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi_cfg));
    ESP_ERROR_CHECK(esp_wifi_start());

    {
        EventBits_t bits = xEventGroupWaitBits(g_net_events,
            PSI_NET_BIT_CONNECTED | PSI_NET_BIT_FAIL, pdFALSE, pdFALSE, pdMS_TO_TICKS(30000));
        if ((bits & PSI_NET_BIT_CONNECTED) == 0u) {
            ESP_LOGE(TAG, "wifi failed to associate");
            return -1;
        }
    }
    return 0;
}
#endif

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

    /* Surface secrets stored in NVS as environment variables before
     * the Lua VM starts. anthropic.lua reads ANTHROPIC_API_KEY via
     * os.getenv; on ESP-IDF newlib that goes through libc's environ,
     * which we populate from the "psi" NVS namespace here. The QEMU
     * test harness writes the key into NVS before launching the
     * firmware. Real-hardware builds use idf.py nvs-partition-gen. */
    {
        nvs_handle_t h;
        if (nvs_open("psi", NVS_READONLY, &h) == ESP_OK) {
            /* NVS limits keys to 15 chars, so we store under short
             * keys here and surface them as their full env-var
             * names (which Lua expects via os.getenv). */
            static const struct {
                const char *nvs_key;
                const char *env_name;
            } keys[] = {
                {"anthropic_key", "ANTHROPIC_API_KEY"},
                {"anthropic_base", "PSI_ANTHROPIC_BASE_URL"},
                {NULL, NULL},
            };
            size_t i;
            for (i = 0; keys[i].nvs_key != NULL; i++) {
                size_t len = 0;
                if (nvs_get_str(h, keys[i].nvs_key, NULL, &len) == ESP_OK && len > 0) {
                    char *buf = (char *)malloc(len);
                    if (buf != NULL && nvs_get_str(h, keys[i].nvs_key, buf, &len) == ESP_OK) {
                        setenv(keys[i].env_name, buf, 1);
                        ESP_LOGI(
                            TAG, "loaded %s from NVS (%u bytes)", keys[i].env_name, (unsigned)len);
                    }
                    free(buf);
                }
            }
            nvs_close(h);
        }
    }

    /* Initialize the abort signal the C agent uses on every WS turn. */
    psi_esp_runtime_init();

    ESP_LOGI(TAG, "free heap before prompt build: %lu",
        (unsigned long)heap_caps_get_free_size(MALLOC_CAP_8BIT));
    ESP_LOGI(TAG, "largest free block:            %lu",
        (unsigned long)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
#if PSI_USE_FORTH_PROMPT
    /* zForth path: tiny stack-based Forth, ~12 KiB total state.
     * Small enough that mbedTLS still gets its handshake buffers
     * afterward. Default extension language for the ESP build. */
    if (psi_esp_get_system_prompt() == NULL) {
        char *fth = psi_esp_forth_build_system_prompt();
        if (fth != NULL) {
            ESP_LOGI(TAG, "system prompt: from zforth (%u bytes)", (unsigned)strlen(fth));
            psi_esp_set_system_prompt(fth);
        } else {
            ESP_LOGW(TAG, "system prompt: zforth failed; falling back to baked-in C");
        }
    }
#endif
    /* Baked-in C fallback. Last resort if zforth fails to build a
     * prompt — ensures the agent never runs unframed. */
    if (psi_esp_get_system_prompt() == NULL) {
        char *baked = (char *)malloc(1024u);
        if (baked != NULL) {
            uint8_t mac[6];
            char mac_str[18] = "??:??:??:??:??:??";
            if (esp_efuse_mac_get_default(mac) == ESP_OK) {
                snprintf(mac_str, sizeof(mac_str), "%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1],
                    mac[2], mac[3], mac[4], mac[5]);
            }
            snprintf(baked, 1024u,
                "You are psi, a coding-agent runtime running on an ESP32 microcontroller "
                "(MAC %s) reachable over the local network. Tools: system_info, "
                "wifi_scan, ble_scan (NimBLE GAP discovery), http_fetch (HTTPS via "
                "mbedTLS), gpio_mode/read/write/blink, nvs_get/set, time_now, "
                "restart, uart_log (write to the operator's serial console), and "
                "forth_eval (evaluate zforth source against the firmware's "
                "persistent Forth dictionary). Prefer tools over guessing. Keep "
                "replies short — the user is on a phone or terminal.",
                mac_str);
            psi_esp_set_system_prompt(baked);
            ESP_LOGI(TAG, "system prompt: baked-in default (%u bytes)", (unsigned)strlen(baked));
        }
    }
    ESP_LOGI(TAG, "free heap after prompt build:  %lu",
        (unsigned long)heap_caps_get_free_size(MALLOC_CAP_8BIT));
    if (psi_net_init() != 0) {
        ESP_LOGE(TAG, "network init failed; refusing to start server");
        return;
    }

    /* NimBLE is NOT initialized here. Booting the BT controller eats
     * ~55 KiB and fragments the heap enough that mbedtls_ssl_setup
     * fails (MBEDTLS_ERR_SSL_ALLOC_FAILED) when the agent tries to
     * reach api.anthropic.com — even when no scan is in progress.
     * On no-PSRAM ESP32 we can't have both at the same time. The
     * ble_scan tool calls psi_esp_ble_init() lazily on first use;
     * once BT is up, agent HTTPS will fail until the chip restarts.
     * That's acceptable for a "scan once, see results" workflow. */

    psi_ws_server_start();
}
