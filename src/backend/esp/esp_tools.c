/* Built-in ESP32 tools the C agent can dispatch. Each handler is a
 * thin wrapper around an ESP-IDF API; they're meant to be small
 * enough that adding a new one is one struct entry plus a function. */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "cJSON.h"
#include "esp_chip_info.h"
#include "esp_crt_bundle.h"
#include "esp_heap_caps.h"
#include "esp_http_client.h"
#include "esp_idf_version.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "nvs.h"

/* GPIO is available on every ESP32 SoC variant. ESP-IDF v5.x has
 * driver/gpio.h for the legacy direct API; we use that for brevity. */
#include "driver/gpio.h"

#include "psi/common.h"
#include "psi/vm.h"
#include "esp_tools.h"
#include "esp_obs_internal.h" /* psi_esp_vm() */

static const char *TAG_NS = "psi";

/* ------------------------------------------------------------------ */
/* helpers                                                              */
/* ------------------------------------------------------------------ */

static char *json_to_string(cJSON *root) {
    char *txt = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    return txt; /* caller frees */
}

static char *err_text(const char *fmt, ...) {
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    return psi_strdup(buf);
}

static int json_int(const cJSON *o, const char *key, int dflt) {
    cJSON *n = cJSON_GetObjectItemCaseSensitive(o, key);
    return cJSON_IsNumber(n) ? (int)n->valuedouble : dflt;
}

static const char *json_str(const cJSON *o, const char *key, const char *dflt) {
    cJSON *n = cJSON_GetObjectItemCaseSensitive(o, key);
    return (cJSON_IsString(n) && n->valuestring) ? n->valuestring : dflt;
}

/* ------------------------------------------------------------------ */
/* system_info                                                          */
/* ------------------------------------------------------------------ */

static char *tool_system_info(const cJSON *input, char **err) {
    esp_chip_info_t chip;
    esp_netif_t *netif;
    esp_netif_ip_info_t ip;
    char ip_str[16] = "0.0.0.0";
    char gw_str[16] = "0.0.0.0";
    char mac_str[18] = "00:00:00:00:00:00";
    uint8_t mac[6];
    cJSON *root;
    (void)input;
    (void)err;

    esp_chip_info(&chip);

    /* Default Ethernet netif name; falls through to NULL on WiFi
     * builds, in which case we just leave 0.0.0.0. */
    netif = esp_netif_get_handle_from_ifkey("ETH_DEF");
    if (netif == NULL)
        netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    if (netif != NULL && esp_netif_get_ip_info(netif, &ip) == ESP_OK) {
        snprintf(ip_str, sizeof(ip_str), IPSTR, IP2STR(&ip.ip));
        snprintf(gw_str, sizeof(gw_str), IPSTR, IP2STR(&ip.gw));
    }

    if (esp_efuse_mac_get_default(mac) == ESP_OK) {
        snprintf(mac_str, sizeof(mac_str), "%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1], mac[2],
            mac[3], mac[4], mac[5]);
    }

    root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "chip_model",
        chip.model == CHIP_ESP32       ? "esp32" :
            chip.model == CHIP_ESP32S2 ? "esp32s2" :
            chip.model == CHIP_ESP32S3 ? "esp32s3" :
            chip.model == CHIP_ESP32C3 ? "esp32c3" :
            chip.model == CHIP_ESP32C6 ? "esp32c6" :
                                         "unknown");
    cJSON_AddNumberToObject(root, "chip_revision", chip.revision);
    cJSON_AddNumberToObject(root, "cores", chip.cores);
    cJSON_AddStringToObject(root, "idf_version", esp_get_idf_version());
    cJSON_AddStringToObject(root, "mac", mac_str);
    cJSON_AddStringToObject(root, "ip", ip_str);
    cJSON_AddStringToObject(root, "gateway", gw_str);
    cJSON_AddNumberToObject(
        root, "free_heap_bytes", (double)heap_caps_get_free_size(MALLOC_CAP_8BIT));
    cJSON_AddNumberToObject(
        root, "largest_free_block", (double)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
    cJSON_AddNumberToObject(root, "uptime_ms", (double)(esp_timer_get_time() / 1000));
    cJSON_AddNumberToObject(root, "reset_reason", (double)esp_reset_reason());
    return json_to_string(root);
}

/* ------------------------------------------------------------------ */
/* gpio_*                                                               */
/* ------------------------------------------------------------------ */

/* GPIO direction can't be read back through driver/gpio.h, so when
 * PSI_GPIO_INTROSPECTION is on we shadow the last requested mode +
 * commanded output level for every pin. The agent could bypass our
 * tools via lua_eval — in that case the grid lags until the next
 * gpio_mode call. */
#define PSI_ESP_GPIO_COUNT 40

enum psi_gpio_shadow_mode {
    PSI_GPIO_OFF = 0,
    PSI_GPIO_IN,
    PSI_GPIO_OUT,
    PSI_GPIO_PULLUP,
    PSI_GPIO_PULLDOWN
};

/* Single source of truth for the agent-facing mode names: maps the
 * JSON string the model sends (and the dashboard renders) to the
 * gpio_config_t fields and the shadow enum. Adding a new mode here
 * is a single row. */
static const struct {
    const char *name;
    gpio_mode_t mode;
    uint8_t pull_up;
    uint8_t pull_down;
    enum psi_gpio_shadow_mode shadow;
} PSI_GPIO_MODES[] = {
    {"out", GPIO_MODE_OUTPUT, 0, 0, PSI_GPIO_OUT},
    {"in", GPIO_MODE_INPUT, 0, 0, PSI_GPIO_IN},
    {"pullup", GPIO_MODE_INPUT, 1, 0, PSI_GPIO_PULLUP},
    {"pulldown", GPIO_MODE_INPUT, 0, 1, PSI_GPIO_PULLDOWN},
};
#define PSI_GPIO_MODES_N (sizeof(PSI_GPIO_MODES) / sizeof(PSI_GPIO_MODES[0]))

static int psi_gpio_find_mode(const char *name) {
    size_t i;
    for (i = 0; i < PSI_GPIO_MODES_N; i++) {
        if (strcmp(PSI_GPIO_MODES[i].name, name) == 0)
            return (int)i;
    }
    return -1;
}

#if PSI_GPIO_INTROSPECTION
static uint8_t g_gpio_mode[PSI_ESP_GPIO_COUNT]; /* enum psi_gpio_shadow_mode */
static int8_t g_gpio_level[PSI_ESP_GPIO_COUNT]; /* -1 = unknown, else 0/1 */

static const char *gpio_shadow_name(enum psi_gpio_shadow_mode m) {
    size_t i;
    for (i = 0; i < PSI_GPIO_MODES_N; i++) {
        if (PSI_GPIO_MODES[i].shadow == m)
            return PSI_GPIO_MODES[i].name;
    }
    return "off";
}

char *psi_esp_gpio_snapshot_json(void) {
    cJSON *root = cJSON_CreateObject();
    cJSON *pins = cJSON_AddArrayToObject(root, "pins");
    int i;
    for (i = 0; i < PSI_ESP_GPIO_COUNT; i++) {
        cJSON *p = cJSON_CreateObject();
        enum psi_gpio_shadow_mode m = (enum psi_gpio_shadow_mode)g_gpio_mode[i];
        cJSON_AddNumberToObject(p, "n", (double)i);
        cJSON_AddStringToObject(p, "mode", gpio_shadow_name(m));
        if (m == PSI_GPIO_OUT) {
            cJSON_AddNumberToObject(
                p, "level", g_gpio_level[i] >= 0 ? (double)g_gpio_level[i] : 0.0);
            if (g_gpio_level[i] < 0)
                cJSON_AddBoolToObject(p, "unknown", 1);
        } else if (m == PSI_GPIO_OFF) {
            cJSON_AddNullToObject(p, "level");
        } else {
            cJSON_AddNumberToObject(p, "level", (double)gpio_get_level((gpio_num_t)i));
        }
        cJSON_AddItemToArray(pins, p);
    }
    return json_to_string(root);
}
#endif /* PSI_GPIO_INTROSPECTION */

static char *tool_gpio_mode(const cJSON *input, char **err) {
    int pin = json_int(input, "pin", -1);
    const char *mode = json_str(input, "mode", "");
    int idx = psi_gpio_find_mode(mode);
    gpio_config_t cfg;

    if (pin < 0 || pin >= GPIO_NUM_MAX) {
        if (err)
            *err = err_text("invalid pin %d", pin);
        return NULL;
    }
    if (idx < 0) {
        if (err)
            *err = err_text("mode must be one of: in, out, pullup, pulldown");
        return NULL;
    }
    memset(&cfg, 0, sizeof(cfg));
    cfg.pin_bit_mask = 1ULL << pin;
    cfg.intr_type = GPIO_INTR_DISABLE;
    cfg.mode = PSI_GPIO_MODES[idx].mode;
    if (PSI_GPIO_MODES[idx].pull_up)
        cfg.pull_up_en = GPIO_PULLUP_ENABLE;
    if (PSI_GPIO_MODES[idx].pull_down)
        cfg.pull_down_en = GPIO_PULLDOWN_ENABLE;
    if (gpio_config(&cfg) != ESP_OK) {
        if (err)
            *err = err_text("gpio_config failed");
        return NULL;
    }
#if PSI_GPIO_INTROSPECTION
    if (pin < PSI_ESP_GPIO_COUNT) {
        g_gpio_mode[pin] = (uint8_t)PSI_GPIO_MODES[idx].shadow;
        /* Switching out of OUTPUT clears the cached level so the grid
         * stops claiming we know what's on the line. */
        if (g_gpio_mode[pin] != PSI_GPIO_OUT)
            g_gpio_level[pin] = -1;
    }
#endif
    {
        cJSON *r = cJSON_CreateObject();
        cJSON_AddBoolToObject(r, "ok", 1);
        cJSON_AddNumberToObject(r, "pin", pin);
        cJSON_AddStringToObject(r, "mode", mode);
        return json_to_string(r);
    }
}

static char *tool_gpio_read(const cJSON *input, char **err) {
    int pin = json_int(input, "pin", -1);
    int level;
    cJSON *r;
    if (pin < 0 || pin >= GPIO_NUM_MAX) {
        if (err)
            *err = err_text("invalid pin %d", pin);
        return NULL;
    }
    level = gpio_get_level(pin);
    r = cJSON_CreateObject();
    cJSON_AddNumberToObject(r, "pin", pin);
    cJSON_AddNumberToObject(r, "level", level);
    return json_to_string(r);
}

static char *tool_gpio_write(const cJSON *input, char **err) {
    int pin = json_int(input, "pin", -1);
    int level = json_int(input, "level", -1);
    cJSON *r;
    if (pin < 0 || pin >= GPIO_NUM_MAX) {
        if (err)
            *err = err_text("invalid pin %d", pin);
        return NULL;
    }
    if (level != 0 && level != 1) {
        if (err)
            *err = err_text("level must be 0 or 1");
        return NULL;
    }
    if (gpio_set_level(pin, level) != ESP_OK) {
        if (err)
            *err = err_text("gpio_set_level failed (configure as output first?)");
        return NULL;
    }
#if PSI_GPIO_INTROSPECTION
    if (pin < PSI_ESP_GPIO_COUNT)
        g_gpio_level[pin] = (int8_t)level;
#endif
    r = cJSON_CreateObject();
    cJSON_AddBoolToObject(r, "ok", 1);
    cJSON_AddNumberToObject(r, "pin", pin);
    cJSON_AddNumberToObject(r, "level", level);
    return json_to_string(r);
}

/* ------------------------------------------------------------------ */
/* nvs_get / nvs_set — small persistent string store, namespace "psi"   */
/* ------------------------------------------------------------------ */

static char *tool_nvs_get(const cJSON *input, char **err) {
    const char *key = json_str(input, "key", NULL);
    nvs_handle_t h;
    size_t sz = 0;
    char *buf;
    cJSON *r;

    if (key == NULL || *key == '\0') {
        if (err)
            *err = err_text("missing string field: key");
        return NULL;
    }
    if (strlen(key) > 15) {
        if (err)
            *err = err_text("nvs key must be <= 15 characters");
        return NULL;
    }
    if (nvs_open(TAG_NS, NVS_READONLY, &h) != ESP_OK) {
        if (err)
            *err = err_text("nvs_open failed");
        return NULL;
    }
    if (nvs_get_str(h, key, NULL, &sz) != ESP_OK || sz == 0u) {
        nvs_close(h);
        r = cJSON_CreateObject();
        cJSON_AddNullToObject(r, "value");
        cJSON_AddBoolToObject(r, "found", 0);
        return json_to_string(r);
    }
    buf = (char *)malloc(sz);
    if (buf == NULL || nvs_get_str(h, key, buf, &sz) != ESP_OK) {
        free(buf);
        nvs_close(h);
        if (err)
            *err = err_text("nvs_get_str failed");
        return NULL;
    }
    nvs_close(h);
    r = cJSON_CreateObject();
    cJSON_AddStringToObject(r, "value", buf);
    cJSON_AddBoolToObject(r, "found", 1);
    free(buf);
    return json_to_string(r);
}

static char *tool_nvs_set(const cJSON *input, char **err) {
    const char *key = json_str(input, "key", NULL);
    const char *value = json_str(input, "value", "");
    nvs_handle_t h;
    cJSON *r;
    if (key == NULL || *key == '\0') {
        if (err)
            *err = err_text("missing string field: key");
        return NULL;
    }
    if (strlen(key) > 15) {
        if (err)
            *err = err_text("nvs key must be <= 15 characters");
        return NULL;
    }
    if (nvs_open(TAG_NS, NVS_READWRITE, &h) != ESP_OK) {
        if (err)
            *err = err_text("nvs_open failed");
        return NULL;
    }
    if (nvs_set_str(h, key, value) != ESP_OK || nvs_commit(h) != ESP_OK) {
        nvs_close(h);
        if (err)
            *err = err_text("nvs write failed");
        return NULL;
    }
    nvs_close(h);
    r = cJSON_CreateObject();
    cJSON_AddBoolToObject(r, "ok", 1);
    cJSON_AddStringToObject(r, "key", key);
    cJSON_AddNumberToObject(r, "bytes", (double)strlen(value));
    return json_to_string(r);
}

/* ------------------------------------------------------------------ */
/* time_now                                                             */
/* ------------------------------------------------------------------ */

static char *tool_time_now(const cJSON *input, char **err) {
    time_t now = time(NULL);
    struct tm gm;
    char iso[32] = "1970-01-01T00:00:00Z";
    cJSON *r;
    (void)input;
    (void)err;
    if (gmtime_r(&now, &gm) != NULL) {
        strftime(iso, sizeof(iso), "%Y-%m-%dT%H:%M:%SZ", &gm);
    }
    r = cJSON_CreateObject();
    cJSON_AddNumberToObject(r, "epoch_seconds", (double)now);
    cJSON_AddStringToObject(r, "iso_utc", iso);
    cJSON_AddNumberToObject(r, "uptime_ms", (double)(esp_timer_get_time() / 1000));
    return json_to_string(r);
}

/* ------------------------------------------------------------------ */
/* restart                                                              */
/* ------------------------------------------------------------------ */

static char *tool_restart(const cJSON *input, char **err) {
    /* 1s delay before esp_restart so the WS frame carrying this
     * tool_result actually flushes to the client before reset. */
    cJSON *r;
    (void)input;
    (void)err;
    r = cJSON_CreateObject();
    cJSON_AddBoolToObject(r, "ok", 1);
    cJSON_AddStringToObject(r, "note", "restart scheduled in 1s");
    {
        char *out = json_to_string(r);
        vTaskDelay(pdMS_TO_TICKS(1000));
        esp_restart();
        return out; /* unreachable, but the compiler doesn't know */
    }
}

/* ------------------------------------------------------------------ */
/* lua_eval                                                             */
/* ------------------------------------------------------------------ */

/* Run a Lua snippet against the firmware's shared psi_vm. Tries the
 * input as an expression first ("return <code>") so simple lookups
 * like "psi.runtime_info().version" return their value; on parse
 * failure, falls back to running it as a statement so longer scripts
 * still work. The Lua state is single-threaded — only the worker task
 * dispatches tools, and it does so serially — so concurrent access
 * isn't a concern.
 *
 * The result is stringified via luaL_tolstring (which calls __tostring
 * if defined, otherwise gives a sensible default for nil/bool/number/
 * string/table). Tool output is wrapped in a JSON object {ok, result,
 * stdout?} so the model can act on it. */
static char *tool_lua_eval(const cJSON *input, char **err) {
    const char *code = json_str(input, "code", NULL);
    struct psi_vm *vm = psi_esp_vm();
    lua_State *L;
    int top;
    int rc;
    cJSON *r;
    char *wrapped;
    size_t code_len;
    const char *result_str;
    size_t result_len;

    if (vm == NULL || vm->L == NULL) {
        if (err)
            *err = err_text("psi VM not initialized");
        return NULL;
    }
    if (code == NULL || *code == '\0') {
        if (err)
            *err = err_text("missing string field: code");
        return NULL;
    }
    L = vm->L;
    top = lua_gettop(L);

    /* Try expression form first: "return (<code>)". */
    code_len = strlen(code);
    wrapped = (char *)malloc(code_len + 16u);
    if (wrapped == NULL) {
        if (err)
            *err = err_text("out of memory");
        return NULL;
    }
    snprintf(wrapped, code_len + 16u, "return (%s)", code);
    rc = luaL_loadbuffer(L, wrapped, strlen(wrapped), "=lua_eval");
    free(wrapped);
    if (rc != LUA_OK) {
        /* Drop the expression-form error, retry as a statement. */
        lua_pop(L, 1);
        rc = luaL_loadbuffer(L, code, code_len, "=lua_eval");
    }
    if (rc != LUA_OK) {
        const char *e = lua_tostring(L, -1);
        char *msg = err_text("compile: %s", e ? e : "?");
        lua_settop(L, top);
        if (err)
            *err = msg;
        else
            free(msg);
        return NULL;
    }

    rc = lua_pcall(L, 0, LUA_MULTRET, 0);
    if (rc != LUA_OK) {
        const char *e = lua_tostring(L, -1);
        char *msg = err_text("runtime: %s", e ? e : "?");
        lua_settop(L, top);
        if (err)
            *err = msg;
        else
            free(msg);
        return NULL;
    }

    /* Stringify whatever's on top (may be nil for statement form). */
    if (lua_gettop(L) > top) {
        result_str = luaL_tolstring(L, -1, &result_len);
    } else {
        result_str = "";
        result_len = 0u;
    }

    /* luaL_tolstring leaves a NUL-terminated string on the Lua
     * stack, so we can pass it straight to cJSON; no copy needed. */
    (void)result_len;
    r = cJSON_CreateObject();
    cJSON_AddBoolToObject(r, "ok", 1);
    cJSON_AddStringToObject(r, "result", result_str ? result_str : "");
    lua_settop(L, top);
    return json_to_string(r);
}

/* ------------------------------------------------------------------ */
/* http_fetch                                                           */
/* ------------------------------------------------------------------ */

struct fetch_collector {
    char *data;
    size_t len;
    size_t cap;
    int oom;
    int truncated;
    size_t cap_max;
};

static esp_err_t fetch_event_cb(esp_http_client_event_t *evt) {
    struct fetch_collector *c = (struct fetch_collector *)evt->user_data;
    size_t need;
    if (c == NULL || evt->event_id != HTTP_EVENT_ON_DATA)
        return ESP_OK;
    if (evt->data_len <= 0)
        return ESP_OK;
    if (c->truncated)
        return ESP_OK;
    need = c->len + (size_t)evt->data_len + 1u;
    if (need > c->cap_max) {
        size_t take = c->cap_max > c->len ? c->cap_max - c->len - 1u : 0u;
        if (take > 0u) {
            if (need > c->cap) {
                char *n = (char *)realloc(c->data, c->cap_max);
                if (n == NULL) {
                    c->oom = 1;
                    return ESP_OK;
                }
                c->data = n;
                c->cap = c->cap_max;
            }
            memcpy(c->data + c->len, evt->data, take);
            c->len += take;
            c->data[c->len] = '\0';
        }
        c->truncated = 1;
        return ESP_OK;
    }
    if (need > c->cap) {
        size_t cap = c->cap ? c->cap * 2u : 1024u;
        char *n;
        while (cap < need)
            cap *= 2u;
        if (cap > c->cap_max)
            cap = c->cap_max;
        n = (char *)realloc(c->data, cap);
        if (n == NULL) {
            c->oom = 1;
            return ESP_OK;
        }
        c->data = n;
        c->cap = cap;
    }
    memcpy(c->data + c->len, evt->data, (size_t)evt->data_len);
    c->len += (size_t)evt->data_len;
    c->data[c->len] = '\0';
    return ESP_OK;
}

static char *tool_http_fetch(const cJSON *input, char **err) {
    const char *url = json_str(input, "url", NULL);
    const char *method = json_str(input, "method", "GET");
    const char *body = json_str(input, "body", NULL);
    const cJSON *headers = cJSON_GetObjectItemCaseSensitive(input, "headers");
    int max_bytes = json_int(input, "max_bytes", 8192);
    esp_http_client_method_t m = HTTP_METHOD_GET;
    esp_http_client_config_t cfg;
    esp_http_client_handle_t cli;
    struct fetch_collector c;
    esp_err_t e;
    cJSON *r;

    if (url == NULL || *url == '\0') {
        if (err)
            *err = err_text("missing string field: url");
        return NULL;
    }
    if (max_bytes <= 0)
        max_bytes = 8192;
    if (max_bytes > 65536)
        max_bytes = 65536; /* keep memory bounded */

    if (strcmp(method, "POST") == 0)
        m = HTTP_METHOD_POST;
    else if (strcmp(method, "PUT") == 0)
        m = HTTP_METHOD_PUT;
    else if (strcmp(method, "DELETE") == 0)
        m = HTTP_METHOD_DELETE;
    else if (strcmp(method, "HEAD") == 0)
        m = HTTP_METHOD_HEAD;

    memset(&c, 0, sizeof(c));
    c.cap_max = (size_t)max_bytes + 1u;

    memset(&cfg, 0, sizeof(cfg));
    cfg.url = url;
    cfg.method = m;
    cfg.event_handler = fetch_event_cb;
    cfg.user_data = &c;
    cfg.timeout_ms = 30000;
    cfg.crt_bundle_attach = esp_crt_bundle_attach;
    cfg.buffer_size = 4096;
    cfg.buffer_size_tx = 4096;

    cli = esp_http_client_init(&cfg);
    if (cli == NULL) {
        if (err)
            *err = err_text("esp_http_client_init failed");
        free(c.data);
        return NULL;
    }
    if (cJSON_IsArray(headers)) {
        cJSON *h;
        cJSON_ArrayForEach(h, headers) {
            if (cJSON_IsString(h) && h->valuestring != NULL) {
                const char *colon = strchr(h->valuestring, ':');
                if (colon != NULL) {
                    char name[128];
                    size_t nl = (size_t)(colon - h->valuestring);
                    const char *v = colon + 1;
                    if (nl >= sizeof(name))
                        nl = sizeof(name) - 1u;
                    memcpy(name, h->valuestring, nl);
                    name[nl] = '\0';
                    while (*v == ' ' || *v == '\t')
                        v++;
                    esp_http_client_set_header(cli, name, v);
                }
            }
        }
    }
    if (body != NULL && *body != '\0' && (m == HTTP_METHOD_POST || m == HTTP_METHOD_PUT))
        esp_http_client_set_post_field(cli, body, (int)strlen(body));

    e = esp_http_client_perform(cli);
    {
        int status = esp_http_client_get_status_code(cli);
        r = cJSON_CreateObject();
        cJSON_AddBoolToObject(r, "ok", e == ESP_OK && status >= 200 && status < 300);
        cJSON_AddNumberToObject(r, "status", (double)status);
        cJSON_AddStringToObject(r, "url", url);
        if (e != ESP_OK)
            cJSON_AddStringToObject(r, "transport_error", esp_err_to_name(e));
        if (c.oom)
            cJSON_AddBoolToObject(r, "oom", 1);
        if (c.truncated) {
            cJSON_AddBoolToObject(r, "truncated", 1);
            cJSON_AddNumberToObject(r, "max_bytes", (double)max_bytes);
        }
        cJSON_AddNumberToObject(r, "bytes", (double)c.len);
        cJSON_AddStringToObject(r, "body", c.data ? c.data : "");
    }
    esp_http_client_cleanup(cli);
    free(c.data);
    return json_to_string(r);
}

/* ------------------------------------------------------------------ */
/* registry                                                             */
/* ------------------------------------------------------------------ */

const struct psi_esp_tool psi_esp_tool_table[] = {
    {
        .name = "system_info",
        .description = "Return ESP32 chip + network state: model, cores, MAC, IP, "
                       "free heap, uptime, reset reason. No arguments.",
        .input_schema_json =
            "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}",
        .handler = tool_system_info,
    },
    {
        .name = "gpio_mode",
        .description = "Configure a GPIO pin's direction and pull. Required: "
                       "pin (int), mode (one of: in, out, pullup, pulldown).",
        .input_schema_json =
            "{\"type\":\"object\","
            "\"properties\":{"
            "\"pin\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":48},"
            "\"mode\":{\"type\":\"string\",\"enum\":[\"in\",\"out\",\"pullup\",\"pulldown\"]}},"
            "\"required\":[\"pin\",\"mode\"]}",
        .handler = tool_gpio_mode,
    },
    {
        .name = "gpio_read",
        .description = "Read a GPIO pin's current digital level (0 or 1). "
                       "Configure the pin with gpio_mode first.",
        .input_schema_json =
            "{\"type\":\"object\","
            "\"properties\":{\"pin\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":48}},"
            "\"required\":[\"pin\"]}",
        .handler = tool_gpio_read,
    },
    {
        .name = "gpio_write",
        .description = "Drive a GPIO pin high or low. Pin must already be in "
                       "output mode. Required: pin (int), level (0 or 1).",
        .input_schema_json = "{\"type\":\"object\","
                             "\"properties\":{"
                             "\"pin\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":48},"
                             "\"level\":{\"type\":\"integer\",\"enum\":[0,1]}},"
                             "\"required\":[\"pin\",\"level\"]}",
        .handler = tool_gpio_write,
    },
    {
        .name = "nvs_get",
        .description = "Read a string value from the device's persistent key/value "
                       "store (NVS). Returns {value, found}; value is null when missing. "
                       "Keys are <= 15 chars, namespace is 'psi'.",
        .input_schema_json = "{\"type\":\"object\","
                             "\"properties\":{\"key\":{\"type\":\"string\",\"maxLength\":15}},"
                             "\"required\":[\"key\"]}",
        .handler = tool_nvs_get,
    },
    {
        .name = "nvs_set",
        .description = "Write a string value to NVS so it survives reboots. "
                       "Required: key (<= 15 chars), value (string).",
        .input_schema_json = "{\"type\":\"object\","
                             "\"properties\":{"
                             "\"key\":{\"type\":\"string\",\"maxLength\":15},"
                             "\"value\":{\"type\":\"string\"}},"
                             "\"required\":[\"key\",\"value\"]}",
        .handler = tool_nvs_set,
    },
    {
        .name = "time_now",
        .description = "Return the current time. Without an SNTP sync the epoch "
                       "starts at boot, so prefer uptime_ms for relative timing.",
        .input_schema_json =
            "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}",
        .handler = tool_time_now,
    },
    {
        .name = "restart",
        .description = "Reboot the ESP32. The WebSocket connection drops; the "
                       "device comes back up in ~5s. Use sparingly.",
        .input_schema_json =
            "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}",
        .handler = tool_restart,
    },
    {
        .name = "lua_eval",
        .description = "Evaluate a Lua expression or short script in the firmware's "
                       "psi VM. Returns {ok, result} where result is the "
                       "stringified return value. The VM has psi.* primitives "
                       "loaded; e.g. psi.runtime_info(), psi.json_encode(t), "
                       "psi.ramfs.read('@mem/foo'). Run untrusted code with care.",
        .input_schema_json = "{\"type\":\"object\","
                             "\"properties\":{\"code\":{\"type\":\"string\"}},"
                             "\"required\":[\"code\"]}",
        .handler = tool_lua_eval,
    },
    {
        .name = "http_fetch",
        .description = "Make an HTTP/HTTPS request from the device. Returns "
                       "{ok, status, body, bytes, truncated?}. Useful for IoT "
                       "webhooks, weather APIs, ifconfig.io, etc. body is "
                       "capped at max_bytes (default 8 KiB, max 64 KiB).",
        .input_schema_json =
            "{\"type\":\"object\","
            "\"properties\":{"
            "\"url\":{\"type\":\"string\"},"
            "\"method\":{\"type\":\"string\",\"enum\":[\"GET\",\"POST\",\"PUT\",\"DELETE\","
            "\"HEAD\"]},"
            "\"body\":{\"type\":\"string\"},"
            "\"headers\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},"
            "\"max_bytes\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":65536}},"
            "\"required\":[\"url\"]}",
        .handler = tool_http_fetch,
    },
    {NULL, NULL, NULL, NULL},
};

const struct psi_esp_tool *psi_esp_tool_find(const char *name) {
    const struct psi_esp_tool *t;
    if (name == NULL)
        return NULL;
    for (t = psi_esp_tool_table; t->name != NULL; t++) {
        if (strcmp(t->name, name) == 0)
            return t;
    }
    return NULL;
}
