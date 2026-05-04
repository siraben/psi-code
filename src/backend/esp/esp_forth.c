/* zForth glue.
 *
 * Builds the agent's system prompt at boot and serves the
 * forth_eval tool at runtime. zforth's whole runtime is one
 * fixed allocation (~10 KiB code + 2 KiB dictionary + 256 B
 * stacks ≈ 12 KiB total) — small enough that the mbedTLS
 * handshake buffers still fit alongside it.
 *
 * Forth has no built-in string concatenation, so the prompt-build
 * pattern is "TELL into a captured buffer, append more, TELL
 * again." Three custom syscalls let the Forth program emit the
 * MAC and pull literal prompt fragments from C without paying for
 * Forth-side string manipulation. The persistent context means
 * agent-supplied definitions stick across forth_eval calls — the
 * dictionary is a real long-lived workspace.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>

#include "esp_log.h"
#include "esp_mac.h"

#include "zforth.h"

static const char *TAG = "psi_forth";

/* Output buffer the prompt accumulates into. Forth's TELL syscall
 * appends to this; psi_esp_forth_build_system_prompt detaches and
 * returns it. */
struct prompt_buf {
    char *data;
    size_t len;
    size_t cap;
};
static struct prompt_buf g_prompt;

/* Statically-allocated Forth context (~3 KiB given our zfconf). One
 * per process — the firmware is single-threaded for prompt building. */
static zf_ctx g_zf_ctx;
static int g_zf_ready = 0;

static char g_mac_str[18] = "00:00:00:00:00:00";

static int prompt_buf_append(const char *src, size_t n) {
    if (g_prompt.len + n + 1u > g_prompt.cap) {
        size_t cap = g_prompt.cap ? g_prompt.cap * 2u : 256u;
        while (cap < g_prompt.len + n + 1u)
            cap *= 2u;
        char *p = (char *)realloc(g_prompt.data, cap);
        if (p == NULL)
            return -1;
        g_prompt.data = p;
        g_prompt.cap = cap;
    }
    memcpy(g_prompt.data + g_prompt.len, src, n);
    g_prompt.len += n;
    g_prompt.data[g_prompt.len] = '\0';
    return 0;
}

/* Custom syscalls the Forth program uses. SYS-MAC pushes a string
 * (addr len) of the MAC, SYS-BODY1/2 push literal prompt fragments. */
enum {
    PSI_SYS_MAC = ZF_SYSCALL_USER + 0,
    PSI_SYS_BODY1 = ZF_SYSCALL_USER + 1,
    PSI_SYS_BODY2 = ZF_SYSCALL_USER + 2,
};

static const char BODY1[] =
    "You are psi, a coding-agent runtime running on an ESP32 microcontroller "
    "(MAC ";
static const char BODY2[] =
    ") reachable on the local LAN. Tools: system_info, wifi_scan, ble_scan "
    "(NimBLE GAP discovery, returns nearby BLE devices), http_fetch (HTTPS "
    "via mbedTLS), gpio_mode/read/write/blink, nvs_get/set, time_now, "
    "restart, uart_log, and forth_eval (run Forth source against the "
    "firmware's persistent zforth dictionary; definitions stick). Prefer "
    "tools over guessing. Keep replies short. [prompt built by zforth]";

/* Push a C string into Forth's dictionary memory and leave (addr len)
 * on the data stack. zforth's TELL syscall expects exactly this
 * shape. We use HERE-style allocation: copy into the dictionary at
 * the current top, advance HERE past it. */
static void zf_push_cstring(zf_ctx *ctx, const char *s, size_t n) {
    zf_cell here_val;
    zf_uservar_get(ctx, ZF_USERVAR_HERE, &here_val);
    zf_addr addr = (zf_addr)here_val;
    uint8_t *dict = (uint8_t *)zf_dump(ctx, NULL);
    memcpy(dict + addr, s, n);
    zf_uservar_set(ctx, ZF_USERVAR_HERE, (zf_cell)(addr + n));
    zf_push(ctx, (zf_cell)addr);
    zf_push(ctx, (zf_cell)n);
}

zf_input_state zf_host_sys(zf_ctx *ctx, zf_syscall_id id, const char *input) {
    (void)input;
    switch ((int)id) {
        case ZF_SYSCALL_EMIT: {
            char ch = (char)zf_pop(ctx);
            prompt_buf_append(&ch, 1);
            break;
        }
        case ZF_SYSCALL_PRINT: {
            char num[24];
            int n = snprintf(num, sizeof(num), "%ld", (long)zf_pop(ctx));
            if (n > 0)
                prompt_buf_append(num, (size_t)n);
            break;
        }
        case ZF_SYSCALL_TELL: {
            zf_cell len = zf_pop(ctx);
            zf_cell addr = zf_pop(ctx);
            uint8_t *dict = (uint8_t *)zf_dump(ctx, NULL);
            prompt_buf_append((const char *)(dict + (zf_addr)addr), (size_t)len);
            break;
        }
        case PSI_SYS_MAC:
            zf_push_cstring(ctx, g_mac_str, strlen(g_mac_str));
            break;
        case PSI_SYS_BODY1:
            zf_push_cstring(ctx, BODY1, sizeof(BODY1) - 1u);
            break;
        case PSI_SYS_BODY2:
            zf_push_cstring(ctx, BODY2, sizeof(BODY2) - 1u);
            break;
        default:
            ESP_LOGW(TAG, "unhandled syscall %d", id);
            break;
    }
    return ZF_INPUT_INTERPRET;
}

void zf_host_trace(zf_ctx *ctx, const char *fmt, va_list va) {
    (void)ctx;
    (void)fmt;
    (void)va;
    /* trace disabled at compile time (ZF_ENABLE_TRACE=0) */
}

zf_cell zf_host_parse_num(zf_ctx *ctx, const char *buf) {
    char *end;
    long v = strtol(buf, &end, 0);
    if (*end != '\0') {
        zf_abort(ctx, ZF_ABORT_NOT_A_WORD);
    }
    return (zf_cell)v;
}

/* The Forth program. zforth's bootstrap dictionary contains only
 * primitives (exit, lit, +, -, sys, ...); helpers like `tell` live
 * in core.zf which we don't bundle. We define what we need inline.
 *
 * Calling convention: `n sys` invokes zf_host_sys with id n.
 * ZF_SYSCALL_TELL=2 (pops addr+len, prints to host).
 * ZF_SYSCALL_USER=128: PSI_SYS_MAC=128, PSI_SYS_BODY1=129, _BODY2=130. */
static const char PROMPT_FORTH[] =
    ": tell        2 sys ;\n"
    ": emit-mac    128 sys ;\n"
    ": emit-body1  129 sys ;\n"
    ": emit-body2  130 sys ;\n"
    ": prompt  emit-body1 tell  emit-mac tell  emit-body2 tell ;\n"
    "prompt\n";

/* One-time bootstrap of the persistent zforth context. Called by
 * both the prompt builder (at boot) and forth_eval (when the agent
 * sends Forth code) — whichever wins the race installs the
 * dictionary that survives for the life of the firmware.
 *
 * The standard-library subset we load below is core.zf from the
 * upstream zforth source (zevv/zforth, MIT) with the host-syscall
 * words trimmed (quit/sin/include/save aren't wired here) and
 * `then` aliased to `fi` since standard ANS Forth spells it `then`.
 * Total ~1.4 KiB compiled into the dictionary; ZF_DICT_SIZE in
 * components/forth-cmod/zfconf.h is sized to fit this plus
 * agent-supplied definitions. */
static const char STDLIB_FORTH[] =
    /* host syscalls */
    ": emit    0 sys ;\n"
    ": .       1 sys ;\n"
    ": tell    2 sys ;\n"
    /* typed memory access wrappers — variable-length cells */
    ": !  0 !! ;\n"
    ": @  0 @@ ;\n"
    ": ,  0 ,, ;\n"
    ": #  0 ## ;\n"
    /* fixed-size jump-cell access (used by if/else/begin etc.) */
    ": !j  64 !! ;\n"
    ": ,j  64 ,, ;\n"
    /* compiler state */
    ": [ 0 compiling ! ; immediate\n"
    ": ] 1 compiling ! ;\n"
    ": postpone 1 _postpone ! ; immediate\n"
    /* arithmetic + stack ergonomics */
    ": 1+ 1 + ;\n"
    ": 1- 1 - ;\n"
    ": negate 0 swap - ;\n"
    ": over 1 pick ;\n"
    ": +!   dup @ rot + swap ! ;\n"
    ": inc  1 swap +! ;\n"
    ": dec  -1 swap +! ;\n"
    /* comparison */
    ": <    - <0 ;\n"
    ": >    swap < ;\n"
    ": <=   over over >r >r < r> r> = + ;\n"
    ": >=   swap <= ;\n"
    ": =0   0 = ;\n"
    ": 0=   0 = ;\n"
    ": 0<   <0 ;\n"
    ": not  =0 ;\n"
    ": !=   = not ;\n"
    /* I/O conveniences */
    ": cr    10 emit ;\n"
    ": space 32 emit ;\n"
    ": br    32 emit ;\n"
    ": ..    dup . ;\n"
    /* memory layout */
    ": here h @ ;\n"
    ": allot h +! ;\n"
    ": var : ' lit , here 5 allot here swap ! 5 allot postpone ; ;\n"
    ": const : ' lit , , postpone ; ;\n"
    ": constant >r : r> postpone literal postpone ; ;\n"
    ": variable >r here r> postpone , constant ;\n"
    /* simple loops */
    ": begin   here ; immediate\n"
    ": again   ' jmp , , ; immediate\n"
    ": until   ' jmp0 , , ; immediate\n"
    /* if/else/then. zforth's core.zf calls the close `fi`; we
     * also alias the standard ANS Forth name `then`. */
    ": if      ' jmp0 , here 0 ,j ; immediate\n"
    ": unless  ' not , postpone if ; immediate\n"
    ": else    ' jmp , here 0 ,j swap here swap !j ; immediate\n"
    ": fi      here swap !j ; immediate\n"
    ": then    postpone fi ; immediate\n"
    /* counted loops with i, j accessors */
    ": i ' lit , 0 , ' pickr , ; immediate\n"
    ": j ' lit , 2 , ' pickr , ; immediate\n"
    ": do ' swap , ' >r , ' >r , here ; immediate\n"
    ": loop+ ' r> , ' + , ' dup , ' >r , ' lit , 1 , ' pickr , ' >= , "
    "' jmp0 , , ' r> , ' drop , ' r> , ' drop , ; immediate\n"
    ": loop ' lit , 1 , postpone loop+ ; immediate\n"
    /* abs uses if/then which we just defined */
    ": abs dup 0< if negate then ;\n"
    /* string literals: s\" pushes (addr len), .\" tells immediately */
    ": s\" compiling @ if ' lits , here 0 , fi here begin key dup 34 = if drop"
    "  compiling @ if here swap - swap ! else dup here swap - fi exit else , fi"
    "  again ; immediate\n"
    ": .\" compiling @ if postpone s\" ' tell , else begin key dup 34 = if drop exit"
    "  else emit fi again fi ; immediate\n";

static void forth_lazy_init(void) {
    if (g_zf_ready)
        return;
    zf_init(&g_zf_ctx, 0);
    zf_bootstrap(&g_zf_ctx);
    zf_result rv = zf_eval(&g_zf_ctx, STDLIB_FORTH);
    if (rv != ZF_OK) {
        ESP_LOGW(TAG, "stdlib eval returned %d", (int)rv);
    }
    g_zf_ready = 1;
}

char *psi_esp_forth_build_system_prompt(void) {
    uint8_t mac[6];
    if (esp_efuse_mac_get_default(mac) == ESP_OK) {
        snprintf(g_mac_str, sizeof(g_mac_str), "%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1],
            mac[2], mac[3], mac[4], mac[5]);
    }
    forth_lazy_init();

    /* Reset the prompt buffer, then evaluate the Forth program. */
    free(g_prompt.data);
    g_prompt.data = NULL;
    g_prompt.len = 0;
    g_prompt.cap = 0;

    zf_result rv = zf_eval(&g_zf_ctx, PROMPT_FORTH);
    if (rv != ZF_OK) {
        ESP_LOGW(TAG, "zf_eval returned %d", (int)rv);
        free(g_prompt.data);
        g_prompt.data = NULL;
        return NULL;
    }

    char *out = g_prompt.data;
    g_prompt.data = NULL;
    g_prompt.len = 0;
    g_prompt.cap = 0;
    return out;
}

/* Public agent-tool entrypoint. Evaluates `code` against the
 * persistent zforth context (same dictionary the prompt builder
 * uses, so any words it defined are still available). Captured
 * `tell` output goes into *out as a malloc'd string the caller
 * frees. Returns 0 on success, non-zero zf_result on Forth error
 * (with *out still containing whatever was emitted before the
 * abort, so the agent can see partial state). */
int psi_esp_forth_eval(const char *code, char **out) {
    if (out != NULL)
        *out = NULL;
    if (code == NULL)
        return ZF_ABORT_INTERNAL_ERROR;

    forth_lazy_init();

    /* Reset capture buffer for this call. */
    free(g_prompt.data);
    g_prompt.data = NULL;
    g_prompt.len = 0;
    g_prompt.cap = 0;

    zf_result rv = zf_eval(&g_zf_ctx, code);
    if (out != NULL) {
        *out = g_prompt.data;
        g_prompt.data = NULL;
        g_prompt.len = 0;
        g_prompt.cap = 0;
    }
    return (int)rv;
}
