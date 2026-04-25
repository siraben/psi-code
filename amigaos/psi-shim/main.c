/* psi-amigaos: minimal Lua-only entry point.
 *
 * v1 scope:
 *   --eval EXPR   evaluate a Lua expression, print the result, exit
 *   --print TEXT  call psi.prompt.handle_print(TEXT), print, exit
 *
 * No HTTP. No TUI. No provider. No tools that touch the network or
 * fork processes. The point is to prove psi's Lua surface runs
 * end-to-end on m68k AmigaOS under vamos.
 *
 * The C side is deliberately tiny so the only platform-specific
 * code is here. Everything else is portable Lua loaded via
 * package.path. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

static void usage(void)
{
    fprintf(stderr,
            "usage: psi --eval EXPR\n"
            "       psi --print TEXT\n"
            "       psi --version\n");
}

static int run_eval(lua_State *L, const char *expr)
{
    /* `return ` prefix lets short expressions like `1+2+3` print. */
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
        /* The `return EXPR` form fails on statement-style input
         * like `local t={}; ...; return ...`. Re-try as a chunk;
         * any explicit `return` in the chunk still produces a
         * top-of-stack value we can print. */
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
    /* Hand off to psi.prompt.handle_print which formats a banner +
     * the user's text. Robust against psi.prompt being unavailable
     * (we may run before psi.* is loaded; fall through to plain
     * print in that case). */
    lua_getglobal(L, "psi");
    if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "prompt");
        if (lua_istable(L, -1)) {
            lua_getfield(L, -1, "handle_print");
            if (lua_isfunction(L, -1)) {
                lua_pushstring(L, text);
                if (lua_pcall(L, 1, 1, 0) == 0) {
                    const char *out = lua_tostring(L, -1);
                    if (out) {
                        fputs(out, stdout);
                        fputc('\n', stdout);
                    }
                    return 0;
                }
                fprintf(stderr, "psi: print failed: %s\n",
                        lua_tostring(L, -1));
                return 1;
            }
        }
    }
    /* Fallback: just print. */
    printf("psi (no Lua bootstrap): %s\n", text);
    return 0;
}

int main(int argc, char **argv)
{
    lua_State *L;
    int rc;

    if (argc < 2) {
        usage();
        return 1;
    }

    if (strcmp(argv[1], "--version") == 0) {
        printf("psi 0.1.0 (AmigaOS m68k, Lua %s)\n", LUA_VERSION);
        return 0;
    }
    if (argc < 3) {
        usage();
        return 1;
    }

    L = luaL_newstate();
    if (L == NULL) {
        fprintf(stderr, "psi: luaL_newstate failed\n");
        return 2;
    }
    luaL_openlibs(L);

    if (strcmp(argv[1], "--eval") == 0) {
        rc = run_eval(L, argv[2]);
    } else if (strcmp(argv[1], "--print") == 0) {
        rc = run_print(L, argv[2]);
    } else {
        usage();
        rc = 1;
    }

    lua_close(L);
    return rc;
}
