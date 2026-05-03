/* Chibi-Scheme glue.
 *
 * Used to build the agent's system prompt at boot. The Lua VM that
 * normally runs psi.prompt.system_prompt() OOMs on no-PSRAM ESP32s
 * (the embedded module graph is too big for the ~256 KiB internal
 * heap), so when that fails we fall back to evaluating a tiny
 * Scheme expression here. Chibi's runtime + a 48 KiB GC heap fits
 * inside ~70 KiB of RAM total — small enough to stand up after WiFi
 * has eaten its share of contiguous space.
 *
 * Scope is deliberately narrow: spin up a context, evaluate the
 * baked-in `(prompt-form mac)` Scheme expression, copy the result
 * out as a C string, tear the context down. The agent loop is
 * still C-native; Scheme is the prompt-builder here, not the agent.
 *
 * If we want richer hooks later, the natural path is to keep the
 * context alive process-wide (psi_esp_chibi_eval(code) → string)
 * and add it as a tool just like lua_eval, but that's not wired in
 * yet.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_log.h"
#include "esp_mac.h"

#include "chibi/eval.h"

static const char *TAG = "psi_chibi";

/* The standard Scheme library (string-append, list, etc.) lives in
 * .scm files that chibi loads at runtime — and we don't have a
 * filesystem on the ESP32, so sexp_load_standard_env brings up an
 * env with `define`, `lambda`, `quote`, etc. but *not* string-append
 * or even basic primitives like `+`. Two options:
 *
 *  (a) run chibi-genstatic on the host to bake (scheme base) into C
 *      and link statically — proper but adds a host-build step
 *  (b) bind the C functions we need directly into the env via the
 *      foreign-function machinery — small, self-contained, and
 *      proves the C↔Scheme bridge actually works
 *
 * We do (b) here. `prompt-fragment` and `prompt-mac` are exposed as
 * Scheme-callable C foreign procedures, and the Scheme expression
 * just composes them. */

/* Foreign function: takes no args, returns the literal prompt body
 * (everything except the MAC address). */
static const char PROMPT_BODY[] =
    "You are psi, a coding agent runtime running on an ESP32 "
    "microcontroller (MAC ";
static const char PROMPT_BODY2[] =
    ") reachable on the local LAN. Tools available: system_info, "
    "wifi_scan, http_fetch (HTTPS via mbedTLS), gpio_mode/read/write, "
    "nvs_get/set, time_now, restart, uart_log (write to the operator's "
    "serial console). Prefer using tools to find ground truth instead "
    "of guessing. Keep replies short. [prompt built by chibi-scheme]";

static sexp ff_prompt_body(sexp ctx, sexp self, sexp_sint_t n) {
    return sexp_c_string(ctx, PROMPT_BODY, -1);
}
static sexp ff_prompt_body2(sexp ctx, sexp self, sexp_sint_t n) {
    return sexp_c_string(ctx, PROMPT_BODY2, -1);
}

/* String concatenation: takes two strings, returns their concatenation.
 * We do this in C because string-append is in (scheme base), which is
 * a Scheme module we'd need to compile in via chibi-genstatic. */
static sexp ff_concat2(sexp ctx, sexp self, sexp_sint_t n, sexp a, sexp b) {
    if (!sexp_stringp(a) || !sexp_stringp(b))
        return sexp_user_exception(ctx, self, "concat2: arguments must be strings", a);
    {
        size_t la = sexp_string_size(a);
        size_t lb = sexp_string_size(b);
        sexp result = sexp_make_string(ctx, sexp_make_fixnum(la + lb), SEXP_VOID);
        char *dst = sexp_string_data(result);
        memcpy(dst, sexp_string_data(a), la);
        memcpy(dst + la, sexp_string_data(b), lb);
        dst[la + lb] = '\0';
        return result;
    }
}

/* The actual Scheme expression — composes the prompt by calling our
 * registered C primitives. Demonstrates the C↔Scheme bridge
 * end-to-end without needing chibi's module loader.
 *
 *   (concat2 (prompt-body)
 *            (concat2 esp32-mac (prompt-body2)))
 *
 * Equivalent to "<body>" + "<MAC>" + "<body2>".
 */
static const char PROMPT_SCM[] =
    "(concat2 (prompt-body) (concat2 esp32-mac (prompt-body2)))";

/* The chibi context is global and stays alive for the life of the
 * firmware. Two reasons:
 *
 * 1. Memory: chibi carves SEXP_INITIAL_HEAP_SIZE bytes from the
 *    system heap on init. Repeatedly allocating + freeing that
 *    chunk fragments the heap (the freed block doesn't always come
 *    back as one piece, depending on what's been allocated meanwhile).
 *    esp_http_client_init wants a contiguous block too, and races
 *    with the freed chibi region for it. Keeping chibi alive once
 *    pins the layout — the rest of the system sees stable bounds.
 *
 * 2. Future use: a future tool (chibi_eval, mirroring lua_eval) can
 *    reuse this same context to run agent-supplied Scheme. The
 *    standard env stays loaded between calls so cold-eval cost is
 *    paid once.
 */
static sexp g_chibi_ctx = NULL;
static sexp g_chibi_env = NULL;

static int chibi_lazy_init(void) {
    if (g_chibi_ctx != NULL)
        return 0;

    /* Initialize chibi's global types vector before allocating
     * anything. sexp_make_eval_context's first allocation triggers
     * the GC, which dereferences SEXP_G_TYPES — NULL until
     * sexp_scheme_init runs. */
    sexp_scheme_init();

    /* Boot a fresh chibi context and load the standard environment
     * (define / lambda / quote / etc.). Heap sizing is compile-time
     * (SEXP_INITIAL_HEAP_SIZE in components/chibi-cmod). */
    g_chibi_ctx = sexp_make_eval_context(NULL, NULL, NULL, 0, 0);
    if (g_chibi_ctx == NULL) {
        ESP_LOGE(TAG, "sexp_make_eval_context returned NULL");
        return -1;
    }
    sexp_load_standard_env(g_chibi_ctx, NULL, SEXP_SEVEN);
    sexp_load_standard_ports(g_chibi_ctx, NULL, stdin, stdout, stderr, 0);
    g_chibi_env = sexp_context_env(g_chibi_ctx);

    /* Register the foreign procedures the Scheme expression
     * depends on. */
    sexp_define_foreign(g_chibi_ctx, g_chibi_env, "prompt-body", 0, ff_prompt_body);
    sexp_define_foreign(g_chibi_ctx, g_chibi_env, "prompt-body2", 0, ff_prompt_body2);
    sexp_define_foreign(g_chibi_ctx, g_chibi_env, "concat2", 2, ff_concat2);

    return 0;
}

char *psi_esp_chibi_build_system_prompt(void) {
    sexp result;
    sexp mac_sexp;
    sexp form;
    sexp ctx;
    sexp env;
    char *copy = NULL;
    uint8_t mac[6];
    char mac_str[18] = "??:??:??:??:??:??";

    if (esp_efuse_mac_get_default(mac) == ESP_OK) {
        snprintf(mac_str, sizeof(mac_str), "%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1], mac[2],
            mac[3], mac[4], mac[5]);
    }

    if (chibi_lazy_init() != 0)
        return NULL;
    ctx = g_chibi_ctx;
    env = g_chibi_env;

    /* Bind esp32-mac to the MAC string before evaluating the form. */
    mac_sexp = sexp_c_string(ctx, mac_str, -1);
    sexp_env_define(ctx, env, sexp_intern(ctx, "esp32-mac", -1), mac_sexp);

    /* Read + eval. read-from-string is part of the (chibi) lib but
     * we have NO_FEATURES on; use sexp_eval_string which combines
     * read+eval and works in the bare-bones build. */
    form = sexp_eval_string(ctx, PROMPT_SCM, -1, env);
    if (sexp_exceptionp(form)) {
        sexp msg = sexp_exception_message(form);
        const char *msg_str = sexp_stringp(msg) ? sexp_string_data(msg) : "?";
        ESP_LOGW(TAG, "chibi eval raised exception: %s", msg_str);
        sexp irritants = sexp_exception_irritants(form);
        if (sexp_pairp(irritants)) {
            sexp first = sexp_car(irritants);
            if (sexp_symbolp(first)) {
                const char *sym = sexp_string_data(sexp_symbol_to_string(ctx, first));
                ESP_LOGW(TAG, "  irritant symbol: %s", sym);
            } else if (sexp_stringp(first)) {
                ESP_LOGW(TAG, "  irritant string: %s", sexp_string_data(first));
            }
        }
        goto done;
    }
    result = form;

    if (!sexp_stringp(result)) {
        ESP_LOGW(TAG, "chibi result was not a string (type tag %d)", sexp_pointer_tag(result));
        goto done;
    }

    {
        const char *bytes = sexp_string_data(result);
        size_t len = sexp_string_size(result);
        copy = (char *)malloc(len + 1u);
        if (copy != NULL) {
            memcpy(copy, bytes, len);
            copy[len] = '\0';
        }
    }

done:
    /* NOTE: ctx is intentionally kept alive (g_chibi_ctx). With
     * SEXP_USE_GLOBAL_HEAP=1 chibi's heap chunk is only allocated
     * once, so destroying the context wouldn't actually free the
     * 96 KiB anyway — it would just leave chibi unable to run
     * later. A future chibi_eval tool can reuse this context. */
    return copy;
}
