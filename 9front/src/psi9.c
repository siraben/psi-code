/* psi9 — Claude coding agent for 9front.
 *
 * Usage:
 *     psi9 [-m MODEL] [-t MAXTOK] [-s SESSION] [-p SYSTEM_PROMPT] \
 *          [-a PROMPT | -e LUA_EXPR | FILE]
 *
 * Modes:
 *     -a PROMPT     one-shot (or multi-turn with -s) agent turn;
 *                   prints the reply text.
 *     -e LUA_EXPR   evaluate a Lua expression.
 *     FILE          run a Lua script.
 *
 * Options:
 *     -s FILE       session JSONL file. Previous turns are replayed.
 *     -m MODEL      override the model (default claude-haiku-4-5).
 *     -t N          override max_tokens (default 1024).
 *     -p TEXT       system prompt prepended to every turn.
 *
 * The C layer provides these Lua globals under `psi`:
 *
 *     http_post(url, body, headers_table) -> (status, resp_body)
 *     json_decode(string) -> lua value
 *     json_encode(value)  -> string
 *     file_read(path)     -> string or nil
 *     file_write(path, s) -> bool          (truncates)
 *     file_append(path,s) -> bool
 *     file_exists(path)   -> bool
 *     getenv(name)        -> string or nil
 *     current_date()      -> ISO 8601 UTC timestamp
 *     stderr(string)      -> write to fd 2
 *     stdout_write(s)     -> write to fd 1
 *     version             -> string constant
 *
 * Everything else (agent loop, session replay, message construction,
 * response parsing) lives in the embedded Lua BOOT script below.
 */

#include <u.h>
#include <libc.h>
#include <json.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

extern int psi_http_post(
	const char *url,
	const char *const *headers, int nheaders,
	const char *body, int body_len,
	long *status_out, char **resp_out);

/* -------------------- Lua <-> JSON -------------------- */

/* Push a JSON tree (from libjson) onto the Lua stack. */
static void
push_json(lua_State *L, JSON *j)
{
	JSONEl *el;
	int i;
	if(j == nil){ lua_pushnil(L); return; }
	switch(j->t){
	case JSONNull:   lua_pushnil(L); return;
	case JSONBool:   lua_pushboolean(L, j->n != 0); return;
	case JSONNumber: lua_pushnumber(L, j->n); return;
	case JSONString: lua_pushstring(L, j->s); return;
	case JSONArray:
		lua_newtable(L);
		i = 1;
		for(el = j->first; el != nil; el = el->next){
			push_json(L, el->val);
			lua_seti(L, -2, i++);
		}
		return;
	case JSONObject:
		lua_newtable(L);
		for(el = j->first; el != nil; el = el->next){
			push_json(L, el->val);
			lua_setfield(L, -2, el->name);
		}
		return;
	}
	lua_pushnil(L);
}

static int
l_json_decode(lua_State *L)
{
	const char *s = luaL_checkstring(L, 1);
	JSON *j;
	char *mut = strdup(s);    /* jsonparse mutates */
	if(mut == nil) return luaL_error(L, "oom");
	j = jsonparse(mut);
	free(mut);
	if(j == nil){ lua_pushnil(L); lua_pushstring(L, "parse error"); return 2; }
	push_json(L, j);
	jsonfree(j);
	return 1;
}

/* JSON emitter: write to a growing buffer. */
struct emitbuf { char *buf; long cap, len; };

static int
emit_grow(struct emitbuf *b, long need)
{
	char *p;
	long c = b->cap ? b->cap : 256;
	while(c - b->len < need) c *= 2;
	if(c == b->cap) return 0;
	p = realloc(b->buf, c);
	if(p == nil) return -1;
	b->buf = p; b->cap = c;
	return 0;
}

static int
emit_putc(struct emitbuf *b, char c)
{
	if(emit_grow(b, 1) < 0) return -1;
	b->buf[b->len++] = c;
	return 0;
}

static int
emit_puts(struct emitbuf *b, const char *s, long n)
{
	if(n < 0) n = strlen(s);
	if(emit_grow(b, n) < 0) return -1;
	memcpy(b->buf + b->len, s, n); b->len += n;
	return 0;
}

static void
emit_escape_string(struct emitbuf *b, const char *s, long n)
{
	long i;
	if(n < 0) n = strlen(s);
	emit_putc(b, '"');
	for(i = 0; i < n; i++){
		unsigned char c = (unsigned char)s[i];
		switch(c){
		case '"':  emit_puts(b, "\\\"", 2); break;
		case '\\': emit_puts(b, "\\\\", 2); break;
		case '\b': emit_puts(b, "\\b", 2); break;
		case '\f': emit_puts(b, "\\f", 2); break;
		case '\n': emit_puts(b, "\\n", 2); break;
		case '\r': emit_puts(b, "\\r", 2); break;
		case '\t': emit_puts(b, "\\t", 2); break;
		default:
			if(c < 0x20){
				char tmp[8];
				snprint(tmp, sizeof tmp, "\\u%04x", c);
				emit_puts(b, tmp, 6);
			} else {
				emit_putc(b, (char)c);
			}
		}
	}
	emit_putc(b, '"');
}

static int
emit_value(lua_State *L, struct emitbuf *b, int idx, int depth)
{
	char tmp[64];
	if(depth > 32) return luaL_error(L, "json depth");
	idx = lua_absindex(L, idx);
	switch(lua_type(L, idx)){
	case LUA_TNIL:
		emit_puts(b, "null", 4); return 0;
	case LUA_TBOOLEAN:
		emit_puts(b, lua_toboolean(L, idx) ? "true" : "false", -1);
		return 0;
	case LUA_TNUMBER:
		if(lua_isinteger(L, idx))
			snprint(tmp, sizeof tmp, "%lld",
				(long long)lua_tointeger(L, idx));
		else
			snprint(tmp, sizeof tmp, "%.17g", lua_tonumber(L, idx));
		emit_puts(b, tmp, -1);
		return 0;
	case LUA_TSTRING: {
		size_t n; const char *s = lua_tolstring(L, idx, &n);
		emit_escape_string(b, s, n);
		return 0;
	}
	case LUA_TTABLE: {
		/* Array if keys 1..n are all set. Else object. */
		lua_Integer len = luaL_len(L, idx);
		int is_array = len > 0;
		if(is_array){
			lua_Integer i;
			for(i = 1; i <= len; i++){
				lua_geti(L, idx, i);
				if(lua_isnil(L, -1)){ is_array = 0; lua_pop(L,1); break; }
				lua_pop(L, 1);
			}
		}
		if(is_array){
			lua_Integer i;
			emit_putc(b, '[');
			for(i = 1; i <= len; i++){
				if(i > 1) emit_putc(b, ',');
				lua_geti(L, idx, i);
				emit_value(L, b, -1, depth+1);
				lua_pop(L, 1);
			}
			emit_putc(b, ']');
		} else {
			int first = 1;
			emit_putc(b, '{');
			lua_pushnil(L);
			while(lua_next(L, idx)){
				if(lua_type(L, -2) != LUA_TSTRING){
					lua_pop(L, 1); continue;
				}
				if(!first) emit_putc(b, ',');
				first = 0;
				{ size_t kn; const char *ks = lua_tolstring(L, -2, &kn);
				  emit_escape_string(b, ks, kn); }
				emit_putc(b, ':');
				emit_value(L, b, -1, depth+1);
				lua_pop(L, 1);
			}
			emit_putc(b, '}');
		}
		return 0;
	}
	default:
		return luaL_error(L, "json: unsupported type %s",
			lua_typename(L, lua_type(L, idx)));
	}
}

static int
l_json_encode(lua_State *L)
{
	struct emitbuf b;
	b.buf = nil; b.cap = 0; b.len = 0;
	emit_value(L, &b, 1, 0);
	lua_pushlstring(L, b.buf, b.len);
	free(b.buf);
	return 1;
}

/* -------------------- HTTP -------------------- */

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

/* -------------------- Misc -------------------- */

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
l_current_date(lua_State *L)
{
	/* UTC ISO 8601: YYYY-MM-DDThh:mm:ssZ */
	Tm tm;
	char buf[32];
	tmtime(&tm, time(nil), nil);
	snprint(buf, sizeof buf, "%04d-%02d-%02dT%02d:%02d:%02dZ",
		tm.year + 1900, tm.mon + 1, tm.mday,
		tm.hour, tm.min, tm.sec);
	lua_pushstring(L, buf);
	return 1;
}

static int
l_stderr(lua_State *L)
{
	size_t n;
	const char *s = luaL_checklstring(L, 1, &n);
	write(2, s, n);
	return 0;
}

static int
l_stdout_write(lua_State *L)
{
	size_t n;
	const char *s = luaL_checklstring(L, 1, &n);
	write(1, s, n);
	return 0;
}

/* -------------------- File I/O -------------------- */

static int
l_file_read(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	int fd, n;
	char *buf = nil;
	long cap = 0, len = 0;
	fd = open(path, OREAD);
	if(fd < 0){ lua_pushnil(L); return 1; }
	for(;;){
		if(len + 8192 + 1 > cap){
			cap = cap == 0 ? 16384 : cap * 2;
			buf = realloc(buf, cap);
			if(buf == nil){ close(fd); lua_pushnil(L); return 1; }
		}
		n = read(fd, buf + len, cap - len - 1);
		if(n <= 0) break;
		len += n;
	}
	close(fd);
	if(buf == nil){ lua_pushlstring(L, "", 0); return 1; }
	buf[len] = 0;
	lua_pushlstring(L, buf, len);
	free(buf);
	return 1;
}

static int
l_file_write(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	size_t n;
	const char *data = luaL_checklstring(L, 2, &n);
	int fd, w;
	fd = create(path, OWRITE|OTRUNC, 0666);
	if(fd < 0){ lua_pushboolean(L, 0); return 1; }
	w = write(fd, data, n);
	close(fd);
	lua_pushboolean(L, w == (int)n);
	return 1;
}

static int
l_file_append(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	size_t n;
	const char *data = luaL_checklstring(L, 2, &n);
	int fd, w;
	fd = open(path, OWRITE);
	if(fd < 0){
		fd = create(path, OWRITE, 0666);
		if(fd < 0){ lua_pushboolean(L, 0); return 1; }
	} else {
		seek(fd, 0, 2);
	}
	w = write(fd, data, n);
	close(fd);
	lua_pushboolean(L, w == (int)n);
	return 1;
}

static int
l_file_exists(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	Dir *d = dirstat(path);
	if(d == nil){ lua_pushboolean(L, 0); return 1; }
	free(d);
	lua_pushboolean(L, 1);
	return 1;
}

/* -------------------- Embedded bootstrap Lua -------------------- */

static const char *BOOT =
"-- psi9 boot. Defines psi.agent_turn using the host bindings.\n"
"psi.model = psi.model or 'claude-haiku-4-5'\n"
"psi.max_tokens = psi.max_tokens or 1024\n"
"\n"
"function psi.session_load(path)\n"
"  local msgs = {}\n"
"  if not path or not psi.file_exists(path) then return msgs end\n"
"  local raw = psi.file_read(path) or ''\n"
"  for line in raw:gmatch('[^\\n]+') do\n"
"    local ok, obj = pcall(psi.json_decode, line)\n"
"    if ok and type(obj) == 'table' and obj.role and obj.content then\n"
"      msgs[#msgs+1] = obj\n"
"    end\n"
"  end\n"
"  return msgs\n"
"end\n"
"\n"
"function psi.session_append(path, role, content)\n"
"  if not path then return end\n"
"  local line = psi.json_encode({\n"
"    role = role, content = content, ts = psi.current_date(),\n"
"  }) .. '\\n'\n"
"  psi.file_append(path, line)\n"
"end\n"
"\n"
"function psi.build_request(messages, system_prompt)\n"
"  local req = {\n"
"    model = psi.model,\n"
"    max_tokens = psi.max_tokens,\n"
"    messages = messages,\n"
"  }\n"
"  if system_prompt and system_prompt ~= '' then\n"
"    req.system = system_prompt\n"
"  end\n"
"  return psi.json_encode(req)\n"
"end\n"
"\n"
"function psi.reply_text(resp)\n"
"  if type(resp) ~= 'table' or type(resp.content) ~= 'table' then\n"
"    return nil\n"
"  end\n"
"  local parts = {}\n"
"  for _, blk in ipairs(resp.content) do\n"
"    if type(blk) == 'table' and blk.type == 'text' and blk.text then\n"
"      parts[#parts+1] = blk.text\n"
"    end\n"
"  end\n"
"  return table.concat(parts, '')\n"
"end\n"
"\n"
"function psi.agent_turn(prompt, session_path, system_prompt)\n"
"  local key = psi.getenv('ANTHROPIC_API_KEY')\n"
"  if not key or key == '' then\n"
"    error('ANTHROPIC_API_KEY not set')\n"
"  end\n"
"  local messages = psi.session_load(session_path)\n"
"  local api_msgs = {}\n"
"  for _, m in ipairs(messages) do\n"
"    api_msgs[#api_msgs+1] = { role = m.role, content = m.content }\n"
"  end\n"
"  api_msgs[#api_msgs+1] = { role = 'user', content = prompt }\n"
"  local body = psi.build_request(api_msgs, system_prompt)\n"
"  local headers = {\n"
"    'anthropic-version: 2023-06-01',\n"
"    'x-api-key: ' .. key,\n"
"  }\n"
"  local status, resp = psi.http_post(\n"
"    'https://api.anthropic.com/v1/messages', body, headers)\n"
"  if not status then error('http: ' .. tostring(resp)) end\n"
"  if resp == nil or resp == '' then\n"
"    error(string.format('empty http response (status %d)', status))\n"
"  end\n"
"  local parsed = psi.json_decode(resp)\n"
"  if type(parsed) == 'table' and parsed.type == 'error' then\n"
"    error('api: ' .. (parsed.error and parsed.error.message or resp:sub(1,200)))\n"
"  end\n"
"  local text = psi.reply_text(parsed)\n"
"  if not text or text == '' then\n"
"    error('no text in response: ' .. resp:sub(1, 300))\n"
"  end\n"
"  psi.session_append(session_path, 'user', prompt)\n"
"  psi.session_append(session_path, 'assistant', text)\n"
"  return text, parsed\n"
"end\n";

static int
run_boot(lua_State *L)
{
	lua_newtable(L);
	lua_pushcfunction(L, l_http_post);    lua_setfield(L, -2, "http_post");
	lua_pushcfunction(L, l_json_decode);  lua_setfield(L, -2, "json_decode");
	lua_pushcfunction(L, l_json_encode);  lua_setfield(L, -2, "json_encode");
	lua_pushcfunction(L, l_getenv);       lua_setfield(L, -2, "getenv");
	lua_pushcfunction(L, l_current_date); lua_setfield(L, -2, "current_date");
	lua_pushcfunction(L, l_stderr);       lua_setfield(L, -2, "stderr");
	lua_pushcfunction(L, l_stdout_write); lua_setfield(L, -2, "stdout_write");
	lua_pushcfunction(L, l_file_read);    lua_setfield(L, -2, "file_read");
	lua_pushcfunction(L, l_file_write);   lua_setfield(L, -2, "file_write");
	lua_pushcfunction(L, l_file_append);  lua_setfield(L, -2, "file_append");
	lua_pushcfunction(L, l_file_exists);  lua_setfield(L, -2, "file_exists");
	lua_pushstring(L, "0.1.0-9front");    lua_setfield(L, -2, "version");
	lua_setglobal(L, "psi");

	if(luaL_loadbuffer(L, BOOT, strlen(BOOT), "boot") != LUA_OK
	 || lua_pcall(L, 0, 0, 0) != LUA_OK){
		fprint(2, "boot: %s\n", lua_tostring(L, -1));
		return -1;
	}
	return 0;
}

/* -------------------- main / CLI -------------------- */

static void
usage(void)
{
	fprint(2, "usage: psi9 [-m MODEL] [-t N] [-s SESSION] [-p SYSTEM] "
		"(-a PROMPT | -e EXPR | FILE)\n");
	exits("usage");
}

void
main(int argc, char **argv)
{
	lua_State *L;
	int i;
	const char *prompt = nil, *expr = nil, *file = nil;
	const char *model = nil, *session = nil, *sysprompt = nil;
	long max_tokens = 0;
	int mode = 0;  /* 1=agent 2=eval 3=file */

	for(i = 1; i < argc; i++){
		const char *a = argv[i];
		if(strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) usage();
		else if(strcmp(a, "-v") == 0 || strcmp(a, "--version") == 0){
			print("psi9 0.1.0-9front\n"); exits(nil);
		}
		else if(strcmp(a, "-a") == 0 && i+1 < argc){ mode = 1; prompt = argv[++i]; }
		else if(strcmp(a, "-e") == 0 && i+1 < argc){ mode = 2; expr   = argv[++i]; }
		else if(strcmp(a, "-m") == 0 && i+1 < argc){ model  = argv[++i]; }
		else if(strcmp(a, "-t") == 0 && i+1 < argc){ max_tokens = strtol(argv[++i], nil, 10); }
		else if(strcmp(a, "-s") == 0 && i+1 < argc){ session = argv[++i]; }
		else if(strcmp(a, "-p") == 0 && i+1 < argc){ sysprompt = argv[++i]; }
		else if(a[0] != '-' && mode == 0){ mode = 3; file = a; }
		else { fprint(2, "unknown: %s\n", a); usage(); }
	}
	if(mode == 0) usage();

	L = luaL_newstate();
	if(L == nil) sysfatal("luaL_newstate");
	luaL_openlibs(L);

	if(run_boot(L) < 0){ lua_close(L); exits("boot"); }

	lua_getglobal(L, "psi");
	if(model){
		lua_pushstring(L, model);
		lua_setfield(L, -2, "model");
	}
	if(max_tokens > 0){
		lua_pushinteger(L, max_tokens);
		lua_setfield(L, -2, "max_tokens");
	}
	lua_pop(L, 1);

	switch(mode){
	case 1: {
		lua_getglobal(L, "psi");
		lua_getfield(L, -1, "agent_turn");
		lua_pushstring(L, prompt);
		if(session) lua_pushstring(L, session); else lua_pushnil(L);
		if(sysprompt) lua_pushstring(L, sysprompt); else lua_pushnil(L);
		if(lua_pcall(L, 3, 1, 0) != LUA_OK){
			fprint(2, "psi9: %s\n", lua_tostring(L, -1));
			lua_close(L);
			exits("agent");
		}
		{ size_t n; const char *s = lua_tolstring(L, -1, &n);
		  write(1, s, n); write(1, "\n", 1); }
		break;
	}
	case 2:
		if(luaL_dostring(L, expr) != LUA_OK){
			fprint(2, "eval: %s\n", lua_tostring(L, -1));
			lua_close(L); exits("eval");
		}
		break;
	case 3:
		if(luaL_dofile(L, file) != LUA_OK){
			fprint(2, "file: %s\n", lua_tostring(L, -1));
			lua_close(L); exits("file");
		}
		break;
	}
	lua_close(L);
	exits(nil);
}
