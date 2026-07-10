/* psi Lua 5.5 VM and FFI bridge. */

#include <ctype.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
#include <cjson/cJSON.h>
#if PSI_ENABLE_REPL_EDITLINE
#include <editline/readline.h>
#endif
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include <time.h>
#include <errno.h>
#include <limits.h>
#ifndef _WIN32
#include <unistd.h>
#endif
#include <sys/time.h>
#if PSI_ENABLE_TUI
#include <poll.h>
#include <termios.h>
#include <sys/ioctl.h>
#endif
#include <dirent.h>
#include <sys/stat.h>
#include <fcntl.h>

#include "psi/abort.h"
#include "psi/agent_runtime.h"
#include "psi/http_buffered.h"
#include "psi/http_async.h"
#include "psi/common.h"
#include "psi/embedded_data.h"
#include "psi/host_ops.h"
#include "psi/message.h"
#include "psi/process.h"
#include "psi/random.h"
#include "psi/runtime.h"
#include "psi/session.h"
#include "psi/vm.h"
#include "psi/wcwidth.h"

#ifndef PSI_ENABLE_TUI
#define PSI_ENABLE_TUI 0
#endif
#ifndef PSI_ENABLE_ANSI
#define PSI_ENABLE_ANSI 0
#endif
#ifndef PSI_ENABLE_COLOR
#define PSI_ENABLE_COLOR 0
#endif
#ifndef PSI_ENABLE_MCP
#define PSI_ENABLE_MCP 0
#endif
#ifndef PSI_ENABLE_REPL_EDITLINE
#define PSI_ENABLE_REPL_EDITLINE 0
#endif

#define PSI_VM_RANDOM_BYTES_MAX 1048576

/* ------------------------------------------------------------------
 * Tiny OS-level helpers used by the FFI date/cwd/file_exists primitives
 * and by runtime_info. Returns a fresh heap string the caller must free,
 * or NULL on failure.
 * ------------------------------------------------------------------ */

static char *psi_vm_current_date(void) {
    char buffer[32];
    time_t now = time(NULL);
    const struct tm *lt = localtime(&now);
    if (lt == NULL)
        return NULL;
    snprintf(
        buffer, sizeof(buffer), "%04d-%02d-%02d", lt->tm_year + 1900, lt->tm_mon + 1, lt->tm_mday);
    return psi_strdup(buffer);
}

static char *psi_vm_current_cwd(void) {
    size_t size = 256u;
    for (;;) {
        char *buf = (char *)malloc(size);
        if (buf == NULL)
            return NULL;
        if (getcwd(buf, size) != NULL)
            return buf;
        free(buf);
        if (size >= 8192u)
            return psi_strdup(".");
        size *= 2u;
    }
}

static int psi_vm_is_abs_path(const char *path) {
    if (path == NULL || path[0] == '\0')
        return 0;
    if (path[0] == '/')
        return 1;
    if (isalpha((unsigned char)path[0]) && path[1] == ':' && (path[2] == '/' || path[2] == '\\')) {
        return 1;
    }
    return 0;
}

static char *psi_vm_path_join(const char *base, const char *name) {
    size_t base_len;
    size_t name_len;
    size_t need_sep;
    char *out;

    if (name == NULL)
        return base != NULL ? psi_strdup(base) : NULL;
    if (base == NULL || base[0] == '\0' || psi_vm_is_abs_path(name) || strcmp(base, ".") == 0) {
        return psi_strdup(name);
    }
    if (name[0] == '\0')
        return psi_strdup(base);

    base_len = strlen(base);
    name_len = strlen(name);
    need_sep = (base[base_len - 1u] == '/' || base[base_len - 1u] == '\\') ? 0u : 1u;
    if (base_len > (size_t)-1 - need_sep)
        return NULL;
    if (name_len > (size_t)-1 - base_len - need_sep - 1u)
        return NULL;
    out = (char *)malloc(base_len + need_sep + name_len + 1u);
    if (out == NULL)
        return NULL;
    memcpy(out, base, base_len);
    if (need_sep)
        out[base_len] = '/';
    memcpy(out + base_len + need_sep, name, name_len + 1u);
    return out;
}

static char *psi_vm_expand_path(const char *path) {
    const char *home;
    const char *p;
    char *out;

    if (path == NULL)
        return NULL;
    p = path;
    if (p[0] == '@')
        p++;
    if (p[0] != '~' || (p[1] != '\0' && p[1] != '/'))
        return psi_strdup(p);
    home = getenv("HOME");
    if (home == NULL || home[0] == '\0')
        return psi_strdup(p);
    if (p[1] == '\0')
        return psi_strdup(home);
    out = psi_vm_path_join(home, p + 2);
    return out;
}

static char *psi_vm_resolve_path(const char *path) {
    char *expanded;
    char *cwd;
    char *out;

    expanded = psi_vm_expand_path(path);
    if (expanded == NULL)
        return NULL;
    if (psi_vm_is_abs_path(expanded))
        return expanded;
    cwd = psi_vm_current_cwd();
    if (cwd == NULL) {
        free(expanded);
        return NULL;
    }
    out = psi_vm_path_join(cwd, expanded);
    free(cwd);
    free(expanded);
    return out;
}

static char *psi_vm_realpath(const char *path) {
#ifndef _WIN32
    char *expanded;
    char *resolved;

    expanded = psi_vm_expand_path(path);
    if (expanded == NULL)
        return NULL;
    resolved = realpath(expanded, NULL);
    free(expanded);
    return resolved;
#else
    return psi_vm_resolve_path(path);
#endif
}

static char *psi_vm_parent_directory(const char *path) {
    size_t end;
    size_t i;
    size_t len;
    char *out;

    if (path == NULL || path[0] == '\0')
        return psi_strdup(".");
    end = strlen(path);
    while (end > 1u && (path[end - 1u] == '/' || path[end - 1u] == '\\'))
        end--;
    i = end;
    while (i > 0u && path[i - 1u] != '/' && path[i - 1u] != '\\')
        i--;
    if (i == 0u)
        return psi_strdup(".");
    while (i > 1u && (path[i - 1u] == '/' || path[i - 1u] == '\\'))
        i--;
    if (i == 1u && (path[0] == '/' || path[0] == '\\'))
        return psi_strdup("/");
    len = i;
    out = (char *)malloc(len + 1u);
    if (out == NULL)
        return NULL;
    memcpy(out, path, len);
    out[len] = '\0';
    return out;
}

static int psi_vm_file_exists(const char *path) {
    struct stat st;
    if (path == NULL || path[0] == '\0')
        return 0;
    return stat(path, &st) == 0 ? 1 : 0;
}

static int psi_vm_file_is_regular(const char *path) {
    struct stat st;
    if (path == NULL || path[0] == '\0')
        return 0;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

static const char *psi_vm_file_type_name(const char *path) {
    struct stat st;
    if (path == NULL || path[0] == '\0')
        return NULL;
    if (stat(path, &st) != 0)
        return NULL;
    if (S_ISDIR(st.st_mode))
        return "directory";
    if (S_ISREG(st.st_mode))
        return "file";
    return "other";
}

static int psi_vm_mkdir_one(const char *path) {
    struct stat st;
    if (path == NULL || path[0] == '\0')
        return PSI_STATUS_ERROR;
    if (stat(path, &st) == 0) {
        return S_ISDIR(st.st_mode) ? PSI_STATUS_OK : PSI_STATUS_ERROR;
    }
    if (mkdir(path, 0777) == 0)
        return PSI_STATUS_OK;
    if (errno == EEXIST && stat(path, &st) == 0 && S_ISDIR(st.st_mode)) {
        return PSI_STATUS_OK;
    }
    return PSI_STATUS_ERROR;
}

static int psi_vm_mkdir_p(const char *path) {
    char *buf;
    size_t n;
    size_t i;
    int status;
    char sep;

    if (path == NULL || path[0] == '\0')
        return PSI_STATUS_ERROR;
    buf = psi_strdup(path);
    if (buf == NULL)
        return PSI_STATUS_ERROR;

    status = PSI_STATUS_OK;
    n = strlen(buf);
    while (n > 1u && (buf[n - 1u] == '/' || buf[n - 1u] == '\\')) {
        buf[--n] = '\0';
    }
    i = (buf[0] == '/' || buf[0] == '\\') ? 1u : 0u;
    for (; i < n; i++) {
        if (buf[i] == '/' || buf[i] == '\\') {
            sep = buf[i];
            buf[i] = '\0';
            if (buf[0] != '\0' && psi_vm_mkdir_one(buf) != PSI_STATUS_OK) {
                status = PSI_STATUS_ERROR;
                break;
            }
            buf[i] = sep;
            while (i + 1u < n && (buf[i + 1u] == '/' || buf[i + 1u] == '\\'))
                i++;
        }
    }
    if (status == PSI_STATUS_OK && psi_vm_mkdir_one(buf) != PSI_STATUS_OK) {
        status = PSI_STATUS_ERROR;
    }
    free(buf);
    return status;
}

static int psi_vm_mkdir_parent(const char *path) {
    char *parent;
    int status;

    parent = psi_vm_parent_directory(path);
    if (parent == NULL)
        return PSI_STATUS_ERROR;
    if (strcmp(parent, ".") == 0 || strcmp(parent, "/") == 0) {
        free(parent);
        return PSI_STATUS_OK;
    }
    status = psi_vm_mkdir_p(parent);
    free(parent);
    return status;
}

static const long PSI_VM_FILE_WRITE_MAX_BYTES = 16777216l;
static const long PSI_VM_READ_FILE_MAX_BYTES = 262144l;

/* Host context is stored in the Lua state's extraspace so FFI primitives
 * can recover it from their lua_State* rather than a file-static. Keeps
 * the door open for multiple VMs and makes cross-thread reasoning easier:
 * each Lua state owns exactly one host, and the worker thread is the
 * only one calling Lua while that host is active. */
#define PSI_VM_HOST(L) (*(struct psi_host_context **)lua_getextraspace(L))

#define PSI_VM_NOREF (-2)

/* Infer analyzes Lua callbacks as roots, so make host-owned session fields
 * visible as retained after mutation. Normal builds compile this to a no-op. */
#ifdef __INFER__
static const void *volatile psi_vm_infer_session_messages;
static const void *volatile psi_vm_infer_session_token_prefix;
static const void *volatile psi_vm_infer_session_id;
static const void *volatile psi_vm_infer_session_path;
static const void *volatile psi_vm_infer_session_parent_id;
#endif

static void psi_vm_session_mark_retained(const struct psi_session *session) {
#ifdef __INFER__
    if (session == NULL)
        return;
    psi_vm_infer_session_messages = session->messages;
    psi_vm_infer_session_token_prefix = session->token_prefix;
    psi_vm_infer_session_id = session->id;
    psi_vm_infer_session_path = session->path;
    psi_vm_infer_session_parent_id = session->parent_id;
#else
    PSI_UNUSED(session);
#endif
}

/* ------------------------------------------------------------------
 * cJSON <-> Lua table conversion
 * ------------------------------------------------------------------ */

static cJSON *psi_vm_lua_value_to_json(lua_State *L, int idx);
static void psi_vm_push_json_value(lua_State *L, const cJSON *v);

#if PSI_ENABLE_TUI
static int psi_vm_require_tui(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    const struct psi_vm *vm = host != NULL ? host->vm : NULL;
    if (vm == NULL || !vm->tui_active) {
        return luaL_error(L, "TUI API is only available in --tui mode");
    }
    return 0;
}
#endif

static void psi_vm_mark_array(lua_State *L) {
    /* Assumes target table is at top of stack. Attaches __jsontype = "array"
     * so an empty array round-trips cleanly. */
    lua_newtable(L);
    lua_pushstring(L, "array");
    lua_setfield(L, -2, "__jsontype");
    lua_setmetatable(L, -2);
}

static void psi_vm_push_json_value(lua_State *L, const cJSON *v) {
    if (cJSON_IsObject(v)) {
        const cJSON *item;
        lua_newtable(L);
        for (item = v->child; item != NULL; item = item->next) {
            psi_vm_push_json_value(L, item);
            lua_setfield(L, -2, item->string ? item->string : "");
        }
        return;
    }
    if (cJSON_IsArray(v)) {
        const cJSON *item;
        int idx = 1;
        lua_newtable(L);
        psi_vm_mark_array(L);
        for (item = v->child; item != NULL; item = item->next) {
            psi_vm_push_json_value(L, item);
            lua_rawseti(L, -2, idx++);
        }
        return;
    }
    if (cJSON_IsString(v) && v->valuestring != NULL) {
        lua_pushstring(L, v->valuestring);
        return;
    }
    if (cJSON_IsBool(v)) {
        lua_pushboolean(L, cJSON_IsTrue(v) ? 1 : 0);
        return;
    }
    if (cJSON_IsNumber(v)) {
        double d = v->valuedouble;
        if (d == d && d >= (double)LUA_MININTEGER && d <= (double)LUA_MAXINTEGER) {
            lua_Integer i = (lua_Integer)d;
            if (d == (double)i) {
                lua_pushinteger(L, i);
            } else {
                lua_pushnumber(L, d);
            }
        } else {
            lua_pushnumber(L, d);
        }
        return;
    }
    lua_pushnil(L);
}

static int psi_vm_table_is_array(lua_State *L, int idx) {
    lua_Integer count;
    lua_Integer i;

    idx = lua_absindex(L, idx);
    if (lua_getmetatable(L, idx)) {
        lua_getfield(L, -1, "__jsontype");
        if (lua_type(L, -1) == LUA_TSTRING) {
            const char *tag = lua_tostring(L, -1);
            int tag_array = tag && strcmp(tag, "array") == 0;
            int tag_object = tag && strcmp(tag, "object") == 0;
            lua_pop(L, 2);
            if (tag_array)
                return 1;
            if (tag_object)
                return 0;
        } else {
            lua_pop(L, 2);
        }
    }

    count = 0;
    lua_pushnil(L);
    while (lua_next(L, idx) != 0) {
        if (lua_type(L, -2) == LUA_TSTRING) {
            lua_pop(L, 2);
            return 0;
        }
        count++;
        lua_pop(L, 1);
    }
    if (count == 0)
        return 0;
    for (i = 1; i <= count; i++) {
        int is_nil;
        lua_rawgeti(L, idx, i);
        is_nil = lua_isnil(L, -1);
        lua_pop(L, 1);
        if (is_nil)
            return 0;
    }
    return 1;
}

static cJSON *psi_vm_lua_value_to_json(lua_State *L, int idx) {
    int t;
    idx = lua_absindex(L, idx);
    t = lua_type(L, idx);

    if (t == LUA_TSTRING) {
        return cJSON_CreateString(lua_tostring(L, idx));
    }
    if (t == LUA_TBOOLEAN) {
        return cJSON_CreateBool(lua_toboolean(L, idx));
    }
    if (t == LUA_TNUMBER) {
        if (lua_isinteger(L, idx)) {
            return cJSON_CreateNumber((double)lua_tointeger(L, idx));
        }
        return cJSON_CreateNumber(lua_tonumber(L, idx));
    }
    if (t == LUA_TNIL) {
        return cJSON_CreateNull();
    }
    if (t == LUA_TTABLE) {
        if (psi_vm_table_is_array(L, idx)) {
            cJSON *arr;
            lua_Integer n, i;
            arr = cJSON_CreateArray();
            if (arr == NULL)
                return NULL;
            n = (lua_Integer)lua_rawlen(L, idx);
            for (i = 1; i <= n; i++) {
                cJSON *item;
                lua_rawgeti(L, idx, i);
                item = psi_vm_lua_value_to_json(L, -1);
                lua_pop(L, 1);
                if (item == NULL) {
                    cJSON_Delete(arr);
                    return NULL;
                }
                cJSON_AddItemToArray(arr, item);
            }
            return arr;
        }
        {
            cJSON *obj;
            obj = cJSON_CreateObject();
            if (obj == NULL)
                return NULL;
            lua_pushnil(L);
            while (lua_next(L, idx) != 0) {
                /* skip metadata-ish keys, and non-string keys */
                if (lua_type(L, -2) == LUA_TSTRING) {
                    const char *key = lua_tostring(L, -2);
                    if (key && strcmp(key, "__kind") != 0 && strcmp(key, "__jsontype") != 0) {
                        cJSON *item = psi_vm_lua_value_to_json(L, -1);
                        if (item != NULL)
                            cJSON_AddItemToObject(obj, key, item);
                    }
                }
                lua_pop(L, 1);
            }
            return obj;
        }
    }
    return cJSON_CreateNull();
}

/* ------------------------------------------------------------------
 * TUI host helpers
 * ------------------------------------------------------------------ */

#if PSI_ENABLE_TUI

#define PSI_VM_TUI_KEY_NAME_MAX 32
#define PSI_VM_TUI_KEY_TEXT_MAX 8
#define PSI_VM_TUI_ESCAPE_SEQUENCE_MAX 64
#define PSI_VM_TUI_DEFAULT_WIDTH 80
#define PSI_VM_TUI_DEFAULT_HEIGHT 24
#define PSI_VM_TUI_FIRST_TERMINAL_CELL 1
#define PSI_VM_TUI_POLL_INFINITE_MS (-1)
#define PSI_VM_TUI_POLL_MAX_MS 3600000
#define PSI_VM_TUI_ESCAPE_INITIAL_TIMEOUT_MS 25
#define PSI_VM_TUI_ESCAPE_CONTINUE_TIMEOUT_MS 5
#define PSI_VM_TUI_ESCAPE_BYTE 27
#define PSI_VM_TUI_BACKSPACE_DELETE 127
#define PSI_VM_TUI_BACKSPACE_ASCII 8
#define PSI_VM_TUI_UTF8_CONTINUE_TIMEOUT_MS 25
#define PSI_VM_TUI_UTF8_LEAD_TWO_MIN 0xc2u
#define PSI_VM_TUI_UTF8_LEAD_TWO_MAX 0xdfu
#define PSI_VM_TUI_UTF8_LEAD_THREE_MIN 0xe0u
#define PSI_VM_TUI_UTF8_LEAD_THREE_MAX 0xefu
#define PSI_VM_TUI_UTF8_LEAD_FOUR_MIN 0xf0u
#define PSI_VM_TUI_UTF8_LEAD_FOUR_MAX 0xf4u
#define PSI_VM_TUI_UTF8_CONTINUATION_MASK 0xc0
#define PSI_VM_TUI_UTF8_CONTINUATION_TAG 0x80
#define PSI_VM_TUI_UTF8_TEXT_MIN_BUFFER 5u
#define PSI_VM_TUI_CONTROL_MIN 1
#define PSI_VM_TUI_CONTROL_MAX 26
#define PSI_VM_TUI_CONTROL_A_OFFSET 1
#define PSI_VM_TUI_CSI_PRIMARY_PARAM 1u
#define PSI_VM_TUI_MODIFIER_SHIFT 2u
#define PSI_VM_TUI_MODIFIER_ALT_SHIFT 4u
#define PSI_VM_TUI_MODIFIER_CTRL 5u
#define PSI_VM_TUI_MODIFIER_ALT 3u
#define PSI_VM_TUI_MODIFIER_SHIFT_MIN 2u
#define PSI_VM_TUI_LEGACY_ENTER_CODE 13u
#define PSI_VM_TUI_KITTY_SHIFT_ENTER_CODE 57414u
#define PSI_VM_TUI_MOUSE_WHEEL_FLAG 64u
#define PSI_VM_TUI_MOUSE_BUTTON_MASK 3u
#define PSI_VM_TUI_MOUSE_WHEEL_UP 0u
#define PSI_VM_TUI_MOUSE_WHEEL_DOWN 1u

static const char PSI_VM_TUI_SYNC_BEGIN[] = "\033[?2026h";
static const char PSI_VM_TUI_SYNC_END[] = "\033[?2026l";
static const char PSI_VM_TUI_CURSOR_HIDE[] = "\033[?25l";
static const char PSI_VM_TUI_CURSOR_SHOW[] = "\033[?25h";
static const char PSI_VM_TUI_RESET_STYLE[] = "\033[0m";
static const char PSI_VM_TUI_CLEAR_LINE[] = "\033[2K";
static const char PSI_VM_TUI_CLOSE_OSC8[] = "\033]8;;\a";
static const char PSI_VM_TUI_CLEAR_SCREEN[] = "\033[2J\033[3J\033[H";

struct psi_vm_tui_key_event {
    char key_name[PSI_VM_TUI_KEY_NAME_MAX];
    char text[PSI_VM_TUI_KEY_TEXT_MAX];
};

static void psi_vm_copy_truncated(char *dest, size_t dest_size, const char *src) {
    size_t length;

    if (dest == NULL || dest_size == 0u) {
        return;
    }
    if (src == NULL) {
        dest[0] = '\0';
        return;
    }

    length = strlen(src);
    if (length >= dest_size) {
        length = dest_size - 1u;
    }
    memcpy(dest, src, length);
    dest[length] = '\0';
}

#endif

#if PSI_ENABLE_TUI

static void psi_vm_set_registry_callback(lua_State *L, int *ref_slot, int arg_index) {
    if (ref_slot == NULL) {
        lua_pop(L, 1);
        return;
    }
    if (*ref_slot != PSI_VM_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, *ref_slot);
        *ref_slot = PSI_VM_NOREF;
    }
    if (lua_isnil(L, arg_index)) {
        return;
    }
    luaL_checktype(L, arg_index, LUA_TFUNCTION);
    lua_pushvalue(L, arg_index);
    *ref_slot = luaL_ref(L, LUA_REGISTRYINDEX);
}

#endif

static void psi_vm_invoke_registry_callback0(lua_State *L, int ref, const char *label) {
    if (ref == PSI_VM_NOREF) {
        return;
    }
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
        fprintf(stderr, "Lua error in %s: %s\n", label, lua_tostring(L, -1));
        lua_pop(L, 1);
    }
}

static void psi_vm_invoke_registry_callback2(lua_State *L, int ref, const char *label,
    const char *a, size_t a_len, const char *b, size_t b_len) {
    if (ref == PSI_VM_NOREF) {
        return;
    }
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
    lua_pushlstring(L, a != NULL ? a : "", a_len);
    lua_pushlstring(L, b != NULL ? b : "", b_len);
    if (lua_pcall(L, 2, 0, 0) != LUA_OK) {
        fprintf(stderr, "Lua error in %s: %s\n", label, lua_tostring(L, -1));
        lua_pop(L, 1);
    }
}

#if PSI_ENABLE_TUI

extern void psi_tui_suspend_terminal(void);
extern void psi_tui_resume_terminal(void);

static int psi_vm_tui_frame_active = 0;
static char **psi_vm_tui_previous_lines = NULL;
static size_t psi_vm_tui_previous_line_count = 0u;
static long psi_vm_tui_previous_top = PSI_VM_TUI_FIRST_TERMINAL_CELL;
static long psi_vm_tui_previous_cursor_row = 0;
static long psi_vm_tui_previous_cursor_col = 0;
static int psi_vm_tui_previous_cursor_visible = 0;
static int psi_vm_tui_discard_escape_final = 0;

static void psi_vm_tui_reset_render_cache(void) {
    if (psi_vm_tui_previous_lines != NULL) {
        size_t i;
        for (i = 0u; i < psi_vm_tui_previous_line_count; i++) {
            free(psi_vm_tui_previous_lines[i]);
        }
        free(psi_vm_tui_previous_lines);
    }
    psi_vm_tui_previous_lines = NULL;
    psi_vm_tui_previous_line_count = 0u;
    psi_vm_tui_previous_top = PSI_VM_TUI_FIRST_TERMINAL_CELL;
    psi_vm_tui_previous_cursor_row = 0;
    psi_vm_tui_previous_cursor_col = 0;
    psi_vm_tui_previous_cursor_visible = 0;
}

static int psi_vm_tui_read_byte(int timeout_ms) {
    struct pollfd pfd;
    unsigned char ch;
    int result;

    pfd.fd = STDIN_FILENO;
    pfd.events = POLLIN;
    pfd.revents = 0;
    result = poll(&pfd, 1, timeout_ms);
    if (result <= 0 || (pfd.revents & POLLIN) == 0) {
        return -1;
    }
    if (read(STDIN_FILENO, &ch, 1) != 1) {
        return -1;
    }
    return (int)ch;
}

static void psi_vm_tui_write(const char *text) {
    if (text != NULL) {
        fputs(text, stdout);
    }
}

static void psi_vm_tui_draw_raw_line(long row, const char *text) {
    printf("\033[%ld;%dH%s%s%s", row, PSI_VM_TUI_FIRST_TERMINAL_CELL, PSI_VM_TUI_CLEAR_LINE,
        text != NULL ? text : "", PSI_VM_TUI_RESET_STYLE);
}

static void psi_vm_tui_draw_frame_line(long row, const char *text) {
    printf("\033[%ld;%dH%s%s%s%s", row, PSI_VM_TUI_FIRST_TERMINAL_CELL, PSI_VM_TUI_CLEAR_LINE,
        text != NULL ? text : "", PSI_VM_TUI_RESET_STYLE, PSI_VM_TUI_CLOSE_OSC8);
}

static int psi_vm_tui_is_csi_final(int ch) {
    return ch >= 0x40 && ch <= 0x7e;
}

static int psi_vm_tui_is_orphan_escape_final(int ch) {
    return ch == '~' || (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z');
}

static int psi_vm_tui_escape_sequence_complete(const char *buffer, size_t length) {
    if (buffer == NULL || length == 0u) {
        return 1;
    }
    if (buffer[0] == '[') {
        size_t i;

        for (i = 1u; i < length; i++) {
            if (psi_vm_tui_is_csi_final((unsigned char)buffer[i])) {
                return 1;
            }
        }
        return 0;
    }
    if (buffer[0] == 'O') {
        return length >= 2u;
    }
    return 1;
}

static void psi_vm_tui_suspend(void) {
    struct sigaction dfl;
    struct sigaction prev;
    sigset_t mask;
    sigset_t prev_mask;

    psi_tui_suspend_terminal();
    memset(&dfl, 0, sizeof(dfl));
    dfl.sa_handler = SIG_DFL;
    sigemptyset(&dfl.sa_mask);
    sigaction(SIGTSTP, &dfl, &prev);
    sigemptyset(&mask);
    sigaddset(&mask, SIGTSTP);
    sigprocmask(SIG_UNBLOCK, &mask, &prev_mask);
    kill(getpid(), SIGTSTP);
    sigprocmask(SIG_SETMASK, &prev_mask, NULL);
    sigaction(SIGTSTP, &prev, NULL);
    psi_tui_resume_terminal();
}

static int psi_vm_tui_collect_escape_sequence(
    char *buffer, size_t buffer_size, int restore_timeout_ms) {
    size_t length;
    int timeout_ms;

    if (buffer == NULL || buffer_size == 0u) {
        return 0;
    }

    length = 0u;
    buffer[0] = '\0';
    /* An ESC byte can be a lone Escape key or the prefix of a terminal sequence. */
    timeout_ms = PSI_VM_TUI_ESCAPE_INITIAL_TIMEOUT_MS;
    for (;;) {
        int ch;

        ch = psi_vm_tui_read_byte(timeout_ms);
        if (ch < 0) {
            break;
        }
        if (length + 1u >= buffer_size) {
            break;
        }
        buffer[length++] = (char)ch;
        buffer[length] = '\0';
        if (psi_vm_tui_escape_sequence_complete(buffer, length)) {
            break;
        }
        timeout_ms = PSI_VM_TUI_ESCAPE_CONTINUE_TIMEOUT_MS;
    }

    PSI_UNUSED(restore_timeout_ms);
    return (int)length;
}

static const char *psi_vm_tui_escape_sequence_key(const char *sequence) {
    unsigned int first;
    unsigned int second;
    unsigned int third;
    unsigned int button;
    unsigned int column;
    unsigned int row;
    char final;

    if (sequence == NULL || sequence[0] == '\0') {
        return "escape";
    }
    if (strcmp(sequence, "b") == 0 || strcmp(sequence, "B") == 0) {
        return "alt-b";
    }
    if (strcmp(sequence, "f") == 0 || strcmp(sequence, "F") == 0) {
        return "alt-f";
    }
    if (strcmp(sequence, "d") == 0 || strcmp(sequence, "D") == 0) {
        return "alt-d";
    }
    if (strcmp(sequence, "\b") == 0 || strcmp(sequence, "\177") == 0) {
        return "alt-backspace";
    }
    if (strcmp(sequence, "\r") == 0 || strcmp(sequence, "\n") == 0) {
        return "alt-enter";
    }
    if (strcmp(sequence, "[A") == 0 || strcmp(sequence, "OA") == 0) {
        return "up";
    }
    if (strcmp(sequence, "[B") == 0 || strcmp(sequence, "OB") == 0) {
        return "down";
    }
    if (strcmp(sequence, "[C") == 0 || strcmp(sequence, "OC") == 0) {
        return "right";
    }
    if (strcmp(sequence, "[D") == 0 || strcmp(sequence, "OD") == 0) {
        return "left";
    }
    if (strcmp(sequence, "[H") == 0 || strcmp(sequence, "OH") == 0 ||
        strcmp(sequence, "[1~") == 0 || strcmp(sequence, "[7~") == 0) {
        return "home";
    }
    if (strcmp(sequence, "[F") == 0 || strcmp(sequence, "OF") == 0 ||
        strcmp(sequence, "[4~") == 0 || strcmp(sequence, "[8~") == 0) {
        return "end";
    }
    if (strcmp(sequence, "[3~") == 0) {
        return "delete";
    }
    if (strcmp(sequence, "[5~") == 0) {
        return "page-up";
    }
    if (strcmp(sequence, "[6~") == 0) {
        return "page-down";
    }
    /* Common CSI modified-arrow form: ESC [ 1 ; <modifier> <arrow>. */
    if (sscanf(sequence, "[%u;%u%c", &first, &second, &final) == 3 &&
        first == PSI_VM_TUI_CSI_PRIMARY_PARAM && second == PSI_VM_TUI_MODIFIER_CTRL) {
        if (final == 'A') {
            return "ctrl-up";
        }
        if (final == 'B') {
            return "ctrl-down";
        }
        if (final == 'C') {
            return "ctrl-right";
        }
        if (final == 'D') {
            return "ctrl-left";
        }
    }
    if (sscanf(sequence, "[%u;%u%c", &first, &second, &final) == 3 &&
        first == PSI_VM_TUI_CSI_PRIMARY_PARAM && second == PSI_VM_TUI_MODIFIER_ALT) {
        if (final == 'A') {
            return "alt-up";
        }
        if (final == 'B') {
            return "alt-down";
        }
        if (final == 'C') {
            return "alt-right";
        }
        if (final == 'D') {
            return "alt-left";
        }
    }
    if (sscanf(sequence, "[<%u;%u;%u%c", &button, &column, &row, &final) == 4 &&
        (final == 'M' || final == 'm')) {
        PSI_UNUSED(column);
        PSI_UNUSED(row);
        /* SGR mouse reports wheel direction in the low button bits. */
        if (final == 'M' && (button & PSI_VM_TUI_MOUSE_WHEEL_FLAG) != 0u) {
            if ((button & PSI_VM_TUI_MOUSE_BUTTON_MASK) == PSI_VM_TUI_MOUSE_WHEEL_UP) {
                return "wheel-up";
            }
            if ((button & PSI_VM_TUI_MOUSE_BUTTON_MASK) == PSI_VM_TUI_MOUSE_WHEEL_DOWN) {
                return "wheel-down";
            }
        }
        return NULL;
    }
    if (sscanf(sequence, "[%u;%u;%u%c", &first, &second, &third, &final) == 4 && final == '~' &&
        first == (unsigned int)PSI_VM_TUI_ESCAPE_BYTE && third == PSI_VM_TUI_LEGACY_ENTER_CODE &&
        second >= PSI_VM_TUI_MODIFIER_SHIFT_MIN) {
        if (second == PSI_VM_TUI_MODIFIER_ALT || second == PSI_VM_TUI_MODIFIER_ALT_SHIFT) {
            return "alt-enter";
        }
        return "shift-enter";
    }
    if (sscanf(sequence, "[%u;%u%c", &first, &second, &final) == 3 &&
        (final == 'u' || final == '~') &&
        (first == PSI_VM_TUI_LEGACY_ENTER_CODE || first == PSI_VM_TUI_KITTY_SHIFT_ENTER_CODE) &&
        second >= PSI_VM_TUI_MODIFIER_SHIFT_MIN) {
        if (second == PSI_VM_TUI_MODIFIER_ALT || second == PSI_VM_TUI_MODIFIER_ALT_SHIFT) {
            return "alt-enter";
        }
        return "shift-enter";
    }
    return NULL;
}

static int psi_vm_tui_read_utf8_tail(unsigned int lead, char *out, size_t out_size) {
    size_t expected;
    size_t i;

    if (out == NULL || out_size < PSI_VM_TUI_UTF8_TEXT_MIN_BUFFER ||
        lead < PSI_VM_TUI_UTF8_LEAD_TWO_MIN || lead > PSI_VM_TUI_UTF8_LEAD_FOUR_MAX) {
        return 0;
    }
    if (lead <= PSI_VM_TUI_UTF8_LEAD_TWO_MAX) {
        expected = 1u;
    } else if (lead <= PSI_VM_TUI_UTF8_LEAD_THREE_MAX) {
        expected = 2u;
    } else {
        expected = 3u;
    }
    out[0] = (char)lead;
    for (i = 1u; i <= expected; i++) {
        int ch;

        ch = psi_vm_tui_read_byte(PSI_VM_TUI_UTF8_CONTINUE_TIMEOUT_MS);
        if (ch < 0 ||
            (((unsigned int)ch) & PSI_VM_TUI_UTF8_CONTINUATION_MASK) !=
                PSI_VM_TUI_UTF8_CONTINUATION_TAG) {
            return 0;
        }
        out[i] = (char)ch;
    }
    out[expected + 1u] = '\0';
    return 1;
}

static int psi_vm_tui_normalize_key(
    int ch, int restore_timeout_ms, struct psi_vm_tui_key_event *event) {
    char sequence[PSI_VM_TUI_ESCAPE_SEQUENCE_MAX];
    char ctrl_name[7];
    const char *key_name;

    if (event == NULL) {
        return 0;
    }
    memset(event, 0, sizeof(*event));

    if (psi_vm_tui_discard_escape_final && psi_vm_tui_is_orphan_escape_final(ch)) {
        psi_vm_tui_discard_escape_final = 0;
        return 0;
    }
    psi_vm_tui_discard_escape_final = 0;

    if (ch == PSI_VM_TUI_ESCAPE_BYTE) {
        psi_vm_tui_collect_escape_sequence(sequence, sizeof(sequence), restore_timeout_ms);
        if (!psi_vm_tui_escape_sequence_complete(sequence, strlen(sequence))) {
            psi_vm_tui_discard_escape_final = 1;
            return 0;
        }
        key_name = psi_vm_tui_escape_sequence_key(sequence);
        if (key_name == NULL) {
            return 0;
        }
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), key_name);
        return 1;
    }
    if (ch == PSI_VM_TUI_BACKSPACE_DELETE || ch == PSI_VM_TUI_BACKSPACE_ASCII) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "backspace");
        return 1;
    }
    if (ch == '\r' || ch == '\n') {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "enter");
        return 1;
    }
    if (ch >= PSI_VM_TUI_CONTROL_MIN && ch <= PSI_VM_TUI_CONTROL_MAX) {
        ctrl_name[0] = 'c';
        ctrl_name[1] = 't';
        ctrl_name[2] = 'r';
        ctrl_name[3] = 'l';
        ctrl_name[4] = '-';
        ctrl_name[5] = (char)('a' + ch - PSI_VM_TUI_CONTROL_A_OFFSET);
        ctrl_name[6] = '\0';
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), ctrl_name);
        return 1;
    }
    if (ch >= (int)PSI_VM_TUI_UTF8_LEAD_TWO_MIN) {
        if (!psi_vm_tui_read_utf8_tail((unsigned int)ch, event->text, sizeof(event->text))) {
            return 0;
        }
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "text");
        return 1;
    }
    if (isprint(ch)) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "text");
        event->text[0] = (char)ch;
        event->text[1] = '\0';
        return 1;
    }
    return 0;
}

#endif

/* ------------------------------------------------------------------
 * FFI primitive procedures (registered on the `psi` global table)
 * ------------------------------------------------------------------ */

static int lfn_version(lua_State *L) {
    lua_pushstring(L, PSI_VERSION);
    return 1;
}

static int lfn_log(lua_State *L) {
    const char *msg = luaL_checkstring(L, 1);
    fprintf(stderr, "[psi] %s\n", msg);
    return 0;
}

/* ------------------------------------------------------------------
 * Terminal text primitives. These intentionally do not require TUI mode:
 * no-tui builds still need the same wrapping and width semantics for tests
 * and for any caller rendering terminal text off-screen.
 * ------------------------------------------------------------------ */

#define PSI_VM_TEXT_BUILDER_INITIAL_CAP 64u
#define PSI_VM_TEXT_ESC_BYTE 0x1bu
#define PSI_VM_TEXT_BEL_BYTE 0x07u
#define PSI_VM_TEXT_TAB_BYTE 0x09u
#define PSI_VM_TEXT_SPACE_BYTE 0x20u
#define PSI_VM_TEXT_CSI_FINAL_MIN 0x40u
#define PSI_VM_TEXT_CSI_FINAL_MAX 0x7eu
#define PSI_VM_TEXT_ASCII_LIMIT 0x80u
#define PSI_VM_TEXT_UTF8_CONTINUATION_MIN 0x80u
#define PSI_VM_TEXT_UTF8_CONTINUATION_MAX 0xbfu
#define PSI_VM_TEXT_UTF8_CONTINUATION_BASE 0x80u
#define PSI_VM_TEXT_UTF8_TWO_BYTE_MIN 0xc2u
#define PSI_VM_TEXT_UTF8_TWO_BYTE_MAX 0xdfu
#define PSI_VM_TEXT_UTF8_TWO_BYTE_BASE 0xc0u
#define PSI_VM_TEXT_UTF8_THREE_BYTE_MIN 0xe0u
#define PSI_VM_TEXT_UTF8_THREE_BYTE_MAX 0xefu
#define PSI_VM_TEXT_UTF8_THREE_BYTE_BASE 0xe0u
#define PSI_VM_TEXT_UTF8_FOUR_BYTE_MIN 0xf0u
#define PSI_VM_TEXT_UTF8_FOUR_BYTE_MAX 0xf4u
#define PSI_VM_TEXT_UTF8_FOUR_BYTE_BASE 0xf0u
#define PSI_VM_TEXT_UTF8_PAYLOAD_BITS_PER_CONTINUATION 0x40u
#define PSI_VM_TEXT_UTF8_THREE_BYTE_LEAD_MULTIPLIER 0x1000u
#define PSI_VM_TEXT_UTF8_FOUR_BYTE_LEAD_MULTIPLIER 0x40000u
#define PSI_VM_TEXT_CODEPOINT_NUL 0u
#define PSI_VM_TEXT_CODEPOINT_NEWLINE 0x0au
#define PSI_VM_TEXT_CODEPOINT_TAB 0x09u
#define PSI_VM_TEXT_CODEPOINT_C0_CONTROL_MAX 0x20u
#define PSI_VM_TEXT_CODEPOINT_DELETE 0x7fu
#define PSI_VM_TEXT_CODEPOINT_C1_CONTROL_MAX 0x9fu
#define PSI_VM_TEXT_CODEPOINT_ZERO_WIDTH_JOINER 0x200du
#define PSI_VM_TEXT_UNICODE_MAX 0x10ffffu
#define PSI_VM_TEXT_WIDTH_ZERO 0
#define PSI_VM_TEXT_WIDTH_NARROW 1
#define PSI_VM_TEXT_WIDTH_WIDE 2
#define PSI_VM_TEXT_WIDTH_TAB 3

static const char PSI_VM_TEXT_UNDERLINE_OFF[] = "\033[24m";
static const char PSI_VM_TEXT_OSC8_CLOSE_BEL[] = "\033]8;;\a";
static const char PSI_VM_TEXT_OSC8_CLOSE_ST[] = "\033]8;;\033\\";

struct psi_vm_text_builder {
    char *data;
    size_t len;
    size_t cap;
    lua_Alloc allocf;
    void *alloc_ud;
};

struct psi_vm_text_wrap_context {
    lua_State *L;
    int table_index;
    int line_count;
    int line_width;
    int word_width;
    int pending_space;
    int pending_space_width;
    int soft_wrapped;
    int width;
    int active_underline;
    int active_hyperlink_terminator;
    struct psi_vm_text_builder line;
    struct psi_vm_text_builder word;
    struct psi_vm_text_builder active_sgr;
    struct psi_vm_text_builder active_hyperlink;
};

static void psi_vm_text_builder_init(struct psi_vm_text_builder *b, lua_State *L) {
    b->data = NULL;
    b->len = 0u;
    b->cap = 0u;
    b->allocf = lua_getallocf(L, &b->alloc_ud);
}

static void psi_vm_text_builder_free(struct psi_vm_text_builder *b) {
    if (b->data != NULL && b->allocf != NULL) {
        b->allocf(b->alloc_ud, b->data, b->cap, 0u);
    }
    b->data = NULL;
    b->len = 0u;
    b->cap = 0u;
}

static void psi_vm_text_builder_clear(struct psi_vm_text_builder *b) {
    b->len = 0u;
    if (b->data != NULL) {
        b->data[0] = '\0';
    }
}

static int psi_vm_text_builder_reserve(struct psi_vm_text_builder *b, size_t extra) {
    size_t needed;
    size_t next_cap;
    char *next;

    if (extra > (size_t)-1 - b->len) {
        return 0;
    }
    needed = b->len + extra + 1u;
    if (needed <= b->cap && b->data != NULL) {
        return 1;
    }
    next_cap = b->cap == 0u ? PSI_VM_TEXT_BUILDER_INITIAL_CAP : b->cap;
    while (next_cap < needed) {
        if (next_cap > ((size_t)-1 / 2u)) {
            next_cap = needed;
            break;
        }
        next_cap *= 2u;
    }
    if (b->allocf == NULL) {
        return 0;
    }
    next = (char *)b->allocf(b->alloc_ud, b->data, b->cap, next_cap);
    if (next == NULL) {
        return 0;
    }
    b->data = next;
    b->cap = next_cap;
    return 1;
}

static int psi_vm_text_builder_append(struct psi_vm_text_builder *b, const char *text, size_t len) {
    if (len == 0u) {
        return 1;
    }
    if (!psi_vm_text_builder_reserve(b, len)) {
        return 0;
    }
    if (b->data == NULL) {
        return 0;
    }
    memcpy(b->data + b->len, text, len);
    b->len += len;
    b->data[b->len] = '\0';
    return 1;
}

static int psi_vm_text_builder_append_char(struct psi_vm_text_builder *b, char ch) {
    return psi_vm_text_builder_append(b, &ch, 1u);
}

static int psi_vm_text_read_escape(const char *text, size_t len, size_t i, size_t *next_i) {
    size_t j;
    unsigned char next_byte;
    unsigned char byte;

    if (i >= len || (unsigned char)text[i] != PSI_VM_TEXT_ESC_BYTE) {
        return 0;
    }
    if (i + 1u >= len) {
        *next_i = i + 1u;
        return 1;
    }
    next_byte = (unsigned char)text[i + 1u];
    if (next_byte == (unsigned char)'[') {
        j = i + 2u;
        while (j < len) {
            byte = (unsigned char)text[j];
            if (byte >= PSI_VM_TEXT_CSI_FINAL_MIN && byte <= PSI_VM_TEXT_CSI_FINAL_MAX) {
                *next_i = j + 1u;
                return 1;
            }
            j++;
        }
        *next_i = len;
        return 1;
    }
    if (next_byte == (unsigned char)']' || next_byte == (unsigned char)'_') {
        j = i + 2u;
        while (j < len) {
            byte = (unsigned char)text[j];
            if (byte == PSI_VM_TEXT_BEL_BYTE) {
                *next_i = j + 1u;
                return 1;
            }
            if (byte == PSI_VM_TEXT_ESC_BYTE && j + 1u < len && text[j + 1u] == '\\') {
                *next_i = j + 2u;
                return 1;
            }
            j++;
        }
        *next_i = len;
        return 1;
    }
    if (next_byte == (unsigned char)'=' || next_byte == (unsigned char)'>') {
        *next_i = i + 2u;
        return 1;
    }
    *next_i = i + 2u;
    return 1;
}

static unsigned long psi_vm_text_decode_utf8(
    const char *text, size_t len, size_t i, size_t *next_i) {
    unsigned char b1;
    unsigned char b2;
    unsigned char b3;
    unsigned char b4;

    if (i >= len) {
        *next_i = i;
        return PSI_VM_TEXT_CODEPOINT_NUL;
    }
    b1 = (unsigned char)text[i];
    if (b1 < PSI_VM_TEXT_ASCII_LIMIT) {
        *next_i = i + 1u;
        return (unsigned long)b1;
    }
    b2 = i + 1u < len ? (unsigned char)text[i + 1u] : 0u;
    b3 = i + 2u < len ? (unsigned char)text[i + 2u] : 0u;
    b4 = i + 3u < len ? (unsigned char)text[i + 3u] : 0u;
    if (b1 >= PSI_VM_TEXT_UTF8_TWO_BYTE_MIN && b1 <= PSI_VM_TEXT_UTF8_TWO_BYTE_MAX &&
        b2 >= PSI_VM_TEXT_UTF8_CONTINUATION_MIN && b2 <= PSI_VM_TEXT_UTF8_CONTINUATION_MAX) {
        *next_i = i + 2u;
        return (unsigned long)((b1 - PSI_VM_TEXT_UTF8_TWO_BYTE_BASE) *
                PSI_VM_TEXT_UTF8_PAYLOAD_BITS_PER_CONTINUATION +
            (b2 - PSI_VM_TEXT_UTF8_CONTINUATION_BASE));
    }
    if (b1 >= PSI_VM_TEXT_UTF8_THREE_BYTE_MIN && b1 <= PSI_VM_TEXT_UTF8_THREE_BYTE_MAX &&
        b2 >= PSI_VM_TEXT_UTF8_CONTINUATION_MIN && b2 <= PSI_VM_TEXT_UTF8_CONTINUATION_MAX &&
        b3 >= PSI_VM_TEXT_UTF8_CONTINUATION_MIN && b3 <= PSI_VM_TEXT_UTF8_CONTINUATION_MAX) {
        *next_i = i + 3u;
        return (unsigned long)((b1 - PSI_VM_TEXT_UTF8_THREE_BYTE_BASE) *
                PSI_VM_TEXT_UTF8_THREE_BYTE_LEAD_MULTIPLIER +
            (b2 - PSI_VM_TEXT_UTF8_CONTINUATION_BASE) *
                PSI_VM_TEXT_UTF8_PAYLOAD_BITS_PER_CONTINUATION +
            (b3 - PSI_VM_TEXT_UTF8_CONTINUATION_BASE));
    }
    if (b1 >= PSI_VM_TEXT_UTF8_FOUR_BYTE_MIN && b1 <= PSI_VM_TEXT_UTF8_FOUR_BYTE_MAX &&
        b2 >= PSI_VM_TEXT_UTF8_CONTINUATION_MIN && b2 <= PSI_VM_TEXT_UTF8_CONTINUATION_MAX &&
        b3 >= PSI_VM_TEXT_UTF8_CONTINUATION_MIN && b3 <= PSI_VM_TEXT_UTF8_CONTINUATION_MAX &&
        b4 >= PSI_VM_TEXT_UTF8_CONTINUATION_MIN && b4 <= PSI_VM_TEXT_UTF8_CONTINUATION_MAX) {
        *next_i = i + 4u;
        return (unsigned long)((b1 - PSI_VM_TEXT_UTF8_FOUR_BYTE_BASE) *
                PSI_VM_TEXT_UTF8_FOUR_BYTE_LEAD_MULTIPLIER +
            (b2 - PSI_VM_TEXT_UTF8_CONTINUATION_BASE) *
                PSI_VM_TEXT_UTF8_THREE_BYTE_LEAD_MULTIPLIER +
            (b3 - PSI_VM_TEXT_UTF8_CONTINUATION_BASE) *
                PSI_VM_TEXT_UTF8_PAYLOAD_BITS_PER_CONTINUATION +
            (b4 - PSI_VM_TEXT_UTF8_CONTINUATION_BASE));
    }
    *next_i = i + 1u;
    return (unsigned long)b1;
}

static int psi_vm_text_in_range(unsigned long cp, unsigned long first, unsigned long last) {
    return cp >= first && cp <= last;
}

static int psi_vm_text_is_regional_indicator(unsigned long cp) {
    return psi_vm_text_in_range(cp, 0x1f1e6u, 0x1f1ffu);
}

static int psi_vm_text_is_control(unsigned long cp) {
    return cp < PSI_VM_TEXT_CODEPOINT_C0_CONTROL_MAX ||
        psi_vm_text_in_range(
            cp, PSI_VM_TEXT_CODEPOINT_DELETE, PSI_VM_TEXT_CODEPOINT_C1_CONTROL_MAX);
}

static int psi_vm_text_codepoint_width(unsigned long cp) {
    int width;

    if (cp == PSI_VM_TEXT_CODEPOINT_TAB) {
        return PSI_VM_TEXT_WIDTH_TAB;
    }
    if (cp > PSI_VM_TEXT_UNICODE_MAX || psi_vm_text_is_control(cp)) {
        return cp > PSI_VM_TEXT_UNICODE_MAX ? PSI_VM_TEXT_WIDTH_NARROW : PSI_VM_TEXT_WIDTH_ZERO;
    }
    width = psi_wcwidth((int)cp);
    if (width <= 0) {
        return PSI_VM_TEXT_WIDTH_ZERO;
    }
    if (width >= PSI_VM_TEXT_WIDTH_WIDE) {
        return PSI_VM_TEXT_WIDTH_WIDE;
    }
    return PSI_VM_TEXT_WIDTH_NARROW;
}

static int psi_vm_text_is_zero_width_cluster_modifier(unsigned long cp) {
    if (cp == PSI_VM_TEXT_CODEPOINT_ZERO_WIDTH_JOINER || cp > PSI_VM_TEXT_UNICODE_MAX ||
        psi_vm_text_is_control(cp)) {
        return 0;
    }
    return psi_wcwidth((int)cp) == PSI_VM_TEXT_WIDTH_ZERO;
}

static void psi_vm_text_next_cluster(
    const char *text, size_t len, size_t i, size_t *next_i, int *cluster_width) {
    size_t start;
    size_t after;
    unsigned long cp;
    int width;
    int saw_zwj;

    start = i;
    cp = psi_vm_text_decode_utf8(text, len, i, &after);
    width = psi_vm_text_codepoint_width(cp);
    if (psi_vm_text_is_regional_indicator(cp)) {
        size_t after2;
        unsigned long cp2;
        cp2 = psi_vm_text_decode_utf8(text, len, after, &after2);
        if (psi_vm_text_is_regional_indicator(cp2)) {
            *next_i = after2;
            *cluster_width = 2;
            PSI_UNUSED(start);
            return;
        }
    }

    i = after;
    saw_zwj = 0;
    while (i < len) {
        unsigned long next_cp;
        size_t next_after;
        next_cp = psi_vm_text_decode_utf8(text, len, i, &next_after);
        if (psi_vm_text_is_zero_width_cluster_modifier(next_cp)) {
            i = next_after;
        } else if (next_cp == PSI_VM_TEXT_CODEPOINT_ZERO_WIDTH_JOINER) {
            saw_zwj = 1;
            i = next_after;
        } else if (saw_zwj) {
            int next_width;
            next_width = psi_vm_text_codepoint_width(next_cp);
            if (next_width > width) {
                width = next_width;
            }
            if (width < PSI_VM_TEXT_WIDTH_WIDE) {
                width = PSI_VM_TEXT_WIDTH_WIDE;
            }
            saw_zwj = 0;
            i = next_after;
        } else {
            break;
        }
    }
    *next_i = i;
    *cluster_width = width;
}

static int psi_vm_text_visible_width_bytes(const char *text, size_t len) {
    size_t i;
    int width;

    i = 0u;
    width = 0;
    while (i < len) {
        size_t next_i = i;
        int cluster_width;
        if (!psi_vm_text_read_escape(text, len, i, &next_i)) {
            psi_vm_text_next_cluster(text, len, i, &next_i, &cluster_width);
            width += cluster_width;
        }
        i = next_i;
    }
    return width;
}

static int psi_vm_text_sgr_resets(const char *seq, size_t len) {
    size_t i;
    int value;
    int saw_digit;

    if (len < 3u || (unsigned char)seq[0] != PSI_VM_TEXT_ESC_BYTE || seq[1] != '[' ||
        seq[len - 1u] != 'm') {
        return 0;
    }
    if (len == 3u) {
        return 1;
    }
    i = 2u;
    value = 0;
    saw_digit = 0;
    while (i + 1u < len) {
        unsigned char ch;
        ch = (unsigned char)seq[i];
        if (ch >= (unsigned char)'0' && ch <= (unsigned char)'9') {
            value = value * 10 + (int)(ch - (unsigned char)'0');
            saw_digit = 1;
        } else {
            if (saw_digit && value == 0) {
                return 1;
            }
            value = 0;
            saw_digit = 0;
        }
        i++;
    }
    return saw_digit && value == 0;
}

/* Parse one numeric SGR parameter and advance past its digits. */
static int psi_vm_text_parse_sgr_value(const char *seq, size_t len, size_t *i, int *value) {
    int saw_digit = 0;
    int parsed = 0;
    while (*i + 1u < len) {
        unsigned char ch;
        ch = (unsigned char)seq[*i];
        if (ch < (unsigned char)'0' || ch > (unsigned char)'9') {
            break;
        }
        parsed = parsed * 10 + (int)(ch - (unsigned char)'0');
        saw_digit = 1;
        (*i)++;
    }
    *value = saw_digit ? parsed : 0;
    return saw_digit;
}

static void psi_vm_text_update_sgr_flags(
    struct psi_vm_text_wrap_context *ctx, const char *seq, size_t len) {
    size_t i = 2u;

    if (len < 3u || (unsigned char)seq[0] != PSI_VM_TEXT_ESC_BYTE || seq[1] != '[' ||
        seq[len - 1u] != 'm') {
        return;
    }
    if (psi_vm_text_sgr_resets(seq, len)) {
        ctx->active_underline = 0;
        return;
    }
    while (i + 1u < len) {
        int code;
        if (seq[i] == ';') {
            i++;
            continue;
        }
        if (!psi_vm_text_parse_sgr_value(seq, len, &i, &code)) {
            i++;
            continue;
        }
        if (code == 0) {
            ctx->active_underline = 0;
        } else if (code == 4) {
            ctx->active_underline = 1;
        } else if (code == 24) {
            ctx->active_underline = 0;
        } else if (code == 38 || code == 48) {
            int mode;
            if (i + 1u < len && seq[i] == ';') {
                i++;
            }
            if (psi_vm_text_parse_sgr_value(seq, len, &i, &mode)) {
                int remaining;
                remaining = mode == 5 ? 1 : mode == 2 ? 3 : 0;
                while (remaining > 0 && i + 1u < len) {
                    int ignored;
                    if (seq[i] == ';') {
                        i++;
                    }
                    if (!psi_vm_text_parse_sgr_value(seq, len, &i, &ignored)) {
                        break;
                    }
                    remaining--;
                }
            }
        }
    }
}

static int psi_vm_text_update_active_osc8(
    struct psi_vm_text_wrap_context *ctx, const char *seq, size_t len) {
    size_t payload_start;
    size_t payload_end;

    if (len < 5u || (unsigned char)seq[0] != PSI_VM_TEXT_ESC_BYTE || seq[1] != ']' ||
        seq[2] != '8' || seq[3] != ';') {
        return 1;
    }
    payload_start = 4u;
    while (payload_start < len && seq[payload_start] != ';') {
        payload_start++;
    }
    if (payload_start >= len) {
        return 1;
    }
    payload_start++;
    if ((unsigned char)seq[len - 1u] == PSI_VM_TEXT_BEL_BYTE) {
        payload_end = len - 1u;
        ctx->active_hyperlink_terminator = PSI_VM_TEXT_BEL_BYTE;
    } else if ((unsigned char)seq[len - 2u] == PSI_VM_TEXT_ESC_BYTE && seq[len - 1u] == '\\') {
        payload_end = len - 2u;
        ctx->active_hyperlink_terminator = '\\';
    } else {
        return 1;
    }
    if (payload_end <= payload_start) {
        psi_vm_text_builder_clear(&ctx->active_hyperlink);
        ctx->active_hyperlink_terminator = 0;
        return 1;
    }
    psi_vm_text_builder_clear(&ctx->active_hyperlink);
    return psi_vm_text_builder_append(&ctx->active_hyperlink, seq, len);
}

static int psi_vm_text_update_active_sgr(
    struct psi_vm_text_wrap_context *ctx, const char *seq, size_t len) {
    if (len < 3u || (unsigned char)seq[0] != PSI_VM_TEXT_ESC_BYTE || seq[1] != '[' ||
        seq[len - 1u] != 'm') {
        return 1;
    }
    psi_vm_text_update_sgr_flags(ctx, seq, len);
    if (psi_vm_text_sgr_resets(seq, len)) {
        psi_vm_text_builder_clear(&ctx->active_sgr);
        return 1;
    }
    return psi_vm_text_builder_append(&ctx->active_sgr, seq, len);
}

static int psi_vm_text_update_active_escape(
    struct psi_vm_text_wrap_context *ctx, const char *seq, size_t len) {
    if (len >= 2u && (unsigned char)seq[0] == PSI_VM_TEXT_ESC_BYTE && seq[1] == '[') {
        return psi_vm_text_update_active_sgr(ctx, seq, len);
    }
    if (len >= 2u && (unsigned char)seq[0] == PSI_VM_TEXT_ESC_BYTE && seq[1] == ']') {
        return psi_vm_text_update_active_osc8(ctx, seq, len);
    }
    return 1;
}

static int psi_vm_text_update_active_from_text(
    struct psi_vm_text_wrap_context *ctx, const char *text, size_t len) {
    size_t i;

    i = 0u;
    while (i < len) {
        size_t next_i = i;
        if (psi_vm_text_read_escape(text, len, i, &next_i)) {
            if (!psi_vm_text_update_active_escape(ctx, text + i, next_i - i)) {
                return 0;
            }
        } else {
            next_i = i + 1u;
        }
        i = next_i;
    }
    return 1;
}

static void psi_vm_text_wrap_context_init(
    struct psi_vm_text_wrap_context *ctx, lua_State *L, int table_index, int width) {
    ctx->L = L;
    ctx->table_index = table_index;
    ctx->line_count = 0;
    ctx->line_width = 0;
    ctx->word_width = 0;
    ctx->pending_space = 0;
    ctx->pending_space_width = 0;
    ctx->soft_wrapped = 0;
    ctx->width = width;
    ctx->active_underline = 0;
    ctx->active_hyperlink_terminator = 0;
    psi_vm_text_builder_init(&ctx->line, L);
    psi_vm_text_builder_init(&ctx->word, L);
    psi_vm_text_builder_init(&ctx->active_sgr, L);
    psi_vm_text_builder_init(&ctx->active_hyperlink, L);
}

static void psi_vm_text_wrap_context_free(struct psi_vm_text_wrap_context *ctx) {
    psi_vm_text_builder_free(&ctx->line);
    psi_vm_text_builder_free(&ctx->word);
    psi_vm_text_builder_free(&ctx->active_sgr);
    psi_vm_text_builder_free(&ctx->active_hyperlink);
}

static int psi_vm_text_wrap_push_line(struct psi_vm_text_wrap_context *ctx, int final_line) {
    if (!final_line && ctx->line.len > 0u && ctx->active_underline) {
        if (!psi_vm_text_builder_append(
                &ctx->line, PSI_VM_TEXT_UNDERLINE_OFF, sizeof(PSI_VM_TEXT_UNDERLINE_OFF) - 1u)) {
            return 0;
        }
    }
    if (!final_line && ctx->line.len > 0u && ctx->active_hyperlink.len > 0u) {
        const char *close;
        size_t close_len;
        close = ctx->active_hyperlink_terminator == PSI_VM_TEXT_BEL_BYTE ?
            PSI_VM_TEXT_OSC8_CLOSE_BEL :
            PSI_VM_TEXT_OSC8_CLOSE_ST;
        close_len = ctx->active_hyperlink_terminator == PSI_VM_TEXT_BEL_BYTE ?
            sizeof(PSI_VM_TEXT_OSC8_CLOSE_BEL) - 1u :
            sizeof(PSI_VM_TEXT_OSC8_CLOSE_ST) - 1u;
        if (!psi_vm_text_builder_append(&ctx->line, close, close_len)) {
            return 0;
        }
    }
    ctx->line_count++;
    lua_pushlstring(ctx->L, ctx->line.data != NULL ? ctx->line.data : "", ctx->line.len);
    lua_rawseti(ctx->L, ctx->table_index, (lua_Integer)ctx->line_count);
    psi_vm_text_builder_clear(&ctx->line);
    if (!final_line && ctx->active_sgr.len > 0u) {
        if (!psi_vm_text_builder_append(&ctx->line, ctx->active_sgr.data, ctx->active_sgr.len)) {
            return 0;
        }
    }
    if (!final_line && ctx->active_hyperlink.len > 0u) {
        if (!psi_vm_text_builder_append(
                &ctx->line, ctx->active_hyperlink.data, ctx->active_hyperlink.len)) {
            return 0;
        }
    }
    return 1;
}

static int psi_vm_text_wrap_append_piece(
    struct psi_vm_text_wrap_context *ctx, const char *piece, size_t piece_len, int piece_width) {
    if (piece_width == 0) {
        return psi_vm_text_builder_append(&ctx->line, piece, piece_len);
    }
    if (ctx->line_width > 0 && ctx->line_width + piece_width > ctx->width) {
        if (!psi_vm_text_wrap_push_line(ctx, 0)) {
            return 0;
        }
        ctx->line_width = 0;
        ctx->soft_wrapped = 1;
    }
    if (!psi_vm_text_builder_append(&ctx->line, piece, piece_len)) {
        return 0;
    }
    ctx->line_width += piece_width;
    ctx->soft_wrapped = 0;
    return 1;
}

static int psi_vm_text_wrap_flush_word(struct psi_vm_text_wrap_context *ctx) {
    if (ctx->word.len == 0u) {
        return 1;
    }
    if (ctx->pending_space) {
        /* Preserve the full whitespace run so indentation is not collapsed.
         * Mirrors pi's wrapTextWithAnsi: whitespace is kept verbatim except
         * when it would begin a soft-wrapped continuation line, where it is
         * dropped ("don't start new line with whitespace"). A whitespace run
         * at the true start of a source line (line_width == 0 and not
         * soft-wrapped) is retained as leading indentation. */
        int space_width = ctx->pending_space_width > 0 ? ctx->pending_space_width : 1;
        if (ctx->line_width == 0 && ctx->soft_wrapped) {
            /* Suppress leading whitespace on a soft-wrapped line. */
        } else if (ctx->line_width > 0 &&
            ctx->line_width + space_width + ctx->word_width > ctx->width) {
            /* Space plus the following word overflows: wrap instead. */
            if (!psi_vm_text_wrap_push_line(ctx, 0)) {
                return 0;
            }
            ctx->line_width = 0;
            ctx->soft_wrapped = 1;
        } else {
            int k;
            for (k = 0; k < space_width; k++) {
                if (!psi_vm_text_builder_append_char(&ctx->line, (char)PSI_VM_TEXT_SPACE_BYTE)) {
                    return 0;
                }
            }
            ctx->line_width += space_width;
        }
    }
    ctx->pending_space = 0;
    ctx->pending_space_width = 0;

    if (ctx->word_width <= ctx->width) {
        if (!psi_vm_text_wrap_append_piece(ctx, ctx->word.data, ctx->word.len, ctx->word_width)) {
            return 0;
        }
        if (!psi_vm_text_update_active_from_text(ctx, ctx->word.data, ctx->word.len)) {
            return 0;
        }
    } else {
        size_t j;
        j = 0u;
        while (j < ctx->word.len) {
            size_t next_j = j;
            if (psi_vm_text_read_escape(ctx->word.data, ctx->word.len, j, &next_j)) {
                if (!psi_vm_text_builder_append(&ctx->line, ctx->word.data + j, next_j - j)) {
                    return 0;
                }
                if (!psi_vm_text_update_active_escape(ctx, ctx->word.data + j, next_j - j)) {
                    return 0;
                }
            } else {
                int cluster_width;
                psi_vm_text_next_cluster(ctx->word.data, ctx->word.len, j, &next_j, &cluster_width);
                if (!psi_vm_text_wrap_append_piece(
                        ctx, ctx->word.data + j, next_j - j, cluster_width)) {
                    return 0;
                }
            }
            j = next_j;
        }
    }

    /* A flushed word is disposable scratch; free it so ownership stays local. */
    psi_vm_text_builder_free(&ctx->word);
    ctx->word_width = 0;
    return 1;
}

static int psi_vm_text_wrap_preserve(
    struct psi_vm_text_wrap_context *ctx, const char *text, size_t len) {
    size_t i;

    i = 0u;
    while (i < len) {
        size_t next_i;

        next_i = i;
        if (psi_vm_text_read_escape(text, len, i, &next_i)) {
            if (!psi_vm_text_builder_append(&ctx->line, text + i, next_i - i)) {
                return 0;
            }
            if (!psi_vm_text_update_active_escape(ctx, text + i, next_i - i)) {
                return 0;
            }
        } else {
            int cluster_width;

            psi_vm_text_next_cluster(text, len, i, &next_i, &cluster_width);
            if (!psi_vm_text_wrap_append_piece(ctx, text + i, next_i - i, cluster_width)) {
                return 0;
            }
        }
        i = next_i;
    }
    return 1;
}

static int lfn_cell_width(lua_State *L) {
    lua_Integer cp;
    int width;

    cp = luaL_checkinteger(L, 1);
    if (cp < 0 || cp > (lua_Integer)PSI_VM_TEXT_UNICODE_MAX) {
        lua_pushinteger(L, PSI_VM_TEXT_WIDTH_NARROW);
        return 1;
    }
    width = psi_wcwidth((int)cp);
    if (width < PSI_VM_TEXT_WIDTH_ZERO) {
        width = PSI_VM_TEXT_WIDTH_ZERO;
    }
    lua_pushinteger(L, (lua_Integer)width);
    return 1;
}

static int lfn_tui_text_strip_ansi(lua_State *L) {
    size_t len;
    size_t i;
    const char *text;
    luaL_Buffer buffer;

    text = luaL_optlstring(L, 1, "", &len);
    luaL_buffinit(L, &buffer);
    i = 0u;
    while (i < len) {
        size_t next_i = i;
        if (!psi_vm_text_read_escape(text, len, i, &next_i)) {
            luaL_addchar(&buffer, text[i]);
            next_i = i + 1u;
        }
        i = next_i;
    }
    luaL_pushresult(&buffer);
    return 1;
}

static int lfn_tui_text_visible_width(lua_State *L) {
    size_t len;
    const char *text;

    text = luaL_optlstring(L, 1, "", &len);
    lua_pushinteger(L, (lua_Integer)psi_vm_text_visible_width_bytes(text, len));
    return 1;
}

static int lfn_tui_text_byte_index_for_width(lua_State *L) {
    size_t len;
    size_t i;
    const char *text;
    lua_Integer width_arg;
    int width;
    int seen;

    text = luaL_optlstring(L, 1, "", &len);
    width_arg = luaL_optinteger(L, 2, 0);
    width = width_arg < 0 ? 0 : (int)width_arg;
    if (width <= 0) {
        lua_pushinteger(L, 0);
        return 1;
    }
    i = 0u;
    seen = 0;
    while (i < len) {
        size_t next_i = i;
        int cluster_width;
        if (!psi_vm_text_read_escape(text, len, i, &next_i)) {
            psi_vm_text_next_cluster(text, len, i, &next_i, &cluster_width);
            if (seen + cluster_width > width) {
                lua_pushinteger(L, (lua_Integer)i);
                return 1;
            }
            seen += cluster_width;
        }
        i = next_i;
    }
    lua_pushinteger(L, (lua_Integer)len);
    return 1;
}

static int lfn_tui_text_pad_line(lua_State *L) {
    size_t len;
    const char *text;
    lua_Integer width_arg;
    int width;
    int visible_width;
    int spaces;
    luaL_Buffer buffer;

    text = luaL_optlstring(L, 1, "", &len);
    width_arg = luaL_optinteger(L, 2, 1);
    width = width_arg < 1 ? 1 : (int)width_arg;
    visible_width = psi_vm_text_visible_width_bytes(text, len);
    spaces = width > visible_width ? width - visible_width : 0;
    luaL_buffinit(L, &buffer);
    luaL_addlstring(&buffer, text, len);
    while (spaces > 0) {
        luaL_addchar(&buffer, ' ');
        spaces--;
    }
    luaL_pushresult(&buffer);
    return 1;
}

static int lfn_tui_text_wrap_ansi(lua_State *L) {
    size_t len;
    const char *text;
    lua_Integer width_arg;
    int width;
    int ok;
    int table_index;
    int preserve_whitespace;
    struct psi_vm_text_wrap_context wrap;

    text = luaL_optlstring(L, 1, "", &len);
    width_arg = luaL_optinteger(L, 2, 1);
    width = width_arg < 1 ? 1 : (int)width_arg;
    preserve_whitespace = 0;
    if (lua_istable(L, 3)) {
        lua_getfield(L, 3, "preserve_whitespace");
        preserve_whitespace = lua_toboolean(L, -1);
        lua_pop(L, 1);
    }
    lua_newtable(L);
    table_index = lua_gettop(L);
    psi_vm_text_wrap_context_init(&wrap, L, table_index, width);
    ok = 1;

    if (preserve_whitespace) {
        ok = psi_vm_text_wrap_preserve(&wrap, text, len);
    } else {
        size_t i;

        i = 0u;
        while (ok && i < len) {
            size_t next_i = i;
            if (psi_vm_text_read_escape(text, len, i, &next_i)) {
                ok = psi_vm_text_builder_append(&wrap.word, text + i, next_i - i);
            } else {
                int cluster_width;
                if ((unsigned char)text[i] == PSI_VM_TEXT_CODEPOINT_NEWLINE) {
                    next_i = i + 1u;
                    ok = psi_vm_text_wrap_flush_word(&wrap) && psi_vm_text_wrap_push_line(&wrap, 0);
                    wrap.line_width = 0;
                    wrap.pending_space = 0;
                    wrap.pending_space_width = 0;
                    /* A hard newline starts a fresh source line, so leading
                     * whitespace on it must be preserved (not treated as a
                     * soft-wrap continuation). */
                    wrap.soft_wrapped = 0;
                } else if ((unsigned char)text[i] == PSI_VM_TEXT_SPACE_BYTE ||
                    (unsigned char)text[i] == PSI_VM_TEXT_TAB_BYTE) {
                    psi_vm_text_next_cluster(text, len, i, &next_i, &cluster_width);
                    ok = psi_vm_text_wrap_flush_word(&wrap);
                    /* Accumulate the actual whitespace width so runs of
                     * spaces/tabs are preserved rather than collapsed to one. */
                    wrap.pending_space = 1;
                    wrap.pending_space_width += cluster_width > 0 ? cluster_width : 1;
                } else {
                    psi_vm_text_next_cluster(text, len, i, &next_i, &cluster_width);
                    ok = psi_vm_text_builder_append(&wrap.word, text + i, next_i - i);
                    wrap.word_width += cluster_width;
                }
            }
            i = next_i;
        }
        if (ok) {
            ok = psi_vm_text_wrap_flush_word(&wrap);
        }
    }
    if (ok && (wrap.line.len > 0u || wrap.line_count == 0)) {
        ok = psi_vm_text_wrap_push_line(&wrap, 1);
    }

    psi_vm_text_wrap_context_free(&wrap);
    if (!ok) {
        return luaL_error(L, "out of memory");
    }
    return 1;
}

static int lfn_session_message_count(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_session *s = host ? host->session : NULL;
    lua_pushinteger(L, s ? (lua_Integer)s->count : 0);
    return 1;
}

static int lfn_read_file(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    FILE *f;
    long size;
    size_t size_n;
    size_t read_n;
    char *buffer;

    if (!psi_vm_file_is_regular(path)) {
        lua_pushnil(L);
        return 1;
    }
    f = fopen(path, "rb");
    if (!f) {
        lua_pushnil(L);
        return 1;
    }
    if (fseek(f, 0l, SEEK_END) != 0) {
        fclose(f);
        lua_pushnil(L);
        return 1;
    }
    size = ftell(f);
    if (size < 0l || size > PSI_VM_READ_FILE_MAX_BYTES) {
        fclose(f);
        lua_pushnil(L);
        return 1;
    }
    size_n = (size_t)size;
    if (fseek(f, 0l, SEEK_SET) != 0) {
        fclose(f);
        lua_pushnil(L);
        return 1;
    }
    buffer = (char *)malloc(size_n + 1u);
    if (!buffer) {
        fclose(f);
        lua_pushnil(L);
        return 1;
    }
    read_n = fread(buffer, 1u, size_n, f);
    fclose(f);
    if (read_n != size_n) {
        free(buffer);
        lua_pushnil(L);
        return 1;
    }
    buffer[size_n] = '\0';
    lua_pushlstring(L, buffer, size_n);
    free(buffer);
    return 1;
}

static int lfn_read_file_prefix(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_Integer requested = luaL_optinteger(L, 2, 32);
    FILE *f;
    size_t limit;
    size_t read_n;
    char *buffer;

    if (requested < 0)
        requested = 0;
    if (requested > PSI_VM_READ_FILE_MAX_BYTES)
        requested = PSI_VM_READ_FILE_MAX_BYTES;
    limit = (size_t)requested;

    f = fopen(path, "rb");
    if (!f) {
        lua_pushnil(L);
        return 1;
    }
    buffer = (char *)malloc(limit + 1u);
    if (!buffer) {
        fclose(f);
        return luaL_error(L, "out of memory");
    }
    read_n = limit > 0u ? fread(buffer, 1u, limit, f) : 0u;
    fclose(f);
    buffer[read_n] = '\0';
    lua_pushlstring(L, buffer, read_n);
    free(buffer);
    return 1;
}

static int lfn_read_file_limited(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_Integer max_requested = luaL_optinteger(L, 2, PSI_VM_READ_FILE_MAX_BYTES);
    FILE *f;
    long size;
    long max_bytes;
    size_t size_n;
    size_t read_n;
    char *buffer;

    if (max_requested <= 0)
        max_requested = PSI_VM_READ_FILE_MAX_BYTES;
    if (max_requested > PSI_VM_FILE_WRITE_MAX_BYTES)
        max_requested = PSI_VM_FILE_WRITE_MAX_BYTES;
    max_bytes = (long)max_requested;

    f = fopen(path, "rb");
    if (!f) {
        lua_pushnil(L);
        return 1;
    }
    if (fseek(f, 0l, SEEK_END) != 0) {
        fclose(f);
        lua_pushnil(L);
        return 1;
    }
    size = ftell(f);
    if (size < 0l || size > max_bytes) {
        fclose(f);
        lua_pushnil(L);
        return 1;
    }
    size_n = (size_t)size;
    if (fseek(f, 0l, SEEK_SET) != 0) {
        fclose(f);
        lua_pushnil(L);
        return 1;
    }
    buffer = (char *)malloc(size_n + 1u);
    if (!buffer) {
        fclose(f);
        lua_pushnil(L);
        return 1;
    }
    read_n = fread(buffer, 1u, size_n, f);
    fclose(f);
    if (read_n != size_n) {
        free(buffer);
        lua_pushnil(L);
        return 1;
    }
    buffer[size_n] = '\0';
    lua_pushlstring(L, buffer, size_n);
    free(buffer);
    return 1;
}

static int lfn_random_bytes(lua_State *L) {
    lua_Integer requested = luaL_checkinteger(L, 1);
    size_t len;
    unsigned char *buffer;

    if (requested < 0 || requested > PSI_VM_RANDOM_BYTES_MAX) {
        lua_pushnil(L);
        lua_pushstring(L, "invalid byte count");
        return 2;
    }
    len = (size_t)requested;
    if (len == 0u) {
        lua_pushliteral(L, "");
        return 1;
    }
    buffer = (unsigned char *)malloc(len);
    if (buffer == NULL)
        return luaL_error(L, "out of memory");

    if (psi_random_bytes(buffer, len) != PSI_STATUS_OK) {
        free(buffer);
        lua_pushnil(L);
        lua_pushstring(L, "secure random source unavailable");
        return 2;
    }

    lua_pushlstring(L, (const char *)buffer, len);
    free(buffer);
    return 1;
}

static int lfn_read_file_bytes(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    long offset = (long)luaL_optinteger(L, 2, 0);
    long limit = (long)luaL_optinteger(L, 3, 4096);
    FILE *f;
    long size;
    size_t limit_n;
    size_t read_n;
    char *buffer;

    if (offset < 0)
        offset = 0;
    if (limit <= 0)
        limit = 1;
    if (limit > PSI_VM_READ_FILE_MAX_BYTES)
        limit = PSI_VM_READ_FILE_MAX_BYTES;

    f = fopen(path, "rb");
    if (!f) {
        lua_pushnil(L);
        return 1;
    }
    if (fseek(f, 0l, SEEK_END) != 0) {
        fclose(f);
        lua_pushnil(L);
        return 1;
    }
    size = ftell(f);
    if (size < 0l) {
        fclose(f);
        lua_pushnil(L);
        return 1;
    }
    if (offset > size)
        offset = size;
    if (fseek(f, offset, SEEK_SET) != 0) {
        fclose(f);
        lua_pushnil(L);
        return 1;
    }
    if (limit > size - offset)
        limit = size - offset;
    limit_n = (size_t)limit;
    buffer = (char *)malloc(limit_n + 1u);
    if (!buffer) {
        fclose(f);
        return luaL_error(L, "out of memory");
    }
    read_n = fread(buffer, 1u, limit_n, f);
    fclose(f);
    if (read_n != limit_n) {
        free(buffer);
        lua_pushnil(L);
        return 1;
    }
    buffer[limit_n] = '\0';

    lua_newtable(L);
    lua_pushlstring(L, buffer, limit_n);
    lua_setfield(L, -2, "bytes");
    lua_pushinteger(L, offset);
    lua_setfield(L, -2, "offset");
    lua_pushinteger(L, limit_n);
    lua_setfield(L, -2, "limit");
    lua_pushinteger(L, size);
    lua_setfield(L, -2, "total_bytes");
    if (offset + limit < size) {
        lua_pushinteger(L, offset + limit);
        lua_setfield(L, -2, "next_offset");
        lua_pushboolean(L, 1);
    } else {
        lua_pushnil(L);
        lua_setfield(L, -2, "next_offset");
        lua_pushboolean(L, 0);
    }
    lua_setfield(L, -2, "truncated");
    free(buffer);
    return 1;
}

static int lfn_read_file_slice(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    long offset = (long)luaL_optinteger(L, 2, 0);
    long limit = (long)luaL_optinteger(L, 3, 2000);
    long max_bytes = (long)luaL_optinteger(L, 4, PSI_VM_READ_FILE_MAX_BYTES);
    FILE *f;
    char *buffer;
    size_t cap;
    size_t len;
    long line;
    long total_lines;
    unsigned char read_buffer[8192];
    size_t read_count;
    int saw_any;
    int last_was_nl;
    int truncated;
    size_t next_cap;
    char *next;

    if (offset < 0)
        offset = 0;
    if (limit <= 0)
        limit = 1;
    if (max_bytes <= 0 || max_bytes > PSI_VM_FILE_WRITE_MAX_BYTES) {
        max_bytes = PSI_VM_READ_FILE_MAX_BYTES;
    }

    if (!psi_vm_file_is_regular(path)) {
        lua_pushnil(L);
        return 1;
    }
    f = fopen(path, "rb");
    if (!f) {
        lua_pushnil(L);
        return 1;
    }
    cap = 4096u;
    buffer = (char *)malloc(cap);
    if (!buffer) {
        fclose(f);
        return luaL_error(L, "out of memory");
    }

    len = 0u;
    line = 0;
    total_lines = 0;
    saw_any = 0;
    last_was_nl = 0;
    truncated = 0;
    while ((read_count = fread(read_buffer, 1u, sizeof(read_buffer), f)) > 0u) {
        size_t pos;
        for (pos = 0u; pos < read_count; pos++) {
            int ch = read_buffer[pos];
            saw_any = 1;
            last_was_nl = 0;
            if (line >= offset && line < offset + limit && !truncated) {
                if ((long)len >= max_bytes) {
                    truncated = 1;
                } else {
                    if (len + 2u > cap) {
                        next_cap = cap * 2u;
                        if ((long)next_cap > max_bytes + 1l)
                            next_cap = (size_t)max_bytes + 1u;
                        next = (char *)realloc(buffer, next_cap);
                        if (!next) {
                            free(buffer);
                            fclose(f);
                            return luaL_error(L, "out of memory");
                        }
                        buffer = next;
                        cap = next_cap;
                    }
                    buffer[len++] = (char)ch;
                }
            }
            if (ch == '\n') {
                total_lines++;
                line++;
                last_was_nl = 1;
            }
        }
        if (read_count < sizeof(read_buffer))
            break;
    }
    if (ferror(f)) {
        free(buffer);
        fclose(f);
        lua_pushnil(L);
        return 1;
    }
    fclose(f);
    if (saw_any && !last_was_nl)
        total_lines++;
    while (len > 0u && buffer[len - 1u] == '\n')
        len--;
    buffer[len] = '\0';

    lua_newtable(L);
    lua_pushlstring(L, buffer, len);
    lua_setfield(L, -2, "text");
    lua_pushinteger(L, total_lines);
    lua_setfield(L, -2, "total_lines");
    lua_pushinteger(L, offset);
    lua_setfield(L, -2, "offset");
    lua_pushinteger(L, limit);
    lua_setfield(L, -2, "limit");
    if (offset + limit < total_lines) {
        lua_pushinteger(L, offset + limit);
        lua_setfield(L, -2, "next_offset");
        lua_pushboolean(L, 1);
    } else {
        lua_pushnil(L);
        lua_setfield(L, -2, "next_offset");
        lua_pushboolean(L, truncated ? 1 : 0);
    }
    lua_setfield(L, -2, "truncated");
    lua_pushboolean(L, truncated ? 1 : 0);
    lua_setfield(L, -2, "truncated_bytes");
    free(buffer);
    return 1;
}

static int lfn_file_write(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    size_t len;
    const char *content = luaL_checklstring(L, 2, &len);
    FILE *f;

    if ((long)len > PSI_VM_FILE_WRITE_MAX_BYTES) {
        lua_pushboolean(L, 0);
        return 1;
    }
    f = fopen(path, "wb");
    if (!f) {
        lua_pushboolean(L, 0);
        return 1;
    }
    if (len > 0 && fwrite(content, 1u, len, f) != len) {
        fclose(f);
        lua_pushboolean(L, 0);
        return 1;
    }
    if (fclose(f) != 0) {
        lua_pushboolean(L, 0);
        return 1;
    }
    lua_pushboolean(L, 1);
    return 1;
}

/* O_CREAT|O_EXCL temp file in the destination directory, fsync,
 * rename(2), then fsync the parent directory. The file at `path` is
 * either the old version or the new one — never a partial write. */
static int psi_vm_file_write_atomic(
    const char *path, const char *content, size_t len, mode_t mode) {
    char tmp_path[1024];
    int fd;
    long pid_l;
    long ts;
    static unsigned long atomic_counter = 0u;

#ifdef _WIN32
    pid_l = 0;
#else
    pid_l = (long)getpid();
#endif
    ts = (long)time(NULL);
    atomic_counter++;
    if ((size_t)snprintf(tmp_path, sizeof(tmp_path), "%s.psi-tmp-%ld-%ld-%lu", path, pid_l, ts,
            atomic_counter) >= sizeof(tmp_path)) {
        return PSI_STATUS_ERROR;
    }

    fd = open(tmp_path, O_WRONLY | O_CREAT | O_EXCL, mode);
    if (fd < 0)
        return PSI_STATUS_ERROR;

    if (len > 0u) {
        size_t off = 0u;
        while (off < len) {
            ssize_t n = write(fd, content + off, len - off);
            if (n < 0) {
                if (errno == EINTR)
                    continue;
                close(fd);
                unlink(tmp_path);
                return PSI_STATUS_ERROR;
            }
            off += (size_t)n;
        }
    }
#ifndef _WIN32
    if (fsync(fd) != 0 && errno != EINVAL) {
        close(fd);
        unlink(tmp_path);
        return PSI_STATUS_ERROR;
    }
#endif
    if (close(fd) != 0) {
        unlink(tmp_path);
        return PSI_STATUS_ERROR;
    }

    if (rename(tmp_path, path) != 0) {
        unlink(tmp_path);
        return PSI_STATUS_ERROR;
    }

#ifndef _WIN32
    {
        const char *slash = strrchr(path, '/');
        int dir_fd;
        if (slash != NULL && slash != path) {
            char dir[1024];
            size_t dlen = (size_t)(slash - path);
            if (dlen < sizeof(dir)) {
                memcpy(dir, path, dlen);
                dir[dlen] = '\0';
                dir_fd = open(dir, O_RDONLY);
                if (dir_fd >= 0) {
                    (void)fsync(dir_fd);
                    close(dir_fd);
                }
            }
        } else if (slash == path) {
            dir_fd = open("/", O_RDONLY);
            if (dir_fd >= 0) {
                (void)fsync(dir_fd);
                close(dir_fd);
            }
        }
    }
#endif

    return PSI_STATUS_OK;
}

static int psi_vm_lfn_atomic_write(lua_State *L, mode_t mode) {
    const char *path = luaL_checkstring(L, 1);
    size_t len;
    const char *content = luaL_checklstring(L, 2, &len);

    if ((long)len > PSI_VM_FILE_WRITE_MAX_BYTES) {
        lua_pushboolean(L, 0);
        return 1;
    }
    lua_pushboolean(L, psi_vm_file_write_atomic(path, content, len, mode) == PSI_STATUS_OK);
    return 1;
}

static int lfn_file_write_secure(lua_State *L) {
    return psi_vm_lfn_atomic_write(L, 0600);
}

static int lfn_file_write_atomic(lua_State *L) {
    mode_t mode = (mode_t)luaL_optinteger(L, 3, 0644);
    return psi_vm_lfn_atomic_write(L, mode);
}

static int psi_vm_file_append_mode(const char *path, const char *content, size_t len, mode_t mode) {
    int fd;
    size_t off;

    fd = open(path, O_WRONLY | O_CREAT | O_APPEND, mode);
    if (fd < 0)
        return PSI_STATUS_ERROR;
#ifndef _WIN32
    (void)fchmod(fd, mode);
#endif
    off = 0u;
    while (off < len) {
        ssize_t n = write(fd, content + off, len - off);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            close(fd);
            return PSI_STATUS_ERROR;
        }
        off += (size_t)n;
    }
#ifndef _WIN32
    if (fsync(fd) != 0 && errno != EINVAL) {
        close(fd);
        return PSI_STATUS_ERROR;
    }
#endif
    if (close(fd) != 0)
        return PSI_STATUS_ERROR;
    return PSI_STATUS_OK;
}

/* psi.file_append(path, content[, mode]) -> bool */
static int lfn_file_append(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    size_t len;
    const char *content = luaL_checklstring(L, 2, &len);
    FILE *f;
    int has_mode;
    mode_t mode;

    if ((long)len > PSI_VM_FILE_WRITE_MAX_BYTES) {
        lua_pushboolean(L, 0);
        return 1;
    }
    has_mode = lua_gettop(L) >= 3 && !lua_isnil(L, 3);
    if (has_mode) {
        mode = (mode_t)luaL_checkinteger(L, 3);
        lua_pushboolean(L, psi_vm_file_append_mode(path, content, len, mode) == PSI_STATUS_OK);
        return 1;
    }
    f = fopen(path, "ab");
    if (!f) {
        lua_pushboolean(L, 0);
        return 1;
    }
    if (len > 0 && fwrite(content, 1u, len, f) != len) {
        fclose(f);
        lua_pushboolean(L, 0);
        return 1;
    }
    if (fflush(f) != 0) {
        fclose(f);
        lua_pushboolean(L, 0);
        return 1;
    }
#ifndef _WIN32
    {
        int fd = fileno(f);
        if (fd >= 0 && fsync(fd) != 0 && errno != EINVAL) {
            fclose(f);
            lua_pushboolean(L, 0);
            return 1;
        }
    }
#endif
    if (fclose(f) != 0) {
        lua_pushboolean(L, 0);
        return 1;
    }
    lua_pushboolean(L, 1);
    return 1;
}

/* psi.tempfile_path([prefix]) -> string|nil */
static int lfn_tempfile_path(lua_State *L) {
    const char *prefix = luaL_optstring(L, 1, "psi-bash-");
    const char *tmpdir;
    char safe_prefix[64];
    size_t i;
    size_t j;
#ifndef _WIN32
    char tmpl[1024];
    int fd;
#else
    static unsigned long counter = 0u;
    char buffer[1024];
    long pid = 0;
    long ts;
#endif

    tmpdir = getenv("TMPDIR");
    if (tmpdir == NULL || *tmpdir == '\0')
        tmpdir = getenv("TEMP");
    if (tmpdir == NULL || *tmpdir == '\0')
        tmpdir = getenv("TMP");
    if (tmpdir == NULL || *tmpdir == '\0')
        tmpdir = "/tmp";
    j = 0u;
    for (i = 0u; prefix[i] != '\0' && j + 1u < sizeof(safe_prefix); i++) {
        unsigned char ch = (unsigned char)prefix[i];
        if (isalnum(ch) || ch == '-' || ch == '_' || ch == '.') {
            safe_prefix[j++] = (char)ch;
        }
    }
    if (j == 0u) {
        memcpy(safe_prefix, "psi-", 5u);
        j = 4u;
    }
    safe_prefix[j] = '\0';
#ifndef _WIN32
    if ((size_t)snprintf(tmpl, sizeof(tmpl), "%s/%sXXXXXX", tmpdir, safe_prefix) >= sizeof(tmpl)) {
        lua_pushnil(L);
        return 1;
    }
    fd = mkstemp(tmpl);
    if (fd < 0) {
        lua_pushnil(L);
        return 1;
    }
    (void)fchmod(fd, 0600);
    if (close(fd) != 0) {
        unlink(tmpl);
        lua_pushnil(L);
        return 1;
    }
    lua_pushstring(L, tmpl);
#else
    ts = (long)time(NULL);
    counter++;
    {
        const char *sep = "/";
        size_t tlen = strlen(tmpdir);
        if (strchr(tmpdir, '\\') != NULL || strchr(tmpdir, ':') != NULL)
            sep = "\\";
        if (tlen > 0u && (tmpdir[tlen - 1u] == '/' || tmpdir[tlen - 1u] == '\\'))
            sep = "";
        snprintf(buffer, sizeof(buffer), "%s%s%s%ld-%ld-%lu", tmpdir, sep, safe_prefix, pid, ts,
            counter);
    }
    lua_pushstring(L, buffer);
#endif
    return 1;
}

/* Push a heap-allocated string as a Lua string (or nil if NULL), then free it. */
static void psi_vm_push_heap_string(lua_State *L, char *s) {
    if (s != NULL) {
        lua_pushstring(L, s);
        free(s);
    } else {
        lua_pushnil(L);
    }
}

static int lfn_current_date(lua_State *L) {
    psi_vm_push_heap_string(L, psi_vm_current_date());
    return 1;
}

static int lfn_cwd(lua_State *L) {
    psi_vm_push_heap_string(L, psi_vm_current_cwd());
    return 1;
}

static int lfn_parent_directory(lua_State *L) {
    psi_vm_push_heap_string(L, psi_vm_parent_directory(luaL_checkstring(L, 1)));
    return 1;
}

static int lfn_path_join(lua_State *L) {
    const char *base = luaL_checkstring(L, 1);
    const char *name = luaL_checkstring(L, 2);
    psi_vm_push_heap_string(L, psi_vm_path_join(base, name));
    return 1;
}

static int lfn_path_expand(lua_State *L) {
    psi_vm_push_heap_string(L, psi_vm_expand_path(luaL_checkstring(L, 1)));
    return 1;
}

static int lfn_path_resolve(lua_State *L) {
    psi_vm_push_heap_string(L, psi_vm_resolve_path(luaL_checkstring(L, 1)));
    return 1;
}

static int lfn_path_realpath(lua_State *L) {
    psi_vm_push_heap_string(L, psi_vm_realpath(luaL_checkstring(L, 1)));
    return 1;
}

static int lfn_file_exists(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_pushboolean(L, psi_vm_file_exists(path) ? 1 : 0);
    return 1;
}

static int lfn_file_type(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    const char *kind = psi_vm_file_type_name(path);
    if (kind == NULL) {
        lua_pushnil(L);
    } else {
        lua_pushstring(L, kind);
    }
    return 1;
}

static int lfn_list_dir(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    DIR *dir;
    struct dirent *entry;
    int i;

    dir = opendir(path);
    if (dir == NULL) {
        lua_pushnil(L);
        return 1;
    }

    lua_newtable(L);
    i = 1;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        lua_pushstring(L, entry->d_name);
        lua_rawseti(L, -2, i++);
    }
    closedir(dir);
    psi_vm_mark_array(L);
    return 1;
}

static int lfn_mkdir_p(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_pushboolean(L, psi_vm_mkdir_p(path) == PSI_STATUS_OK ? 1 : 0);
    return 1;
}

static int lfn_mkdir_parent(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_pushboolean(L, psi_vm_mkdir_parent(path) == PSI_STATUS_OK ? 1 : 0);
    return 1;
}

static void psi_vm_process_progress(void *userdata, const char *chunk, size_t len) {
    struct psi_host_context *host = (struct psi_host_context *)userdata;
    if (host == NULL || host->active_observer == NULL)
        return;
    if (host->active_observer->on_tool_progress == NULL)
        return;
    host->active_observer->on_tool_progress(
        host->active_observer->userdata, host->active_tool_id, chunk, len);
}

/* psi.tool_progress(tool_id, chunk) — stream an incremental chunk of
 * tool output to the currently-active observer. Used by the Lua
 * tool_shell coroutine path so the TUI sees live output even when
 * multiple tools are dispatched in parallel. The blocking
 * psi.process_run path already forwards progress through the C
 * callback above, so this entry point is for async tools only.
 *
 * tool_id is taken explicitly (not from host->active_tool_id)
 * because multiple tools may be in flight concurrently — each
 * sub-coroutine knows its own id. host->active_tool_id is
 * unused here. */
static int lfn_tool_progress(lua_State *L) {
    const char *tool_id;
    size_t chunk_len;
    const char *chunk;
    struct psi_host_context *host;
    const struct psi_vm *vm;

    tool_id = luaL_optstring(L, 1, NULL);
    chunk = lua_type(L, 2) == LUA_TSTRING ? lua_tolstring(L, 2, &chunk_len) : NULL;
    if (chunk == NULL || chunk_len == 0u)
        return 0;

    host = PSI_VM_HOST(L);
    if (host != NULL && host->active_observer != NULL &&
        host->active_observer->on_tool_progress != NULL) {
        host->active_observer->on_tool_progress(
            host->active_observer->userdata, tool_id, chunk, chunk_len);
        return 0;
    }

    vm = host != NULL ? host->vm : NULL;
    if (vm != NULL) {
        psi_vm_invoke_registry_callback2(L, vm->tui_tool_progress_callback_ref,
            "psi.tui_set_tool_progress_handler", tool_id != NULL ? tool_id : "",
            tool_id != NULL ? strlen(tool_id) : 0u, chunk, chunk_len);
    }
    return 0;
}

static char **psi_vm_argv_from_table(lua_State *L, int idx, int *argc_out);
static void psi_vm_argv_free(char **argv);

static void psi_vm_push_process_result(
    lua_State *L, const char *output, int exit_status, int truncated) {
    lua_newtable(L);
    lua_pushstring(L, output ? output : "");
    lua_setfield(L, -2, "output");
    lua_pushinteger(L, (lua_Integer)exit_status);
    lua_setfield(L, -2, "status");
    lua_pushboolean(L, truncated ? 1 : 0);
    lua_setfield(L, -2, "truncated");
}

static int lfn_process_run(lua_State *L) {
    const char *command = luaL_checkstring(L, 1);
    char *output = NULL;
    int status = -1;
    int truncated = 0;
    struct psi_host_context *host = PSI_VM_HOST(L);
    psi_process_progress_cb on_chunk = NULL;
    void *on_chunk_userdata = NULL;

    if (host != NULL && host->active_observer != NULL &&
        host->active_observer->on_tool_progress != NULL) {
        on_chunk = psi_vm_process_progress;
        on_chunk_userdata = host;
    }

    if (psi_process_run_shell(command, &output, &status, &truncated, on_chunk, on_chunk_userdata,
            host ? host->abort_signal : NULL) != PSI_STATUS_OK) {
        free(output);
        return luaL_error(L, "failed to run shell command");
    }
    psi_vm_push_process_result(L, output, status, truncated);
    free(output);
    return 1;
}

static int lfn_process_run_argv(lua_State *L) {
    const struct psi_host_context *host = PSI_VM_HOST(L);
    char *output = NULL;
    int exit_status = -1;
    int truncated = 0;
    int status;
    int argc;
    char **argv;

    argc = 0;
    argv = psi_vm_argv_from_table(L, 1, &argc);
    if (argv == NULL || argc <= 0) {
        psi_vm_argv_free(argv);
        psi_vm_push_process_result(L, "invalid argv", -1, 0);
        return 1;
    }

    status = psi_process_run_argv(
        argv, &output, &exit_status, &truncated, host ? host->abort_signal : NULL);
    psi_vm_argv_free(argv);

    psi_vm_push_process_result(
        L, (status == PSI_STATUS_OK && output != NULL) ? output : "", exit_status, truncated);
    free(output);
    return 1;
}

/* ------------------------------------------------------------------
 * Async process (psi.process_begin / _poll / _finish).
 *
 * Mirrors the http_stream_* surface. Callers drive the poll loop
 * from a Lua coroutine via psi.sched.proc_poll; the main thread
 * stays free to service the TUI event loop in between.
 *
 * Handle lifetime: full userdata + __gc, same rationale as
 * http_stream — a coroutine that errors between begin and finish
 * must not leak the fork()ed child + pipe fds. __gc on the
 * userdata will reap a leaked child by SIGTERMing it and running
 * psi_process_finish.
 * ------------------------------------------------------------------ */

#define PSI_PROCESS_HANDLE_MT "psi.process_handle"

static struct psi_process_handle **psi_vm_process_ud_check(lua_State *L, int idx) {
    return (struct psi_process_handle **)luaL_checkudata(L, idx, PSI_PROCESS_HANDLE_MT);
}

static int lfn_process_gc(lua_State *L) {
    struct psi_process_handle **ud = psi_vm_process_ud_check(L, 1);
    if (*ud != NULL) {
        char *out = NULL;
        int ex = -1, tr = 0;
        psi_process_terminate(*ud);
        psi_process_finish(*ud, &out, &ex, &tr);
        free(out);
        *ud = NULL;
    }
    return 0;
}

static int lfn_process_begin(lua_State *L) {
    const char *command = luaL_checkstring(L, 1);
    const struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_process_handle *h;
    struct psi_process_handle **ud;
    int status;

    h = NULL;
    status = psi_process_begin(command, host ? host->abort_signal : NULL, &h);
    if (status != PSI_STATUS_OK || h == NULL) {
        lua_pushnil(L);
        lua_pushstring(L, "failed to spawn shell");
        return 2;
    }
    ud = (struct psi_process_handle **)lua_newuserdata(L, sizeof(*ud));
    *ud = h;
    luaL_setmetatable(L, PSI_PROCESS_HANDLE_MT);
    return 1;
}

static char **psi_vm_argv_from_table(lua_State *L, int idx, int *argc_out) {
    lua_Integer n;
    char **argv;
    lua_Integer i;

    luaL_checktype(L, idx, LUA_TTABLE);
    n = lua_rawlen(L, idx);
    if (n <= 0)
        return NULL;

    /* Pre-validate every entry first. luaL_checkstring would longjmp
     * out of a half-allocated argv loop and leak. */
    for (i = 1; i <= n; i++) {
        int t;
        lua_rawgeti(L, idx, i);
        t = lua_type(L, -1);
        lua_pop(L, 1);
        if (t != LUA_TSTRING && t != LUA_TNUMBER)
            return NULL;
    }

    argv = (char **)calloc((size_t)n + 1u, sizeof(char *));
    if (argv == NULL)
        return NULL;
    for (i = 1; i <= n; i++) {
        const char *value;
        lua_rawgeti(L, idx, i);
        value = lua_tostring(L, -1);
        argv[i - 1] = (value != NULL) ? psi_strdup(value) : NULL;
        lua_pop(L, 1);
        if (argv[i - 1] == NULL) {
            lua_Integer j;
            for (j = 0; j < i - 1; j++)
                free(argv[j]);
            free(argv);
            return NULL;
        }
    }
    argv[n] = NULL;
    if (argc_out != NULL)
        *argc_out = (int)n;
    return argv;
}

static void psi_vm_argv_free(char **argv) {
    int i;
    if (argv == NULL)
        return;
    for (i = 0; argv[i] != NULL; i++) {
        free(argv[i]);
    }
    free(argv);
}

static int lfn_process_begin_argv(lua_State *L) {
    const struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_process_handle *h;
    struct psi_process_handle **ud;
    char **argv;
    int argc;
    int status;

    argc = 0;
    argv = psi_vm_argv_from_table(L, 1, &argc);
    if (argv == NULL || argc <= 0) {
        psi_vm_argv_free(argv);
        lua_pushnil(L);
        lua_pushstring(L, "invalid argv");
        return 2;
    }

    h = NULL;
    status = psi_process_begin_argv(argv, host ? host->abort_signal : NULL, &h);
    psi_vm_argv_free(argv);
    if (status != PSI_STATUS_OK || h == NULL) {
        lua_pushnil(L);
        lua_pushstring(L, "failed to spawn process");
        return 2;
    }
    ud = (struct psi_process_handle **)lua_newuserdata(L, sizeof(*ud));
    *ud = h;
    luaL_setmetatable(L, PSI_PROCESS_HANDLE_MT);
    return 1;
}

#if PSI_ENABLE_MCP
static int lfn_process_begin_stdio_argv(lua_State *L) {
    const struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_process_handle *h;
    struct psi_process_handle **ud;
    char **argv;
    char **env_pairs;
    int argc;
    int env_count;
    int status;

    argc = 0;
    argv = psi_vm_argv_from_table(L, 1, &argc);
    if (argv == NULL || argc <= 0) {
        psi_vm_argv_free(argv);
        lua_pushnil(L);
        lua_pushstring(L, "invalid argv");
        return 2;
    }

    env_pairs = NULL;
    env_count = 0;
    if (lua_istable(L, 2)) {
        env_pairs = psi_vm_argv_from_table(L, 2, &env_count);
    }

    h = NULL;
    status = psi_process_begin_stdio_argv(
        argv, (const char *const *)env_pairs, env_count, host ? host->abort_signal : NULL, &h);
    psi_vm_argv_free(argv);
    psi_vm_argv_free(env_pairs);
    if (status != PSI_STATUS_OK || h == NULL) {
        lua_pushnil(L);
        lua_pushstring(L, "failed to spawn stdio process");
        return 2;
    }
    ud = (struct psi_process_handle **)lua_newuserdata(L, sizeof(*ud));
    *ud = h;
    luaL_setmetatable(L, PSI_PROCESS_HANDLE_MT);
    return 1;
}

static int lfn_process_write(lua_State *L) {
    struct psi_process_handle **ud;
    struct psi_process_handle *h;
    const char *data;
    size_t data_len;

    ud = psi_vm_process_ud_check(L, 1);
    h = *ud;
    if (h == NULL) {
        lua_pushnil(L);
        lua_pushstring(L, "process_write: handle already finished");
        return 2;
    }
    data = luaL_checklstring(L, 2, &data_len);
    if (psi_process_write(h, data, data_len) != PSI_STATUS_OK) {
        lua_pushnil(L);
        lua_pushstring(L, "process_write failed");
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int lfn_process_try_write(lua_State *L) {
    struct psi_process_handle **ud;
    struct psi_process_handle *h;
    const char *data;
    size_t data_len;
    size_t written;

    ud = psi_vm_process_ud_check(L, 1);
    h = *ud;
    if (h == NULL) {
        lua_pushnil(L);
        lua_pushstring(L, "process_try_write: handle already finished");
        return 2;
    }
    data = luaL_checklstring(L, 2, &data_len);
    written = 0u;
    if (psi_process_try_write(h, data, data_len, &written) != PSI_STATUS_OK) {
        lua_pushnil(L);
        lua_pushstring(L, "process_try_write failed");
        return 2;
    }
    lua_pushinteger(L, (lua_Integer)written);
    return 1;
}

static int lfn_process_close_stdin(lua_State *L) {
    struct psi_process_handle **ud;
    struct psi_process_handle *h;

    ud = psi_vm_process_ud_check(L, 1);
    h = *ud;
    if (h == NULL) {
        lua_pushboolean(L, 1);
        return 1;
    }
    if (psi_process_close_stdin(h) != PSI_STATUS_OK) {
        lua_pushnil(L);
        lua_pushstring(L, "process_close_stdin failed");
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int lfn_process_terminate(lua_State *L) {
    struct psi_process_handle **ud;
    struct psi_process_handle *h;

    ud = psi_vm_process_ud_check(L, 1);
    h = *ud;
    if (h == NULL) {
        lua_pushboolean(L, 1);
        return 1;
    }
    if (psi_process_terminate(h) != PSI_STATUS_OK) {
        lua_pushnil(L);
        lua_pushstring(L, "process_terminate failed");
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}
#endif

static int lfn_process_poll(lua_State *L) {
    struct psi_process_handle **ud;
    struct psi_process_handle *h;
    int timeout_ms;
    char *chunk;
    size_t chunk_len;
    int result;

    ud = psi_vm_process_ud_check(L, 1);
    h = *ud;
    if (h == NULL) {
        return luaL_error(L, "process_poll: handle already finished");
    }
    timeout_ms = (int)luaL_optinteger(L, 2, 0);
    chunk = NULL;
    chunk_len = 0u;

    result = psi_process_poll(h, timeout_ms, &chunk, &chunk_len);

    /* (chunk | nil, done_flag) mirroring http_stream_poll.
     *
     * psi_process_poll returns:
     *   1  chunk available
     *   0  timeout
     *   2  child done (EOF)
     *  -1  unrecoverable error (alloc fail etc.)
     *
     * Both "done" and "error" collapse to done=true from Lua's
     * perspective so the coroutine stops the poll loop; the
     * caller's finish() will then reap the child with whatever
     * status applies. (Lua-side: a nil chunk with done=true is
     * the terminal signal.) */
    if (result == 1 && chunk != NULL) {
        lua_pushlstring(L, chunk, chunk_len);
        free(chunk);
    } else {
        lua_pushnil(L);
    }
    lua_pushboolean(L, (result == 2 || result < 0) ? 1 : 0);
    return 2;
}

static int lfn_process_finish(lua_State *L) {
    struct psi_process_handle **ud;
    struct psi_process_handle *h;
    char *output;
    int status;
    int truncated;

    ud = psi_vm_process_ud_check(L, 1);
    h = *ud;
    if (h == NULL) {
        /* Idempotent double-finish: return a zero-shaped result. */
        psi_vm_push_process_result(L, "", -1, 0);
        return 1;
    }
    *ud = NULL; /* consumed before the C call so __gc skips */
    output = NULL;
    status = -1;
    truncated = 0;

    if (psi_process_finish(h, &output, &status, &truncated) != PSI_STATUS_OK) {
        free(output);
        return luaL_error(L, "process_finish failed");
    }

    psi_vm_push_process_result(L, output, status, truncated);
    free(output);
    return 1;
}

static int lfn_session_append(lua_State *L) {
    const char *role = luaL_checkstring(L, 1);
    const char *text = luaL_checkstring(L, 2);
    const char *data = NULL;
    lua_Integer estimate_arg = -1;
    struct psi_host_context *host;
    struct psi_session *s;
    int status;

    if (lua_type(L, 3) == LUA_TSTRING)
        data = lua_tostring(L, 3);
    if (lua_type(L, 4) == LUA_TNUMBER)
        estimate_arg = lua_tointeger(L, 4);

    host = PSI_VM_HOST(L);
    s = host ? host->session : NULL;
    if (!s) {
        lua_pushboolean(L, 0);
        return 1;
    }
    if (estimate_arg >= 0) {
        status = psi_session_append_with_data_and_estimate(
            s, psi_session_role_from_name(role), text, data, (size_t)estimate_arg);
    } else {
        status = psi_session_append_with_data(s, psi_session_role_from_name(role), text, data);
    }
    if (status == PSI_STATUS_OK)
        psi_vm_session_mark_retained(s);
    lua_pushboolean(L, status == PSI_STATUS_OK ? 1 : 0);
    return 1;
}

static int lfn_json_encode(lua_State *L) {
    cJSON *value;
    char *encoded;

    if (lua_gettop(L) < 1 || lua_isnil(L, 1)) {
        lua_pushstring(L, "null");
        return 1;
    }
    value = psi_vm_lua_value_to_json(L, 1);
    if (value == NULL) {
        return luaL_error(L, "failed to encode value as JSON");
    }
    encoded = cJSON_PrintUnformatted(value);
    cJSON_Delete(value);
    if (encoded == NULL) {
        return luaL_error(L, "failed to serialize JSON");
    }
    lua_pushstring(L, encoded);
    free(encoded);
    return 1;
}

static int lfn_json_decode(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    cJSON *value;

    if (text[0] == '\0') {
        lua_pushnil(L);
        return 1;
    }
    value = cJSON_Parse(text);
    if (value == NULL) {
        return luaL_error(L, "invalid JSON");
    }
    psi_vm_push_json_value(L, value);
    cJSON_Delete(value);
    return 1;
}

typedef int (*psi_session_set_fn)(struct psi_session *, const char *);

static int psi_vm_session_set(lua_State *L, psi_session_set_fn fn) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_session *s = host ? host->session : NULL;
    const char *val = lua_type(L, 1) == LUA_TSTRING ? lua_tostring(L, 1) : NULL;
    int status;

    if (!s) {
        lua_pushboolean(L, 0);
        return 1;
    }
    status = fn(s, val);
    if (status == PSI_STATUS_OK)
        psi_vm_session_mark_retained(s);
    lua_pushboolean(L, status == PSI_STATUS_OK ? 1 : 0);
    return 1;
}

static int lfn_session_set_id(lua_State *L) {
    return psi_vm_session_set(L, psi_session_set_id);
}
static int lfn_session_set_path(lua_State *L) {
    return psi_vm_session_set(L, psi_session_set_path);
}
static int lfn_session_set_parent_id(lua_State *L) {
    return psi_vm_session_set(L, psi_session_set_parent_id);
}

static int psi_vm_session_get_string(lua_State *L, size_t offset) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_session *s = host ? host->session : NULL;
    const char *val;
    if (!s) {
        lua_pushnil(L);
        return 1;
    }
    val = *(const char **)((const char *)s + offset);
    if (!val) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushstring(L, val);
    return 1;
}

static int lfn_session_path(lua_State *L) {
    return psi_vm_session_get_string(L, offsetof(struct psi_session, path));
}
static int lfn_session_parent_id(lua_State *L) {
    return psi_vm_session_get_string(L, offsetof(struct psi_session, parent_id));
}
static int lfn_session_id(lua_State *L) {
    return psi_vm_session_get_string(L, offsetof(struct psi_session, id));
}

static int psi_lua_collect_headers(lua_State *L, int idx, char ***out, size_t *out_count) {
    lua_Integer len;
    lua_Integer i;
    char **headers;

    idx = lua_absindex(L, idx);
    len = (lua_Integer)lua_rawlen(L, idx);
    if (len <= 0) {
        *out = NULL;
        *out_count = 0u;
        return 0;
    }
    headers = (char **)malloc(sizeof(*headers) * (size_t)len);
    if (headers == NULL)
        return -1;
    for (i = 1; i <= len; i++) {
        const char *value;
        lua_rawgeti(L, idx, i);
        value = lua_tostring(L, -1);
        headers[i - 1] = value != NULL ? psi_strdup(value) : psi_strdup("");
        lua_pop(L, 1);
    }
    *out = headers;
    *out_count = (size_t)len;
    return 0;
}

static void psi_lua_free_headers(char **headers, size_t count) {
    size_t i;
    if (headers == NULL)
        return;
    for (i = 0; i < count; i++)
        free(headers[i]);
    free((void *)headers);
}

/* ------------------------------------------------------------------
 * Async streaming HTTP (psi.http_stream_*).
 *
 * Begin spawns a helper thread that runs curl_easy_perform; poll
 * drains one chunk at a time with a timeout; finish joins the thread
 * and returns the HTTP status code.
 *
 * Ownership: the handle is returned as a FULL userdata with a
 * metatable that has a __gc finaliser. If the Lua caller explicitly
 * calls finish (the normal path), the pointer is nulled out so the
 * finaliser is a no-op. If the coroutine errors between begin and
 * finish (OOM mid-sse_feed, bug in a provider module), the userdata
 * becomes unreachable and __gc reaps the pthread + curl handle +
 * queued chunks. Before this change the handle was light userdata
 * with no GC — errors leaked everything.
 * ------------------------------------------------------------------ */

#define PSI_HTTP_STREAM_MT "psi.http_stream"

struct psi_vm_http_stream_ud {
    struct psi_http_stream *stream;
};

static struct psi_vm_http_stream_ud *psi_vm_http_stream_ud_check(lua_State *L, int idx) {
    struct psi_vm_http_stream_ud *ud;

    ud = (struct psi_vm_http_stream_ud *)luaL_checkudata(L, idx, PSI_HTTP_STREAM_MT);
    if (ud == NULL) {
        luaL_error(L, "invalid http stream handle");
        abort();
    }
    return ud;
}

static int lfn_http_stream_gc(lua_State *L) {
    struct psi_vm_http_stream_ud *ud = psi_vm_http_stream_ud_check(L, 1);
    psi_http_stream_finish_owned(&ud->stream, NULL);
    return 0;
}

static int lfn_http_stream_begin(lua_State *L) {
    const char *url = luaL_checkstring(L, 1);
    size_t body_len;
    const char *body;
    char **headers;
    size_t header_count;
    const struct psi_host_context *host;
    struct psi_http_stream *h;
    struct psi_vm_http_stream_ud *ud;
    int status;

    luaL_checktype(L, 2, LUA_TTABLE);
    body = luaL_checklstring(L, 3, &body_len);

    if (psi_lua_collect_headers(L, 2, &headers, &header_count) != 0) {
        return luaL_error(L, "failed to collect headers");
    }

    host = PSI_VM_HOST(L);
    h = NULL;
    status = psi_http_stream_begin(url, (const char *const *)headers, header_count, body, body_len,
        host ? host->abort_signal : NULL, &h);
    psi_lua_free_headers(headers, header_count);

    if (status != PSI_STATUS_OK || h == NULL) {
        lua_pushnil(L);
        lua_pushstring(L, "failed to start http stream");
        return 2;
    }

    ud = (struct psi_vm_http_stream_ud *)lua_newuserdata(L, sizeof(*ud));
    ud->stream = h;
    luaL_setmetatable(L, PSI_HTTP_STREAM_MT);
    return 1;
}

static int lfn_http_stream_poll(lua_State *L) {
    struct psi_vm_http_stream_ud *ud;
    struct psi_http_stream *h;
    int timeout_ms;
    char *chunk;
    size_t chunk_len;
    int result;

    ud = psi_vm_http_stream_ud_check(L, 1);
    h = ud->stream;
    if (h == NULL) {
        return luaL_error(L, "http_stream_poll: handle already finished");
    }
    timeout_ms = (int)luaL_optinteger(L, 2, 0);
    chunk = NULL;
    chunk_len = 0u;

    result = psi_http_stream_poll(h, timeout_ms, &chunk, &chunk_len);

    /* Returns (chunk, done_flag):
     *   1 → (string, false)
     *   0 → (nil,    false)   -- timeout
     *   2 → (nil,    true)    -- stream done
     */
    if (result == 1 && chunk != NULL) {
        lua_pushlstring(L, chunk, chunk_len);
        free(chunk);
    } else {
        lua_pushnil(L);
    }
    lua_pushboolean(L, result == 2 ? 1 : 0);
    return 2;
}

static int lfn_http_stream_finish(lua_State *L) {
    struct psi_vm_http_stream_ud *ud;
    long status;
    char *error_message;

    ud = (struct psi_vm_http_stream_ud *)luaL_checkudata(L, 1, PSI_HTTP_STREAM_MT);
    if (ud == NULL) {
        return luaL_error(L, "http_stream_finish: invalid stream handle");
    }

    error_message = NULL;
    status = psi_http_stream_finish_owned(&ud->stream, &error_message);
    lua_pushinteger(L, (lua_Integer)status);
    if (status < 0 && error_message != NULL) {
        lua_pushstring(L, error_message);
        free(error_message);
        return 2;
    }
    return 1;
}

/* Shared buffered HTTP request: collect headers from arg 2, call
 * psi_http_post (body=NULL acts as GET), push (status_code, body)
 * or (nil, error_message). */
static int psi_vm_http_request(lua_State *L, const char *url, const char *body, size_t body_len) {
    char **headers;
    size_t header_count;
    struct psi_host_context *host;
    long status_code;
    char *response;
    char *error_message;
    int status;

    if (psi_lua_collect_headers(L, 2, &headers, &header_count) != 0) {
        return luaL_error(L, "failed to collect headers");
    }

    host = PSI_VM_HOST(L);
    status_code = 0l;
    response = NULL;
    error_message = NULL;
    status = psi_http_post(url, (const char *const *)headers, header_count, body, body_len,
        host ? host->abort_signal : NULL, &status_code, &response, &error_message);

    psi_lua_free_headers(headers, header_count);

    if (status != PSI_STATUS_OK) {
        free(response);
        lua_pushnil(L);
        lua_pushstring(L, error_message != NULL ? error_message : "http request failed");
        free(error_message);
        return 2;
    }
    lua_pushinteger(L, status_code);
    lua_pushstring(L, response != NULL ? response : "");
    free(response);
    return 2;
}

static int lfn_http_post(lua_State *L) {
    const char *url = luaL_checkstring(L, 1);
    size_t body_len;
    const char *body;
    luaL_checktype(L, 2, LUA_TTABLE);
    body = luaL_checklstring(L, 3, &body_len);
    return psi_vm_http_request(L, url, body, body_len);
}

static int lfn_http_get(lua_State *L) {
    const char *url = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    return psi_vm_http_request(L, url, NULL, 0u);
}

static int lfn_is_aborted(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    lua_pushboolean(L, host != NULL && psi_abort_signal_is_triggered(host->abort_signal) ? 1 : 0);
    return 1;
}

static int lfn_abort_trigger(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    if (host != NULL) {
        psi_abort_signal_trigger(host->abort_signal);
    }
    return 0;
}

static int lfn_abort_reset(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    if (host != NULL) {
        psi_abort_signal_reset(host->abort_signal);
    }
    return 0;
}

/* psi.set_usage(input, output, cache_read, cache_write, total, context_window)
 *
 * Publishes the most recent API-reported usage into the shared
 * host-context mirror so the TUI main thread can render rich status
 * without calling into Lua (which is unsafe while the worker thread
 * is mid-lua_pcall on the same state — see commit 3548caa).
 *
 * Each field is a Lua integer, coerced to long. `psi.context.
 * record_usage` is the normal caller; `reset_usage` passes zeros. */
static int lfn_set_usage(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    if (host == NULL)
        return 0;
    host->usage.input = (long)luaL_optinteger(L, 1, 0);
    host->usage.output = (long)luaL_optinteger(L, 2, 0);
    host->usage.cache_read = (long)luaL_optinteger(L, 3, 0);
    host->usage.cache_write = (long)luaL_optinteger(L, 4, 0);
    host->usage.total = (long)luaL_optinteger(L, 5, 0);
    host->usage.context_window = (long)luaL_optinteger(L, 6, 0);
    return 0;
}

/* Inflate an embedded entry into a caller-provided buffer. Returns
 * PSI_STATUS_OK on success (buffer filled with entry->raw_len bytes).
 * The caller owns the buffer; on error the buffer contents are
 * undefined but no allocation is retained. */
static int psi_vm_embedded_inflate(
    const struct psi_embedded_data *e, unsigned char *out, size_t out_len) {
    uLongf dst_len = (uLongf)out_len;
    int rc;
    if (e == NULL || e->src == NULL || out == NULL)
        return PSI_STATUS_ERROR;
    rc = uncompress(out, &dst_len, e->src, (uLong)e->len);
    if (rc != Z_OK || dst_len != (uLongf)e->raw_len) {
        fprintf(stderr, "psi: inflate failed for %s (zlib %d, %lu/%lu)\n", e->name, rc,
            (unsigned long)dst_len, (unsigned long)e->raw_len);
        return PSI_STATUS_ERROR;
    }
    return PSI_STATUS_OK;
}

static int psi_vm_lookup_embedded(lua_State *L, const struct psi_embedded_data *table) {
    const char *name = luaL_checkstring(L, 1);
    const struct psi_embedded_data *e;
    for (e = table; e->name != NULL; e++) {
        if (strcmp(e->name, name) == 0) {
            unsigned char *buf = (unsigned char *)malloc(e->raw_len + 1u);
            if (buf == NULL)
                return luaL_error(L, "out of memory");
            if (psi_vm_embedded_inflate(e, buf, e->raw_len) != PSI_STATUS_OK) {
                free(buf);
                lua_pushnil(L);
                return 1;
            }
            buf[e->raw_len] = 0;
            lua_pushlstring(L, (const char *)buf, e->raw_len);
            free(buf);
            return 1;
        }
    }
    lua_pushnil(L);
    return 1;
}

static int psi_vm_list_embedded_names(lua_State *L, const struct psi_embedded_data *table) {
    const struct psi_embedded_data *e;
    int i = 1;
    lua_newtable(L);
    for (e = table; e->name != NULL; e++, i++) {
        lua_pushstring(L, e->name);
        lua_rawseti(L, -2, i);
    }
    return 1;
}

static int lfn_embedded_doc(lua_State *L) {
    return psi_vm_lookup_embedded(L, psi_embedded_docs_table);
}

static int lfn_embedded_doc_names(lua_State *L) {
    return psi_vm_list_embedded_names(L, psi_embedded_docs_table);
}

static int lfn_embedded_source(lua_State *L) {
    return psi_vm_lookup_embedded(L, psi_embedded_lua_table);
}

static int lfn_embedded_source_names(lua_State *L) {
    return psi_vm_list_embedded_names(L, psi_embedded_lua_table);
}

static int lfn_session_clear(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_session *s = host ? host->session : NULL;
    if (!s) {
        lua_pushboolean(L, 0);
        return 1;
    }
    lua_pushboolean(L, psi_session_clear(s) == PSI_STATUS_OK ? 1 : 0);
    return 1;
}

static int lfn_session_messages(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_session *s = host ? host->session : NULL;
    size_t i;

    lua_newtable(L);
    psi_vm_mark_array(L);
    if (!s)
        return 1;
    for (i = 0; i < s->count; i++) {
        lua_newtable(L);
        lua_pushstring(L, psi_message_role_name(s->messages[i].role));
        lua_setfield(L, -2, "role");
        lua_pushstring(L, s->messages[i].text ? s->messages[i].text : "");
        lua_setfield(L, -2, "text");
        if (s->messages[i].data_json) {
            lua_pushstring(L, s->messages[i].data_json);
            lua_setfield(L, -2, "data");
        }
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
    }
    return 1;
}

static int lfn_session_messages_from(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_session *s = host ? host->session : NULL;
    lua_Integer start_arg = luaL_optinteger(L, 1, 1);
    size_t start;
    size_t i;
    int out_index;

    lua_newtable(L);
    psi_vm_mark_array(L);
    if (!s)
        return 1;
    if (start_arg < 1)
        start_arg = 1;
    start = (size_t)(start_arg - 1);
    if (start >= s->count)
        return 1;

    out_index = 1;
    for (i = start; i < s->count; i++) {
        lua_newtable(L);
        lua_pushstring(L, psi_message_role_name(s->messages[i].role));
        lua_setfield(L, -2, "role");
        lua_pushstring(L, s->messages[i].text ? s->messages[i].text : "");
        lua_setfield(L, -2, "text");
        if (s->messages[i].data_json) {
            lua_pushstring(L, s->messages[i].data_json);
            lua_setfield(L, -2, "data");
        }
        lua_rawseti(L, -2, out_index++);
    }
    return 1;
}

static int lfn_session_token_estimate_from(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    const struct psi_session *s = host ? host->session : NULL;
    lua_Integer start_arg = luaL_optinteger(L, 1, 1);
    size_t start;

    if (!s) {
        lua_pushinteger(L, 0);
        return 1;
    }
    if (start_arg < 1)
        start_arg = 1;
    start = (size_t)start_arg;
    lua_pushinteger(L, (lua_Integer)psi_session_token_estimate_from(s, start));
    return 1;
}

static int lfn_session_keep_recent_by_tokens(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    const struct psi_session *s = host ? host->session : NULL;
    lua_Integer target_arg = luaL_optinteger(L, 1, 0);
    size_t target;

    if (!s) {
        lua_pushinteger(L, 0);
        return 1;
    }
    target = target_arg < 0 ? 0u : (size_t)target_arg;
    lua_pushinteger(L, (lua_Integer)psi_session_keep_recent_by_tokens(s, target));
    return 1;
}

static int lfn_runtime_info(lua_State *L) {
    struct psi_host_context *host;
    char *date;
    char *cwd;

    host = PSI_VM_HOST(L);
    date = psi_vm_current_date();
    cwd = psi_vm_current_cwd();
    if (!date || !cwd) {
        free(date);
        free(cwd);
        return luaL_error(L, "failed to collect runtime info");
    }

    lua_newtable(L);

    lua_pushstring(L, PSI_VERSION);
    lua_setfield(L, -2, "version");
    lua_pushstring(L, PSI_GIT_COMMIT);
    lua_setfield(L, -2, "git-commit");

    if (host && host->vm && host->vm->boot_file) {
        lua_pushstring(L, host->vm->boot_file);
    } else {
        lua_pushnil(L);
    }
    lua_setfield(L, -2, "boot-file");

    lua_pushstring(L, date);
    lua_setfield(L, -2, "current-date");

    lua_pushstring(L, cwd);
    lua_setfield(L, -2, "current-working-directory");

    lua_pushboolean(L, PSI_ENABLE_ANSI ? 1 : 0);
    lua_setfield(L, -2, "ansi");
    lua_pushboolean(L, (PSI_ENABLE_ANSI && PSI_ENABLE_COLOR) ? 1 : 0);
    lua_setfield(L, -2, "color");
    lua_pushboolean(L, PSI_ENABLE_MCP ? 1 : 0);
    lua_setfield(L, -2, "mcp");
    lua_pushboolean(L, PSI_ENABLE_REPL_EDITLINE ? 1 : 0);
    lua_setfield(L, -2, "repl-editline");
    lua_pushboolean(L, PSI_ENABLE_TUI ? 1 : 0);
    lua_setfield(L, -2, "tui");

    {
        struct psi_session *s = host ? host->session : NULL;
        lua_pushinteger(L, s ? (lua_Integer)s->count : 0);
        lua_setfield(L, -2, "session-message-count");
    }

    /* Iterate the live `psi` table so the primitives list can't
     * drift from the actual registration. */
    lua_newtable(L);
    psi_vm_mark_array(L);
    {
        lua_Integer next_idx = 1;
        lua_getglobal(L, "psi");
        if (lua_type(L, -1) == LUA_TTABLE) {
            lua_pushnil(L);
            while (lua_next(L, -2) != 0) {
                if (lua_type(L, -2) == LUA_TSTRING && lua_type(L, -1) == LUA_TFUNCTION) {
                    lua_pushvalue(L, -2); /* key copy */
                    lua_rawseti(L, -5, next_idx); /* primitives[next_idx] = key */
                    next_idx++;
                }
                lua_pop(L, 1); /* value, keep key for next iter */
            }
        }
        lua_pop(L, 1); /* psi global (or nil) */
    }
    lua_setfield(L, -2, "primitives");

    free(date);
    free(cwd);
    return 1;
}

/* psi.readline(prompt) -> string or nil (nil on EOF / Ctrl-D). */
static int lfn_readline(lua_State *L) {
    const char *prompt = lua_type(L, 1) == LUA_TSTRING ? lua_tostring(L, 1) : "";
#if PSI_ENABLE_REPL_EDITLINE
    char *line = readline(prompt);
    if (line == NULL) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushstring(L, line);
    free(line);
    return 1;
#else
    char buffer[4096];
    size_t len;
    fputs(prompt, stdout);
    fflush(stdout);
    if (fgets(buffer, sizeof(buffer), stdin) == NULL) {
        lua_pushnil(L);
        return 1;
    }
    len = strlen(buffer);
    while (len > 0u && (buffer[len - 1u] == '\n' || buffer[len - 1u] == '\r')) {
        buffer[--len] = '\0';
    }
    lua_pushstring(L, buffer);
    return 1;
#endif
}

/* psi.add_history(line) -- libedit history append. */
static int lfn_add_history(lua_State *L) {
#if PSI_ENABLE_REPL_EDITLINE
    const char *line = lua_type(L, 1) == LUA_TSTRING ? lua_tostring(L, 1) : NULL;
    if (line != NULL && line[0] != '\0')
        add_history(line);
#else
    PSI_UNUSED(L);
#endif
    return 0;
}

#if PSI_ENABLE_TUI

static int lfn_tui_size(lua_State *L) {
    struct winsize ws;
    int height = PSI_VM_TUI_DEFAULT_HEIGHT;
    int width = PSI_VM_TUI_DEFAULT_WIDTH;

    psi_vm_require_tui(L);
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0) {
        if (ws.ws_col > 0) {
            width = (int)ws.ws_col;
        }
        if (ws.ws_row > 0) {
            height = (int)ws.ws_row;
        }
    }
    lua_newtable(L);
    lua_pushinteger(L, (lua_Integer)width);
    lua_setfield(L, -2, "width");
    lua_pushinteger(L, (lua_Integer)height);
    lua_setfield(L, -2, "height");
    return 1;
}

static int lfn_tui_poll_key(lua_State *L) {
    lua_Integer timeout_ms;
    int ch;
    struct psi_vm_tui_key_event event;

    psi_vm_require_tui(L);
    timeout_ms = luaL_optinteger(L, 1, PSI_VM_TUI_POLL_INFINITE_MS);
    if (timeout_ms < PSI_VM_TUI_POLL_INFINITE_MS) {
        timeout_ms = PSI_VM_TUI_POLL_INFINITE_MS;
    }
    if (timeout_ms > PSI_VM_TUI_POLL_MAX_MS) {
        timeout_ms = PSI_VM_TUI_POLL_MAX_MS;
    }
    ch = psi_vm_tui_read_byte((int)timeout_ms);
    if (ch < 0) {
        lua_pushnil(L);
        return 1;
    }
    if (!psi_vm_tui_normalize_key(ch, (int)timeout_ms, &event)) {
        lua_pushnil(L);
        return 1;
    }

    lua_newtable(L);
    lua_pushstring(L, event.key_name);
    lua_setfield(L, -2, "key");
    if (event.text[0] != '\0') {
        lua_pushstring(L, event.text);
        lua_setfield(L, -2, "text");
    }
    return 1;
}

static int lfn_tui_clear(lua_State *L) {
    int force_physical_clear = lua_toboolean(L, 1);
    psi_vm_require_tui(L);
    if (force_physical_clear) {
        psi_vm_tui_reset_render_cache();
        psi_vm_tui_write(PSI_VM_TUI_CLEAR_SCREEN);
    }
    return 0;
}

static int lfn_tui_draw_raw_line(lua_State *L) {
    lua_Integer row = luaL_checkinteger(L, 1);
    const char *text = lua_type(L, 2) == LUA_TSTRING ? lua_tostring(L, 2) : "";

    psi_vm_require_tui(L);
    if (row < PSI_VM_TUI_FIRST_TERMINAL_CELL) {
        row = PSI_VM_TUI_FIRST_TERMINAL_CELL;
    }

    psi_vm_tui_draw_raw_line((long)row, text);
    return 0;
}

static int lfn_tui_draw_line(lua_State *L) {
    return lfn_tui_draw_raw_line(L);
}

static int lfn_tui_render_frame(lua_State *L) {
    const char *frame = lua_type(L, 1) == LUA_TSTRING ? lua_tostring(L, 1) : "";
    lua_Integer row = luaL_optinteger(L, 2, PSI_VM_TUI_FIRST_TERMINAL_CELL);
    lua_Integer col = luaL_optinteger(L, 3, PSI_VM_TUI_FIRST_TERMINAL_CELL);
    int visible = lua_toboolean(L, 4);

    psi_vm_require_tui(L);
    if (row < PSI_VM_TUI_FIRST_TERMINAL_CELL) {
        row = PSI_VM_TUI_FIRST_TERMINAL_CELL;
    }
    if (col < PSI_VM_TUI_FIRST_TERMINAL_CELL) {
        col = PSI_VM_TUI_FIRST_TERMINAL_CELL;
    }
    if (visible) {
        printf("%s%s%s%s\033[%ld;%ldH%s%s", PSI_VM_TUI_SYNC_BEGIN, PSI_VM_TUI_CURSOR_HIDE, frame,
            PSI_VM_TUI_RESET_STYLE, (long)row, (long)col, PSI_VM_TUI_CURSOR_SHOW,
            PSI_VM_TUI_SYNC_END);
    } else {
        printf("%s%s%s%s%s", PSI_VM_TUI_SYNC_BEGIN, PSI_VM_TUI_CURSOR_HIDE, frame,
            PSI_VM_TUI_RESET_STYLE, PSI_VM_TUI_SYNC_END);
    }
    fflush(stdout);
    psi_vm_tui_frame_active = 0;
    return 0;
}

static int lfn_tui_render_lines(lua_State *L) {
    char **next_lines;
    size_t line_count;
    size_t i;
    lua_Integer cursor_row_arg;
    lua_Integer cursor_col_arg;
    lua_Integer top_arg;
    long top;
    long cursor_row;
    long cursor_col;
    long physical_cursor_row;
    int cursor_visible;
    int force_full;
    int full_redraw;
    int any_output;
    int cursor_changed;

    psi_vm_require_tui(L);
    luaL_checktype(L, 1, LUA_TTABLE);
    line_count = (size_t)lua_rawlen(L, 1);
    if (line_count == 0u) {
        line_count = 1u;
    }
    next_lines = (char **)calloc(line_count, sizeof(char *));
    if (next_lines == NULL) {
        return luaL_error(L, "out of memory");
    }
    for (i = 0u; i < line_count; i++) {
        const char *line;
        lua_rawgeti(L, 1, (lua_Integer)i + 1);
        line = lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : "";
        next_lines[i] = psi_strdup(line != NULL ? line : "");
        lua_pop(L, 1);
        if (next_lines[i] == NULL) {
            size_t j;
            for (j = 0u; j < i; j++) {
                free(next_lines[j]);
            }
            free(next_lines);
            return luaL_error(L, "out of memory");
        }
    }

    cursor_row_arg = luaL_optinteger(L, 2, PSI_VM_TUI_FIRST_TERMINAL_CELL);
    cursor_col_arg = luaL_optinteger(L, 3, PSI_VM_TUI_FIRST_TERMINAL_CELL);
    cursor_visible = lua_toboolean(L, 4);
    force_full = lua_toboolean(L, 5);
    top_arg = luaL_optinteger(L, 6, PSI_VM_TUI_FIRST_TERMINAL_CELL);
    cursor_row = cursor_row_arg < PSI_VM_TUI_FIRST_TERMINAL_CELL ? PSI_VM_TUI_FIRST_TERMINAL_CELL :
                                                                   (long)cursor_row_arg;
    cursor_col = cursor_col_arg < PSI_VM_TUI_FIRST_TERMINAL_CELL ? PSI_VM_TUI_FIRST_TERMINAL_CELL :
                                                                   (long)cursor_col_arg;
    top = top_arg < PSI_VM_TUI_FIRST_TERMINAL_CELL ? PSI_VM_TUI_FIRST_TERMINAL_CELL : (long)top_arg;
    if (cursor_row > (long)line_count) {
        cursor_row = (long)line_count;
    }
    /* Lua frames are 1-based and local to the viewport; terminals are physical rows. */
    physical_cursor_row = top + cursor_row - PSI_VM_TUI_FIRST_TERMINAL_CELL;

    /* A moved viewport invalidates every cached physical row, even if line text matches. */
    full_redraw = force_full || psi_vm_tui_previous_lines == NULL ||
        psi_vm_tui_previous_line_count != line_count || psi_vm_tui_previous_top != top;
    cursor_changed = psi_vm_tui_previous_cursor_row != cursor_row ||
        psi_vm_tui_previous_cursor_col != cursor_col ||
        psi_vm_tui_previous_cursor_visible != cursor_visible;
    any_output = full_redraw || cursor_changed;

    if (!any_output) {
        for (i = 0u; i < line_count; i++) {
            if (strcmp(psi_vm_tui_previous_lines[i], next_lines[i]) != 0) {
                any_output = 1;
                break;
            }
        }
    }

    if (any_output) {
        psi_vm_tui_write(PSI_VM_TUI_SYNC_BEGIN);
        psi_vm_tui_write(PSI_VM_TUI_CURSOR_HIDE);
        if (full_redraw && psi_vm_tui_previous_lines != NULL &&
            (psi_vm_tui_previous_top != top || psi_vm_tui_previous_line_count != line_count)) {
            /* Clear rows that belonged to the previous viewport before drawing the new one. */
            for (i = 0u; i < psi_vm_tui_previous_line_count; i++) {
                printf("\033[%ld;%dH%s", psi_vm_tui_previous_top + (long)i,
                    PSI_VM_TUI_FIRST_TERMINAL_CELL, PSI_VM_TUI_CLEAR_LINE);
            }
        }
        if (full_redraw) {
            for (i = 0u; i < line_count; i++) {
                psi_vm_tui_draw_frame_line(top + (long)i, next_lines[i]);
            }
        } else {
            for (i = 0u; i < line_count; i++) {
                if (strcmp(psi_vm_tui_previous_lines[i], next_lines[i]) != 0) {
                    psi_vm_tui_draw_frame_line(top + (long)i, next_lines[i]);
                }
            }
        }
        if (cursor_visible) {
            printf("\033[%ld;%ldH%s", physical_cursor_row, cursor_col, PSI_VM_TUI_CURSOR_SHOW);
        } else {
            psi_vm_tui_write(PSI_VM_TUI_CURSOR_HIDE);
        }
        psi_vm_tui_write(PSI_VM_TUI_SYNC_END);
        fflush(stdout);
    }

    psi_vm_tui_reset_render_cache();
    psi_vm_tui_previous_lines = next_lines;
    psi_vm_tui_previous_line_count = line_count;
    psi_vm_tui_previous_top = top;
    psi_vm_tui_previous_cursor_row = cursor_row;
    psi_vm_tui_previous_cursor_col = cursor_col;
    psi_vm_tui_previous_cursor_visible = cursor_visible;
    psi_vm_tui_frame_active = 0;
    return 0;
}

static int lfn_tui_set_cursor(lua_State *L) {
    lua_Integer row = luaL_optinteger(L, 1, PSI_VM_TUI_FIRST_TERMINAL_CELL);
    lua_Integer col = luaL_optinteger(L, 2, PSI_VM_TUI_FIRST_TERMINAL_CELL);
    int visible = lua_toboolean(L, 3);

    psi_vm_require_tui(L);
    if (row < PSI_VM_TUI_FIRST_TERMINAL_CELL) {
        row = PSI_VM_TUI_FIRST_TERMINAL_CELL;
    }
    if (col < PSI_VM_TUI_FIRST_TERMINAL_CELL) {
        col = PSI_VM_TUI_FIRST_TERMINAL_CELL;
    }
    if (!visible && !psi_vm_tui_frame_active) {
        psi_vm_tui_write(PSI_VM_TUI_SYNC_BEGIN);
        psi_vm_tui_frame_active = 1;
    }
    printf("%s\033[%ld;%ldH", visible ? PSI_VM_TUI_CURSOR_SHOW : PSI_VM_TUI_CURSOR_HIDE, (long)row,
        (long)col);
    return 0;
}

static int lfn_tui_refresh(lua_State *L) {
    psi_vm_require_tui(L);
    if (psi_vm_tui_frame_active) {
        psi_vm_tui_write(PSI_VM_TUI_SYNC_END);
        psi_vm_tui_frame_active = 0;
    }
    fflush(stdout);
    return 0;
}

static int lfn_tui_suspend(lua_State *L) {
    psi_vm_require_tui(L);
    psi_vm_tui_suspend();
    return 0;
}

static char *psi_vm_shell_quote_arg(const char *text) {
    size_t extra;
    size_t len;
    size_t i;
    size_t j;
    char *out;

    text = text != NULL ? text : "";
    len = strlen(text);
    extra = 2u;
    for (i = 0u; i < len; i++) {
        if (text[i] == '\'') {
            extra += 3u;
        }
    }
    out = (char *)malloc(len + extra + 1u);
    if (out == NULL) {
        return NULL;
    }
    j = 0u;
    out[j++] = '\'';
    for (i = 0u; i < len; i++) {
        if (text[i] == '\'') {
            out[j++] = '\'';
            out[j++] = '\\';
            out[j++] = '\'';
            out[j++] = '\'';
        } else {
            out[j++] = text[i];
        }
    }
    out[j++] = '\'';
    out[j] = '\0';
    return out;
}

static int lfn_tui_external_editor(lua_State *L) {
    const char *path;
    const char *editor;
    char *quoted_path;
    char *command;
    size_t editor_len;
    size_t path_len;
    int status;

    psi_vm_require_tui(L);
    path = luaL_checkstring(L, 1);
    editor = luaL_checkstring(L, 2);
    if (editor == NULL || editor[0] == '\0') {
        lua_pushnil(L);
        lua_pushstring(L, "No editor configured. Set VISUAL or EDITOR.");
        return 2;
    }
    quoted_path = psi_vm_shell_quote_arg(path);
    if (quoted_path == NULL) {
        lua_pushnil(L);
        lua_pushstring(L, "out of memory");
        return 2;
    }
    editor_len = strlen(editor);
    path_len = strlen(quoted_path);
    command = (char *)malloc(editor_len + 1u + path_len + 1u);
    if (command == NULL) {
        free(quoted_path);
        lua_pushnil(L);
        lua_pushstring(L, "out of memory");
        return 2;
    }
    memcpy(command, editor, editor_len);
    command[editor_len] = ' ';
    memcpy(command + editor_len + 1u, quoted_path, path_len + 1u);
    free(quoted_path);

    psi_tui_suspend_terminal();
    status = system(command);
    psi_tui_resume_terminal();
    free(command);
    psi_vm_tui_reset_render_cache();

    lua_pushinteger(L, status);
    return 1;
}

/* psi.tui_write(text) -- emit raw bytes to stdout while the TUI is active.
 *
 * Used by chat-mode rendering to append transcript lines to the terminal's
 * native scrollback and to position the sticky input box with relative
 * cursor moves. Frame mode keeps using tui_render_frame for atomic repaints. */
static int lfn_tui_write(lua_State *L) {
    const char *text = lua_type(L, 1) == LUA_TSTRING ? lua_tostring(L, 1) : "";
    psi_vm_require_tui(L);
    psi_vm_tui_write(text);
    fflush(stdout);
    return 0;
}

extern void psi_tui_set_alt_screen_active(int active);

/* psi.tui_set_alt_screen_active(flag) -- tell the C side whether Lua has
 * entered the alt screen. Suspend/resume read this to know if SIGTSTP
 * handling should leave/re-enter alt-screen, since chat mode never enters
 * it and we don't want to corrupt the user's scrollback on Ctrl-Z. */
static int lfn_tui_set_alt_screen_active(lua_State *L) {
    int active = lua_toboolean(L, 1);
    psi_vm_require_tui(L);
    psi_tui_set_alt_screen_active(active);
    return 0;
}

static int lfn_tui_set_tick_handler(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_vm *vm = host != NULL ? host->vm : NULL;
    psi_vm_require_tui(L);
    if (vm == NULL) {
        lua_pushnil(L);
        return 1;
    }
    lua_settop(L, 1);
    psi_vm_set_registry_callback(L, &vm->tui_tick_callback_ref, 1);
    return 0;
}

static int lfn_tui_set_tool_progress_handler(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_vm *vm = host != NULL ? host->vm : NULL;
    psi_vm_require_tui(L);
    if (vm == NULL) {
        lua_pushnil(L);
        return 1;
    }
    lua_settop(L, 1);
    psi_vm_set_registry_callback(L, &vm->tui_tool_progress_callback_ref, 1);
    return 0;
}

#else

static int lfn_tui_unavailable(lua_State *L) {
    return luaL_error(L, "TUI support is not compiled in");
}

#define lfn_tui_size lfn_tui_unavailable
#define lfn_tui_poll_key lfn_tui_unavailable
#define lfn_tui_clear lfn_tui_unavailable
#define lfn_tui_draw_line lfn_tui_unavailable
#define lfn_tui_draw_raw_line lfn_tui_unavailable
#define lfn_tui_render_frame lfn_tui_unavailable
#define lfn_tui_render_lines lfn_tui_unavailable
#define lfn_tui_set_cursor lfn_tui_unavailable
#define lfn_tui_refresh lfn_tui_unavailable
#define lfn_tui_suspend lfn_tui_unavailable
#define lfn_tui_external_editor lfn_tui_unavailable
#define lfn_tui_write lfn_tui_unavailable
#define lfn_tui_set_alt_screen_active lfn_tui_unavailable
#define lfn_tui_set_tick_handler lfn_tui_unavailable
#define lfn_tui_set_tool_progress_handler lfn_tui_unavailable

#endif

/* psi.host_tick() -- run one iteration of the host's event loop.
 *
 * Called by psi.sched between coroutine resumes. Does nothing if no
 * host (e.g. --eval, --print, --agent scripts) has installed a hook.
 * The TUI installs one that pumps terminal input + redraws; this is
 * how the UI stays responsive during a streaming turn. */
static int lfn_host_tick(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    const struct psi_vm *vm = host != NULL ? host->vm : NULL;
    if (host != NULL && host->tick_hook != NULL) {
        host->tick_hook(host->tick_userdata);
    }
    if (vm != NULL) {
        psi_vm_invoke_registry_callback0(L, vm->tui_tick_callback_ref, "psi.tui_set_tick_handler");
    }
    return 0;
}

/* psi.sleep_ms(ms) -- cooperative sleep (no thread involvement).
 * Used by psi.sched to honour sleep requests. Clamped to 1 hour so
 * buggy callers don't peg a UI thread indefinitely. */
static int lfn_sleep_ms(lua_State *L) {
    lua_Integer ms = luaL_optinteger(L, 1, 0);
    struct timespec ts;
    if (ms <= 0)
        return 0;
    if (ms > 3600000l)
        ms = 3600000l;
    ts.tv_sec = (time_t)(ms / 1000l);
    ts.tv_nsec = (long)((ms % 1000l) * 1000000l);
    nanosleep(&ts, NULL);
    return 0;
}

static int lfn_time_ms(lua_State *L) {
    struct timeval tv;
    if (gettimeofday(&tv, NULL) != 0) {
        lua_pushinteger(L, (lua_Integer)time(NULL) * 1000);
        return 1;
    }
    lua_pushinteger(L, ((lua_Integer)tv.tv_sec * 1000) + ((lua_Integer)tv.tv_usec / 1000));
    return 1;
}

/* psi.stdout_write(text) -- raw unbuffered write to stdout. */
static int lfn_stdout_write(lua_State *L) {
    size_t len = 0;
    const char *text = lua_type(L, 1) == LUA_TSTRING ? lua_tolstring(L, 1, &len) : NULL;
    if (text != NULL && len > 0) {
        fwrite(text, 1, len, stdout);
        fflush(stdout);
    }
    return 0;
}

/* psi.tool_call(name, input) -> result alist, via psi.tools.dispatch_alist. */
static int lfn_tool_call(lua_State *L) {
    luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_getglobal(L, "psi");
    lua_getfield(L, -1, "tools");
    lua_getfield(L, -1, "dispatch_alist");
    lua_pushvalue(L, 1);
    lua_pushvalue(L, 2);
    if (lua_pcall(L, 2, 1, 0) != LUA_OK) {
        return lua_error(L);
    }
    /* stack: name, input, psi, tools, result */
    lua_remove(L, -2); /* remove tools */
    lua_remove(L, -2); /* remove psi */
    return 1;
}

/* ------------------------------------------------------------------
 * VM lifecycle
 * ------------------------------------------------------------------ */

/* Install a metatable with a __gc finaliser under `name` in the
 * registry (luaL_newmetatable / luaL_setmetatable convention).
 * Idempotent: re-calling leaves the same metatable in place. */
static void psi_vm_register_gc_mt(lua_State *L, const char *name, lua_CFunction gc_fn) {
    if (luaL_newmetatable(L, name)) {
        lua_pushcfunction(L, gc_fn);
        lua_setfield(L, -2, "__gc");
    }
    lua_pop(L, 1);
}

static void psi_vm_register_psi(lua_State *L) {
    /* Handle metatables. Must be registered BEFORE any begin() can
     * fire so luaL_setmetatable always finds them. */
    psi_vm_register_gc_mt(L, PSI_HTTP_STREAM_MT, lfn_http_stream_gc);
    psi_vm_register_gc_mt(L, PSI_PROCESS_HANDLE_MT, lfn_process_gc);

    lua_newtable(L); /* psi */

    /* Sub-table for host-primitive docstrings: psi.__doc_host[name] = doc.
     * lua/psi/doc.lua harvests these at boot into psi.doc. Kept as a
     * sub-table on the psi global so it survives across reloads without
     * extra plumbing. The "__" prefix is the convention for internal-only
     * surface — `/describe` reads it but extensions shouldn't rely on it. */
    lua_newtable(L);
    lua_setfield(L, -2, "__doc_host");

#define PSI_REG(name, fn)                                                                          \
    do {                                                                                           \
        lua_pushcfunction(L, fn);                                                                  \
        lua_setfield(L, -2, name);                                                                 \
    } while (0)

/* Register a host primitive AND attach a docstring queryable via
 * psi.doc.get("name"). The docstring is one line, present-tense, and
 * describes the contract — not the implementation. Always pass a
 * non-empty string literal; the Lua side has no NULL handling. */
#define PSI_REG_DOC(name, fn, doc)                                                                 \
    do {                                                                                           \
        lua_pushcfunction(L, fn);                                                                  \
        lua_setfield(L, -2, name);                                                                 \
        lua_getfield(L, -1, "__doc_host");                                                         \
        lua_pushstring(L, doc);                                                                    \
        lua_setfield(L, -2, name);                                                                 \
        lua_pop(L, 1);                                                                             \
    } while (0)

    PSI_REG_DOC("version", lfn_version, "Return psi's version string.");
    PSI_REG_DOC(
        "log", lfn_log, "Append one line to the host debug log ($XDG_STATE_HOME/psi/debug.log).");
    PSI_REG("session_message_count", lfn_session_message_count);
    PSI_REG_DOC("read_file", lfn_read_file,
        "Read a file off disk. Returns text on success, nil + error string on failure.");
    PSI_REG_DOC("read_file_prefix", lfn_read_file_prefix,
        "Read at most N bytes from the beginning of a file. Returns a binary string or nil.");
    PSI_REG_DOC("read_file_limited", lfn_read_file_limited,
        "Read a file only if it is at most N bytes. Returns a binary string or nil.");
    PSI_REG_DOC("read_file_bytes", lfn_read_file_bytes,
        "Read a byte range from a file. Returns bytes plus offset/size metadata.");
    PSI_REG_DOC("read_file_slice", lfn_read_file_slice,
        "Read a [offset, offset+limit) line range from a file without slurping the whole "
        "file. Returns text plus line/truncation metadata.");
    PSI_REG_DOC("file_write", lfn_file_write,
        "Write text to a file (truncating). Creates parent directories if needed.");
    PSI_REG("file_write_secure", lfn_file_write_secure);
    PSI_REG("file_write_atomic", lfn_file_write_atomic);
    PSI_REG_DOC("file_append", lfn_file_append,
        "Append text to a file in 'ab' mode. Optional mode sets file permissions.");
    PSI_REG_DOC("tempfile_path", lfn_tempfile_path,
        "Return a temp path under $TMPDIR, $TEMP, $TMP, or /tmp; POSIX creates it 0600.");
    PSI_REG_DOC("random_bytes", lfn_random_bytes,
        "Return N bytes from the host secure random source, or nil plus an error.");
    PSI_REG_DOC("current_date", lfn_current_date,
        "Return the current date as 'YYYY-MM-DD' in the host's local timezone.");
    PSI_REG_DOC("cwd", lfn_cwd, "Return the host process's current working directory.");
    PSI_REG_DOC("parent_directory", lfn_parent_directory, "Return the parent directory of a path.");
    PSI_REG_DOC("path_join", lfn_path_join,
        "Join a base path and a name with the host's separator, normalizing duplicates.");
    PSI_REG_DOC("path_expand", lfn_path_expand,
        "Expand leading '~' and '@' in a path, returning the absolute form.");
    PSI_REG_DOC("path_resolve", lfn_path_resolve,
        "Anchor a relative path at the current working directory; absolute paths pass through.");
    PSI_REG_DOC("path_realpath", lfn_path_realpath,
        "Return the filesystem-canonical path, or nil when it cannot be resolved.");
    PSI_REG_DOC(
        "file_exists", lfn_file_exists, "Return true when a path exists in the filesystem.");
    PSI_REG_DOC("file_type", lfn_file_type,
        "Return 'file', 'directory', 'other', or nil for the path's stat kind.");
    PSI_REG_DOC("list_dir", lfn_list_dir,
        "Return an array of names in a directory, excluding '.' and '..'.");
    PSI_REG_DOC("mkdir_p", lfn_mkdir_p,
        "Create a directory and any missing parents; succeeds if the path already exists.");
    PSI_REG("mkdir_parent", lfn_mkdir_parent);
    PSI_REG_DOC("runtime_info", lfn_runtime_info,
        "Return a table describing compiled-in capabilities (TUI, ANSI, COLOR, REPL_EDITLINE).");
    PSI_REG_DOC("cell_width", lfn_cell_width,
        "Return terminal display cell width for a Unicode codepoint.");
    PSI_REG_DOC("tui_text_strip_ansi", lfn_tui_text_strip_ansi,
        "Strip ANSI CSI/OSC terminal control sequences from text.");
    PSI_REG_DOC("tui_text_visible_width", lfn_tui_text_visible_width,
        "Return terminal display cell width for UTF-8 text, ignoring ANSI control sequences.");
    PSI_REG_DOC("tui_text_byte_index_for_width", lfn_tui_text_byte_index_for_width,
        "Return the byte length that fits within a terminal display cell width.");
    PSI_REG_DOC("tui_text_pad_line", lfn_tui_text_pad_line,
        "Pad text with spaces until it reaches a terminal display cell width.");
    PSI_REG_DOC("tui_text_wrap_ansi", lfn_tui_text_wrap_ansi,
        "Wrap styled terminal text to a display cell width while preserving SGR state.");
    PSI_REG_DOC("time_ms", lfn_time_ms,
        "Return a wall-clock millisecond timestamp (gettimeofday); useful for timings, "
        "but not guaranteed monotonic across system clock adjustments.");
    PSI_REG("session_messages", lfn_session_messages);
    PSI_REG("session_messages_from", lfn_session_messages_from);
    PSI_REG("session_token_estimate_from", lfn_session_token_estimate_from);
    PSI_REG("session_keep_recent_by_tokens", lfn_session_keep_recent_by_tokens);
    PSI_REG("process_run", lfn_process_run);
    PSI_REG("process_run_argv", lfn_process_run_argv);
    PSI_REG("process_begin", lfn_process_begin);
    PSI_REG("process_begin_argv", lfn_process_begin_argv);
#if PSI_ENABLE_MCP
    PSI_REG("process_begin_stdio_argv", lfn_process_begin_stdio_argv);
    PSI_REG("process_write", lfn_process_write);
    PSI_REG("process_try_write", lfn_process_try_write);
    PSI_REG("process_close_stdin", lfn_process_close_stdin);
    PSI_REG("process_terminate", lfn_process_terminate);
#endif
    PSI_REG("process_poll", lfn_process_poll);
    PSI_REG("process_finish", lfn_process_finish);
    PSI_REG("session_append", lfn_session_append);
    PSI_REG("session_clear", lfn_session_clear);
    PSI_REG("session_id", lfn_session_id);
    PSI_REG("session_parent_id", lfn_session_parent_id);
    PSI_REG("session_path", lfn_session_path);
    PSI_REG("session_set_id", lfn_session_set_id);
    PSI_REG("session_set_path", lfn_session_set_path);
    PSI_REG("session_set_parent_id", lfn_session_set_parent_id);
    PSI_REG_DOC("is_aborted", lfn_is_aborted,
        "Return true when Ctrl-C/Ctrl-G has fired; long-running Lua should poll this.");
    PSI_REG("abort_trigger", lfn_abort_trigger);
    PSI_REG("abort_reset", lfn_abort_reset);
    PSI_REG("set_usage", lfn_set_usage);
    PSI_REG_DOC("embedded_doc", lfn_embedded_doc,
        "Return the bytes of a doc embedded into the binary (e.g. 'README.md').");
    PSI_REG_DOC("embedded_doc_names", lfn_embedded_doc_names,
        "Return the array of names available to psi.embedded_doc.");
    PSI_REG_DOC("embedded_source", lfn_embedded_source,
        "Return the raw Lua source of an embedded module (e.g. 'psi.render').");
    PSI_REG("embedded_source_names", lfn_embedded_source_names);
    PSI_REG_DOC("json_encode", lfn_json_encode,
        "Encode a Lua value as JSON. Tables with string keys become objects; numeric become "
        "arrays.");
    PSI_REG_DOC("json_decode", lfn_json_decode,
        "Decode a JSON string into Lua values. Returns nil + error on parse failure.");
    PSI_REG("http_post", lfn_http_post);
    PSI_REG("http_get", lfn_http_get);
    PSI_REG("http_stream_begin", lfn_http_stream_begin);
    PSI_REG("http_stream_poll", lfn_http_stream_poll);
    PSI_REG("http_stream_finish", lfn_http_stream_finish);
    PSI_REG_DOC("tool_call", lfn_tool_call,
        "Dispatch a tool through the full before/after hook chain. Prefer this over calling "
        "tool.impl directly, which skips hook processing.");
    PSI_REG_DOC("readline", lfn_readline,
        "Prompt for one line of input via libedit (when REPL_EDITLINE=1) or fgets fallback. "
        "Returns nil on EOF.");
    PSI_REG("add_history", lfn_add_history);
    PSI_REG("stdout_write", lfn_stdout_write);
    PSI_REG("sleep_ms", lfn_sleep_ms);
    PSI_REG("host_tick", lfn_host_tick);
    PSI_REG("tool_progress", lfn_tool_progress);
    PSI_REG("tui_size", lfn_tui_size);
    PSI_REG("tui_poll_key", lfn_tui_poll_key);
    PSI_REG("tui_clear", lfn_tui_clear);
    PSI_REG("tui_draw_line", lfn_tui_draw_line);
    PSI_REG("tui_draw_raw_line", lfn_tui_draw_raw_line);
    PSI_REG("tui_render_frame", lfn_tui_render_frame);
    PSI_REG("tui_render_lines", lfn_tui_render_lines);
    PSI_REG("tui_set_cursor", lfn_tui_set_cursor);
    PSI_REG("tui_refresh", lfn_tui_refresh);
    PSI_REG("tui_suspend", lfn_tui_suspend);
    PSI_REG("tui_external_editor", lfn_tui_external_editor);
    PSI_REG("tui_write", lfn_tui_write);
    PSI_REG("tui_set_alt_screen_active", lfn_tui_set_alt_screen_active);
    PSI_REG("tui_set_tick_handler", lfn_tui_set_tick_handler);
    PSI_REG("tui_set_tool_progress_handler", lfn_tui_set_tool_progress_handler);

#undef PSI_REG

    lua_setglobal(L, "psi");
}

static int psi_vm_apply_package_path(lua_State *L, const char *boot_file) {
    char *copy;
    char *parent;
    char buffer[4096];

    if (boot_file == NULL || boot_file[0] == '\0')
        return PSI_STATUS_OK;
    copy = psi_strdup(boot_file);
    if (!copy)
        return PSI_STATUS_ERROR;
    parent = psi_vm_parent_directory(copy);
    free(copy);
    if (!parent)
        return PSI_STATUS_ERROR;
    snprintf(buffer, sizeof(buffer), "%s/?.lua;%s/?/init.lua", parent, parent);
    free(parent);

    lua_getglobal(L, "package");
    lua_pushstring(L, buffer);
    lua_setfield(L, -2, "path");
    lua_pop(L, 1);
    return PSI_STATUS_OK;
}

/* Lua-callable searcher: resolves require("psi.X") against the
 * embedded table in psi_embedded_lua_table. Registered as the second
 * entry in package.searchers (after the preload lookup) so user
 * extensions on disk can still shadow the built-ins if the user sets
 * an explicit package.path via --boot. Entries are DEFLATE-compressed;
 * we inflate into a scratch buffer, hand it to luaL_loadbuffer (which
 * copies what it needs), then free. */
static int psi_vm_embedded_searcher(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    const struct psi_embedded_data *e;
    for (e = psi_embedded_lua_table; e->name != NULL; e++) {
        if (strcmp(e->name, name) == 0) {
            unsigned char *buf = (unsigned char *)malloc(e->raw_len);
            int load_rc;
            if (buf == NULL)
                return luaL_error(L, "out of memory");
            if (psi_vm_embedded_inflate(e, buf, e->raw_len) != PSI_STATUS_OK) {
                free(buf);
                return luaL_error(L, "inflate failed for %s", name);
            }
            load_rc = luaL_loadbuffer(L, (const char *)buf, e->raw_len, e->name);
            free(buf);
            if (load_rc != LUA_OK)
                return lua_error(L);
            return 1;
        }
    }
    lua_pushfstring(L, "\n\tno embedded psi module '%s'", name);
    return 1;
}

/* Install the embedded searcher at package.searchers[2] so require()
 * finds psi's modules without any filesystem lookup. Position 1 is
 * Lua's built-in preload search; inserting at 2 lets extensions on
 * disk (PSI_EXTENSIONS_DIR, ./.psi/extensions/) still be loaded via
 * the standard path-based searcher that remains at position 3+. */
static void psi_vm_register_embedded(lua_State *L) {
    int n;
    int i;
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "searchers");
    /* Shift existing searchers down by one so we can slot ours into 2. */
    n = (int)lua_rawlen(L, -1);
    for (i = n; i >= 2; i--) {
        lua_rawgeti(L, -1, i);
        lua_rawseti(L, -2, i + 1);
    }
    lua_pushcfunction(L, psi_vm_embedded_searcher);
    lua_rawseti(L, -2, 2);
    lua_pop(L, 2); /* searchers + package */
}

static const struct psi_embedded_data *psi_vm_embedded_find(const char *name) {
    const struct psi_embedded_data *e;
    for (e = psi_embedded_lua_table; e->name != NULL; e++) {
        if (strcmp(e->name, name) == 0)
            return e;
    }
    return NULL;
}

int psi_vm_init(struct psi_vm *vm, const char *boot_file, FILE *input, FILE *output,
    FILE *error_output, int load_extensions) {
    PSI_UNUSED(input);
    PSI_UNUSED(output);
    PSI_UNUSED(error_output);

    if (!vm)
        return PSI_STATUS_ERROR;
    memset(vm, 0, sizeof(*vm));
    vm->boot_file = boot_file;
    vm->host.vm = vm;
    vm->tui_tick_callback_ref = PSI_VM_NOREF;
    vm->tui_tool_progress_callback_ref = PSI_VM_NOREF;

    vm->L = luaL_newstate();
    if (!vm->L)
        return PSI_STATUS_ERROR;
    luaL_openlibs(vm->L);

    PSI_VM_HOST(vm->L) = &vm->host;

    if (psi_vm_apply_package_path(vm->L, boot_file) != PSI_STATUS_OK) {
        lua_close(vm->L);
        vm->L = NULL;
        return PSI_STATUS_ERROR;
    }

    psi_vm_register_embedded(vm->L);

    psi_vm_register_psi(vm->L);
    lua_getglobal(vm->L, "psi");
    lua_pushboolean(vm->L, load_extensions ? 1 : 0);
    lua_setfield(vm->L, -2, "load_user_extensions");
    lua_pop(vm->L, 1);

    /* Bootstrap: use the file at boot_file if it exists (source-tree
     * dev runs, or installs that ship lua/ alongside the binary);
     * otherwise fall back to the embedded boot.lua compiled into the
     * binary. This is what makes static psi binaries self-contained —
     * a stripped-down install or a different host without the Nix
     * store still finds its Lua without touching the filesystem. */
    if (boot_file != NULL && boot_file[0] != '\0' && psi_vm_file_exists(boot_file)) {
        if (luaL_dofile(vm->L, boot_file) != LUA_OK) {
            fprintf(stderr, "failed to load Lua bootstrap: %s\n%s\n", boot_file,
                lua_tostring(vm->L, -1));
            lua_close(vm->L);
            vm->L = NULL;
            return PSI_STATUS_ERROR;
        }
    } else {
        const struct psi_embedded_data *boot = psi_vm_embedded_find("boot");
        unsigned char *buf;
        int load_rc;
        if (boot == NULL) {
            fprintf(stderr, "psi: no embedded boot module compiled in\n");
            lua_close(vm->L);
            vm->L = NULL;
            return PSI_STATUS_ERROR;
        }
        buf = (unsigned char *)malloc(boot->raw_len);
        if (buf == NULL) {
            lua_close(vm->L);
            vm->L = NULL;
            return PSI_STATUS_ERROR;
        }
        if (psi_vm_embedded_inflate(boot, buf, boot->raw_len) != PSI_STATUS_OK) {
            free(buf);
            lua_close(vm->L);
            vm->L = NULL;
            return PSI_STATUS_ERROR;
        }
        load_rc = luaL_loadbuffer(vm->L, (const char *)buf, boot->raw_len, "=boot");
        free(buf);
        if (load_rc != LUA_OK || lua_pcall(vm->L, 0, 0, 0) != LUA_OK) {
            fprintf(stderr, "psi: embedded boot failed: %s\n", lua_tostring(vm->L, -1));
            lua_close(vm->L);
            vm->L = NULL;
            return PSI_STATUS_ERROR;
        }
    }
    return PSI_STATUS_OK;
}

void psi_vm_destroy(struct psi_vm *vm) {
    if (!vm || !vm->L)
        return;
#if PSI_ENABLE_TUI
    psi_vm_tui_reset_render_cache();
#endif
    if (vm->tui_tick_callback_ref != PSI_VM_NOREF) {
        luaL_unref(vm->L, LUA_REGISTRYINDEX, vm->tui_tick_callback_ref);
        vm->tui_tick_callback_ref = PSI_VM_NOREF;
    }
    if (vm->tui_tool_progress_callback_ref != PSI_VM_NOREF) {
        luaL_unref(vm->L, LUA_REGISTRYINDEX, vm->tui_tool_progress_callback_ref);
        vm->tui_tool_progress_callback_ref = PSI_VM_NOREF;
    }
    PSI_VM_HOST(vm->L) = NULL;
    lua_close(vm->L);
    vm->L = NULL;
    vm->host.session = NULL;
    vm->host.vm = NULL;
}

void psi_vm_bind_session(struct psi_vm *vm, struct psi_session *session) {
    if (!vm)
        return;
    vm->host.session = session;
    /* host pointer in extraspace already points at vm->host from init */
}

void psi_vm_set_tui_active(struct psi_vm *vm, int active) {
    if (!vm)
        return;
    vm->tui_active = active ? 1 : 0;
}

/* ------------------------------------------------------------------
 * Helpers: walk dotted procedure names and coerce results.
 * ------------------------------------------------------------------ */

static int psi_vm_push_dotted(lua_State *L, const char *name) {
    size_t len = strlen(name);
    size_t start = 0;
    size_t i;
    int first = 1;

    for (i = 0; i <= len; i++) {
        if (i == len || name[i] == '.') {
            char token[256];
            size_t tok_len = i - start;
            if (tok_len == 0 || tok_len >= sizeof(token)) {
                if (!first)
                    lua_pop(L, 1);
                return -1;
            }
            memcpy(token, name + start, tok_len);
            token[tok_len] = '\0';
            if (first) {
                lua_getglobal(L, token);
                first = 0;
            } else {
                lua_getfield(L, -1, token);
                lua_remove(L, -2);
            }
            if (lua_isnil(L, -1)) {
                lua_pop(L, 1);
                return -1;
            }
            start = i + 1;
        }
    }
    return 0;
}

static void psi_vm_print_error(const char *where, const char *msg) {
    fprintf(stderr, "Lua error in %s: %s\n", where, msg ? msg : "<unknown>");
}

/* Resolve a dotted Lua procedure name and push it on the stack.
 * Returns 0 on success (function left at top), -1 on failure (nothing pushed,
 * error already logged). */
static int psi_vm_begin_call(lua_State *L, const char *dotted) {
    if (psi_vm_push_dotted(L, dotted) != 0) {
        fprintf(stderr, "undefined Lua procedure: %s\n", dotted);
        return -1;
    }
    return 0;
}

/* pcall the function on the stack with `nargs` args (already pushed) expecting
 * `nresults` results. On error, pops the error message and logs it; on success
 * leaves results on the stack. Returns PSI_STATUS_OK / PSI_STATUS_ERROR. */
static int psi_vm_finish_call(lua_State *L, int nargs, int nresults, const char *where) {
    if (lua_pcall(L, nargs, nresults, 0) != LUA_OK) {
        psi_vm_print_error(where, lua_tostring(L, -1));
        lua_pop(L, 1);
        return PSI_STATUS_ERROR;
    }
    return PSI_STATUS_OK;
}

/* ------------------------------------------------------------------
 * Public helpers invoked by runtime modes / anthropic / agent / host_ops.
 * ------------------------------------------------------------------ */

/* ------------------------------------------------------------------
 * Observer / abort trampolines for the Lua agent loop.
 *
 * The TUI and other C callers hand us a struct psi_agent_observer
 * whose fields are plain function pointers. The Lua agent code wants
 * a callbacks table instead. We wrap each pointer as a C closure that
 * unpacks the observer from its upvalue and forwards the call.
 * ------------------------------------------------------------------ */

static struct psi_agent_observer *psi_vm_unpack_observer(lua_State *L) {
    return (struct psi_agent_observer *)lua_touserdata(L, lua_upvalueindex(1));
}

static int psi_vm_ob_text_delta(lua_State *L) {
    struct psi_agent_observer *obs = psi_vm_unpack_observer(L);
    const char *text = luaL_optstring(L, 1, "");
    if (obs != NULL && obs->on_assistant_text_delta != NULL) {
        obs->on_assistant_text_delta(obs->userdata, text);
    }
    return 0;
}

static int psi_vm_ob_tool_call(lua_State *L) {
    struct psi_agent_observer *obs = psi_vm_unpack_observer(L);
    const char *id = luaL_optstring(L, 1, NULL);
    const char *name = luaL_optstring(L, 2, NULL);
    const char *input_json = luaL_optstring(L, 3, "");
    if (obs != NULL && obs->on_tool_call != NULL) {
        obs->on_tool_call(obs->userdata, id, name, input_json);
    }
    return 0;
}

static int psi_vm_ob_tool_result(lua_State *L) {
    struct psi_agent_observer *obs = psi_vm_unpack_observer(L);
    const char *id = luaL_optstring(L, 1, NULL);
    const char *name = luaL_optstring(L, 2, NULL);
    const char *output_json = luaL_optstring(L, 3, "");
    if (obs != NULL && obs->on_tool_result != NULL) {
        obs->on_tool_result(obs->userdata, id, name, output_json);
    }
    return 0;
}

static int psi_vm_ob_thinking_delta(lua_State *L) {
    struct psi_agent_observer *obs = psi_vm_unpack_observer(L);
    const char *text = luaL_optstring(L, 1, "");
    if (obs != NULL && obs->on_thinking_delta != NULL) {
        obs->on_thinking_delta(obs->userdata, text);
    }
    return 0;
}

static int psi_vm_ob_tool_call_delta(lua_State *L) {
    struct psi_agent_observer *obs = psi_vm_unpack_observer(L);
    const char *id = luaL_optstring(L, 1, NULL);
    const char *partial = luaL_optstring(L, 2, "");
    if (obs != NULL && obs->on_tool_call_delta != NULL) {
        obs->on_tool_call_delta(obs->userdata, id, partial);
    }
    return 0;
}

static int psi_vm_abort_check(lua_State *L) {
    struct psi_abort_signal *sig =
        (struct psi_abort_signal *)lua_touserdata(L, lua_upvalueindex(1));
    lua_pushboolean(L, psi_abort_signal_is_triggered(sig) ? 1 : 0);
    return 1;
}

static void psi_vm_push_observer_table(lua_State *L, struct psi_agent_observer *observer) {
    lua_newtable(L);
    if (observer == NULL)
        return;
#define PSI_OB_BIND(key, fn)                                                                       \
    do {                                                                                           \
        lua_pushlightuserdata(L, observer);                                                        \
        lua_pushcclosure(L, fn, 1);                                                                \
        lua_setfield(L, -2, key);                                                                  \
    } while (0)
    PSI_OB_BIND("on_assistant_text_delta", psi_vm_ob_text_delta);
    PSI_OB_BIND("on_tool_call", psi_vm_ob_tool_call);
    PSI_OB_BIND("on_tool_result", psi_vm_ob_tool_result);
    PSI_OB_BIND("on_thinking_delta", psi_vm_ob_thinking_delta);
    PSI_OB_BIND("on_tool_call_delta", psi_vm_ob_tool_call_delta);
#undef PSI_OB_BIND
}

static int psi_vm_call_agent(struct psi_vm *vm, const char *procedure,
    struct psi_agent_observer *observer, struct psi_abort_signal *abort_signal, const char *model,
    long max_tokens, const char *user_text, long keep_recent, char **output_text) {
    int ok;
    const char *text;

    if (vm == NULL || vm->L == NULL)
        return PSI_STATUS_ERROR;
    if (output_text != NULL)
        *output_text = NULL;

    if (psi_vm_begin_call(vm->L, procedure) != 0)
        return PSI_STATUS_ERROR;

    vm->host.abort_signal = abort_signal;
    /* Stamp the observer on the host context so FFI primitives
     * (psi.tool_progress) can forward incremental tool output to
     * the TUI while a turn is running. Cleared on return. */
    vm->host.active_observer = observer;

    lua_newtable(vm->L);
    if (user_text != NULL) {
        lua_pushstring(vm->L, user_text);
        lua_setfield(vm->L, -2, "user_text");
    }
    if (model != NULL) {
        lua_pushstring(vm->L, model);
        lua_setfield(vm->L, -2, "model");
    }
    lua_pushinteger(vm->L, (lua_Integer)max_tokens);
    lua_setfield(vm->L, -2, "max_tokens");
    if (keep_recent >= 0) {
        lua_pushinteger(vm->L, (lua_Integer)keep_recent);
        lua_setfield(vm->L, -2, "keep_recent");
    }

    psi_vm_push_observer_table(vm->L, observer);
    lua_setfield(vm->L, -2, "observer");

    lua_pushlightuserdata(vm->L, abort_signal);
    lua_pushcclosure(vm->L, psi_vm_abort_check, 1);
    lua_setfield(vm->L, -2, "abort_check");

    if (psi_vm_finish_call(vm->L, 1, 2, procedure) != PSI_STATUS_OK) {
        vm->host.abort_signal = NULL;
        vm->host.active_observer = NULL;
        return PSI_STATUS_ERROR;
    }

    ok = lua_toboolean(vm->L, -2);
    text = lua_tostring(vm->L, -1);
    if (output_text != NULL) {
        *output_text = psi_strdup(text != NULL ? text : "");
    }
    lua_pop(vm->L, 2);

    vm->host.abort_signal = NULL;
    vm->host.active_observer = NULL;
    return ok ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

int psi_vm_run_agent_turn(struct psi_vm *vm, const char *user_text,
    struct psi_agent_observer *observer, struct psi_abort_signal *abort_signal, const char *model,
    long max_tokens, char **response_text) {
    return psi_vm_call_agent(vm, "psi.agent.run_turn", observer, abort_signal, model, max_tokens,
        user_text != NULL ? user_text : "", -1, response_text);
}

static int psi_vm_session_call_with_path(
    struct psi_vm *vm, const char *procedure, const char *path) {
    int ok;
    if (vm == NULL || vm->L == NULL)
        return PSI_STATUS_ERROR;
    if (psi_vm_begin_call(vm->L, procedure) != 0)
        return PSI_STATUS_ERROR;
    if (path != NULL)
        lua_pushstring(vm->L, path);
    else
        lua_pushnil(vm->L);
    if (psi_vm_finish_call(vm->L, 1, 1, procedure) != PSI_STATUS_OK)
        return PSI_STATUS_ERROR;
    ok = lua_toboolean(vm->L, -1);
    lua_pop(vm->L, 1);
    return ok ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

int psi_vm_session_save(struct psi_vm *vm, const char *path) {
    return psi_vm_session_call_with_path(vm, "psi.session.save", path);
}

int psi_vm_session_load(struct psi_vm *vm, const char *path) {
    return psi_vm_session_call_with_path(vm, "psi.session.load", path);
}

int psi_vm_run_agent_compact(struct psi_vm *vm, size_t keep_recent,
    struct psi_abort_signal *abort_signal, const char *model, long max_tokens,
    char **summary_text) {
    return psi_vm_call_agent(vm, "psi.agent.run_compact", NULL, abort_signal, model, max_tokens,
        NULL, (long)keep_recent, summary_text);
}

int psi_vm_run_lua_mode(
    struct psi_vm *vm, const char *mode, const struct psi_cli_options *options) {
    int ok;
    if (vm == NULL || vm->L == NULL || mode == NULL || options == NULL)
        return PSI_STATUS_ERROR;
    if (psi_vm_begin_call(vm->L, "psi.modes.run") != 0)
        return PSI_STATUS_ERROR;

    lua_newtable(vm->L);
    lua_pushstring(vm->L, mode);
    lua_setfield(vm->L, -2, "mode");
    if (options->payload != NULL) {
        lua_pushstring(vm->L, options->payload);
        lua_setfield(vm->L, -2, "payload");
    }
    if (options->session_file != NULL) {
        lua_pushstring(vm->L, options->session_file);
        lua_setfield(vm->L, -2, "session_file");
    }
    if (options->resume) {
        lua_pushboolean(vm->L, 1);
        lua_setfield(vm->L, -2, "resume");
    }
    if (options->continue_recent) {
        lua_pushboolean(vm->L, 1);
        lua_setfield(vm->L, -2, "continue_recent");
    }
    lua_pushboolean(vm->L, options->load_extensions ? 1 : 0);
    lua_setfield(vm->L, -2, "load_extensions");
    if (options->model != NULL) {
        lua_pushstring(vm->L, options->model);
        lua_setfield(vm->L, -2, "model");
    }
    if (options->thinking_level != NULL) {
        lua_pushstring(vm->L, options->thinking_level);
        lua_setfield(vm->L, -2, "thinking_level");
    }
    if (options->layout_mode != NULL) {
        lua_pushstring(vm->L, options->layout_mode);
        lua_setfield(vm->L, -2, "layout_mode");
    }
    if (options->prompt_template_file != NULL) {
        lua_pushstring(vm->L, options->prompt_template_file);
        lua_setfield(vm->L, -2, "prompt_template_file");
    }
    if (options->no_context_files) {
        lua_pushboolean(vm->L, 1);
        lua_setfield(vm->L, -2, "no_context_files");
    }
    if (options->no_prompt_templates) {
        lua_pushboolean(vm->L, 1);
        lua_setfield(vm->L, -2, "no_prompt_templates");
    }
    lua_pushinteger(vm->L, (lua_Integer)options->max_tokens);
    lua_setfield(vm->L, -2, "max_tokens");
    lua_pushinteger(vm->L, (lua_Integer)options->keep_recent);
    lua_setfield(vm->L, -2, "keep_recent");

    if (psi_vm_finish_call(vm->L, 1, 1, "psi.modes.run") != PSI_STATUS_OK)
        return PSI_STATUS_ERROR;
    ok = lua_toboolean(vm->L, -1);
    lua_pop(vm->L, 1);
    return ok ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}
