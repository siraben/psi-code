/* NimBLE bring-up + ble_scan agent tool.
 *
 * The chip's BT controller is enabled at compile time
 * (CONFIG_BT_ENABLED in sdkconfig.hardware) and NimBLE runs as the
 * host. Init happens once after WiFi is up — we wait on a sync
 * semaphore the host fires once it's ready to accept GAP commands.
 *
 * The scan tool starts a GAP discovery for the requested duration,
 * accumulates each advertisement into a fixed-size buffer (under a
 * mutex because the NimBLE host task fires the callback
 * concurrently with the agent worker), then formats the buffer as
 * JSON for the model. We deliberately don't pin the BLE host task
 * to a core or fight the WiFi/BLE coexistence layer; ESP-IDF's
 * default time-slicing is fine for a single scan-style tool.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "esp_bt.h"
#include "host/ble_gap.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/ble.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"

#include "psi/common.h"
#include "esp_obs_internal.h"

static const char *TAG = "psi_ble";

/* Per-advertisement record, accumulated by the GAP callback. We
 * stage these in C structs (not cJSON) inside the callback so the
 * critical section is short and we don't touch cJSON from two
 * tasks. JSON is built afterward, in the tool function. */
struct ble_dev {
    uint8_t addr[6];
    uint8_t addr_type;
    int8_t rssi;
    int has_name;
    char name[32];
};

struct ble_scan_state {
    SemaphoreHandle_t mutex;
    struct ble_dev *devs;
    int count;
    int cap;
    int duplicates_skipped;
};

static int g_ble_inited = 0;
static SemaphoreHandle_t g_ble_sync_sem = NULL;
static struct ble_scan_state *g_active_scan = NULL;

static int ble_addr_eq(const uint8_t *a, const uint8_t *b) {
    int i;
    for (i = 0; i < 6; i++)
        if (a[i] != b[i])
            return 0;
    return 1;
}

static void on_sync(void) {
    /* Generate a default identity address if we don't have one yet,
     * then signal the init waiter. */
    int rc = ble_hs_util_ensure_addr(0);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_hs_util_ensure_addr rc=%d", rc);
    }
    if (g_ble_sync_sem != NULL)
        xSemaphoreGive(g_ble_sync_sem);
}

static void on_reset(int reason) {
    ESP_LOGW(TAG, "BLE host reset, reason=%d", reason);
}

static void host_task(void *param) {
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

int psi_esp_ble_init(void) {
    if (g_ble_inited)
        return 0;
    g_ble_sync_sem = xSemaphoreCreateBinary();
    if (g_ble_sync_sem == NULL)
        return -1;

    esp_err_t e = nimble_port_init();
    if (e != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init: %d", (int)e);
        return -1;
    }
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;

    nimble_port_freertos_init(host_task);

    if (xSemaphoreTake(g_ble_sync_sem, pdMS_TO_TICKS(10000)) != pdTRUE) {
        ESP_LOGE(TAG, "BLE sync timeout");
        return -1;
    }
    g_ble_inited = 1;
    ESP_LOGI(TAG, "NimBLE up");
    return 0;
}

/* GAP event handler. Called from the NimBLE host task with each
 * advertisement; we copy the bits we want into the active scan
 * buffer (under its mutex) and return quickly. */
static int gap_event(struct ble_gap_event *event, void *arg) {
    (void)arg;
    if (event->type != BLE_GAP_EVENT_DISC && event->type != BLE_GAP_EVENT_EXT_DISC)
        return 0;

    struct ble_scan_state *st = g_active_scan;
    if (st == NULL)
        return 0;

    const uint8_t *addr;
    uint8_t addr_type;
    int8_t rssi;
    const uint8_t *adv_data;
    uint8_t adv_len;

    if (event->type == BLE_GAP_EVENT_DISC) {
        addr = event->disc.addr.val;
        addr_type = event->disc.addr.type;
        rssi = event->disc.rssi;
        adv_data = event->disc.data;
        adv_len = event->disc.length_data;
    } else {
        return 0;
    }

    xSemaphoreTake(st->mutex, portMAX_DELAY);

    /* Dedupe by address — many devices broadcast multiple
     * advertisements per second. */
    int i;
    for (i = 0; i < st->count; i++) {
        if (st->devs[i].addr_type == addr_type && ble_addr_eq(st->devs[i].addr, addr)) {
            /* Update RSSI to most recent reading. */
            st->devs[i].rssi = rssi;
            st->duplicates_skipped++;
            xSemaphoreGive(st->mutex);
            return 0;
        }
    }

    if (st->count < st->cap) {
        struct ble_dev *d = &st->devs[st->count];
        memcpy(d->addr, addr, 6);
        d->addr_type = addr_type;
        d->rssi = rssi;
        d->has_name = 0;
        d->name[0] = '\0';

        struct ble_hs_adv_fields fields;
        if (ble_hs_adv_parse_fields(&fields, adv_data, adv_len) == 0) {
            const uint8_t *name = fields.name;
            uint8_t name_len = fields.name_len;
            if (name != NULL && name_len > 0) {
                size_t n = name_len < (sizeof(d->name) - 1u) ? name_len : sizeof(d->name) - 1u;
                memcpy(d->name, name, n);
                d->name[n] = '\0';
                d->has_name = 1;
            }
        }
        st->count++;
    }

    xSemaphoreGive(st->mutex);
    return 0;
}

char *psi_esp_ble_scan_json(int duration_ms, int max_results) {
    if (duration_ms < 500)
        duration_ms = 500;
    if (duration_ms > 10000)
        duration_ms = 10000;
    if (max_results < 1)
        max_results = 1;
    if (max_results > 64)
        max_results = 64;

    if (!g_ble_inited) {
        if (psi_esp_ble_init() != 0)
            return NULL;
    }

    struct ble_scan_state st;
    st.mutex = xSemaphoreCreateMutex();
    st.devs = (struct ble_dev *)calloc((size_t)max_results, sizeof(struct ble_dev));
    st.count = 0;
    st.cap = max_results;
    st.duplicates_skipped = 0;
    if (st.mutex == NULL || st.devs == NULL) {
        if (st.mutex != NULL)
            vSemaphoreDelete(st.mutex);
        free(st.devs);
        return NULL;
    }

    /* Install state pointer, kick off scan. NimBLE's discovery API
     * is non-blocking; the callback fires per advertisement until
     * we cancel or the duration elapses. */
    g_active_scan = &st;

    struct ble_gap_disc_params dp;
    memset(&dp, 0, sizeof(dp));
    dp.passive = 0; /* active scan = ask for scan-response too */
    dp.itvl = 0;
    dp.window = 0;
    dp.filter_duplicates = 1;
    dp.filter_policy = 0;
    dp.limited = 0;

    int rc = ble_gap_disc(BLE_OWN_ADDR_PUBLIC, duration_ms, &dp, gap_event, NULL);
    if (rc != 0) {
        ESP_LOGW(TAG, "ble_gap_disc rc=%d", rc);
        g_active_scan = NULL;
        vSemaphoreDelete(st.mutex);
        free(st.devs);
        return NULL;
    }

    vTaskDelay(pdMS_TO_TICKS(duration_ms + 200));
    if (ble_gap_disc_active())
        ble_gap_disc_cancel();

    g_active_scan = NULL;

    /* Build the response JSON from the staged array. */
    cJSON *root = cJSON_CreateObject();
    cJSON *devs = cJSON_AddArrayToObject(root, "devices");
    int i;
    char addr_str[18];
    for (i = 0; i < st.count; i++) {
        cJSON *o = cJSON_CreateObject();
        snprintf(addr_str, sizeof(addr_str), "%02x:%02x:%02x:%02x:%02x:%02x", st.devs[i].addr[5],
            st.devs[i].addr[4], st.devs[i].addr[3], st.devs[i].addr[2], st.devs[i].addr[1],
            st.devs[i].addr[0]);
        cJSON_AddStringToObject(o, "addr", addr_str);
        cJSON_AddNumberToObject(o, "rssi", (double)st.devs[i].rssi);
        cJSON_AddNumberToObject(o, "addr_type", (double)st.devs[i].addr_type);
        if (st.devs[i].has_name)
            cJSON_AddStringToObject(o, "name", st.devs[i].name);
        cJSON_AddItemToArray(devs, o);
    }
    cJSON_AddNumberToObject(root, "count", (double)st.count);
    cJSON_AddNumberToObject(root, "duration_ms", (double)duration_ms);
    if (st.duplicates_skipped > 0)
        cJSON_AddNumberToObject(root, "duplicate_advertisements", (double)st.duplicates_skipped);

    vSemaphoreDelete(st.mutex);
    free(st.devs);

    char *out = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    return out;
}
