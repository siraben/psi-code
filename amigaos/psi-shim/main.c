/* psi-amigaos: minimal entry point with embedded Lua bootstrap.
 *
 * v1.1 scope (Phase 7):
 *   --eval EXPR   evaluate a Lua expression, print the result, exit
 *   --print TEXT  call psi.prompt.handle_print(TEXT)
 *   --version     banner
 *
 * Embedded Lua modules: lua/boot.lua + lua/psi/*.lua are baked into
 * the binary via amigaos/scripts/embed_lua_raw.c. We install a
 * searcher into package.searchers[2] that maps require("psi.X") to
 * the embedded table — no filesystem lookup.
 *
 * Boot.lua tries to load extensions from $HOME/.config/psi/extensions
 * which doesn't exist on AmigaOS; it pcalls those so the failures
 * are silent. The overall psi global table comes up populated. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "psi/embedded_lua.h"

typedef long PSI_LONG;
typedef long PSI_BPTR;
typedef const char *PSI_CONST_STRPTR;
typedef void *PSI_APTR;
typedef const void *PSI_CONST_APTR;

extern void *DOSBase;
PSI_BPTR psi_dos_open(__reg("a6") void *, __reg("d1") PSI_CONST_STRPTR name, __reg("d2") PSI_LONG accessMode)="\tjsr\t-30(a6)";
PSI_LONG psi_dos_close(__reg("a6") void *, __reg("d1") PSI_BPTR file)="\tjsr\t-36(a6)";
PSI_LONG psi_dos_read(__reg("a6") void *, __reg("d1") PSI_BPTR file, __reg("d2") PSI_APTR buffer, __reg("d3") PSI_LONG length)="\tjsr\t-42(a6)";
PSI_LONG psi_dos_write(__reg("a6") void *, __reg("d1") PSI_BPTR file, __reg("d2") PSI_CONST_APTR buffer, __reg("d3") PSI_LONG length)="\tjsr\t-48(a6)";
PSI_BPTR psi_dos_output(__reg("a6") void *)="\tjsr\t-60(a6)";
PSI_LONG psi_dos_seek(__reg("a6") void *, __reg("d1") PSI_BPTR file, __reg("d2") PSI_LONG position, __reg("d3") PSI_LONG offset)="\tjsr\t-66(a6)";

#define PSI_MODE_OLDFILE 1005L
#define PSI_MODE_NEWFILE 1006L
#define PSI_OFFSET_BEGINNING -1L
#define PSI_OFFSET_END 1L

struct session_record {
    char *role;
    char *text;
    char *data;
};

static struct {
    struct session_record *items;
    int count;
    int cap;
    char *id;
    char *parent_id;
    char *path;
} g_session;

struct amiga_http_stream {
    char *bridge_dir;
    char *id;
    char *body_path;
    char *status_path;
    char *response;
    long response_len;
    long offset;
    int done_seen;
};

#define PSI_AMIGA_HTTP_MT "psi.amiga_http_stream"

static char g_last_bridge_error[512];

/* vbcc's libc declares strdup but its prototype isn't visible
 * through the headers we include — the implicit return is `int`
 * which then assigns to `char *` and yields "invalid types for
 * assignment" with `-fno-asm`-style strictness. Roll our own. */
static char *psi_strdup(const char *s)
{
    size_t n;
    char *out;
    if (s == NULL) return NULL;
    n = strlen(s) + 1;
    out = (char *)malloc(n);
    if (out == NULL) return NULL;
    memcpy(out, s, n);
    return out;
}

static char *psi_join3(const char *a, const char *b, const char *c)
{
    size_t la = strlen(a), lb = strlen(b), lc = strlen(c);
    char *out = (char *)malloc(la + lb + lc + 1);
    if (out == NULL) return NULL;
    memcpy(out, a, la);
    memcpy(out + la, b, lb);
    memcpy(out + la + lb, c, lc);
    out[la + lb + lc] = '\0';
    return out;
}

static void console_write_len(const char *s, size_t len)
{
    PSI_BPTR out;
    if (s == NULL || len == 0) return;
    out = psi_dos_output(DOSBase);
    if (out != 0) {
        psi_dos_write(DOSBase, out, s, (PSI_LONG)len);
    } else {
        fwrite(s, 1, len, stdout);
        fflush(stdout);
    }
}

static void console_write(const char *s)
{
    if (s != NULL) console_write_len(s, strlen(s));
}

static int file_exists_c(const char *path)
{
    PSI_BPTR fh;
    if (path == NULL || path[0] == '\0') return 0;
    fh = psi_dos_open(DOSBase, path, PSI_MODE_OLDFILE);
    if (fh == 0) return 0;
    psi_dos_close(DOSBase, fh);
    return 1;
}

static char *read_file_c(const char *path, long *len_out)
{
    PSI_BPTR fh;
    long len = 0;
    long cap = 4096;
    char *buf;
    PSI_LONG got;
    if (len_out != NULL) *len_out = 0;
    fh = psi_dos_open(DOSBase, path, PSI_MODE_OLDFILE);
    if (fh == 0) return NULL;
    buf = (char *)malloc((size_t)cap + 1u);
    if (buf == NULL) { psi_dos_close(DOSBase, fh); return NULL; }
    for (;;) {
        if (cap - len < 4096) {
            char *next;
            cap *= 2;
            next = (char *)realloc(buf, (size_t)cap + 1u);
            if (next == NULL) {
                free(buf); psi_dos_close(DOSBase, fh); return NULL;
            }
            buf = next;
        }
        got = psi_dos_read(DOSBase, fh, buf + len, 4096);
        if (got < 0) {
            free(buf); psi_dos_close(DOSBase, fh); return NULL;
        }
        if (got == 0) break;
        len += got;
    }
    psi_dos_close(DOSBase, fh);
    buf[len] = '\0';
    if (len_out != NULL) *len_out = len;
    return buf;
}

static int write_file_c(const char *path, const char *data, size_t len)
{
    PSI_BPTR fh;
    PSI_LONG wrote;
    fh = psi_dos_open(DOSBase, path, PSI_MODE_NEWFILE);
    if (fh == 0) return 0;
    wrote = len > 0 ? psi_dos_write(DOSBase, fh, data, (PSI_LONG)len) : 0;
    if (len > 0 && wrote != (PSI_LONG)len) {
        psi_dos_close(DOSBase, fh);
        return 0;
    }
    psi_dos_close(DOSBase, fh);
    return 1;
}

static int try_write_bridge_probe(const char *dir)
{
    char *path;
    int ok;
    if (dir == NULL || dir[0] == '\0') return 0;
    path = psi_join3(dir,
        (dir[strlen(dir) - 1] == ':' || dir[strlen(dir) - 1] == '/') ? "" : "/",
        "probe");
    if (path == NULL) return 0;
    ok = write_file_c(path, "ok\n", 3);
    free(path);
    return ok;
}

static const char *bridge_dir_candidates[] = {
    "bridge:",
    "DH1:",
    "DH0:bridge",
    "DH0:bridge/",
    "dh0:bridge",
    "dh0:bridge/",
    NULL
};

static int write_bridge_probe_any(const char **used_dir)
{
    const char *env_dir = getenv("PSI_AMIGA_BRIDGE_DIR");
    int i;
    if (used_dir != NULL) *used_dir = NULL;
    if (env_dir != NULL && env_dir[0] != '\0') {
        if (try_write_bridge_probe(env_dir)) {
            if (used_dir != NULL) *used_dir = env_dir;
            return 1;
        }
        return 0;
    }
    for (i = 0; bridge_dir_candidates[i] != NULL; i++) {
        if (try_write_bridge_probe(bridge_dir_candidates[i])) {
            if (used_dir != NULL) *used_dir = bridge_dir_candidates[i];
            return 1;
        }
    }
    return 0;
}

static void sleep_ms_c(int ms)
{
    clock_t start;
    if (ms <= 0) return;
    start = clock();
    while ((((clock() - start) * 1000L) / CLOCKS_PER_SEC) < ms) {
        /* Classic Amiga/vamos portable fallback: short busy wait. */
    }
}

static void session_clear_c(void)
{
    int i;
    for (i = 0; i < g_session.count; i++) {
        free(g_session.items[i].role);
        free(g_session.items[i].text);
        free(g_session.items[i].data);
    }
    free(g_session.items);
    g_session.items = NULL;
    g_session.count = 0;
    g_session.cap = 0;
}

static int session_set_string(char **slot, const char *value)
{
    char *copy = value != NULL ? psi_strdup(value) : NULL;
    if (value != NULL && copy == NULL) return 0;
    free(*slot);
    *slot = copy;
    return 1;
}

static int session_append_c(const char *role, const char *text, const char *data)
{
    struct session_record *next;
    if (g_session.count == g_session.cap) {
        int new_cap = g_session.cap == 0 ? 8 : g_session.cap * 2;
        next = (struct session_record *)realloc(g_session.items,
                sizeof(*g_session.items) * (size_t)new_cap);
        if (next == NULL) return 0;
        g_session.items = next;
        g_session.cap = new_cap;
    }
    g_session.items[g_session.count].role = psi_strdup(role ? role : "");
    g_session.items[g_session.count].text = psi_strdup(text ? text : "");
    g_session.items[g_session.count].data = data ? psi_strdup(data) : NULL;
    if (g_session.items[g_session.count].role == NULL ||
        g_session.items[g_session.count].text == NULL ||
        (data != NULL && g_session.items[g_session.count].data == NULL)) {
        return 0;
    }
    g_session.count++;
    return 1;
}

static void usage(void)
{
    console_write(
            "usage: psi --eval EXPR\n"
            "       psi --print TEXT\n"
            "       psi --agent TEXT [--session FILE] [--model MODEL] [--max-tokens N]\n"
            "       psi --probe-bridge\n"
            "       psi --version\n");
}

static int lfn_version(lua_State *L) { lua_pushstring(L, "0.1.0 (AmigaOS)"); return 1; }
static int lfn_current_date(lua_State *L) { lua_pushstring(L, "2026-04-25"); return 1; }
static int lfn_cwd(lua_State *L) { lua_pushstring(L, "SYS:"); return 1; }
static int lfn_parent_directory(lua_State *L) { lua_pushvalue(L, 1); return 1; }
static int lfn_is_aborted(lua_State *L) { lua_pushboolean(L, 0); return 1; }

static int lfn_stdout_write(lua_State *L)
{
    size_t len;
    const char *s = luaL_checklstring(L, 1, &len);
    console_write_len(s, len);
    return 0;
}

static int lfn_sleep_ms(lua_State *L)
{
    sleep_ms_c((int)luaL_optinteger(L, 1, 0));
    return 0;
}

static int lfn_file_exists(lua_State *L)
{
    lua_pushboolean(L, file_exists_c(luaL_checkstring(L, 1)));
    return 1;
}

static int lfn_read_file(lua_State *L)
{
    long len;
    char *buf = read_file_c(luaL_checkstring(L, 1), &len);
    if (buf == NULL) { lua_pushnil(L); return 1; }
    lua_pushlstring(L, buf, (size_t)len);
    free(buf);
    return 1;
}

static int lfn_file_write(lua_State *L)
{
    size_t len;
    const char *path = luaL_checkstring(L, 1);
    const char *data = luaL_checklstring(L, 2, &len);
    lua_pushboolean(L, write_file_c(path, data, len));
    return 1;
}

static int lfn_session_message_count(lua_State *L) { lua_pushinteger(L, g_session.count); return 1; }
static int lfn_session_clear(lua_State *L) { session_clear_c(); return 0; }

static int lfn_session_append(lua_State *L)
{
    const char *role = luaL_checkstring(L, 1);
    const char *text = luaL_optstring(L, 2, "");
    const char *data = lua_type(L, 3) == LUA_TSTRING ? lua_tostring(L, 3) : NULL;
    lua_pushboolean(L, session_append_c(role, text, data));
    return 1;
}

static int lfn_session_messages(lua_State *L)
{
    int i;
    lua_newtable(L);
    for (i = 0; i < g_session.count; i++) {
        lua_newtable(L);
        lua_pushstring(L, g_session.items[i].role); lua_setfield(L, -2, "role");
        lua_pushstring(L, g_session.items[i].text); lua_setfield(L, -2, "text");
        if (g_session.items[i].data != NULL) lua_pushstring(L, g_session.items[i].data);
        else lua_pushnil(L);
        lua_setfield(L, -2, "data");
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

static int lfn_session_id(lua_State *L) { if (g_session.id) lua_pushstring(L, g_session.id); else lua_pushnil(L); return 1; }
static int lfn_session_path(lua_State *L) { if (g_session.path) lua_pushstring(L, g_session.path); else lua_pushnil(L); return 1; }
static int lfn_session_parent_id(lua_State *L) { if (g_session.parent_id) lua_pushstring(L, g_session.parent_id); else lua_pushnil(L); return 1; }
static int lfn_session_set_id(lua_State *L) { lua_pushboolean(L, session_set_string(&g_session.id, luaL_optstring(L, 1, NULL))); return 1; }
static int lfn_session_set_path(lua_State *L) { lua_pushboolean(L, session_set_string(&g_session.path, luaL_optstring(L, 1, NULL))); return 1; }
static int lfn_session_set_parent_id(lua_State *L) { lua_pushboolean(L, session_set_string(&g_session.parent_id, luaL_optstring(L, 1, NULL))); return 1; }

static int lfn_json_encode(lua_State *L)
{
    lua_getglobal(L, "require");
    lua_pushstring(L, "psi.json");
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) return lua_error(L);
    lua_getfield(L, -1, "encode");
    lua_pushvalue(L, 1);
    lua_call(L, 1, 1);
    return 1;
}

static int lfn_json_decode(lua_State *L)
{
    lua_getglobal(L, "require");
    lua_pushstring(L, "psi.json");
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) return lua_error(L);
    lua_getfield(L, -1, "decode");
    lua_pushvalue(L, 1);
    lua_call(L, 1, 1);
    return 1;
}

static struct amiga_http_stream **http_ud(lua_State *L, int idx)
{
    return (struct amiga_http_stream **)luaL_checkudata(L, idx, PSI_AMIGA_HTTP_MT);
}

static void http_stream_free(struct amiga_http_stream *h)
{
    if (h == NULL) return;
    free(h->bridge_dir);
    free(h->id);
    free(h->body_path);
    free(h->status_path);
    free(h->response);
    free(h);
}

static int lfn_http_stream_gc(lua_State *L)
{
    struct amiga_http_stream **ud = http_ud(L, 1);
    http_stream_free(*ud);
    *ud = NULL;
    return 0;
}

static int write_headers_file(lua_State *L, const char *path, int idx)
{
    PSI_BPTR fh;
    int i, n;
    fh = psi_dos_open(DOSBase, path, PSI_MODE_NEWFILE);
    if (fh == 0) return 0;
    n = (int)lua_rawlen(L, idx);
    for (i = 1; i <= n; i++) {
        const char *h;
        lua_rawgeti(L, idx, i);
        h = lua_tostring(L, -1);
        if (h != NULL) {
            psi_dos_write(DOSBase, fh, h, (PSI_LONG)strlen(h));
            psi_dos_write(DOSBase, fh, "\n", 1);
        }
        lua_pop(L, 1);
    }
    psi_dos_close(DOSBase, fh);
    return 1;
}

static int lfn_http_stream_begin(lua_State *L)
{
    const char *url = luaL_checkstring(L, 1);
    size_t body_len;
    const char *body;
    const char *dir;
    char idbuf[64];
    char *prefix, *url_path, *headers_path, *req_body_path, *ready_path;
    struct amiga_http_stream *h;
    struct amiga_http_stream **ud;
    static int seq = 0;
    int bridge_attempt = 0;

    luaL_checktype(L, 2, LUA_TTABLE);
    body = luaL_checklstring(L, 3, &body_len);
    dir = getenv("PSI_AMIGA_BRIDGE_DIR");
    if (dir == NULL || dir[0] == '\0') dir = "bridge:";

retry_bridge_dir:
    snprintf(g_last_bridge_error, sizeof(g_last_bridge_error),
        "trying bridge dir %s", dir);
    sprintf(idbuf, "req-%ld-%d", (long)time(NULL), ++seq);
    prefix = psi_join3(dir,
        (dir[strlen(dir) - 1] == ':' || dir[strlen(dir) - 1] == '/') ? "" : "/",
        idbuf);
    url_path = psi_join3(prefix, ".", "url");
    headers_path = psi_join3(prefix, ".", "headers");
    req_body_path = psi_join3(prefix, ".", "request");
    ready_path = psi_join3(prefix, ".", "ready");
    if (!prefix || !url_path || !headers_path || !req_body_path || !ready_path) {
        lua_pushnil(L); lua_pushstring(L, "out of memory"); return 2;
    }
    if (!write_file_c(url_path, url, strlen(url)) ||
        !write_headers_file(L, headers_path, 2) ||
        !write_file_c(req_body_path, body, body_len) ||
        !write_file_c(ready_path, "ready\n", 6)) {
        free(prefix); free(url_path); free(headers_path); free(req_body_path); free(ready_path);
        snprintf(g_last_bridge_error, sizeof(g_last_bridge_error),
            "failed to write bridge request in %s", dir);
        if (getenv("PSI_AMIGA_BRIDGE_DIR") == NULL || getenv("PSI_AMIGA_BRIDGE_DIR")[0] == '\0') {
            bridge_attempt++;
            if (bridge_dir_candidates[bridge_attempt] != NULL) {
                dir = bridge_dir_candidates[bridge_attempt];
                goto retry_bridge_dir;
            }
        }
        lua_pushnil(L); lua_pushstring(L, g_last_bridge_error); return 2;
    }

    snprintf(g_last_bridge_error, sizeof(g_last_bridge_error),
        "bridge request written in %s", dir);

    h = (struct amiga_http_stream *)calloc(1u, sizeof(*h));
    if (h == NULL) {
        free(prefix); free(url_path); free(headers_path); free(req_body_path); free(ready_path);
        lua_pushnil(L); lua_pushstring(L, "out of memory"); return 2;
    }
    h->bridge_dir = psi_strdup(dir);
    h->id = psi_strdup(idbuf);
    h->body_path = psi_join3(prefix, ".", "body");
    h->status_path = psi_join3(prefix, ".", "status");
    free(prefix); free(url_path); free(headers_path); free(req_body_path); free(ready_path);
    if (!h->bridge_dir || !h->id || !h->body_path || !h->status_path) {
        http_stream_free(h);
        lua_pushnil(L); lua_pushstring(L, "out of memory"); return 2;
    }
    ud = (struct amiga_http_stream **)lua_newuserdata(L, sizeof(*ud));
    *ud = h;
    luaL_setmetatable(L, PSI_AMIGA_HTTP_MT);
    return 1;
}

static int lfn_http_stream_poll(lua_State *L)
{
    struct amiga_http_stream **ud = http_ud(L, 1);
    struct amiga_http_stream *h = *ud;
    int timeout_ms = (int)luaL_optinteger(L, 2, 0);
    clock_t start = clock();
    if (h == NULL) { lua_pushnil(L); lua_pushboolean(L, 1); return 2; }
    for (;;) {
        if (h->response == NULL && file_exists_c(h->body_path)) {
            h->response = read_file_c(h->body_path, &h->response_len);
        }
        if (h->response != NULL && h->offset < h->response_len) {
            long avail = h->response_len - h->offset;
            if (avail > 4096) avail = 4096;
            lua_pushlstring(L, h->response + h->offset, (size_t)avail);
            h->offset += avail;
            lua_pushboolean(L, 0);
            return 2;
        }
        if (file_exists_c(h->status_path)) {
            lua_pushnil(L);
            lua_pushboolean(L, 1);
            return 2;
        }
        if (timeout_ms <= 0) break;
        if ((((clock() - start) * 1000L) / CLOCKS_PER_SEC) >= timeout_ms) break;
    }
    lua_pushnil(L);
    lua_pushboolean(L, 0);
    return 2;
}

static int lfn_http_stream_finish(lua_State *L)
{
    struct amiga_http_stream **ud = http_ud(L, 1);
    struct amiga_http_stream *h = *ud;
    char *s;
    long len;
    long status = -1;
    if (h != NULL) {
        s = read_file_c(h->status_path, &len);
        if (s != NULL) { status = atol(s); free(s); }
        http_stream_free(h);
        *ud = NULL;
    }
    lua_pushinteger(L, (lua_Integer)status);
    return 1;
}

static int lfn_http_post(lua_State *L)
{
    lua_pushcfunction(L, lfn_http_stream_begin);
    lua_pushvalue(L, 1); lua_pushvalue(L, 2); lua_pushvalue(L, 3);
    if (lua_pcall(L, 3, 2, 0) != LUA_OK) return lua_error(L);
    if (lua_isnil(L, -2)) return 2;
    lua_pop(L, 1);
    for (;;) {
        lua_pushcfunction(L, lfn_http_stream_poll);
        lua_pushvalue(L, -2);
        lua_pushinteger(L, 100);
        lua_call(L, 2, 2);
        if (lua_toboolean(L, -1)) { lua_pop(L, 2); break; }
        lua_pop(L, 2);
    }
    lua_pushcfunction(L, lfn_http_stream_finish);
    lua_pushvalue(L, -2);
    lua_call(L, 1, 1);
    lua_pushliteral(L, "");
    return 2;
}

/* Lua-callable searcher: resolves require("psi.X") against the
 * embedded table. Mirrors psi_vm_embedded_searcher in src/lua/vm.c
 * but with no zlib (entries are stored raw on AmigaOS). */
static int psi_amiga_embedded_searcher(lua_State *L)
{
    const char *name = luaL_checkstring(L, 1);
    const struct psi_embedded_lua *e;
    for (e = psi_embedded_lua_table; e->name != NULL; e++) {
        if (strcmp(e->name, name) == 0) {
            int rc = luaL_loadbuffer(L, (const char *)e->src,
                                     e->raw_len, e->name);
            if (rc != 0) return lua_error(L);
            return 1;
        }
    }
    lua_pushfstring(L, "\n\tno embedded psi module '%s'", name);
    return 1;
}

/* Install the embedded searcher at package.searchers[2] so require()
 * finds psi's modules without filesystem lookup. Position 1 is the
 * preload searcher; we slot in at 2 and shift the rest down. */
static int psi_amiga_register_searcher(lua_State *L)
{
    int n, i;
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "searchers");
    n = (int)lua_rawlen(L, -1);
    for (i = n; i >= 2; i--) {
        lua_rawgeti(L, -1, i);
        lua_rawseti(L, -2, i + 1);
    }
    lua_pushcfunction(L, psi_amiga_embedded_searcher);
    lua_rawseti(L, -2, 2);
    lua_pop(L, 2);
    return 0;
}

/* Stand up enough of psi.* for handle_print / runtime_summary. We
 * skip lua/boot.lua's full sequence (it loads markdown / sched /
 * anthropic / etc. that aren't useful for the eval/print v1) and
 * just create a `psi` global table with the bare minimum, then let
 * require() pull modules on demand from the embedded table. */
static int setup_psi_global(lua_State *L)
{
    /* Create global `psi` and register the host primitives that the
     * normal Lua runtime expects. Amiga networking is implemented by a
     * file-backed bridge: http_stream_begin writes request files into
     * PSI_AMIGA_BRIDGE_DIR, and amigaos/psi-http-bridge.py performs the
     * real HTTPS request on the host side. */
    lua_newtable(L);

    lua_pushstring(L, "0.1.0");
    lua_setfield(L, -2, "_version");

#define PSI_SET(name, fn) do { lua_pushcfunction(L, fn); lua_setfield(L, -2, name); } while (0)
    PSI_SET("version", lfn_version);
    PSI_SET("current_date", lfn_current_date);
    PSI_SET("cwd", lfn_cwd);
    PSI_SET("parent_directory", lfn_parent_directory);
    PSI_SET("read_file", lfn_read_file);
    PSI_SET("file_exists", lfn_file_exists);
    PSI_SET("file_write", lfn_file_write);
    PSI_SET("stdout_write", lfn_stdout_write);
    PSI_SET("sleep_ms", lfn_sleep_ms);
    PSI_SET("session_message_count", lfn_session_message_count);
    PSI_SET("session_messages", lfn_session_messages);
    PSI_SET("session_append", lfn_session_append);
    PSI_SET("session_clear", lfn_session_clear);
    PSI_SET("session_id", lfn_session_id);
    PSI_SET("session_path", lfn_session_path);
    PSI_SET("session_parent_id", lfn_session_parent_id);
    PSI_SET("session_set_id", lfn_session_set_id);
    PSI_SET("session_set_path", lfn_session_set_path);
    PSI_SET("session_set_parent_id", lfn_session_set_parent_id);
    PSI_SET("is_aborted", lfn_is_aborted);
    PSI_SET("json_encode", lfn_json_encode);
    PSI_SET("json_decode", lfn_json_decode);
    PSI_SET("http_post", lfn_http_post);
    PSI_SET("http_stream_begin", lfn_http_stream_begin);
    PSI_SET("http_stream_poll", lfn_http_stream_poll);
    PSI_SET("http_stream_finish", lfn_http_stream_finish);
#undef PSI_SET

    if (luaL_newmetatable(L, PSI_AMIGA_HTTP_MT)) {
        lua_pushcfunction(L, lfn_http_stream_gc);
        lua_setfield(L, -2, "__gc");
    }
    lua_pop(L, 1);

    lua_setglobal(L, "psi");
    if (luaL_dostring(L,
        "psi.embedded_doc = function(name) return nil end\n"
        "psi.embedded_doc_names = function() return {} end\n"
        "psi.amiga_bridge = true\n"
        "psi.amiga_bridge_api_key = function() return 'bridge' end\n"
        "psi.host_tick = function() end\n"
        "psi.process_run = function(cmd) return { output='', status=127, truncated=false } end\n"
        "psi.process_begin = function(cmd) return nil, 'processes are not available on AmigaOS shim' end\n"
        "psi.runtime_info = function() return {\n"
        "  version='0.1.0', ['boot-file']='<embedded>',\n"
        "  ['current-date']=psi.current_date(), ['current-working-directory']=psi.cwd(),\n"
        "  ['session-message-count']=psi.session_message_count(),\n"
        "  primitives={'json_encode','json_decode','http_stream_begin','http_stream_poll','http_stream_finish'}\n"
        "} end\n") != 0) {
        fprintf(stderr, "psi: failed to install Lua stubs: %s\n", lua_tostring(L, -1));
        return 1;
    }
    return 0;
}

/* Pull psi.prompt out of the embedded table and attach it to the
 * `psi` global so handle_print is reachable. */
static int load_prompt_module(lua_State *L)
{
    int rc = luaL_dostring(L,
        "psi.prelude = require('psi.prelude')\n"
        "psi.records = require('psi.records')\n"
        "psi.tools = require('psi.tools')\n"
        "psi.session = require('psi.session')\n"
        "psi.prompt = require('psi.prompt')\n"
    );
    if (rc != 0) {
        fprintf(stderr, "psi: failed to load prompt module: %s\n",
                lua_tostring(L, -1));
        return 1;
    }
    return 0;
}

static int load_runtime_modules(lua_State *L)
{
    int rc = luaL_dostring(L,
        "psi.prelude = require('psi.prelude')\n"
        "psi.records = require('psi.records')\n"
        "psi.ansi = require('psi.ansi')\n"
        "psi.events = require('psi.events')\n"
        "psi.context = require('psi.context')\n"
        "psi.markdown = require('psi.markdown')\n"
        "psi.render = require('psi.render')\n"
        "psi.sched = require('psi.sched')\n"
        "psi.tool_registry = require('psi.tool_registry')\n"
        "psi.tool_shell = require('psi.tool_shell')\n"
        "psi.tools = require('psi.tools')\n"
        "psi.tools.set_active({'read','write','edit','lua'})\n"
        "psi.tools.add_before_hook(function(name)\n"
        "  if name == 'bash' or name == 'grep' or name == 'find' or name == 'ls' then\n"
        "    return psi.tools.cancel('AmigaOS shim does not expose a Unix shell; use read/write/edit/lua tools', name)\n"
        "  end\n"
        "end)\n"
        "psi.session = require('psi.session')\n"
        "psi.prompt = require('psi.prompt')\n"
        "psi.anthropic = require('psi.anthropic')\n"
        "psi.ollama = require('psi.ollama')\n"
        "psi.openrouter = require('psi.openrouter')\n"
        "psi.openai_compat = require('psi.openai_compat')\n"
        "psi.agent = require('psi.agent')\n"
        "psi.modes = require('psi.modes')\n"
        "require('boot')\n"
    );
    if (rc != 0) {
        fprintf(stderr, "psi: failed to load runtime modules: %s\n", lua_tostring(L, -1));
        return 1;
    }
    return 0;
}

static int run_eval(lua_State *L, const char *expr)
{
    char *buf;
    size_t len;
    int rc;

    len = strlen(expr) + 8;
    buf = (char *)malloc(len + 1);
    if (buf == NULL) {
        fprintf(stderr, "psi: out of memory\n");
        return 2;
    }
    sprintf(buf, "return %s", expr);
    rc = luaL_dostring(L, buf);
    free(buf);
    if (rc != 0) {
        lua_settop(L, 0);
        if (luaL_dostring(L, expr) != 0) {
            fprintf(stderr, "psi: eval error: %s\n", lua_tostring(L, -1));
            return 1;
        }
    }
    if (lua_gettop(L) > 0) {
        const char *out = lua_tostring(L, -1);
        if (out != NULL) {
            console_write(out);
            console_write("\n");
        }
    }
    return 0;
}

static int run_print(lua_State *L, const char *text)
{
    if (load_prompt_module(L) != 0) {
        console_write("psi (no Lua prompt module): ");
        console_write(text);
        console_write("\n");
        return 1;
    }
    lua_getglobal(L, "psi");
    lua_getfield(L, -1, "prompt");
    lua_getfield(L, -1, "handle_print");
    if (lua_isfunction(L, -1)) {
        lua_pushstring(L, text != NULL ? text : "");
        if (lua_pcall(L, 1, 1, 0) == 0) {
            const char *out = lua_tostring(L, -1);
            if (out) {
                console_write(out);
                console_write("\n");
            }
            return 0;
        }
        fprintf(stderr, "psi: print failed: %s\n", lua_tostring(L, -1));
        console_write("psi: print failed\n");
        return 1;
    }
    fprintf(stderr, "psi: handle_print not found in psi.prompt\n");
    console_write("psi: handle_print not found in psi.prompt\n");
    return 1;
}

static int run_mode(lua_State *L, const char *mode, const char *payload,
                    const char *session_file, const char *model, int max_tokens)
{
    int ok;
    if (load_runtime_modules(L) != 0) return 1;
    lua_getglobal(L, "psi");
    lua_getfield(L, -1, "modes");
    lua_getfield(L, -1, "run");
    lua_newtable(L);
    lua_pushstring(L, mode); lua_setfield(L, -2, "mode");
    lua_pushstring(L, payload ? payload : ""); lua_setfield(L, -2, "payload");
    if (session_file != NULL) { lua_pushstring(L, session_file); lua_setfield(L, -2, "session_file"); }
    if (model != NULL) { lua_pushstring(L, model); lua_setfield(L, -2, "model"); }
    lua_pushinteger(L, max_tokens > 0 ? max_tokens : 4096); lua_setfield(L, -2, "max_tokens");
    lua_pushinteger(L, 12); lua_setfield(L, -2, "keep_recent");
    if (lua_pcall(L, 1, 1, 0) != 0) {
        fprintf(stderr, "psi: mode failed: %s\n", lua_tostring(L, -1));
        console_write("psi: mode failed: ");
        console_write(lua_tostring(L, -1));
        console_write("\n");
        return 1;
    }
    ok = lua_toboolean(L, -1);
    lua_pop(L, 3);
    if (!ok) {
        console_write("psi: ");
        console_write(mode ? mode : "mode");
        console_write(" failed; bridge status: ");
        console_write(g_last_bridge_error[0] ? g_last_bridge_error : "no bridge request attempted");
        console_write("\n");
    }
    return ok ? 0 : 1;
}

static int run_bridge_probe(void)
{
    const char *used = NULL;
    if (write_bridge_probe_any(&used)) {
        console_write("psi: bridge probe ok: ");
        console_write(used ? used : "?");
        console_write("\n");
        return 0;
    }
    console_write("psi: bridge probe failed. Tried bridge:, DH1:, DH0:bridge, dh0:bridge\n");
    return 1;
}

int main(int argc, char **argv)
{
    lua_State *L;
    int rc;
    char *mode_copy = NULL;
    char *arg_copy = NULL;
    char *session_copy = NULL;
    char *model_copy = NULL;
    int max_tokens = 4096;
    int i;

    if (argc < 2) { usage(); return 1; }

    if (strcmp(argv[1], "--version") == 0) {
        console_write("psi 0.1.0 (AmigaOS m68k, Lua ");
        console_write(LUA_VERSION);
        console_write(", embedded modules)\n");
        return 0;
    }
    if (strcmp(argv[1], "--probe-bridge") == 0) {
        return run_bridge_probe();
    }
    if (argc < 3) { usage(); return 1; }

    /* vbcc's AmigaOS startup parses the DOS command line into argv
     * but the storage is NOT stable across arbitrary library
     * activity — opening dos.library / Lua's io / etc. reuses the
     * scratch the parser wrote into, so by the time we call
     * run_print(argv[2]) the C string at that address is already
     * overwritten. Snapshot to heap before any other allocation.
     * Same defensive copy in haiku/JOURNEY.md §POSIX-args-on-DOS. */
    mode_copy = psi_strdup(argv[1]);
    arg_copy = psi_strdup(argv[2]);
    for (i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--session") == 0 && i + 1 < argc) {
            session_copy = psi_strdup(argv[++i]);
        } else if (strcmp(argv[i], "--model") == 0 && i + 1 < argc) {
            model_copy = psi_strdup(argv[++i]);
        } else if (strcmp(argv[i], "--max-tokens") == 0 && i + 1 < argc) {
            max_tokens = atoi(argv[++i]);
        }
    }
    if (mode_copy == NULL || arg_copy == NULL) {
        fprintf(stderr, "psi: out of memory copying argv\n");
        free(mode_copy); free(arg_copy); free(session_copy); free(model_copy);
        return 2;
    }

    L = luaL_newstate();
    if (L == NULL) {
        fprintf(stderr, "psi: luaL_newstate failed\n");
        free(mode_copy); free(arg_copy);
        return 2;
    }
    luaL_openlibs(L);
    psi_amiga_register_searcher(L);
    if (setup_psi_global(L) != 0) {
        lua_close(L);
        free(mode_copy); free(arg_copy);
        return 2;
    }

    if (strcmp(mode_copy, "--eval") == 0) {
        rc = run_eval(L, arg_copy);
    } else if (strcmp(mode_copy, "--print") == 0) {
        rc = run_print(L, arg_copy);
    } else if (strcmp(mode_copy, "--agent") == 0) {
        rc = run_mode(L, "agent", arg_copy, session_copy, model_copy, max_tokens);
    } else {
        usage();
        rc = 1;
    }

    /* Under vamos, Lua's exit-time close of standard/file handles can
     * trip DosLibrary.Close on an already-invalid emulated handle after
     * otherwise successful runs. This process is short-lived; let the
     * OS reclaim the Lua heap on exit instead of walking finalizers. */
    (void)L;
    session_clear_c();
    free(g_session.id);
    free(g_session.parent_id);
    free(g_session.path);
    free(mode_copy);
    free(arg_copy);
    free(session_copy);
    free(model_copy);
    return rc;
}
