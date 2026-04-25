/* psi9 — minimal psi runtime for 9front.
 *
 * Usage:
 *     psi9 -a PROMPT               # one-shot agent turn
 *     psi9 -e LUA_EXPR             # evaluate Lua expression
 *     psi9 FILE                    # run Lua script
 *
 * The C layer provides:
 *   - Lua 5.4 state (via linked liblua.a)
 *   - global `psi.http_post(url, body_string, header_lines_table)`
 *     → returns (status_code:number, response_body:string)
 *   - `psi.getenv(name)` → string or nil
 *   - a boot Lua script embedded as the BOOT string below
 *
 * The agent-turn logic lives in Lua (see BOOT): it constructs the
 * Anthropic request JSON, POSTs, parses the response, returns the
 * assistant's reply text. That's all psi needs for the MVP `--agent`
 * path. Tool calls, sessions, and full agent loop come later.
 */

#include <u.h>
#include <libc.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* From http_webfs.c */
extern int psi_http_post(
	const char *url,
	const char *const *header_lines, int header_count,
	const char *body, int body_len,
	long *status_code, char **response_body);

/* Convert a Lua table of strings at index idx into a C array.
 * Caller must free the array (not the strings — they're owned by Lua). */
static const char **
table_to_cstr_array(lua_State *L, int idx, int *n_out)
{
	int i, n;
	const char **arr;
	n = (int)luaL_len(L, idx);
	arr = malloc(sizeof(*arr) * (n + 1));
	if(arr == nil) return nil;
	for(i = 0; i < n; i++){
		lua_geti(L, idx, i + 1);
		arr[i] = lua_tostring(L, -1);
		lua_pop(L, 1);
	}
	arr[n] = nil;
	*n_out = n;
	return arr;
}

/* psi.http_post(url, body, headers_table) →
 *   (status:number, response:string)  on success,
 *   (nil, error_string) on transport failure. */
static int
l_http_post(lua_State *L)
{
	const char *url, *body;
	size_t body_len;
	const char **headers = nil;
	int header_count = 0;
	long status = 0;
	char *resp = nil;
	int rc;

	url = luaL_checkstring(L, 1);
	body = luaL_checklstring(L, 2, &body_len);
	if(!lua_isnoneornil(L, 3)){
		luaL_checktype(L, 3, LUA_TTABLE);
		headers = table_to_cstr_array(L, 3, &header_count);
		if(headers == nil) return luaL_error(L, "oom");
	}
	rc = psi_http_post(url, headers, header_count,
		body, (int)body_len, &status, &resp);
	free((void *)headers);
	if(rc != 0){
		lua_pushnil(L);
		lua_pushstring(L, "http_post failed");
		if(resp) free(resp);
		return 2;
	}
	lua_pushinteger(L, status);
	lua_pushlstring(L, resp ? resp : "", resp ? strlen(resp) : 0);
	free(resp);
	return 2;
}

/* psi.getenv("NAME") → string or nil */
static int
l_getenv(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);
	char *v = getenv(name);
	if(v == nil || *v == '\0'){ lua_pushnil(L); return 1; }
	lua_pushstring(L, v);
	free(v);
	return 1;
}

static int
l_print(lua_State *L)
{
	int i, n = lua_gettop(L);
	for(i = 1; i <= n; i++){
		size_t len;
		const char *s = luaL_tolstring(L, i, &len);
		write(1, s, len);
		lua_pop(L, 1);
	}
	write(1, "\n", 1);
	return 0;
}

/* Embedded bootstrap Lua.  Parses Anthropic Messages API responses
 * with a trivial ad-hoc JSON string extractor — sufficient for MVP,
 * replaced by libjson bindings in a later phase.
 *
 * The script expects the caller to set `psi.prompt` and `psi.model`,
 * then calls agent_turn which returns the reply text or raises.
 */
static const char *BOOT =
"psi.model = psi.model or 'claude-haiku-4-5'\n"
"psi.max_tokens = psi.max_tokens or 128\n"
"\n"
"local function json_escape(s)\n"
"  return (s:gsub('\\\\', '\\\\\\\\'):gsub('\"', '\\\\\"')\n"
"          :gsub('\\n', '\\\\n'):gsub('\\r', '\\\\r')\n"
"          :gsub('\\t', '\\\\t'))\n"
"end\n"
"\n"
"function psi.agent_turn(prompt)\n"
"  local key = psi.getenv('ANTHROPIC_API_KEY')\n"
"  if not key or key == '' then error('ANTHROPIC_API_KEY not set') end\n"
"  local body = string.format(\n"
"    '{\"model\":\"%s\",\"max_tokens\":%d,'\n"
"    ..'\"messages\":[{\"role\":\"user\",\"content\":\"%s\"}]}',\n"
"    psi.model, psi.max_tokens, json_escape(prompt))\n"
"  local headers = {\n"
"    'anthropic-version: 2023-06-01',\n"
"    'x-api-key: ' .. key,\n"
"  }\n"
"  local status, resp = psi.http_post(\n"
"    'https://api.anthropic.com/v1/messages', body, headers)\n"
"  if not status then error('http: ' .. tostring(resp)) end\n"
"  -- webfs sometimes reports status=0 even on success; accept any\n"
"  -- response that has a 'content' block and fail only if we see an\n"
"  -- Anthropic error object.\n"
"  if resp == nil or resp == '' then\n"
"    error(string.format('http status %d: empty', status))\n"
"  end\n"
"  if resp:match('\"type\"%s*:%s*\"error\"') then\n"
"    error('api: ' .. resp:sub(1, 300))\n"
"  end\n"
"  -- Trivial extractor for the first assistant text block.\n"
"  local text = resp:match('\"text\"%s*:%s*\"(.-)\"')\n"
"  if not text then error('no text in response: ' .. resp:sub(1, 200)) end\n"
"  -- Unescape the common JSON escapes.\n"
"  text = text:gsub('\\\\\"', '\"'):gsub('\\\\n', '\\n')\n"
"             :gsub('\\\\t', '\\t'):gsub('\\\\\\\\', '\\\\')\n"
"  return text\n"
"end\n";

static int
run_boot(lua_State *L)
{
	/* Create `psi` table and install bindings. */
	lua_newtable(L);
	lua_pushcfunction(L, l_http_post);
	lua_setfield(L, -2, "http_post");
	lua_pushcfunction(L, l_getenv);
	lua_setfield(L, -2, "getenv");
	lua_setglobal(L, "psi");

	/* Override print so it goes straight to stdout (not stderr). */
	lua_pushcfunction(L, l_print);
	lua_setglobal(L, "print");

	if(luaL_loadbuffer(L, BOOT, strlen(BOOT), "boot") != LUA_OK
	 || lua_pcall(L, 0, 0, 0) != LUA_OK){
		fprint(2, "boot: %s\n", lua_tostring(L, -1));
		return -1;
	}
	return 0;
}

static void
usage(void)
{
	fprint(2, "usage: psi9 -a PROMPT | -e EXPR | FILE\n");
	exits("usage");
}

void
main(int argc, char **argv)
{
	lua_State *L;
	int mode = 0;   /* 1=agent 2=eval 3=file */
	const char *arg = nil;

	if(argc < 2) usage();
	if(strcmp(argv[1], "-a") == 0 && argc >= 3){ mode = 1; arg = argv[2]; }
	else if(strcmp(argv[1], "-e") == 0 && argc >= 3){ mode = 2; arg = argv[2]; }
	else { mode = 3; arg = argv[1]; }

	L = luaL_newstate();
	if(L == nil) sysfatal("luaL_newstate");
	luaL_openlibs(L);

	if(run_boot(L) < 0){ lua_close(L); exits("boot"); }

	switch(mode){
	case 1: {
		lua_getglobal(L, "psi");
		lua_getfield(L, -1, "agent_turn");
		lua_pushstring(L, arg);
		if(lua_pcall(L, 1, 1, 0) != LUA_OK){
			fprint(2, "psi9: %s\n", lua_tostring(L, -1));
			lua_close(L);
			exits("agent");
		}
		{ size_t n;
		  const char *s = lua_tolstring(L, -1, &n);
		  write(1, s, n); write(1, "\n", 1); }
		break;
	}
	case 2:
		if(luaL_dostring(L, arg) != LUA_OK){
			fprint(2, "eval: %s\n", lua_tostring(L, -1));
			lua_close(L); exits("eval");
		}
		break;
	case 3:
		if(luaL_dofile(L, arg) != LUA_OK){
			fprint(2, "file: %s\n", lua_tostring(L, -1));
			lua_close(L); exits("file");
		}
		break;
	}
	lua_close(L);
	exits(nil);
}
