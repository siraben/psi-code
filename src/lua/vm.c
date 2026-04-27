/* psi Lua 5.4 VM and FFI bridge. */

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
#if PSI_ENABLE_TUI
#include <ncurses.h>
#endif

#include <time.h>
#include <errno.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>

#include "psi/abort.h"
#include "psi/agent.h"
#include "psi/anthropic.h"
#include "psi/http_async.h"
#include "psi/common.h"
#include "psi/embedded_lua.h"
#include "psi/host_ops.h"
#include "psi/message.h"
#include "psi/process.h"
#include "psi/session.h"
#include "psi/vm.h"

#ifndef PSI_ENABLE_TUI
#define PSI_ENABLE_TUI 0
#endif
#ifndef PSI_ENABLE_ANSI
#define PSI_ENABLE_ANSI 0
#endif
#ifndef PSI_ENABLE_COLOR
#define PSI_ENABLE_COLOR 0
#endif
#ifndef PSI_ENABLE_REPL_EDITLINE
#define PSI_ENABLE_REPL_EDITLINE 0
#endif

/* ------------------------------------------------------------------
 * Tiny OS-level helpers used by the FFI date/cwd/file_exists primitives
 * and by runtime_info. Returns a fresh heap string the caller must free,
 * or NULL on failure.
 * ------------------------------------------------------------------ */

static char *psi_vm_current_date(void) {
    char buffer[32];
    time_t now = time(NULL);
    const struct tm *lt = localtime(&now);
    if (lt == NULL) return NULL;
    snprintf(buffer, sizeof(buffer), "%04d-%02d-%02d",
             lt->tm_year + 1900, lt->tm_mon + 1, lt->tm_mday);
    return psi_strdup(buffer);
}

static char *psi_vm_current_cwd(void) {
    size_t size = 256u;
    for (;;) {
        char *buf = (char *)malloc(size);
        if (buf == NULL) return NULL;
        if (getcwd(buf, size) != NULL) return buf;
        free(buf);
        if (size >= 8192u) return psi_strdup(".");
        size *= 2u;
    }
}

static int psi_vm_is_abs_path(const char *path) {
    if (path == NULL || path[0] == '\0') return 0;
    if (path[0] == '/') return 1;
    if (isalpha((unsigned char)path[0]) && path[1] == ':' &&
        (path[2] == '/' || path[2] == '\\')) {
        return 1;
    }
    return 0;
}

static char *psi_vm_path_join(const char *base, const char *name) {
    size_t base_len;
    size_t name_len;
    size_t need_sep;
    char *out;

    if (name == NULL) return base != NULL ? psi_strdup(base) : NULL;
    if (base == NULL || base[0] == '\0' || psi_vm_is_abs_path(name) ||
        strcmp(base, ".") == 0) {
        return psi_strdup(name);
    }
    if (name[0] == '\0') return psi_strdup(base);

    base_len = strlen(base);
    name_len = strlen(name);
    need_sep = (base[base_len - 1u] == '/' || base[base_len - 1u] == '\\') ? 0u : 1u;
    out = (char *)malloc(base_len + need_sep + name_len + 1u);
    if (out == NULL) return NULL;
    memcpy(out, base, base_len);
    if (need_sep) out[base_len] = '/';
    memcpy(out + base_len + need_sep, name, name_len + 1u);
    return out;
}

static char *psi_vm_expand_path(const char *path) {
    const char *home;
    const char *p;
    char *out;

    if (path == NULL) return NULL;
    p = path;
    if (p[0] == '@') p++;
    if (p[0] != '~' || (p[1] != '\0' && p[1] != '/')) return psi_strdup(p);
    home = getenv("HOME");
    if (home == NULL || home[0] == '\0') return psi_strdup(p);
    if (p[1] == '\0') return psi_strdup(home);
    out = psi_vm_path_join(home, p + 2);
    return out;
}

static char *psi_vm_resolve_path(const char *path) {
    char *expanded;
    char *cwd;
    char *out;

    expanded = psi_vm_expand_path(path);
    if (expanded == NULL) return NULL;
    if (psi_vm_is_abs_path(expanded)) return expanded;
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

static char *psi_vm_parent_directory(const char *path) {
    size_t end;
    size_t i;
    size_t len;
    char *out;

    if (path == NULL || path[0] == '\0') return psi_strdup(".");
    end = strlen(path);
    while (end > 1u && (path[end - 1u] == '/' || path[end - 1u] == '\\')) end--;
    i = end;
    while (i > 0u && path[i - 1u] != '/' && path[i - 1u] != '\\') i--;
    if (i == 0u) return psi_strdup(".");
    while (i > 1u && (path[i - 1u] == '/' || path[i - 1u] == '\\')) i--;
    if (i == 1u && (path[0] == '/' || path[0] == '\\')) return psi_strdup("/");
    len = i;
    out = (char *)malloc(len + 1u);
    if (out == NULL) return NULL;
    memcpy(out, path, len);
    out[len] = '\0';
    return out;
}

static int psi_vm_file_exists(const char *path) {
    struct stat st;
    if (path == NULL || path[0] == '\0') return 0;
    return stat(path, &st) == 0 ? 1 : 0;
}

static const char *psi_vm_file_type_name(const char *path) {
    struct stat st;
    if (path == NULL || path[0] == '\0') return NULL;
    if (stat(path, &st) != 0) return NULL;
    if (S_ISDIR(st.st_mode)) return "directory";
    if (S_ISREG(st.st_mode)) return "file";
    return "other";
}

static int psi_vm_mkdir_one(const char *path) {
    struct stat st;
    if (path == NULL || path[0] == '\0') return PSI_STATUS_ERROR;
    if (stat(path, &st) == 0) {
        return S_ISDIR(st.st_mode) ? PSI_STATUS_OK : PSI_STATUS_ERROR;
    }
    if (mkdir(path, 0777) == 0) return PSI_STATUS_OK;
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

    if (path == NULL || path[0] == '\0') return PSI_STATUS_ERROR;
    buf = psi_strdup(path);
    if (buf == NULL) return PSI_STATUS_ERROR;

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
            while (i + 1u < n && (buf[i + 1u] == '/' || buf[i + 1u] == '\\')) i++;
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
    if (parent == NULL) return PSI_STATUS_ERROR;
    if (strcmp(parent, ".") == 0 || strcmp(parent, "/") == 0) {
        free(parent);
        return PSI_STATUS_OK;
    }
    status = psi_vm_mkdir_p(parent);
    free(parent);
    return status;
}

static const long PSI_VM_FILE_WRITE_MAX_BYTES = 16777216l;
static const long PSI_VM_READ_FILE_MAX_BYTES  = 262144l;

/* Host context is stored in the Lua state's extraspace so FFI primitives
 * can recover it from their lua_State* rather than a file-static. Keeps
 * the door open for multiple VMs and makes cross-thread reasoning easier:
 * each Lua state owns exactly one host, and the worker thread is the
 * only one calling Lua while that host is active. */
#define PSI_VM_HOST(L) (*(struct psi_host_context **)lua_getextraspace(L))

#define PSI_VM_NOREF (-2)

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
        if (d == (double)(lua_Integer)d) {
            lua_pushinteger(L, (lua_Integer)d);
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
            int tag_array  = tag && strcmp(tag, "array")  == 0;
            int tag_object = tag && strcmp(tag, "object") == 0;
            lua_pop(L, 2);
            if (tag_array)  return 1;
            if (tag_object) return 0;
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
    if (count == 0) return 0;
    for (i = 1; i <= count; i++) {
        int is_nil;
        lua_rawgeti(L, idx, i);
        is_nil = lua_isnil(L, -1);
        lua_pop(L, 1);
        if (is_nil) return 0;
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
            if (arr == NULL) return NULL;
            n = (lua_Integer)lua_rawlen(L, idx);
            for (i = 1; i <= n; i++) {
                cJSON *item;
                lua_rawgeti(L, idx, i);
                item = psi_vm_lua_value_to_json(L, -1);
                lua_pop(L, 1);
                if (item == NULL) { cJSON_Delete(arr); return NULL; }
                cJSON_AddItemToArray(arr, item);
            }
            return arr;
        }
        {
            cJSON *obj;
            obj = cJSON_CreateObject();
            if (obj == NULL) return NULL;
            lua_pushnil(L);
            while (lua_next(L, idx) != 0) {
                /* skip metadata-ish keys, and non-string keys */
                if (lua_type(L, -2) == LUA_TSTRING) {
                    const char *key = lua_tostring(L, -2);
                    if (key && strcmp(key, "__kind") != 0 && strcmp(key, "__jsontype") != 0) {
                        cJSON *item = psi_vm_lua_value_to_json(L, -1);
                        if (item != NULL) cJSON_AddItemToObject(obj, key, item);
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

static void psi_vm_invoke_registry_callback2(
    lua_State *L,
    int ref,
    const char *label,
    const char *a,
    size_t a_len,
    const char *b,
    size_t b_len
) {
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

static void psi_vm_tui_draw_plain_line(int row, const char *text) {
    int max_width;

    move(row, 0);
    clrtoeol();
    if (text == NULL) {
        return;
    }
    max_width = COLS > 1 ? COLS - 1 : 0;
    if (max_width > 0) {
        mvaddnstr(row, 0, text, max_width);
    }
}

#if PSI_ENABLE_ANSI

struct psi_vm_tui_ansi_state {
    attr_t attrs;
#if PSI_ENABLE_COLOR
    int fg;
    int bg;
#endif
};

#if PSI_ENABLE_COLOR
#define PSI_VM_TUI_DYNAMIC_PAIR_START 9
#define PSI_VM_TUI_DYNAMIC_PAIR_MAX 64

static int psi_vm_tui_dynamic_fg[PSI_VM_TUI_DYNAMIC_PAIR_MAX];
static int psi_vm_tui_dynamic_bg[PSI_VM_TUI_DYNAMIC_PAIR_MAX];
static int psi_vm_tui_dynamic_pairs = 0;

static int psi_vm_tui_pair_for_colors(int fg, int bg) {
    int i;
    int pair;

    if (COLOR_PAIRS <= PSI_VM_TUI_DYNAMIC_PAIR_START) {
        return 0;
    }
    if ((fg < -1 || fg >= COLORS) || (bg < -1 || bg >= COLORS)) {
        return 0;
    }
    if (fg < 0 && bg < 0) {
        return 0;
    }
    for (i = 0; i < psi_vm_tui_dynamic_pairs; i++) {
        if (psi_vm_tui_dynamic_fg[i] == fg && psi_vm_tui_dynamic_bg[i] == bg) {
            return PSI_VM_TUI_DYNAMIC_PAIR_START + i;
        }
    }
    if (psi_vm_tui_dynamic_pairs >= PSI_VM_TUI_DYNAMIC_PAIR_MAX) {
        return 0;
    }
    pair = PSI_VM_TUI_DYNAMIC_PAIR_START + psi_vm_tui_dynamic_pairs;
    if (pair >= COLOR_PAIRS) {
        return 0;
    }
    init_pair((short)pair, (short)fg, (short)bg);
    psi_vm_tui_dynamic_fg[psi_vm_tui_dynamic_pairs] = fg;
    psi_vm_tui_dynamic_bg[psi_vm_tui_dynamic_pairs] = bg;
    psi_vm_tui_dynamic_pairs++;
    return pair;
}
#endif

static void psi_vm_tui_ansi_apply_code(struct psi_vm_tui_ansi_state *s, int code) {
    switch (code) {
        case 0:
            s->attrs = 0;
#if PSI_ENABLE_COLOR
            s->fg = -1;
            s->bg = -1;
#endif
            break;
        case 1:  s->attrs |= A_BOLD; break;
        case 2:  s->attrs |= A_DIM; break;
        case 3:
#ifdef A_ITALIC
            s->attrs |= A_ITALIC;
#else
            s->attrs |= A_DIM;
#endif
            break;
        case 4:  s->attrs |= A_UNDERLINE; break;
        case 7:  s->attrs |= A_REVERSE; break;
#if PSI_ENABLE_COLOR
        case 30: s->fg = COLOR_BLACK; break;
        case 31: s->fg = COLOR_RED; break;
        case 32: s->fg = COLOR_GREEN; break;
        case 33: s->fg = COLOR_YELLOW; break;
        case 34: s->fg = COLOR_BLUE; break;
        case 35: s->fg = COLOR_MAGENTA; break;
        case 36: s->fg = COLOR_CYAN; break;
        case 37: s->fg = COLOR_WHITE; break;
        case 39: s->fg = -1; break;
        case 40: s->bg = COLOR_BLACK; break;
        case 41: s->bg = COLOR_RED; break;
        case 42: s->bg = COLOR_GREEN; break;
        case 43: s->bg = COLOR_YELLOW; break;
        case 44: s->bg = COLOR_BLUE; break;
        case 45: s->bg = COLOR_MAGENTA; break;
        case 46: s->bg = COLOR_CYAN; break;
        case 47: s->bg = COLOR_WHITE; break;
        case 49: s->bg = -1; break;
        case 242:
            if (COLORS > 242) {
                s->fg = 242;
            } else {
                s->attrs |= A_DIM;
            }
            break;
#endif
        default: break;
    }
}

static void psi_vm_tui_ansi_apply_params(struct psi_vm_tui_ansi_state *s,
                                         const int *params,
                                         int count) {
    int i;

    if (count <= 0) {
        psi_vm_tui_ansi_apply_code(s, 0);
        return;
    }
    for (i = 0; i < count; i++) {
#if PSI_ENABLE_COLOR
        if (params[i] == 38 && i + 2 < count && params[i + 1] == 5) {
            s->fg = params[i + 2];
            i += 2;
            continue;
        }
        if (params[i] == 48 && i + 2 < count && params[i + 1] == 5) {
            s->bg = params[i + 2];
            i += 2;
            continue;
        }
#endif
        psi_vm_tui_ansi_apply_code(s, params[i]);
    }
}

static void psi_vm_tui_draw_ansi_line(int row, const char *text) {
    int max_width;
    int len;
    int col;
    int i;
    struct psi_vm_tui_ansi_state st;

    move(row, 0);
    clrtoeol();
    if (text == NULL) {
        return;
    }

    max_width = COLS > 1 ? COLS - 1 : 0;
    st.attrs = 0;
#if PSI_ENABLE_COLOR
    st.fg = -1;
    st.bg = -1;
#endif
    len = (int)strlen(text);
    col = 0;
    i = 0;
    while (i < len && col < max_width) {
        if (text[i] == 0x1b && i + 1 < len && text[i + 1] == '[') {
            int j = i + 2;
            int params[16];
            int param_count = 0;
            unsigned int code = 0u;
            int has_digit = 0;
            while (j < len && text[j] != 'm') {
                if (text[j] >= '0' && text[j] <= '9') {
                    if (code <= 999u) {
                        code = code * 10u + (unsigned int)(text[j] - '0');
                    }
                    has_digit = 1;
                } else if (text[j] == ';') {
                    if (param_count < (int)(sizeof(params) / sizeof(params[0]))) {
                        params[param_count++] = has_digit ? (int)code : 0;
                    }
                    code = 0u;
                    has_digit = 0;
                } else {
                    break;
                }
                j++;
            }
            if (j < len && text[j] == 'm') {
                if (has_digit || param_count == 0) {
                    if (param_count < (int)(sizeof(params) / sizeof(params[0]))) {
                        params[param_count++] = has_digit ? (int)code : 0;
                    }
                }
                psi_vm_tui_ansi_apply_params(&st, params, param_count);
                i = j + 1;
                continue;
            }
            i = j < len ? j : len;
            continue;
        }

        {
            int span_start = i;
            int take;
            attr_t cur = st.attrs;

            while (i < len && text[i] != 0x1b) {
                i++;
            }
            take = i - span_start;
            if (take > max_width - col) {
                take = max_width - col;
            }
            if (take <= 0) {
                continue;
            }

#if PSI_ENABLE_COLOR
            {
                int pair = psi_vm_tui_pair_for_colors(st.fg, st.bg);
                if (pair > 0) {
                    cur |= COLOR_PAIR(pair);
                }
            }
#endif
            if (cur != 0) {
                attron(cur);
            }
            if (st.bg >= 0) {
                int k;
                for (k = 0; k < take; k++) {
                    addch((chtype)(unsigned char)text[span_start + k]);
                }
            } else {
                addnstr(text + span_start, take);
            }
            if (cur != 0) {
                attroff(cur);
            }
            col += take;
            i = span_start + take;
        }
    }
}

#endif

static void psi_vm_tui_suspend_terminal(void) {
    struct sigaction dfl;
    struct sigaction prev;
    sigset_t mask;
    sigset_t prev_mask;

    endwin();
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
    refresh();
    clearok(stdscr, TRUE);
}

static int psi_vm_tui_collect_escape_sequence(char *buffer, size_t buffer_size, int restore_timeout_ms) {
    size_t length;
    int timeout_ms;

    if (buffer == NULL || buffer_size == 0u) {
        return 0;
    }

    length = 0u;
    buffer[0] = '\0';
    timeout_ms = 25;
    for (;;) {
        int ch;

        wtimeout(stdscr, timeout_ms);
        ch = getch();
        if (ch == ERR) {
            break;
        }
        if (ch < 0 || ch > 255) {
            break;
        }
        if (length + 1u >= buffer_size) {
            break;
        }
        buffer[length++] = (char)ch;
        buffer[length] = '\0';
        if (ch == '\r' || ch == '\n' || ch == '~' ||
            (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')) {
            break;
        }
        timeout_ms = 5;
    }

    wtimeout(stdscr, restore_timeout_ms);
    return (int)length;
}

static const char *psi_vm_tui_escape_sequence_key(const char *sequence) {
    unsigned int first;
    unsigned int second;
    unsigned int third;
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
        return "shift-enter";
    }
    if (sscanf(sequence, "[%u;%u;%u%c", &first, &second, &third, &final) == 4 &&
        final == '~' && first == 27u && third == 13u && second >= 2u) {
        return "shift-enter";
    }
    if (sscanf(sequence, "[%u;%u%c", &first, &second, &final) == 3 &&
        (final == 'u' || final == '~') &&
        (first == 13u || first == 57414u) &&
        second >= 2u) {
        return "shift-enter";
    }
    return NULL;
}

static int psi_vm_tui_normalize_key(
    int ch,
    int restore_timeout_ms,
    struct psi_vm_tui_key_event *event
) {
    char sequence[64];
    const char *key_name;

    if (event == NULL) {
        return 0;
    }
    memset(event, 0, sizeof(*event));

    if (ch == KEY_RESIZE) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "resize");
        return 1;
    }
    if (ch == KEY_PPAGE) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "page-up");
        return 1;
    }
    if (ch == KEY_NPAGE) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "page-down");
        return 1;
    }
    if (ch == KEY_UP) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "up");
        return 1;
    }
    if (ch == KEY_DOWN) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "down");
        return 1;
    }
    if (ch == 27) {
        psi_vm_tui_collect_escape_sequence(sequence, sizeof(sequence), restore_timeout_ms);
        key_name = psi_vm_tui_escape_sequence_key(sequence);
        if (key_name == NULL) {
            return 0;
        }
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), key_name);
        return 1;
    }
    if (ch == 12) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "ctrl-l");
        return 1;
    }
    if (ch == 26) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "ctrl-z");
        return 1;
    }
    if (ch == KEY_BACKSPACE || ch == 127 || ch == 8) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "backspace");
        return 1;
    }
    if (ch == KEY_DC) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "delete");
        return 1;
    }
    if (ch == 4) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "ctrl-d");
        return 1;
    }
    if (ch == 23) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "ctrl-w");
        return 1;
    }
    if (ch == 11) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "ctrl-k");
        return 1;
    }
    if (ch == 21) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "ctrl-u");
        return 1;
    }
    if (ch == KEY_LEFT || ch == 2) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "left");
        return 1;
    }
    if (ch == KEY_RIGHT || ch == 6) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "right");
        return 1;
    }
    if (ch == KEY_HOME || ch == 1) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "home");
        return 1;
    }
    if (ch == KEY_END || ch == 5) {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "end");
        return 1;
    }
    if (ch == KEY_ENTER || ch == '\r' || ch == '\n') {
        psi_vm_copy_truncated(event->key_name, sizeof(event->key_name), "enter");
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
    size_t read_n;
    char *buffer;

    f = fopen(path, "rb");
    if (!f) { lua_pushnil(L); return 1; }
    if (fseek(f, 0l, SEEK_END) != 0) { fclose(f); lua_pushnil(L); return 1; }
    size = ftell(f);
    if (size < 0l || size > PSI_VM_READ_FILE_MAX_BYTES) {
        fclose(f); lua_pushnil(L); return 1;
    }
    if (fseek(f, 0l, SEEK_SET) != 0) { fclose(f); lua_pushnil(L); return 1; }
    buffer = (char *)malloc((size_t)size + 1u);
    if (!buffer) { fclose(f); lua_pushnil(L); return 1; }
    read_n = fread(buffer, 1u, (size_t)size, f);
    fclose(f);
    if ((long)read_n != size) { free(buffer); lua_pushnil(L); return 1; }
    buffer[size] = '\0';
    lua_pushlstring(L, buffer, (size_t)size);
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

    if (offset < 0) offset = 0;
    if (limit <= 0) limit = 1;
    if (max_bytes <= 0 || max_bytes > PSI_VM_FILE_WRITE_MAX_BYTES) {
        max_bytes = PSI_VM_READ_FILE_MAX_BYTES;
    }

    f = fopen(path, "rb");
    if (!f) { lua_pushnil(L); return 1; }
    cap = 4096u;
    buffer = (char *)malloc(cap);
    if (!buffer) { fclose(f); return luaL_error(L, "out of memory"); }

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
                        if ((long)next_cap > max_bytes + 1l) next_cap = (size_t)max_bytes + 1u;
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
    }
    fclose(f);
    if (saw_any && !last_was_nl) total_lines++;
    while (len > 0u && buffer[len - 1u] == '\n') len--;
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

    if ((long)len > PSI_VM_FILE_WRITE_MAX_BYTES) { lua_pushboolean(L, 0); return 1; }
    f = fopen(path, "wb");
    if (!f) { lua_pushboolean(L, 0); return 1; }
    if (len > 0 && fwrite(content, 1u, len, f) != len) {
        fclose(f); lua_pushboolean(L, 0); return 1;
    }
    if (fclose(f) != 0) { lua_pushboolean(L, 0); return 1; }
    lua_pushboolean(L, 1);
    return 1;
}

static int lfn_file_append(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    size_t len;
    const char *content = luaL_checklstring(L, 2, &len);
    FILE *f;

    if ((long)len > PSI_VM_FILE_WRITE_MAX_BYTES) { lua_pushboolean(L, 0); return 1; }
    f = fopen(path, "ab");
    if (!f) { lua_pushboolean(L, 0); return 1; }
    if (len > 0 && fwrite(content, 1u, len, f) != len) {
        fclose(f); lua_pushboolean(L, 0); return 1;
    }
    if (fclose(f) != 0) { lua_pushboolean(L, 0); return 1; }
    lua_pushboolean(L, 1);
    return 1;
}

/* psi.tempfile_path([prefix]) -> string
 *
 * Compute a unique path under the system tempdir. Does NOT create
 * the file; callers (e.g. bash spillover) decide when to materialise
 * it via psi.file_write / psi.file_append. We avoid mkstemp because
 * we want C89 portability and don't need the open-fd guarantee — the
 * filename is randomised with PID + monotonic counter + time.
 */
static int lfn_tempfile_path(lua_State *L) {
    const char *prefix = luaL_optstring(L, 1, "psi-bash-");
    static unsigned long counter = 0u;
    const char *tmpdir;
    char buffer[1024];
    long pid = 0;
    long ts;

    tmpdir = getenv("TMPDIR");
    if (tmpdir == NULL || *tmpdir == '\0') tmpdir = "/tmp";
#ifndef _WIN32
    pid = (long)getpid();
#endif
    ts = (long)time(NULL);
    counter++;
    snprintf(buffer, sizeof(buffer), "%s/%s%ld-%ld-%lu",
             tmpdir, prefix, pid, ts, counter);
    lua_pushstring(L, buffer);
    return 1;
}

static int lfn_current_date(lua_State *L) {
    char *d = psi_vm_current_date();
    if (!d) { lua_pushnil(L); return 1; }
    lua_pushstring(L, d);
    free(d);
    return 1;
}

static int lfn_cwd(lua_State *L) {
    char *p = psi_vm_current_cwd();
    if (!p) { lua_pushnil(L); return 1; }
    lua_pushstring(L, p);
    free(p);
    return 1;
}

static int lfn_parent_directory(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    char *parent = psi_vm_parent_directory(path);
    if (!parent) { lua_pushnil(L); return 1; }
    lua_pushstring(L, parent);
    free(parent);
    return 1;
}

static int lfn_path_join(lua_State *L) {
    const char *base = luaL_checkstring(L, 1);
    const char *name = luaL_checkstring(L, 2);
    char *out = psi_vm_path_join(base, name);
    if (!out) { lua_pushnil(L); return 1; }
    lua_pushstring(L, out);
    free(out);
    return 1;
}

static int lfn_path_expand(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    char *out = psi_vm_expand_path(path);
    if (!out) { lua_pushnil(L); return 1; }
    lua_pushstring(L, out);
    free(out);
    return 1;
}

static int lfn_path_resolve(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    char *out = psi_vm_resolve_path(path);
    if (!out) { lua_pushnil(L); return 1; }
    lua_pushstring(L, out);
    free(out);
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

static const char *psi_vm_dirent_type_name(const struct dirent *entry) {
#ifdef DT_DIR
    if (entry->d_type == DT_DIR) return "directory";
    if (entry->d_type == DT_REG) return "file";
#else
    PSI_UNUSED(entry);
#endif
    return NULL;
}

static int lfn_list_dir_typed(lua_State *L) {
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
        const char *kind;
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
#ifdef DT_DIR
        kind = psi_vm_dirent_type_name(entry);
        if (kind == NULL)
#else
        kind = NULL;
#endif
        {
            char *full = psi_vm_path_join(path, entry->d_name);
            kind = full != NULL ? psi_vm_file_type_name(full) : NULL;
            free(full);
        }

        lua_newtable(L);
        lua_pushstring(L, entry->d_name);
        lua_setfield(L, -2, "name");
        if (kind != NULL) {
            lua_pushstring(L, kind);
            lua_setfield(L, -2, "type");
        }
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
    if (host == NULL || host->active_observer == NULL) return;
    if (host->active_observer->on_tool_progress == NULL) return;
    host->active_observer->on_tool_progress(
        host->active_observer->userdata,
        host->active_tool_id,
        chunk,
        len
    );
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
    if (chunk == NULL || chunk_len == 0u) return 0;

    host = PSI_VM_HOST(L);
    if (host != NULL && host->active_observer != NULL &&
        host->active_observer->on_tool_progress != NULL) {
        host->active_observer->on_tool_progress(
            host->active_observer->userdata,
            tool_id,
            chunk,
            chunk_len
        );
        return 0;
    }

    vm = host != NULL ? host->vm : NULL;
    if (vm != NULL) {
        psi_vm_invoke_registry_callback2(
            L,
            vm->tui_tool_progress_callback_ref,
            "psi.tui_set_tool_progress_handler",
            tool_id != NULL ? tool_id : "",
            tool_id != NULL ? strlen(tool_id) : 0u,
            chunk,
            chunk_len
        );
    }
    return 0;
}

static char **psi_vm_argv_from_table(lua_State *L, int idx, int *argc_out);
static void psi_vm_argv_free(char **argv);

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

    if (psi_process_run_shell(
            command, &output, &status, &truncated,
            on_chunk, on_chunk_userdata,
            host ? host->abort_signal : NULL) != PSI_STATUS_OK) {
        free(output);
        return luaL_error(L, "failed to run shell command");
    }
    lua_newtable(L);
    lua_pushstring(L, output ? output : "");
    lua_setfield(L, -2, "output");
    lua_pushinteger(L, (lua_Integer)status);
    lua_setfield(L, -2, "status");
    lua_pushboolean(L, truncated ? 1 : 0);
    lua_setfield(L, -2, "truncated");
    free(output);
    return 1;
}

static char **psi_vm_argv_from_table(lua_State *L, int idx, int *argc_out);
static void psi_vm_argv_free(char **argv);

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
        lua_newtable(L);
        lua_pushstring(L, "invalid argv");
        lua_setfield(L, -2, "output");
        lua_pushinteger(L, -1);
        lua_setfield(L, -2, "status");
        lua_pushboolean(L, 0);
        lua_setfield(L, -2, "truncated");
        return 1;
    }

    status = psi_process_run_argv(
        argv,
        &output,
        &exit_status,
        &truncated,
        host ? host->abort_signal : NULL);
    psi_vm_argv_free(argv);

    lua_newtable(L);
    if (status == PSI_STATUS_OK && output != NULL) {
        lua_pushstring(L, output);
    } else {
        lua_pushstring(L, "");
    }
    lua_setfield(L, -2, "output");
    lua_pushinteger(L, exit_status);
    lua_setfield(L, -2, "status");
    lua_pushboolean(L, truncated ? 1 : 0);
    lua_setfield(L, -2, "truncated");
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
    status = psi_process_begin(
        command,
        host ? host->abort_signal : NULL,
        &h);
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
    if (n <= 0) return NULL;
    argv = (char **)calloc((size_t)n + 1u, sizeof(char *));
    if (argv == NULL) return NULL;
    for (i = 1; i <= n; i++) {
        const char *value;
        lua_rawgeti(L, idx, i);
        value = luaL_checkstring(L, -1);
        argv[i - 1] = psi_strdup(value);
        lua_pop(L, 1);
        if (argv[i - 1] == NULL) {
            lua_Integer j;
            for (j = 0; j < i - 1; j++) free(argv[j]);
            free(argv);
            return NULL;
        }
    }
    argv[n] = NULL;
    if (argc_out != NULL) *argc_out = (int)n;
    return argv;
}

static void psi_vm_argv_free(char **argv) {
    int i;
    if (argv == NULL) return;
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
    status = psi_process_begin_argv(
        argv,
        host ? host->abort_signal : NULL,
        &h);
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
        lua_newtable(L);
        lua_pushstring(L, "");       lua_setfield(L, -2, "output");
        lua_pushinteger(L, -1);      lua_setfield(L, -2, "status");
        lua_pushboolean(L, 0);       lua_setfield(L, -2, "truncated");
        return 1;
    }
    *ud = NULL;  /* consumed before the C call so __gc skips */
    output = NULL;
    status = -1;
    truncated = 0;

    if (psi_process_finish(h, &output, &status, &truncated) != PSI_STATUS_OK) {
        free(output);
        return luaL_error(L, "process_finish failed");
    }

    lua_newtable(L);
    lua_pushstring(L, output ? output : "");
    lua_setfield(L, -2, "output");
    lua_pushinteger(L, (lua_Integer)status);
    lua_setfield(L, -2, "status");
    lua_pushboolean(L, truncated ? 1 : 0);
    lua_setfield(L, -2, "truncated");
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

    if (lua_type(L, 3) == LUA_TSTRING) data = lua_tostring(L, 3);
    if (lua_type(L, 4) == LUA_TNUMBER) estimate_arg = lua_tointeger(L, 4);

    host = PSI_VM_HOST(L);
    s = host ? host->session : NULL;
    if (!s) { lua_pushboolean(L, 0); return 1; }
    if (estimate_arg >= 0) {
        status = psi_session_append_with_data_and_estimate(
            s, psi_session_role_from_name(role), text, data, (size_t)estimate_arg);
    } else {
        status = psi_session_append_with_data(s, psi_session_role_from_name(role), text, data);
    }
    lua_pushboolean(L, status == PSI_STATUS_OK ? 1 : 0);
    return 1;
}

static void psi_vm_json_copy_field(cJSON *dst, const cJSON *src, const char *name) {
    cJSON *item;
    cJSON *copy;

    item = cJSON_GetObjectItemCaseSensitive((cJSON *)src, name);
    if (item == NULL) return;
    copy = cJSON_Duplicate(item, 1);
    if (copy == NULL) return;
    cJSON_AddItemToObject(dst, name, copy);
}

static cJSON *psi_vm_session_disk_entry(const struct psi_message *message) {
    cJSON *body;
    cJSON *entry;
    cJSON *entry_type;
    const char *type_name;
    int is_compaction;
    static const char *CUSTOM_FIELDS[] = {
        "id", "parentId", "timestamp", "name", "data", NULL
    };
    static const char *CUSTOM_MESSAGE_FIELDS[] = {
        "id", "parentId", "timestamp", "message", NULL
    };
    static const char *MODEL_CHANGE_FIELDS[] = {
        "id", "parentId", "timestamp", "model", NULL
    };
    static const char *THINKING_LEVEL_FIELDS[] = {
        "id", "parentId", "timestamp", "thinkingLevel", NULL
    };
    static const char *COMPACTION_FIELDS[] = {
        "id", "parentId", "timestamp", "summary", "firstKeptEntryId",
        "tokensBefore", "readFiles", "modifiedFiles", "compactedCount", NULL
    };
    static const char *MESSAGE_FIELDS[] = {
        "id", "parentId", "timestamp", "message", NULL
    };
    const char **fields;
    size_t i;

    if (message == NULL || message->data_json == NULL) return NULL;
    body = cJSON_Parse(message->data_json);
    if (body == NULL || !cJSON_IsObject(body)) {
        cJSON_Delete(body);
        return NULL;
    }

    entry = cJSON_CreateObject();
    if (entry == NULL) {
        cJSON_Delete(body);
        return NULL;
    }

    entry_type = cJSON_GetObjectItemCaseSensitive(body, "__entry_type");
    type_name = cJSON_IsString(entry_type) ? entry_type->valuestring : NULL;
    is_compaction = (message->role == PSI_MESSAGE_COMPACTION_SUMMARY);

    if (type_name != NULL && strcmp(type_name, "custom") == 0) {
        cJSON_AddStringToObject(entry, "type", "custom");
        fields = CUSTOM_FIELDS;
    } else if (type_name != NULL && strcmp(type_name, "custom_message") == 0) {
        cJSON_AddStringToObject(entry, "type", "custom_message");
        fields = CUSTOM_MESSAGE_FIELDS;
    } else if (type_name != NULL && strcmp(type_name, "model_change") == 0) {
        cJSON_AddStringToObject(entry, "type", "model_change");
        fields = MODEL_CHANGE_FIELDS;
    } else if (type_name != NULL && strcmp(type_name, "thinking_level_change") == 0) {
        cJSON_AddStringToObject(entry, "type", "thinking_level_change");
        fields = THINKING_LEVEL_FIELDS;
    } else if (is_compaction) {
        cJSON_AddStringToObject(entry, "type", "compaction");
        fields = COMPACTION_FIELDS;
    } else {
        cJSON_AddStringToObject(entry, "type", "message");
        fields = MESSAGE_FIELDS;
    }

    for (i = 0u; fields[i] != NULL; i++) {
        psi_vm_json_copy_field(entry, body, fields[i]);
    }
    if (is_compaction && cJSON_GetObjectItemCaseSensitive(entry, "summary") == NULL) {
        cJSON_AddStringToObject(entry, "summary", message->text ? message->text : "");
    }
    cJSON_Delete(body);
    return entry;
}

static int lfn_session_append_jsonl(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_Integer start_arg = luaL_optinteger(L, 2, 1);
    struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_session *s = host ? host->session : NULL;
    FILE *file;
    size_t start;
    size_t i;

    if (!s) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "no session");
        return 2;
    }
    if (start_arg < 1) start_arg = 1;
    start = (size_t)(start_arg - 1);
    if (start >= s->count) {
        lua_pushboolean(L, 1);
        return 1;
    }

    file = fopen(path, "a");
    if (file == NULL) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, strerror(errno));
        return 2;
    }

    for (i = start; i < s->count; i++) {
        cJSON *entry;
        char *json;
        size_t len;
        entry = psi_vm_session_disk_entry(&s->messages[i]);
        if (entry == NULL) {
            fclose(file);
            lua_pushboolean(L, 0);
            lua_pushstring(L, "message has no structured data");
            return 2;
        }
        json = cJSON_PrintUnformatted(entry);
        cJSON_Delete(entry);
        if (json == NULL) {
            fclose(file);
            lua_pushboolean(L, 0);
            lua_pushstring(L, "failed to encode session entry");
            return 2;
        }
        len = strlen(json);
        if ((len > 0u && fwrite(json, 1u, len, file) != len) || fputc('\n', file) == EOF) {
            free(json);
            fclose(file);
            lua_pushboolean(L, 0);
            lua_pushstring(L, "write failed");
            return 2;
        }
        free(json);
    }
    if (fclose(file) != 0) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "close failed");
        return 2;
    }
    lua_pushboolean(L, 1);
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

static int lfn_session_set_id(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_session *s = host ? host->session : NULL;
    const char *id = lua_type(L, 1) == LUA_TSTRING ? lua_tostring(L, 1) : NULL;
    if (!s) { lua_pushboolean(L, 0); return 1; }
    lua_pushboolean(L, psi_session_set_id(s, id) == PSI_STATUS_OK ? 1 : 0);
    return 1;
}

static int lfn_session_set_path(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_session *s = host ? host->session : NULL;
    const char *path = lua_type(L, 1) == LUA_TSTRING ? lua_tostring(L, 1) : NULL;
    if (!s) { lua_pushboolean(L, 0); return 1; }
    lua_pushboolean(L, psi_session_set_path(s, path) == PSI_STATUS_OK ? 1 : 0);
    return 1;
}

static int lfn_session_set_parent_id(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_session *s = host ? host->session : NULL;
    const char *pid = lua_type(L, 1) == LUA_TSTRING ? lua_tostring(L, 1) : NULL;
    if (!s) { lua_pushboolean(L, 0); return 1; }
    lua_pushboolean(L, psi_session_set_parent_id(s, pid) == PSI_STATUS_OK ? 1 : 0);
    return 1;
}

static int lfn_session_path(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_session *s = host ? host->session : NULL;
    if (!s || !s->path) { lua_pushnil(L); return 1; }
    lua_pushstring(L, s->path);
    return 1;
}

static int lfn_session_parent_id(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_session *s = host ? host->session : NULL;
    if (!s || !s->parent_id) { lua_pushnil(L); return 1; }
    lua_pushstring(L, s->parent_id);
    return 1;
}

static int lfn_session_id(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_session *s = host ? host->session : NULL;
    if (!s || !s->id) { lua_pushnil(L); return 1; }
    lua_pushstring(L, s->id);
    return 1;
}

struct psi_lua_http_stream_ctx {
    lua_State *L;
    int cb_ref;
};

static void psi_lua_http_stream_cb(void *userdata, const char *chunk, size_t len) {
    struct psi_lua_http_stream_ctx *ctx = (struct psi_lua_http_stream_ctx *)userdata;
    lua_State *L = ctx->L;
    lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->cb_ref);
    lua_pushlstring(L, chunk, len);
    if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
        /* Swallow the error into stderr; we can't usefully propagate it
         * out of libcurl's write callback without leaking resources. */
        fprintf(stderr, "http_post_stream callback error: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
    }
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
    if (headers == NULL) return -1;
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
    if (headers == NULL) return;
    for (i = 0; i < count; i++) free(headers[i]);
    free((void *)headers);
}

static int lfn_http_post_stream(lua_State *L) {
    const char *url = luaL_checkstring(L, 1);
    size_t body_len;
    const char *body;
    char **headers;
    size_t header_count;
    const struct psi_host_context *host;
    struct psi_lua_http_stream_ctx ctx;
    long status_code;
    int status;

    luaL_checktype(L, 2, LUA_TTABLE);
    body = luaL_checklstring(L, 3, &body_len);
    luaL_checktype(L, 4, LUA_TFUNCTION);

    if (psi_lua_collect_headers(L, 2, &headers, &header_count) != 0) {
        return luaL_error(L, "failed to collect headers");
    }

    lua_pushvalue(L, 4);
    ctx.L = L;
    ctx.cb_ref = luaL_ref(L, LUA_REGISTRYINDEX);

    host = PSI_VM_HOST(L);
    status_code = 0l;
    status = psi_http_post_stream(
        url,
        (const char *const *)headers, header_count,
        body, body_len,
        psi_lua_http_stream_cb, &ctx,
        host ? host->abort_signal : NULL,
        &status_code);

    luaL_unref(L, LUA_REGISTRYINDEX, ctx.cb_ref);
    psi_lua_free_headers(headers, header_count);

    if (status != PSI_STATUS_OK) {
        lua_pushnil(L);
        lua_pushstring(L, "http request failed");
        return 2;
    }
    lua_pushinteger(L, status_code);
    return 1;
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
 * finish (OOM mid-sse_feed, bug in anthropic.lua), the userdata
 * becomes unreachable and __gc reaps the pthread + curl handle +
 * queued chunks. Before this change the handle was light userdata
 * with no GC — errors leaked everything.
 * ------------------------------------------------------------------ */

#define PSI_HTTP_STREAM_MT "psi.http_stream"

static struct psi_http_stream **psi_vm_http_stream_ud_check(lua_State *L, int idx) {
    return (struct psi_http_stream **)luaL_checkudata(L, idx, PSI_HTTP_STREAM_MT);
}

static int lfn_http_stream_gc(lua_State *L) {
    struct psi_http_stream **ud = psi_vm_http_stream_ud_check(L, 1);
    if (*ud != NULL) {
        psi_http_stream_finish(*ud);
        *ud = NULL;
    }
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
    struct psi_http_stream **ud;
    int status;

    luaL_checktype(L, 2, LUA_TTABLE);
    body = luaL_checklstring(L, 3, &body_len);

    if (psi_lua_collect_headers(L, 2, &headers, &header_count) != 0) {
        return luaL_error(L, "failed to collect headers");
    }

    host = PSI_VM_HOST(L);
    h = NULL;
    status = psi_http_stream_begin(
        url,
        (const char *const *)headers, header_count,
        body, body_len,
        host ? host->abort_signal : NULL,
        &h);
    psi_lua_free_headers(headers, header_count);

    if (status != PSI_STATUS_OK || h == NULL) {
        lua_pushnil(L);
        lua_pushstring(L, "failed to start http stream");
        return 2;
    }

    ud = (struct psi_http_stream **)lua_newuserdata(L, sizeof(*ud));
    *ud = h;
    luaL_setmetatable(L, PSI_HTTP_STREAM_MT);
    return 1;
}

static int lfn_http_stream_poll(lua_State *L) {
    struct psi_http_stream **ud;
    struct psi_http_stream *h;
    int timeout_ms;
    char *chunk;
    size_t chunk_len;
    int result;

    ud = psi_vm_http_stream_ud_check(L, 1);
    h = *ud;
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
    struct psi_http_stream **ud;
    struct psi_http_stream *h;
    long status;

    ud = psi_vm_http_stream_ud_check(L, 1);
    h = *ud;
    if (h == NULL) {
        /* Idempotent: explicit finish after GC, or double-finish. */
        lua_pushinteger(L, 0);
        return 1;
    }
    *ud = NULL;  /* flag consumed before the C call so __gc is a no-op */
    status = psi_http_stream_finish(h);
    lua_pushinteger(L, (lua_Integer)status);
    return 1;
}

static int lfn_http_post(lua_State *L) {
    const char *url = luaL_checkstring(L, 1);
    size_t body_len;
    const char *body;
    char **headers;
    size_t header_count;
    struct psi_host_context *host;
    long status_code;
    char *response;
    int status;

    luaL_checktype(L, 2, LUA_TTABLE);
    body = luaL_checklstring(L, 3, &body_len);

    if (psi_lua_collect_headers(L, 2, &headers, &header_count) != 0) {
        return luaL_error(L, "failed to collect headers");
    }

    host = PSI_VM_HOST(L);
    status_code = 0l;
    response = NULL;
    status = psi_http_post(
        url,
        (const char *const *)headers, header_count,
        body, body_len,
        host ? host->abort_signal : NULL,
        &status_code, &response);

    psi_lua_free_headers(headers, header_count);

    if (status != PSI_STATUS_OK) {
        free(response);
        lua_pushnil(L);
        lua_pushstring(L, "http request failed");
        return 2;
    }
    lua_pushinteger(L, status_code);
    lua_pushstring(L, response != NULL ? response : "");
    free(response);
    return 2;
}

static int lfn_http_get(lua_State *L) {
    const char *url = luaL_checkstring(L, 1);
    char **headers;
    size_t header_count;
    struct psi_host_context *host;
    long status_code;
    char *response;
    int status;

    luaL_checktype(L, 2, LUA_TTABLE);

    if (psi_lua_collect_headers(L, 2, &headers, &header_count) != 0) {
        return luaL_error(L, "failed to collect headers");
    }

    host = PSI_VM_HOST(L);
    status_code = 0l;
    response = NULL;
    status = psi_http_get(
        url,
        (const char *const *)headers, header_count,
        host ? host->abort_signal : NULL,
        &status_code, &response);

    psi_lua_free_headers(headers, header_count);

    if (status != PSI_STATUS_OK) {
        free(response);
        lua_pushnil(L);
        lua_pushstring(L, "http request failed");
        return 2;
    }
    lua_pushinteger(L, status_code);
    lua_pushstring(L, response != NULL ? response : "");
    free(response);
    return 2;
}

static int lfn_is_aborted(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    lua_pushboolean(L,
        host != NULL && psi_abort_signal_is_triggered(host->abort_signal) ? 1 : 0);
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
    if (host == NULL) return 0;
    host->usage.input          = (long)luaL_optinteger(L, 1, 0);
    host->usage.output         = (long)luaL_optinteger(L, 2, 0);
    host->usage.cache_read     = (long)luaL_optinteger(L, 3, 0);
    host->usage.cache_write    = (long)luaL_optinteger(L, 4, 0);
    host->usage.total          = (long)luaL_optinteger(L, 5, 0);
    host->usage.context_window = (long)luaL_optinteger(L, 6, 0);
    return 0;
}

/* Inflate an embedded entry into a caller-provided buffer. Returns
 * PSI_STATUS_OK on success (buffer filled with entry->raw_len bytes).
 * The caller owns the buffer; on error the buffer contents are
 * undefined but no allocation is retained. */
static int psi_vm_embedded_inflate(const struct psi_embedded_lua *e,
                                   unsigned char *out, size_t out_len) {
    uLongf dst_len = (uLongf)out_len;
    int rc;
    if (e == NULL || e->src == NULL || out == NULL) return PSI_STATUS_ERROR;
    rc = uncompress(out, &dst_len, e->src, (uLong)e->len);
    if (rc != Z_OK || dst_len != (uLongf)e->raw_len) {
        fprintf(stderr, "psi: inflate failed for %s (zlib %d, %lu/%lu)\n",
                e->name, rc, (unsigned long)dst_len, (unsigned long)e->raw_len);
        return PSI_STATUS_ERROR;
    }
    return PSI_STATUS_OK;
}

/* psi.embedded_doc(name) -> string | nil
 * Look up a file name in the embedded docs table. Returns the file
 * contents as a Lua string, or nil if the name isn't embedded.
 * Entries are DEFLATE-compressed; we inflate on demand. */
static int lfn_embedded_doc(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    const struct psi_embedded_lua *e;
    for (e = psi_embedded_docs_table; e->name != NULL; e++) {
        if (strcmp(e->name, name) == 0) {
            unsigned char *buf = (unsigned char *)malloc(e->raw_len + 1u);
            if (buf == NULL) return luaL_error(L, "out of memory");
            if (psi_vm_embedded_inflate(e, buf, e->raw_len) != PSI_STATUS_OK) {
                free(buf);
                lua_pushnil(L);
                return 1;
            }
            buf[e->raw_len] = 0; /* keep as NUL-terminated for safety */
            lua_pushlstring(L, (const char *)buf, e->raw_len);
            free(buf);
            return 1;
        }
    }
    lua_pushnil(L);
    return 1;
}

/* psi.embedded_doc_names() -> array-of-strings
 * List every doc embedded in the binary. Handy for a `/docs` command
 * or an agent discovering what docs are available. */
static int lfn_embedded_doc_names(lua_State *L) {
    const struct psi_embedded_lua *e;
    int i = 1;
    lua_newtable(L);
    for (e = psi_embedded_docs_table; e->name != NULL; e++, i++) {
        lua_pushstring(L, e->name);
        lua_rawseti(L, -2, i);
    }
    return 1;
}

/* psi.embedded_source(name) -> string | nil
 * Return the raw Lua source for an embedded module (same name as
 * `require(...)`, e.g. "psi.render"). Lets extensions and live-runtime
 * introspection inspect built-in modules without a real filesystem
 * path. Parallel to embedded_doc but over psi_embedded_lua_table. */
static int lfn_embedded_source(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    const struct psi_embedded_lua *e;
    for (e = psi_embedded_lua_table; e->name != NULL; e++) {
        if (strcmp(e->name, name) == 0) {
            unsigned char *buf = (unsigned char *)malloc(e->raw_len + 1u);
            if (buf == NULL) return luaL_error(L, "out of memory");
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

/* psi.embedded_source_names() -> array-of-strings
 * List every Lua module embedded in the binary. Complement of
 * embedded_doc_names; useful for extension authors wanting to know
 * what they can introspect. */
static int lfn_embedded_source_names(lua_State *L) {
    const struct psi_embedded_lua *e;
    int i = 1;
    lua_newtable(L);
    for (e = psi_embedded_lua_table; e->name != NULL; e++, i++) {
        lua_pushstring(L, e->name);
        lua_rawseti(L, -2, i);
    }
    return 1;
}

static int lfn_session_clear(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_session *s = host ? host->session : NULL;
    if (!s) { lua_pushboolean(L, 0); return 1; }
    lua_pushboolean(L, psi_session_clear(s) == PSI_STATUS_OK ? 1 : 0);
    return 1;
}

static int lfn_session_messages(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    struct psi_session *s = host ? host->session : NULL;
    size_t i;

    lua_newtable(L);
    psi_vm_mark_array(L);
    if (!s) return 1;
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
    if (!s) return 1;
    if (start_arg < 1) start_arg = 1;
    start = (size_t)(start_arg - 1);
    if (start >= s->count) return 1;

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
    if (start_arg < 1) start_arg = 1;
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
    static const char *PRIMITIVES[] = {
        "version", "log", "session_message_count", "read_file", "read_file_slice",
        "file_write", "file_append", "tempfile_path", "current_date", "cwd", "parent_directory", "path_join",
        "path_expand", "path_resolve", "file_exists", "file_type", "list_dir",
        "list_dir_typed",
        "mkdir_p", "mkdir_parent", "runtime_info", "session_messages",
        "session_messages_from", "session_token_estimate_from",
        "session_keep_recent_by_tokens", "process_run", "process_run_argv", "process_begin_argv",
        "session_append", "session_append_jsonl", "session_clear",
        "http_get", "http_post",
        "tool_call",
        NULL
    };
    struct psi_host_context *host;
    char *date;
    char *cwd;
    int i;

    host = PSI_VM_HOST(L);
    date = psi_vm_current_date();
    cwd  = psi_vm_current_cwd();
    if (!date || !cwd) {
        free(date); free(cwd);
        return luaL_error(L, "failed to collect runtime info");
    }

    lua_newtable(L);

    lua_pushstring(L, PSI_VERSION);
    lua_setfield(L, -2, "version");

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
    lua_pushboolean(L, PSI_ENABLE_REPL_EDITLINE ? 1 : 0);
    lua_setfield(L, -2, "repl-editline");
    lua_pushboolean(L, PSI_ENABLE_TUI ? 1 : 0);
    lua_setfield(L, -2, "tui");

    {
        struct psi_session *s = host ? host->session : NULL;
        lua_pushinteger(L, s ? (lua_Integer)s->count : 0);
        lua_setfield(L, -2, "session-message-count");
    }

    lua_newtable(L);
    psi_vm_mark_array(L);
    for (i = 0; PRIMITIVES[i] != NULL; i++) {
        lua_pushstring(L, PRIMITIVES[i]);
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
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
    if (line != NULL && line[0] != '\0') add_history(line);
#else
    PSI_UNUSED(L);
#endif
    return 0;
}

#if PSI_ENABLE_TUI

static int lfn_tui_size(lua_State *L) {
    int height;
    int width;
    psi_vm_require_tui(L);
    getmaxyx(stdscr, height, width);
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
    timeout_ms = luaL_optinteger(L, 1, -1);
    if (timeout_ms < -1) {
        timeout_ms = -1;
    }
    if (timeout_ms > 3600000) {
        timeout_ms = 3600000;
    }
    wtimeout(stdscr, (int)timeout_ms);
    ch = getch();
    if (ch == ERR) {
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
    psi_vm_require_tui(L);
    erase();
    return 0;
}

static int lfn_tui_draw_line(lua_State *L) {
    lua_Integer row = luaL_checkinteger(L, 1);
#if PSI_ENABLE_ANSI
    size_t len = 0;
    const char *text = lua_type(L, 2) == LUA_TSTRING ? lua_tolstring(L, 2, &len) : "";
#else
    const char *text = lua_type(L, 2) == LUA_TSTRING ? lua_tostring(L, 2) : "";
#endif
    psi_vm_require_tui(L);
    if (row < 1) {
        row = 1;
    }
    if (row > LINES) {
        row = LINES;
    }
#if PSI_ENABLE_ANSI
    if (memchr(text, 0x1b, len) != NULL) {
        psi_vm_tui_draw_ansi_line((int)row - 1, text);
    } else {
        psi_vm_tui_draw_plain_line((int)row - 1, text);
    }
#else
    psi_vm_tui_draw_plain_line((int)row - 1, text);
#endif
    return 0;
}

static int lfn_tui_draw_raw_line(lua_State *L) {
    lua_Integer row = luaL_checkinteger(L, 1);
    const char *text = lua_type(L, 2) == LUA_TSTRING ? lua_tostring(L, 2) : "";

    psi_vm_require_tui(L);
    if (row < 1) {
        row = 1;
    }
    if (row > LINES) {
        row = LINES;
    }

    /*
     * Bypass ncurses color-pair translation for diagnostic / raw ANSI
     * output. Save and restore the hardware cursor so Lua-owned cursor
     * placement remains stable after direct terminal writes.
     */
    printf("\0337\033[%ld;1H\033[2K%s\033[0m\0338", (long)row, text);
    fflush(stdout);
    return 0;
}

static int lfn_tui_set_cursor(lua_State *L) {
    lua_Integer row = luaL_optinteger(L, 1, 1);
    lua_Integer col = luaL_optinteger(L, 2, 1);
    int visible = lua_toboolean(L, 3);

    psi_vm_require_tui(L);
    if (row < 1) row = 1;
    if (col < 1) col = 1;
    if (row > LINES) row = LINES;
    if (col > COLS) col = COLS;
    curs_set(visible ? 1 : 0);
    move((int)row - 1, (int)col - 1);
    return 0;
}

static int lfn_tui_refresh(lua_State *L) {
    psi_vm_require_tui(L);
    refresh();
    return 0;
}

static int lfn_tui_suspend(lua_State *L) {
    psi_vm_require_tui(L);
    psi_vm_tui_suspend_terminal();
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

static int lfn_tui_size(lua_State *L) { return lfn_tui_unavailable(L); }
static int lfn_tui_poll_key(lua_State *L) { return lfn_tui_unavailable(L); }
static int lfn_tui_clear(lua_State *L) { return lfn_tui_unavailable(L); }
static int lfn_tui_draw_line(lua_State *L) { return lfn_tui_unavailable(L); }
static int lfn_tui_draw_raw_line(lua_State *L) { return lfn_tui_unavailable(L); }
static int lfn_tui_set_cursor(lua_State *L) { return lfn_tui_unavailable(L); }
static int lfn_tui_refresh(lua_State *L) { return lfn_tui_unavailable(L); }
static int lfn_tui_suspend(lua_State *L) { return lfn_tui_unavailable(L); }
static int lfn_tui_set_tick_handler(lua_State *L) { return lfn_tui_unavailable(L); }
static int lfn_tui_set_tool_progress_handler(lua_State *L) { return lfn_tui_unavailable(L); }

#endif

/* psi.host_tick() -- run one iteration of the host's event loop.
 *
 * Called by psi.sched between coroutine resumes. Does nothing if no
 * host (e.g. --eval, --print, --agent scripts) has installed a hook.
 * The TUI installs one that pumps ncurses input + redraws; this is
 * how the UI stays responsive during a streaming turn. */
static int lfn_host_tick(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    const struct psi_vm *vm = host != NULL ? host->vm : NULL;
    if (host != NULL && host->tick_hook != NULL) {
        host->tick_hook(host->tick_userdata);
    }
    if (vm != NULL) {
        psi_vm_invoke_registry_callback0(
            L,
            vm->tui_tick_callback_ref,
            "psi.tui_set_tick_handler"
        );
    }
    return 0;
}

/* psi.sleep_ms(ms) -- cooperative sleep (no thread involvement).
 * Used by psi.sched to honour sleep requests. Clamped to 1 hour so
 * buggy callers don't peg a UI thread indefinitely. */
static int lfn_sleep_ms(lua_State *L) {
    lua_Integer ms = luaL_optinteger(L, 1, 0);
    struct timespec ts;
    if (ms <= 0) return 0;
    if (ms > 3600000l) ms = 3600000l;
    ts.tv_sec = (time_t)(ms / 1000l);
    ts.tv_nsec = (long)((ms % 1000l) * 1000000l);
    nanosleep(&ts, NULL);
    return 0;
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

    lua_newtable(L);

#define PSI_REG(name, fn) \
    do { lua_pushcfunction(L, fn); lua_setfield(L, -2, name); } while (0)

    PSI_REG("version",               lfn_version);
    PSI_REG("log",                   lfn_log);
    PSI_REG("session_message_count", lfn_session_message_count);
    PSI_REG("read_file",             lfn_read_file);
    PSI_REG("read_file_slice",       lfn_read_file_slice);
    PSI_REG("file_write",            lfn_file_write);
    PSI_REG("file_append",           lfn_file_append);
    PSI_REG("tempfile_path",         lfn_tempfile_path);
    PSI_REG("current_date",          lfn_current_date);
    PSI_REG("cwd",                   lfn_cwd);
    PSI_REG("parent_directory",      lfn_parent_directory);
    PSI_REG("path_join",             lfn_path_join);
    PSI_REG("path_expand",           lfn_path_expand);
    PSI_REG("path_resolve",          lfn_path_resolve);
    PSI_REG("file_exists",           lfn_file_exists);
    PSI_REG("file_type",             lfn_file_type);
    PSI_REG("list_dir",              lfn_list_dir);
    PSI_REG("list_dir_typed",        lfn_list_dir_typed);
    PSI_REG("mkdir_p",               lfn_mkdir_p);
    PSI_REG("mkdir_parent",          lfn_mkdir_parent);
    PSI_REG("runtime_info",          lfn_runtime_info);
    PSI_REG("session_messages",      lfn_session_messages);
    PSI_REG("session_messages_from", lfn_session_messages_from);
    PSI_REG("session_token_estimate_from", lfn_session_token_estimate_from);
    PSI_REG("session_keep_recent_by_tokens", lfn_session_keep_recent_by_tokens);
    PSI_REG("process_run",           lfn_process_run);
    PSI_REG("process_run_argv",      lfn_process_run_argv);
    PSI_REG("process_begin",         lfn_process_begin);
    PSI_REG("process_begin_argv",    lfn_process_begin_argv);
    PSI_REG("process_poll",          lfn_process_poll);
    PSI_REG("process_finish",        lfn_process_finish);
    PSI_REG("session_append",        lfn_session_append);
    PSI_REG("session_append_jsonl",  lfn_session_append_jsonl);
    PSI_REG("session_clear",         lfn_session_clear);
    PSI_REG("session_id",            lfn_session_id);
    PSI_REG("session_parent_id",     lfn_session_parent_id);
    PSI_REG("session_path",          lfn_session_path);
    PSI_REG("session_set_id",        lfn_session_set_id);
    PSI_REG("session_set_path",      lfn_session_set_path);
    PSI_REG("session_set_parent_id", lfn_session_set_parent_id);
    PSI_REG("is_aborted",            lfn_is_aborted);
    PSI_REG("abort_trigger",         lfn_abort_trigger);
    PSI_REG("abort_reset",           lfn_abort_reset);
    PSI_REG("set_usage",             lfn_set_usage);
    PSI_REG("embedded_doc",          lfn_embedded_doc);
    PSI_REG("embedded_doc_names",    lfn_embedded_doc_names);
    PSI_REG("embedded_source",       lfn_embedded_source);
    PSI_REG("embedded_source_names", lfn_embedded_source_names);
    PSI_REG("json_encode",           lfn_json_encode);
    PSI_REG("json_decode",           lfn_json_decode);
    PSI_REG("http_post",             lfn_http_post);
    PSI_REG("http_get",              lfn_http_get);
    PSI_REG("http_post_stream",      lfn_http_post_stream);
    PSI_REG("http_stream_begin",     lfn_http_stream_begin);
    PSI_REG("http_stream_poll",      lfn_http_stream_poll);
    PSI_REG("http_stream_finish",    lfn_http_stream_finish);
    PSI_REG("tool_call",             lfn_tool_call);
    PSI_REG("readline",              lfn_readline);
    PSI_REG("add_history",           lfn_add_history);
    PSI_REG("stdout_write",          lfn_stdout_write);
    PSI_REG("sleep_ms",              lfn_sleep_ms);
    PSI_REG("host_tick",             lfn_host_tick);
    PSI_REG("tool_progress",         lfn_tool_progress);
    PSI_REG("tui_size",              lfn_tui_size);
    PSI_REG("tui_poll_key",          lfn_tui_poll_key);
    PSI_REG("tui_clear",             lfn_tui_clear);
    PSI_REG("tui_draw_line",         lfn_tui_draw_line);
    PSI_REG("tui_draw_raw_line",     lfn_tui_draw_raw_line);
    PSI_REG("tui_set_cursor",        lfn_tui_set_cursor);
    PSI_REG("tui_refresh",           lfn_tui_refresh);
    PSI_REG("tui_suspend",           lfn_tui_suspend);
    PSI_REG("tui_set_tick_handler",  lfn_tui_set_tick_handler);
    PSI_REG("tui_set_tool_progress_handler", lfn_tui_set_tool_progress_handler);

#undef PSI_REG

    lua_setglobal(L, "psi");
}

static int psi_vm_apply_package_path(lua_State *L, const char *boot_file) {
    char *copy;
    char *parent;
    char buffer[4096];

    if (!boot_file) return PSI_STATUS_OK;
    copy = psi_strdup(boot_file);
    if (!copy) return PSI_STATUS_ERROR;
    parent = psi_vm_parent_directory(copy);
    free(copy);
    if (!parent) return PSI_STATUS_ERROR;
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
    const struct psi_embedded_lua *e;
    for (e = psi_embedded_lua_table; e->name != NULL; e++) {
        if (strcmp(e->name, name) == 0) {
            unsigned char *buf = (unsigned char *)malloc(e->raw_len);
            int load_rc;
            if (buf == NULL) return luaL_error(L, "out of memory");
            if (psi_vm_embedded_inflate(e, buf, e->raw_len) != PSI_STATUS_OK) {
                free(buf);
                return luaL_error(L, "inflate failed for %s", name);
            }
            load_rc = luaL_loadbuffer(L, (const char *)buf, e->raw_len, e->name);
            free(buf);
            if (load_rc != LUA_OK) return lua_error(L);
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

static const struct psi_embedded_lua *psi_vm_embedded_find(const char *name) {
    const struct psi_embedded_lua *e;
    for (e = psi_embedded_lua_table; e->name != NULL; e++) {
        if (strcmp(e->name, name) == 0) return e;
    }
    return NULL;
}

int psi_vm_init(struct psi_vm *vm, const char *boot_file, FILE *input, FILE *output, FILE *error_output) {
    PSI_UNUSED(input);
    PSI_UNUSED(output);
    PSI_UNUSED(error_output);

    if (!vm) return PSI_STATUS_ERROR;
    memset(vm, 0, sizeof(*vm));
    vm->boot_file = boot_file;
    vm->host.vm = vm;
    vm->tui_tick_callback_ref = PSI_VM_NOREF;
    vm->tui_tool_progress_callback_ref = PSI_VM_NOREF;

    vm->L = luaL_newstate();
    if (!vm->L) return PSI_STATUS_ERROR;
    luaL_openlibs(vm->L);

    PSI_VM_HOST(vm->L) = &vm->host;

    if (psi_vm_apply_package_path(vm->L, boot_file) != PSI_STATUS_OK) {
        lua_close(vm->L);
        vm->L = NULL;
        return PSI_STATUS_ERROR;
    }

    psi_vm_register_embedded(vm->L);

    psi_vm_register_psi(vm->L);

    /* Bootstrap: use the file at boot_file if it exists (source-tree
     * dev runs, or installs that ship lua/ alongside the binary);
     * otherwise fall back to the embedded boot.lua compiled into the
     * binary. This is what makes static psi binaries self-contained —
     * a stripped-down install or a different host without the Nix
     * store still finds its Lua without touching the filesystem. */
    if (boot_file != NULL && boot_file[0] != '\0' && psi_vm_file_exists(boot_file)) {
        if (luaL_dofile(vm->L, boot_file) != LUA_OK) {
            fprintf(stderr, "failed to load Lua bootstrap: %s\n%s\n",
                    boot_file, lua_tostring(vm->L, -1));
            lua_close(vm->L);
            vm->L = NULL;
            return PSI_STATUS_ERROR;
        }
    } else {
        const struct psi_embedded_lua *boot = psi_vm_embedded_find("boot");
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
    if (!vm || !vm->L) return;
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
    if (!vm) return;
    vm->host.session = session;
    /* host pointer in extraspace already points at vm->host from init */
}

void psi_vm_set_tui_active(struct psi_vm *vm, int active) {
    if (!vm) return;
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
                if (!first) lua_pop(L, 1);
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

static int psi_vm_pop_string(lua_State *L, char **out) {
    const char *s;
    if (lua_type(L, -1) == LUA_TSTRING) {
        s = lua_tostring(L, -1);
    } else {
        luaL_tolstring(L, -1, NULL);
        s = lua_tostring(L, -1);
        lua_remove(L, -2); /* remove original */
    }
    *out = psi_strdup(s ? s : "");
    lua_pop(L, 1);
    return *out ? PSI_STATUS_OK : PSI_STATUS_ERROR;
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

int psi_vm_eval_to_string(struct psi_vm *vm, const char *expression, char **output_text) {
    size_t n;
    char *prefixed;
    int loaded;

    if (!vm || !vm->L || !output_text) return PSI_STATUS_ERROR;
    *output_text = NULL;
    if (!expression) expression = "";

    n = strlen(expression);
    prefixed = (char *)malloc(n + 8u);
    if (!prefixed) return PSI_STATUS_ERROR;
    memcpy(prefixed, "return ", 7);
    memcpy(prefixed + 7, expression, n + 1u);
    loaded = luaL_loadstring(vm->L, prefixed);
    free(prefixed);
    if (loaded != LUA_OK) {
        lua_pop(vm->L, 1);
        if (luaL_loadstring(vm->L, expression) != LUA_OK) {
            psi_vm_print_error("eval (parse)", lua_tostring(vm->L, -1));
            lua_pop(vm->L, 1);
            return PSI_STATUS_ERROR;
        }
    }
    if (lua_pcall(vm->L, 0, 1, 0) != LUA_OK) {
        psi_vm_print_error("eval", lua_tostring(vm->L, -1));
        lua_pop(vm->L, 1);
        return PSI_STATUS_ERROR;
    }
    return psi_vm_pop_string(vm->L, output_text);
}

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
    struct psi_abort_signal *sig = (struct psi_abort_signal *)lua_touserdata(L, lua_upvalueindex(1));
    lua_pushboolean(L, psi_abort_signal_is_triggered(sig) ? 1 : 0);
    return 1;
}

static void psi_vm_push_observer_table(lua_State *L, struct psi_agent_observer *observer) {
    lua_newtable(L);
    if (observer == NULL) return;
#define PSI_OB_BIND(key, fn) do { \
    lua_pushlightuserdata(L, observer); \
    lua_pushcclosure(L, fn, 1); \
    lua_setfield(L, -2, key); \
} while (0)
    PSI_OB_BIND("on_assistant_text_delta", psi_vm_ob_text_delta);
    PSI_OB_BIND("on_tool_call",            psi_vm_ob_tool_call);
    PSI_OB_BIND("on_tool_result",          psi_vm_ob_tool_result);
    PSI_OB_BIND("on_thinking_delta",       psi_vm_ob_thinking_delta);
    PSI_OB_BIND("on_tool_call_delta",      psi_vm_ob_tool_call_delta);
#undef PSI_OB_BIND
}

static int psi_vm_call_agent(
    struct psi_vm *vm,
    const char *procedure,
    struct psi_agent_observer *observer,
    struct psi_abort_signal *abort_signal,
    const char *model,
    long max_tokens,
    const char *user_text,
    long keep_recent,
    char **output_text
) {
    int ok;
    const char *text;

    if (vm == NULL || vm->L == NULL) return PSI_STATUS_ERROR;
    if (output_text != NULL) *output_text = NULL;

    if (psi_vm_begin_call(vm->L, procedure) != 0) return PSI_STATUS_ERROR;

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

int psi_vm_run_agent_turn(
    struct psi_vm *vm,
    const char *user_text,
    struct psi_agent_observer *observer,
    struct psi_abort_signal *abort_signal,
    const char *model,
    long max_tokens,
    char **response_text
) {
    return psi_vm_call_agent(
        vm, "psi.agent.run_turn",
        observer, abort_signal, model, max_tokens,
        user_text != NULL ? user_text : "", -1,
        response_text);
}

static int psi_vm_session_call_with_path(struct psi_vm *vm, const char *procedure, const char *path) {
    int ok;
    if (vm == NULL || vm->L == NULL) return PSI_STATUS_ERROR;
    if (psi_vm_begin_call(vm->L, procedure) != 0) return PSI_STATUS_ERROR;
    if (path != NULL) lua_pushstring(vm->L, path); else lua_pushnil(vm->L);
    if (psi_vm_finish_call(vm->L, 1, 1, procedure) != PSI_STATUS_OK) return PSI_STATUS_ERROR;
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

int psi_vm_run_agent_compact(
    struct psi_vm *vm,
    size_t keep_recent,
    struct psi_abort_signal *abort_signal,
    const char *model,
    long max_tokens,
    char **summary_text
) {
    return psi_vm_call_agent(
        vm, "psi.agent.run_compact",
        NULL, abort_signal, model, max_tokens,
        NULL, (long)keep_recent,
        summary_text);
}
