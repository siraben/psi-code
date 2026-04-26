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

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "psi/embedded_lua.h"

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

static void usage(void)
{
    fprintf(stderr,
            "usage: psi --eval EXPR\n"
            "       psi --print TEXT\n"
            "       psi --version\n");
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
    /* Create global `psi` table with a stub `current_date`,
     * `read_file`, `cwd`, `version`, `parent_directory`, etc. so
     * lua/psi/prompt.lua's M.system_prompt() / handle_print() can
     * run. Real values where possible; reasonable stubs otherwise.
     *
     * The C-side host on Linux registers ~50 such primitives via
     * vm.c's PSI_REG block; we only need a small subset for the
     * Phase-7 demo. */
    lua_newtable(L);

    lua_pushstring(L, "0.1.0");
    lua_setfield(L, -2, "_version");

    lua_pushcclosure(L, 0, 0); /* placeholder */
    lua_pop(L, 1);

    /* version() */
    {
        const char *src =
            "psi.version = function() return '0.1.0 (AmigaOS)' end\n"
            "psi.current_date = function() return '2026-04-25' end\n"
            "psi.cwd = function() return 'SYS:' end\n"
            "psi.parent_directory = function(p) return p end\n"
            "psi.read_file = function(p) return nil end\n"
            "psi.file_exists = function(p) return false end\n"
            "psi.file_write = function(p,c) return false end\n"
            "psi.session_message_count = function() return 0 end\n"
            "psi.session_messages = function() return {} end\n"
            "psi.session_id = function() return '' end\n"
            "psi.session_path = function() return '' end\n"
            "psi.session_set_id = function(id) end\n"
            "psi.session_set_path = function(p) return false end\n"
            "psi.session_append = function() end\n"
            "psi.is_aborted = function() return false end\n"
            "psi.json_encode = function(t) return '{}' end\n"
            "psi.json_decode = function(s) return nil end\n"
            "psi.embedded_doc = function(name) return nil end\n"
            "psi.embedded_doc_names = function() return {} end\n"
            "psi.runtime_info = function() return {\n"
            "  version='0.1.0',\n"
            "  ['boot-file']='<embedded>',\n"
            "  ['current-date']='2026-04-25',\n"
            "  ['current-working-directory']='SYS:',\n"
            "  ['session-message-count']=0,\n"
            "  primitives={'read_file','file_exists','json_encode'}\n"
            "} end\n";

        /* Set the table we built as global `psi` first, then run the
         * stub-installer chunk against it. */
        lua_setglobal(L, "psi");
        if (luaL_dostring(L, src) != 0) {
            fprintf(stderr, "psi: failed to install stubs: %s\n",
                    lua_tostring(L, -1));
            return 1;
        }
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
            fputs(out, stdout);
            fputc('\n', stdout);
        }
    }
    return 0;
}

static int run_print(lua_State *L, const char *text)
{
    if (load_prompt_module(L) != 0) {
        printf("psi (no Lua prompt module): %s\n", text);
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
                fputs(out, stdout);
                fputc('\n', stdout);
            }
            return 0;
        }
        fprintf(stderr, "psi: print failed: %s\n", lua_tostring(L, -1));
        return 1;
    }
    fprintf(stderr, "psi: handle_print not found in psi.prompt\n");
    return 1;
}

int main(int argc, char **argv)
{
    lua_State *L;
    int rc;
    char *mode_copy = NULL;
    char *arg_copy = NULL;

    if (argc < 2) { usage(); return 1; }

    if (strcmp(argv[1], "--version") == 0) {
        printf("psi 0.1.0 (AmigaOS m68k, Lua %s, embedded modules)\n",
               LUA_VERSION);
        return 0;
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
    if (mode_copy == NULL || arg_copy == NULL) {
        fprintf(stderr, "psi: out of memory copying argv\n");
        free(mode_copy); free(arg_copy);
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
    } else {
        usage();
        rc = 1;
    }

    lua_close(L);
    free(mode_copy);
    free(arg_copy);
    return rc;
}
