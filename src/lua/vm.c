/* psi Lua 5.4 VM and FFI bridge. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
#include <cjson/cJSON.h>
#include <editline/readline.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include <time.h>
#include <unistd.h>
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

static char *psi_vm_parent_directory(const char *path) {
    const char *slash;
    size_t len;
    char *out;

    if (path == NULL || path[0] == '\0') return psi_strdup(".");
    slash = strrchr(path, '/');
    if (slash == NULL) return psi_strdup(".");
    if (slash == path) return psi_strdup("/");
    len = (size_t)(slash - path);
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

static const long PSI_VM_FILE_WRITE_MAX_BYTES = 16777216l;
static const long PSI_VM_READ_FILE_MAX_BYTES  = 262144l;

/* Host context is stored in the Lua state's extraspace so FFI primitives
 * can recover it from their lua_State* rather than a file-static. Keeps
 * the door open for multiple VMs and makes cross-thread reasoning easier:
 * each Lua state owns exactly one host, and the worker thread is the
 * only one calling Lua while that host is active. */
#define PSI_VM_HOST(L) (*(struct psi_host_context **)lua_getextraspace(L))

/* ------------------------------------------------------------------
 * cJSON <-> Lua table conversion
 * ------------------------------------------------------------------ */

static cJSON *psi_vm_lua_value_to_json(lua_State *L, int idx);
static void psi_vm_push_json_value(lua_State *L, const cJSON *v);

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

static int lfn_file_exists(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_pushboolean(L, psi_vm_file_exists(path) ? 1 : 0);
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

    tool_id = luaL_optstring(L, 1, NULL);
    chunk = lua_type(L, 2) == LUA_TSTRING ? lua_tolstring(L, 2, &chunk_len) : NULL;
    if (chunk == NULL || chunk_len == 0u) return 0;

    host = PSI_VM_HOST(L);
    if (host == NULL || host->active_observer == NULL) return 0;
    if (host->active_observer->on_tool_progress == NULL) return 0;
    host->active_observer->on_tool_progress(
        host->active_observer->userdata,
        tool_id,
        chunk,
        chunk_len
    );
    return 0;
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
    struct psi_host_context *host;
    struct psi_session *s;
    int status;

    if (lua_type(L, 3) == LUA_TSTRING) data = lua_tostring(L, 3);

    host = PSI_VM_HOST(L);
    s = host ? host->session : NULL;
    if (!s) { lua_pushboolean(L, 0); return 1; }
    status = psi_session_append_with_data(s, psi_session_role_from_name(role), text, data);
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

static int lfn_is_aborted(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    lua_pushboolean(L,
        host != NULL && psi_abort_signal_is_triggered(host->abort_signal) ? 1 : 0);
    return 1;
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

static int lfn_runtime_info(lua_State *L) {
    static const char *PRIMITIVES[] = {
        "version", "log", "session_message_count", "read_file", "file_write",
        "current_date", "cwd", "parent_directory", "file_exists", "runtime_info",
        "session_messages", "process_run", "session_append", "session_clear",
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
    char *line = readline(prompt);
    if (line == NULL) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushstring(L, line);
    free(line);
    return 1;
}

/* psi.add_history(line) -- libedit history append. */
static int lfn_add_history(lua_State *L) {
    const char *line = lua_type(L, 1) == LUA_TSTRING ? lua_tostring(L, 1) : NULL;
    if (line != NULL && line[0] != '\0') add_history(line);
    return 0;
}

/* psi.host_tick() -- run one iteration of the host's event loop.
 *
 * Called by psi.sched between coroutine resumes. Does nothing if no
 * host (e.g. --eval, --print, --agent scripts) has installed a hook.
 * The TUI installs one that pumps ncurses input + redraws; this is
 * how the UI stays responsive during a streaming turn. */
static int lfn_host_tick(lua_State *L) {
    struct psi_host_context *host = PSI_VM_HOST(L);
    if (host != NULL && host->tick_hook != NULL) {
        host->tick_hook(host->tick_userdata);
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
    PSI_REG("file_write",            lfn_file_write);
    PSI_REG("current_date",          lfn_current_date);
    PSI_REG("cwd",                   lfn_cwd);
    PSI_REG("parent_directory",      lfn_parent_directory);
    PSI_REG("file_exists",           lfn_file_exists);
    PSI_REG("runtime_info",          lfn_runtime_info);
    PSI_REG("session_messages",      lfn_session_messages);
    PSI_REG("process_run",           lfn_process_run);
    PSI_REG("process_begin",         lfn_process_begin);
    PSI_REG("process_poll",          lfn_process_poll);
    PSI_REG("process_finish",        lfn_process_finish);
    PSI_REG("session_append",        lfn_session_append);
    PSI_REG("session_clear",         lfn_session_clear);
    PSI_REG("session_id",            lfn_session_id);
    PSI_REG("session_parent_id",     lfn_session_parent_id);
    PSI_REG("session_path",          lfn_session_path);
    PSI_REG("session_set_id",        lfn_session_set_id);
    PSI_REG("session_set_path",      lfn_session_set_path);
    PSI_REG("session_set_parent_id", lfn_session_set_parent_id);
    PSI_REG("is_aborted",            lfn_is_aborted);
    PSI_REG("set_usage",             lfn_set_usage);
    PSI_REG("embedded_doc",          lfn_embedded_doc);
    PSI_REG("embedded_doc_names",    lfn_embedded_doc_names);
    PSI_REG("embedded_source",       lfn_embedded_source);
    PSI_REG("embedded_source_names", lfn_embedded_source_names);
    PSI_REG("json_encode",           lfn_json_encode);
    PSI_REG("json_decode",           lfn_json_decode);
    PSI_REG("http_post",             lfn_http_post);
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

int psi_vm_call_string_procedure(struct psi_vm *vm, const char *procedure_name,
                                  const char *argument, char **output_text) {
    if (!vm || !vm->L || !procedure_name || !output_text) return PSI_STATUS_ERROR;
    *output_text = NULL;
    if (psi_vm_begin_call(vm->L, procedure_name) != 0) return PSI_STATUS_ERROR;
    lua_pushstring(vm->L, argument ? argument : "");
    if (psi_vm_finish_call(vm->L, 1, 1, procedure_name) != PSI_STATUS_OK) return PSI_STATUS_ERROR;
    return psi_vm_pop_string(vm->L, output_text);
}

int psi_vm_markdown_render_line(struct psi_vm *vm, const char *text, int in_code_fence, char **output_text) {
    if (!vm || !vm->L || !output_text) return PSI_STATUS_ERROR;
    *output_text = NULL;
    if (psi_vm_begin_call(vm->L, "psi.markdown.render_line") != 0) return PSI_STATUS_ERROR;
    lua_pushstring(vm->L, text ? text : "");
    lua_pushboolean(vm->L, in_code_fence ? 1 : 0);
    if (psi_vm_finish_call(vm->L, 2, 1, "psi.markdown.render_line") != PSI_STATUS_OK) return PSI_STATUS_ERROR;
    return psi_vm_pop_string(vm->L, output_text);
}

int psi_vm_tui_status_line(struct psi_vm *vm, const char *arg_json, char **output_text) {
    return psi_vm_call_string_procedure(vm, "psi.tui.status_line", arg_json, output_text);
}

int psi_vm_tui_footer_hint(struct psi_vm *vm, const char *arg_json, char **output_text) {
    return psi_vm_call_string_procedure(vm, "psi.tui.footer_hint", arg_json, output_text);
}

int psi_vm_call_procedure0_to_string(struct psi_vm *vm, const char *procedure_name,
                                      char **output_text) {
    if (!vm || !vm->L || !procedure_name || !output_text) return PSI_STATUS_ERROR;
    *output_text = NULL;
    if (psi_vm_begin_call(vm->L, procedure_name) != 0) return PSI_STATUS_ERROR;
    if (psi_vm_finish_call(vm->L, 0, 1, procedure_name) != PSI_STATUS_OK) return PSI_STATUS_ERROR;
    return psi_vm_pop_string(vm->L, output_text);
}

int psi_vm_render_event_json(struct psi_vm *vm, const char *event_name,
                              const char *payload_json, char **output_text) {
    if (!vm || !vm->L || !event_name || !output_text) return PSI_STATUS_ERROR;
    *output_text = NULL;

    if (psi_vm_begin_call(vm->L, "psi.render.handle_event") != 0) return PSI_STATUS_ERROR;
    lua_pushstring(vm->L, event_name);
    if (payload_json && payload_json[0] != '\0') {
        cJSON *root = cJSON_Parse(payload_json);
        if (!root) { lua_pop(vm->L, 2); return PSI_STATUS_ERROR; }
        psi_vm_push_json_value(vm->L, root);
        cJSON_Delete(root);
    } else {
        lua_newtable(vm->L);
    }
    if (psi_vm_finish_call(vm->L, 2, 1, "psi.render.handle_event") != PSI_STATUS_OK)
        return PSI_STATUS_ERROR;
    if (lua_type(vm->L, -1) != LUA_TSTRING) {
        *output_text = psi_strdup("");
        lua_pop(vm->L, 1);
        return *output_text ? PSI_STATUS_OK : PSI_STATUS_ERROR;
    }
    *output_text = psi_strdup(lua_tostring(vm->L, -1));
    lua_pop(vm->L, 1);
    return *output_text ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

int psi_vm_parse_command(struct psi_vm *vm, const char *line,
                          char **action_name, char **action_text, long *action_number) {
    if (!vm || !vm->L || !line || !action_name || !action_text || !action_number)
        return PSI_STATUS_ERROR;
    *action_name = NULL;
    *action_text = NULL;
    *action_number = 0l;

    if (psi_vm_begin_call(vm->L, "psi.commands.handle_command_list") != 0) return PSI_STATUS_ERROR;
    lua_pushstring(vm->L, line);
    if (psi_vm_finish_call(vm->L, 1, 1, "psi.commands.handle_command_list") != PSI_STATUS_OK)
        return PSI_STATUS_ERROR;

    if (lua_isnil(vm->L, -1) || (lua_isboolean(vm->L, -1) && !lua_toboolean(vm->L, -1))) {
        lua_pop(vm->L, 1);
        return PSI_STATUS_OK;
    }
    if (!lua_istable(vm->L, -1)) {
        fprintf(stderr, "invalid Lua command result\n");
        lua_pop(vm->L, 1);
        return PSI_STATUS_ERROR;
    }

    lua_rawgeti(vm->L, -1, 1);
    if (lua_type(vm->L, -1) != LUA_TSTRING) {
        lua_pop(vm->L, 2);
        return PSI_STATUS_ERROR;
    }
    *action_name = psi_strdup(lua_tostring(vm->L, -1));
    lua_pop(vm->L, 1);
    if (!*action_name) { lua_pop(vm->L, 1); return PSI_STATUS_ERROR; }

    lua_rawgeti(vm->L, -1, 2);
    if (strcmp(*action_name, "print") == 0) {
        if (lua_type(vm->L, -1) == LUA_TSTRING) {
            *action_text = psi_strdup(lua_tostring(vm->L, -1));
        }
    } else if (strcmp(*action_name, "compact") == 0) {
        if (lua_type(vm->L, -1) == LUA_TNUMBER) {
            *action_number = (long)lua_tointeger(vm->L, -1);
        }
    }
    lua_pop(vm->L, 2);
    return PSI_STATUS_OK;
}

int psi_vm_build_compaction_request(struct psi_vm *vm, long keep_recent,
                                     char **system_prompt, char **user_prompt) {
    if (!vm || !vm->L || !system_prompt || !user_prompt) return PSI_STATUS_ERROR;
    *system_prompt = NULL;
    *user_prompt = NULL;

    if (psi_vm_begin_call(vm->L, "psi.prompt.compaction_request") != 0) return PSI_STATUS_ERROR;
    lua_pushinteger(vm->L, (lua_Integer)keep_recent);
    if (psi_vm_finish_call(vm->L, 1, 1, "psi.prompt.compaction_request") != PSI_STATUS_OK)
        return PSI_STATUS_ERROR;
    if (!lua_istable(vm->L, -1)) {
        fprintf(stderr, "invalid Lua compaction request\n");
        lua_pop(vm->L, 1);
        return PSI_STATUS_ERROR;
    }

    lua_rawgeti(vm->L, -1, 1);
    if (lua_type(vm->L, -1) != LUA_TSTRING) { lua_pop(vm->L, 2); return PSI_STATUS_ERROR; }
    *system_prompt = psi_strdup(lua_tostring(vm->L, -1));
    lua_pop(vm->L, 1);

    lua_rawgeti(vm->L, -1, 2);
    if (lua_type(vm->L, -1) != LUA_TSTRING) {
        free(*system_prompt); *system_prompt = NULL;
        lua_pop(vm->L, 2);
        return PSI_STATUS_ERROR;
    }
    *user_prompt = psi_strdup(lua_tostring(vm->L, -1));
    lua_pop(vm->L, 2);
    return (*system_prompt && *user_prompt) ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

int psi_vm_dispatch_tool_json(struct psi_vm *vm, const char *tool_name,
                               const char *input_json, char **output_json) {
    cJSON *root;
    cJSON *result;

    if (!vm || !vm->L || !tool_name || !output_json) return PSI_STATUS_ERROR;
    *output_json = NULL;

    root = (input_json && input_json[0] != '\0')
        ? cJSON_Parse(input_json)
        : cJSON_CreateObject();
    if (!root) return PSI_STATUS_ERROR;

    if (psi_vm_begin_call(vm->L, "psi.tools.dispatch_alist") != 0) {
        cJSON_Delete(root);
        return PSI_STATUS_ERROR;
    }
    lua_pushstring(vm->L, tool_name);
    psi_vm_push_json_value(vm->L, root);
    cJSON_Delete(root);
    if (psi_vm_finish_call(vm->L, 2, 1, "psi.tools.dispatch_alist") != PSI_STATUS_OK)
        return PSI_STATUS_ERROR;
    result = psi_vm_lua_value_to_json(vm->L, -1);
    lua_pop(vm->L, 1);
    if (!result) return PSI_STATUS_ERROR;
    *output_json = cJSON_PrintUnformatted(result);
    cJSON_Delete(result);
    return *output_json ? PSI_STATUS_OK : PSI_STATUS_ERROR;
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

int psi_vm_session_compact(struct psi_vm *vm, long keep_recent, const char *summary_text) {
    int ok;
    if (!vm || !vm->L || !summary_text) return PSI_STATUS_ERROR;

    if (psi_vm_begin_call(vm->L, "psi.session.do_compact") != 0) return PSI_STATUS_ERROR;
    lua_pushinteger(vm->L, (lua_Integer)keep_recent);
    lua_pushstring(vm->L, summary_text);
    if (psi_vm_finish_call(vm->L, 2, 1, "psi.session.do_compact") != PSI_STATUS_OK)
        return PSI_STATUS_ERROR;
    ok = lua_toboolean(vm->L, -1);
    lua_pop(vm->L, 1);
    return ok ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}
