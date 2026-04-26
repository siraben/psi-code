#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <io.h>
#include <winsock2.h>
#include <windows.h>
#endif

static const char *bridge_dirs[] = {
    "D:\\bridge",
    "E:\\bridge",
    "F:\\bridge",
    "C:\\psi\\bridge",
    ".\\bridge",
    NULL
};

static FILE *agent_output = NULL;

struct agent_trace_observer {
    void (*on_tool_call)(void *userdata, const char *tool_call_id, const char *tool_name, const char *input_json);
    void (*on_tool_result)(void *userdata, const char *tool_call_id, const char *tool_name, const char *output_json);
    void *userdata;
};

static int write_file(const char *path, const char *data)
{
    FILE *f = fopen(path, "wb");
    size_t n;
    if (!f) return 0;
    n = data ? strlen(data) : 0u;
    if (n > 0u && fwrite(data, 1, n, f) != n) {
        fclose(f);
        return 0;
    }
    fclose(f);
    return 1;
}

static char *read_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    long n;
    char *buf;
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    n = ftell(f);
    if (n < 0) { fclose(f); return NULL; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
    buf = (char *)malloc((size_t)n + 1u);
    if (!buf) { fclose(f); return NULL; }
    if (n > 0 && fread(buf, 1, (size_t)n, f) != (size_t)n) {
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);
    buf[n] = 0;
    return buf;
}

static char *join3(const char *a, const char *b, const char *c)
{
    size_t na = strlen(a), nb = strlen(b), nc = strlen(c);
    char *out = (char *)malloc(na + nb + nc + 1u);
    if (!out) return NULL;
    memcpy(out, a, na);
    memcpy(out + na, b, nb);
    memcpy(out + na + nb, c, nc);
    out[na + nb + nc] = 0;
    return out;
}

static char *bridge_path(const char *dir, const char *id, const char *suffix)
{
    char *prefix;
    char *path;
    const char last = dir[strlen(dir) - 1u];
    const char *sep = (last == '\\' || last == '/') ? "" : "\\";
    prefix = join3(dir, sep, id);
    if (!prefix) return NULL;
    path = join3(prefix, ".", suffix);
    free(prefix);
    return path;
}

static char *str_dup(const char *s)
{
    char *out = (char *)malloc(strlen(s) + 1u);
    if (out) strcpy(out, s);
    return out;
}

static char *json_escape(const char *s)
{
    size_t i, extra = 0u;
    char *out, *p;
    for (i = 0u; s[i]; i++) {
        if (s[i] == '"' || s[i] == '\\' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t') extra++;
    }
    out = (char *)malloc(strlen(s) + extra + 1u);
    if (!out) return NULL;
    p = out;
    for (i = 0u; s[i]; i++) {
        if (s[i] == '"' || s[i] == '\\') { *p++ = '\\'; *p++ = s[i]; }
        else if (s[i] == '\n') { *p++ = '\\'; *p++ = 'n'; }
        else if (s[i] == '\r') { *p++ = '\\'; *p++ = 'r'; }
        else if (s[i] == '\t') { *p++ = '\\'; *p++ = 't'; }
        else *p++ = s[i];
    }
    *p = 0;
    return out;
}

static char *json_escape_control_chars(const char *s)
{
    const unsigned char *p;
    char *out, *q;
    size_t n = 1u;
    if (!s) return str_dup("{}");
    for (p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '\n':
        case '\r':
        case '\t':
            n += 2u;
            break;
        default:
            n += (*p < 32u) ? 6u : 1u;
            break;
        }
    }
    out = (char *)malloc(n);
    if (!out) return NULL;
    q = out;
    for (p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '\n': *q++ = '\\'; *q++ = 'n'; break;
        case '\r': *q++ = '\\'; *q++ = 'r'; break;
        case '\t': *q++ = '\\'; *q++ = 't'; break;
        default:
            if (*p < 32u) {
                sprintf(q, "\\u%04x", (unsigned int)*p);
                q += 6;
            } else {
                *q++ = (char)*p;
            }
            break;
        }
    }
    *q = 0;
    return out;
}

static char *json_unescape_slice(const char *start, const char *end)
{
    char *out = (char *)malloc((size_t)(end - start) + 1u);
    char *p = out;
    if (!out) return NULL;
    while (start < end) {
        if (*start == '\\' && start + 1 < end) {
            start++;
            if (*start == 'n') *p++ = '\n';
            else if (*start == 'r') *p++ = '\r';
            else if (*start == 't') *p++ = '\t';
            else *p++ = *start;
            start++;
        } else {
            *p++ = *start++;
        }
    }
    *p = 0;
    return out;
}

static char *json_get_string(const char *json, const char *key)
{
    char needle[64];
    const char *p, *start, *end;
    sprintf(needle, "\"%s\"", key);
    p = strstr(json, needle);
    if (!p) return NULL;
    p = strchr(p + strlen(needle), ':');
    if (!p) return NULL;
    p++;
    while (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t') p++;
    if (*p != '"') return NULL;
    start = ++p;
    end = start;
    while (*end) {
        if (*end == '"' && (end == start || end[-1] != '\\')) break;
        end++;
    }
    if (*end != '"') return NULL;
    return json_unescape_slice(start, end);
}

static char *replace_first(const char *text, const char *old_text, const char *new_text)
{
    const char *hit = strstr(text, old_text);
    char *out;
    size_t before, n;
    if (!hit) return NULL;
    before = (size_t)(hit - text);
    n = before + strlen(new_text) + strlen(hit + strlen(old_text)) + 1u;
    out = (char *)malloc(n);
    if (!out) return NULL;
    memcpy(out, text, before);
    strcpy(out + before, new_text);
    strcat(out, hit + strlen(old_text));
    return out;
}

static char *make_summary2(const char *a, const char *b)
{
    size_t n;
    char *out;
    a = a ? a : "";
    b = b ? b : "";
    n = strlen(a) + strlen(b) + 1u;
    out = (char *)malloc(n);
    if (!out) return NULL;
    strcpy(out, a);
    strcat(out, b);
    return out;
}

static char *make_summary3(const char *a, const char *b, const char *c)
{
    size_t n;
    char *out;
    a = a ? a : "";
    b = b ? b : "";
    c = c ? c : "";
    n = strlen(a) + strlen(b) + strlen(c) + 1u;
    out = (char *)malloc(n);
    if (!out) return NULL;
    strcpy(out, a);
    strcat(out, b);
    strcat(out, c);
    return out;
}

static int json_get_bool_true(const char *json, const char *key)
{
    char needle[64];
    const char *p;
    sprintf(needle, "\"%s\"", key);
    p = strstr(json ? json : "", needle);
    if (!p) return 0;
    p = strchr(p + strlen(needle), ':');
    if (!p) return 0;
    p++;
    while (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t') p++;
    return strncmp(p, "true", 4) == 0;
}

static char *limit_text(const char *s, size_t max_len)
{
    char *out;
    size_t n;
    if (!s) return str_dup("");
    n = strlen(s);
    if (n <= max_len) return str_dup(s);
    if (max_len < 4u) max_len = 4u;
    out = (char *)malloc(max_len + 1u);
    if (!out) return NULL;
    memcpy(out, s, max_len - 3u);
    out[max_len - 3u] = '.';
    out[max_len - 2u] = '.';
    out[max_len - 1u] = '.';
    out[max_len] = 0;
    return out;
}

static char *format_tool_call_summary(const char *tool_name, const char *input_json)
{
    char *value = NULL;
    char *summary;
    if (!tool_name) tool_name = "tool";
    if (strcmp(tool_name, "read") == 0 || strcmp(tool_name, "write") == 0 || strcmp(tool_name, "edit") == 0) {
        value = json_get_string(input_json, "path");
        summary = make_summary3(tool_name, " ", value ? value : "");
    } else if (strcmp(tool_name, "cmd") == 0) {
        value = json_get_string(input_json, "command");
        summary = make_summary2("cmd ", value ? value : "");
    } else {
        summary = make_summary3(tool_name, " ", input_json ? input_json : "");
    }
    if (value) free(value);
    return summary ? summary : str_dup(tool_name);
}

static char *format_tool_result_summary(const char *tool_name, const char *output_json)
{
    char *value = NULL;
    char *summary;
    if (!tool_name) tool_name = "tool";
    if (!json_get_bool_true(output_json, "ok")) {
        value = json_get_string(output_json, "error");
        summary = make_summary2("error: ", value ? value : "unknown error");
    } else if (strcmp(tool_name, "read") == 0) {
        value = json_get_string(output_json, "text");
        summary = limit_text(value ? value : "", 1400u);
    } else if (strcmp(tool_name, "cmd") == 0) {
        value = json_get_string(output_json, "output");
        summary = limit_text(value ? value : "", 1400u);
    } else if (strcmp(tool_name, "write") == 0) {
        summary = str_dup("written");
    } else if (strcmp(tool_name, "edit") == 0) {
        summary = str_dup("edited");
    } else {
        summary = limit_text(output_json ? output_json : "", 1400u);
    }
    if (value) free(value);
    return summary ? summary : str_dup("");
}

static char *panel_open_text(const char *summary)
{
    return make_summary2("\xE2\x95\xAD\xE2\x94\x80 ", summary ? summary : "");
}

static char *panel_close_text(const char *summary)
{
    char *limited = limit_text(summary ? summary : "", 1400u);
    char *body = make_summary3("\xE2\x94\x82 ", limited ? limited : "", "\n\xE2\x95\xB0\xE2\x94\x80");
    if (limited) free(limited);
    return body;
}

static char *run_command(const char *command)
{
    FILE *p;
    char buf[512];
    char *out = NULL;
    size_t len = 0u, cap = 0u;
#ifdef _WIN32
    p = _popen(command, "r");
#else
    p = popen(command, "r");
#endif
    if (!p) return str_dup("");
    while (fgets(buf, sizeof(buf), p) != NULL) {
        size_t n = strlen(buf);
        if (len + n + 1u > cap) {
            size_t next = cap ? cap * 2u : 1024u;
            char *tmp;
            while (len + n + 1u > next) next *= 2u;
            tmp = (char *)realloc(out, next);
            if (!tmp) break;
            out = tmp;
            cap = next;
        }
        memcpy(out + len, buf, n);
        len += n;
        out[len] = 0;
        if (len > 65536u) break;
    }
#ifdef _WIN32
    _pclose(p);
#else
    pclose(p);
#endif
    if (!out) return str_dup("");
    return out;
}

static char *execute_tool(const char *name, const char *input_json)
{
    char *path = json_get_string(input_json, "path");
    char *content = json_get_string(input_json, "content");
    char *command = json_get_string(input_json, "command");
    char *text = NULL, *esc = NULL, *out = NULL;
    if (strcmp(name, "cmd") == 0) {
        if (!command) return str_dup("{\"ok\":false,\"error\":\"missing command\"}");
        text = run_command(command);
        esc = json_escape(text ? text : "");
        out = (char *)malloc(strlen(esc ? esc : "") + 64u);
        if (out) sprintf(out, "{\"ok\":true,\"output\":\"%s\"}", esc ? esc : "");
    } else if (!path) {
        out = str_dup("{\"ok\":false,\"error\":\"missing path\"}");
    } else if (strcmp(name, "read") == 0) {
        text = read_file(path);
        if (!text) out = str_dup("{\"ok\":false,\"error\":\"could not read file\"}");
        else {
            esc = json_escape(text);
            out = (char *)malloc(strlen(esc ? esc : "") + strlen(path) + 64u);
            if (out) sprintf(out, "{\"ok\":true,\"path\":\"%s\",\"text\":\"%s\"}", path, esc ? esc : "");
        }
    } else if (strcmp(name, "write") == 0) {
        if (!content) content = json_get_string(input_json, "text");
        if (!content) out = str_dup("{\"ok\":false,\"error\":\"missing content\"}");
        else if (write_file(path, content)) out = str_dup("{\"ok\":true,\"status\":\"written\"}");
        else out = str_dup("{\"ok\":false,\"error\":\"could not write file\"}");
    } else if (strcmp(name, "edit") == 0) {
        char *old_text = json_get_string(input_json, "oldText");
        char *new_text = json_get_string(input_json, "newText");
        text = read_file(path);
        if (!old_text || !new_text) out = str_dup("{\"ok\":false,\"error\":\"missing oldText or newText\"}");
        else if (!text) out = str_dup("{\"ok\":false,\"error\":\"could not read file\"}");
        else {
            char *edited = replace_first(text, old_text, new_text);
            if (!edited) out = str_dup("{\"ok\":false,\"error\":\"target text not found\"}");
            else if (write_file(path, edited)) out = str_dup("{\"ok\":true,\"status\":\"edited\"}");
            else out = str_dup("{\"ok\":false,\"error\":\"could not write file\"}");
            if (edited) free(edited);
        }
        if (old_text) free(old_text);
        if (new_text) free(new_text);
    } else {
        out = str_dup("{\"ok\":false,\"error\":\"unknown tool\"}");
    }
    if (path) free(path);
    if (content) free(content);
    if (command) free(command);
    if (text) free(text);
    if (esc) free(esc);
    return out ? out : str_dup("{\"ok\":false,\"error\":\"out of memory\"}");
}

static const char *tool_specs =
    ",\"tools\":["
    "{\"name\":\"read\",\"description\":\"Read a file from a ReactOS path.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}},"
    "{\"name\":\"write\",\"description\":\"Write a full file to a ReactOS path.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}},"
    "{\"name\":\"edit\",\"description\":\"Replace exact text in a file at a ReactOS path.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"oldText\":{\"type\":\"string\"},\"newText\":{\"type\":\"string\"}},\"required\":[\"path\",\"oldText\",\"newText\"]}},"
    "{\"name\":\"cmd\",\"description\":\"Run a ReactOS command shell command and return stdout.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}}"
    "]";

static char *make_request_body(const char *prompt, int max_tokens,
                               const char *tool_id, const char *tool_name,
                               const char *tool_input_json,
                               const char *tool_result_json)
{
    const char *prefix = "{\"model\":\"claude-opus-4-7\",\"max_tokens\":";
    const char *mid1 = ",\"system\":\"You are a concise ReactOS CLI assistant. Use tools when file reading, writing, editing, or command execution is needed.\",\"messages\":[{\"role\":\"user\",\"content\":\"";
    const char *suffix1 = "\"}";
    const char *suffix2 = "}";
    char num[32];
    char *esc, *body, *tool_input_safe = NULL, *tool_result_esc = NULL;
    size_t n;
    sprintf(num, "%d", max_tokens > 0 ? max_tokens : 1024);
    esc = json_escape(prompt);
    if (!esc) return NULL;
    if (tool_input_json) tool_input_safe = json_escape_control_chars(tool_input_json);
    if (tool_result_json) tool_result_esc = json_escape(tool_result_json);
    n = strlen(prefix) + strlen(num) + strlen(mid1) + strlen(esc) + strlen(suffix1)
        + strlen(tool_specs) + strlen(suffix2) + 512u;
    if (tool_id) n += strlen(tool_id) * 2u + strlen(tool_name) + strlen(tool_input_safe ? tool_input_safe : "{}") + strlen(tool_result_esc ? tool_result_esc : "");
    body = (char *)malloc(n);
    if (!body) { free(esc); if (tool_input_safe) free(tool_input_safe); if (tool_result_esc) free(tool_result_esc); return NULL; }
    strcpy(body, prefix);
    strcat(body, num);
    strcat(body, mid1);
    strcat(body, esc);
    strcat(body, suffix1);
    if (tool_id) {
        strcat(body, ",{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"");
        strcat(body, tool_id);
        strcat(body, "\",\"name\":\"");
        strcat(body, tool_name);
        strcat(body, "\",\"input\":");
        strcat(body, tool_input_safe ? tool_input_safe : "{}");
        strcat(body, "}]},{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"");
        strcat(body, tool_id);
        strcat(body, "\",\"content\":\"");
        strcat(body, tool_result_esc ? tool_result_esc : "");
        strcat(body, "\"}]}");
    }
    strcat(body, "]");
    strcat(body, tool_specs);
    strcat(body, suffix2);
    free(esc);
    if (tool_input_safe) free(tool_input_safe);
    if (tool_result_esc) free(tool_result_esc);
    return body;
}

static void print_sse_text_deltas(const char *body)
{
    const char *p = body;
    FILE *out = agent_output ? agent_output : stdout;
    int wrote = 0;
    while ((p = strstr(p, "\"type\":\"text_delta\",\"text\":\"")) != NULL) {
        const char *start = p + 28;
        const char *end = start;
        char *tmp;
        while (*end) {
            if (*end == '"' && (end == start || end[-1] != '\\')) break;
            end++;
        }
        tmp = json_unescape_slice(start, end);
        if (!tmp) return;
        fputs(tmp, out);
        free(tmp);
        wrote = 1;
        p = end;
    }
    p = body;
    while ((p = strstr(p, "\"type\":\"text\",\"text\":\"")) != NULL) {
        const char *start = p + 22;
        const char *end = start;
        char *tmp;
        while (*end) {
            if (*end == '"' && (end == start || end[-1] != '\\')) break;
            end++;
        }
        tmp = json_unescape_slice(start, end);
        if (!tmp) return;
        fputs(tmp, out);
        free(tmp);
        wrote = 1;
        p = end;
    }
    if (wrote) fputc('\n', out);
}

static char *extract_after(const char *p, const char *needle)
{
    const char *start, *end;
    p = strstr(p, needle);
    if (!p) return NULL;
    start = p + strlen(needle);
    end = start;
    while (*end) {
        if (*end == '"' && (end == start || end[-1] != '\\')) break;
        end++;
    }
    if (*end != '"') return NULL;
    return json_unescape_slice(start, end);
}

static char *copy_json_object_after(const char *p, const char *needle)
{
    const char *start, *q;
    int depth = 0, in_str = 0, esc = 0;
    p = strstr(p, needle);
    if (!p) return NULL;
    start = p + strlen(needle);
    while (*start == ' ' || *start == '\t' || *start == '\r' || *start == '\n') start++;
    if (*start != '{') return NULL;
    for (q = start; *q; q++) {
        if (in_str) {
            if (esc) {
                esc = 0;
            } else if (*q == '\\') {
                esc = 1;
            } else if (*q == '"') {
                in_str = 0;
            }
        } else if (*q == '"') {
            in_str = 1;
        } else if (*q == '{') {
            depth++;
        } else if (*q == '}') {
            depth--;
            if (depth == 0) {
                size_t n = (size_t)(q - start + 1);
                char *out = (char *)malloc(n + 1u);
                if (!out) return NULL;
                memcpy(out, start, n);
                out[n] = 0;
                return out;
            }
        }
    }
    return NULL;
}

static int extract_tool_use(const char *body, char **id, char **name, char **input_json)
{
    const char *p = strstr(body, "\"type\":\"tool_use\"");
    const char *q = body;
    size_t cap = 256u, len = 0u;
    char *input;
    if (!p) return 0;
    *id = extract_after(p, "\"id\":\"");
    *name = extract_after(p, "\"name\":\"");
    input = (char *)malloc(cap);
    if (!input) return 0;
    input[0] = 0;
    while ((q = strstr(q, "\"type\":\"input_json_delta\",\"partial_json\":\"")) != NULL) {
        char *part = extract_after(q, "\"partial_json\":\"");
        size_t need;
        if (!part) break;
        need = len + strlen(part) + 1u;
        if (need > cap) {
            char *next;
            while (need > cap) cap *= 2u;
            next = (char *)realloc(input, cap);
            if (!next) { free(part); free(input); return 0; }
            input = next;
        }
        strcpy(input + len, part);
        len += strlen(part);
        free(part);
        q += 16;
    }
    if (input[0] == 0) {
        char *obj = copy_json_object_after(p, "\"input\":");
        if (obj) {
            free(input);
            input = obj;
        }
    }
    *input_json = input;
    return *id && *name && input[0] != 0;
}

static char *http_post_proxy(const char *body)
{
#ifdef _WIN32
    WSADATA wsa;
    SOCKET s;
    struct sockaddr_in addr;
    const char *host = "10.0.2.2";
    const int port = 18080;
    char header[512];
    char buf[2048];
    char *resp = NULL, *payload, *out;
    size_t len = 0u, cap = 0u;
    int n;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return NULL;
    s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) { WSACleanup(); return NULL; }
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((u_short)port);
    addr.sin_addr.s_addr = inet_addr(host);
    if (connect(s, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        closesocket(s); WSACleanup(); return NULL;
    }
    sprintf(header,
        "POST /anthropic HTTP/1.1\r\n"
        "Host: 10.0.2.2:18080\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %lu\r\n"
        "Connection: close\r\n\r\n",
        (unsigned long)strlen(body));
    send(s, header, (int)strlen(header), 0);
    send(s, body, (int)strlen(body), 0);
    while ((n = recv(s, buf, sizeof(buf), 0)) > 0) {
        if (len + (size_t)n + 1u > cap) {
            size_t next = cap ? cap * 2u : 8192u;
            char *tmp;
            while (len + (size_t)n + 1u > next) next *= 2u;
            tmp = (char *)realloc(resp, next);
            if (!tmp) { free(resp); closesocket(s); WSACleanup(); return NULL; }
            resp = tmp; cap = next;
        }
        memcpy(resp + len, buf, (size_t)n);
        len += (size_t)n;
        resp[len] = 0;
    }
    closesocket(s);
    WSACleanup();
    if (!resp) return NULL;
    if (strncmp(resp, "HTTP/1.0 200", 12) != 0 && strncmp(resp, "HTTP/1.1 200", 12) != 0) {
        printf("psi: proxy request failed\n%s\n", resp);
        free(resp);
        return NULL;
    }
    payload = strstr(resp, "\r\n\r\n");
    if (!payload) { free(resp); return NULL; }
    payload += 4;
    out = str_dup(payload);
    free(resp);
    return out;
#else
    (void)body;
    return NULL;
#endif
}

static int probe_bridge(void)
{
    int i;
    for (i = 0; bridge_dirs[i]; i++) {
        char *path = bridge_path(bridge_dirs[i], "probe", "txt");
        int ok = path && write_file(path, "ok\r\n");
        if (path) free(path);
        if (ok) {
            printf("psi: bridge probe ok: %s\n", bridge_dirs[i]);
            return 0;
        }
    }
    printf("psi: bridge probe failed\n");
    return 1;
}

static char *send_bridge_request(const char *body)
{
    char *http_resp = http_post_proxy(body);
    if (http_resp) return http_resp;
    int i, spin;
    char id[64];
    for (i = 0; bridge_dirs[i]; i++) {
        char *seq_path = bridge_path(bridge_dirs[i], "seq", "txt");
        char *seq_text = seq_path ? read_file(seq_path) : NULL;
        long seq = seq_text ? atol(seq_text) + 1 : 1;
        char *url, *headers, *request, *ready, *status, *resp;
        if (seq < 1) seq = 1;
        sprintf(id, "req-%ld", seq);
        if (seq_path) {
            char next_seq[32];
            sprintf(next_seq, "%ld\r\n", seq);
            write_file(seq_path, next_seq);
        }
        if (seq_text) free(seq_text);
        if (seq_path) free(seq_path);
        url = bridge_path(bridge_dirs[i], id, "url");
        headers = bridge_path(bridge_dirs[i], id, "headers");
        request = bridge_path(bridge_dirs[i], id, "request");
        ready = bridge_path(bridge_dirs[i], id, "ready");
        status = bridge_path(bridge_dirs[i], id, "status");
        resp = bridge_path(bridge_dirs[i], id, "body");
        if (url && headers && request && ready && status && resp &&
            write_file(url, "https://api.anthropic.com/v1/messages") &&
            write_file(headers, "content-type: application/json\nanthropic-version: 2023-06-01\nx-api-key: bridge\n") &&
            write_file(request, body) &&
            write_file(status, "0\n") &&
            write_file(ready, "ready\n")) {
            for (spin = 0; spin < 1200; spin++) {
                char *st = read_file(status);
                if (st) {
                    char *rb = read_file(resp);
                    if (strncmp(st, "0", 1) == 0) {
                        free(st);
                        if (rb) free(rb);
                    } else if (strncmp(st, "200", 3) != 0) {
                        printf("psi: request failed: %s\n", st);
                        if (rb) printf("%s\n", rb);
                        free(st); if (rb) free(rb);
                        free(url); free(headers); free(request); free(ready); free(status); free(resp);
                        return NULL;
                    } else if (rb) {
                        free(st);
                        free(url); free(headers); free(request); free(ready); free(status); free(resp);
                        return rb;
                    }
                }
#ifdef _WIN32
                Sleep(250);
#else
                { volatile long delay; for (delay = 0; delay < 250000L; delay++) {} }
#endif
            }
            printf("psi: timed out waiting for bridge\n");
            free(url); free(headers); free(request); free(ready); free(status); free(resp);
            return NULL;
        }
        if (url) free(url);
        if (headers) free(headers);
        if (request) free(request);
        if (ready) free(ready);
        if (status) free(status);
        if (resp) free(resp);
    }
    printf("psi: could not write bridge request\n");
    return NULL;
}

static int run_agent_with_trace(const char *prompt, int max_tokens, struct agent_trace_observer *observer)
{
    char *body = make_request_body(prompt, max_tokens, NULL, NULL, NULL, NULL);
    char *resp, *tool_id = NULL, *tool_name = NULL, *tool_input = NULL;
    int iter;
    if (!body) { printf("psi: out of memory\n"); return 1; }
    for (iter = 0; iter < 6; iter++) {
        resp = send_bridge_request(body);
        free(body);
        if (!resp) return 1;
        if (!extract_tool_use(resp, &tool_id, &tool_name, &tool_input)) {
            print_sse_text_deltas(resp);
            free(resp);
            return 0;
        }
        {
            if (observer && observer->on_tool_call) {
                observer->on_tool_call(observer->userdata, tool_id, tool_name, tool_input);
            }
            {
                char *result = execute_tool(tool_name, tool_input);
            if (observer && observer->on_tool_result) {
                observer->on_tool_result(observer->userdata, tool_id, tool_name, result ? result : "{}");
            }
            body = make_request_body(prompt, max_tokens, tool_id, tool_name, tool_input, result);
            if (result) free(result);
            }
        }
        free(resp);
        if (tool_id) free(tool_id);
        if (tool_name) free(tool_name);
        if (tool_input) free(tool_input);
        tool_id = tool_name = tool_input = NULL;
        if (!body) { printf("psi: out of memory\n"); return 1; }
    }
    if (body) free(body);
    printf("psi: too many tool iterations\n");
    return 1;
}

static int run_agent(const char *prompt, int max_tokens)
{
    return run_agent_with_trace(prompt, max_tokens, NULL);
}

static void stdout_trace_tool_call(void *userdata, const char *tool_call_id, const char *tool_name, const char *input_json)
{
    char *summary;
    char *panel;
    (void)userdata;
    (void)tool_call_id;
    summary = format_tool_call_summary(tool_name, input_json);
    panel = panel_open_text(summary);
    printf("\n%s\n", panel ? panel : "");
    if (summary) free(summary);
    if (panel) free(panel);
}

static void stdout_trace_tool_result(void *userdata, const char *tool_call_id, const char *tool_name, const char *output_json)
{
    char *summary;
    char *panel;
    (void)userdata;
    (void)tool_call_id;
    summary = format_tool_result_summary(tool_name, output_json);
    panel = panel_close_text(summary);
    printf("%s\n", panel ? panel : "");
    if (summary) free(summary);
    if (panel) free(panel);
}

static char *run_agent_capture(const char *prompt, int max_tokens, int *status_out, struct agent_trace_observer *observer)
{
    char temp_path[MAX_PATH];
    FILE *saved_output;
    FILE *f;
    char *text;
    int status;
#ifdef _WIN32
    GetTempPathA((DWORD)sizeof(temp_path), temp_path);
    strcat(temp_path, "psi-agent-output.txt");
#else
    strcpy(temp_path, "psi-agent-output.txt");
#endif
    f = fopen(temp_path, "wb");
    if (!f) {
        status = run_agent_with_trace(prompt, max_tokens, observer);
        if (status_out) *status_out = status;
        return str_dup("");
    }
    saved_output = agent_output;
    agent_output = f;
    status = run_agent_with_trace(prompt, max_tokens, observer);
    fflush(f);
    fclose(f);
    agent_output = saved_output;
    text = read_file(temp_path);
    remove(temp_path);
    if (status_out) *status_out = status;
    return text ? text : str_dup("");
}

static void strip_line(char *s)
{
    size_t n;
    if (!s) return;
    n = strlen(s);
    while (n > 0u && (s[n - 1u] == '\n' || s[n - 1u] == '\r')) {
        s[--n] = 0;
    }
}

static int stdin_is_tty(void)
{
#ifdef _WIN32
    return _isatty(_fileno(stdin));
#else
    return 1;
#endif
}

#ifdef _WIN32
struct tui_entry {
    char role[16];
    char *text;
};

struct tui_state {
    struct tui_entry *entries;
    size_t count;
    size_t cap;
    int width;
    int height;
    int busy;
    char status[256];
};

static void tui_redraw(struct tui_state *state, const char *input);

static void tui_free(struct tui_state *state)
{
    size_t i;
    if (!state) return;
    for (i = 0u; i < state->count; i++) {
        if (state->entries[i].text) free(state->entries[i].text);
    }
    if (state->entries) free(state->entries);
    memset(state, 0, sizeof(*state));
}

static int tui_add(struct tui_state *state, const char *role, const char *text)
{
    struct tui_entry *next;
    if (state->count + 1u > state->cap) {
        size_t cap = state->cap ? state->cap * 2u : 16u;
        next = (struct tui_entry *)realloc(state->entries, cap * sizeof(state->entries[0]));
        if (!next) return 0;
        state->entries = next;
        state->cap = cap;
    }
    strncpy(state->entries[state->count].role, role, sizeof(state->entries[state->count].role) - 1u);
    state->entries[state->count].role[sizeof(state->entries[state->count].role) - 1u] = 0;
    state->entries[state->count].text = str_dup(text ? text : "");
    if (!state->entries[state->count].text) return 0;
    state->count++;
    return 1;
}

static void tui_trace_tool_call(void *userdata, const char *tool_call_id, const char *tool_name, const char *input_json)
{
    struct tui_state *state = (struct tui_state *)userdata;
    char *summary;
    char *panel;
    if (!state) return;
    (void)tool_call_id;
    summary = format_tool_call_summary(tool_name, input_json);
    panel = panel_open_text(summary);
    tui_add(state, "panel", panel ? panel : "");
    if (summary) free(summary);
    if (panel) free(panel);
    strcpy(state->status, "running tool");
    tui_redraw(state, "");
}

static void tui_trace_tool_result(void *userdata, const char *tool_call_id, const char *tool_name, const char *output_json)
{
    struct tui_state *state = (struct tui_state *)userdata;
    char *summary;
    char *panel;
    if (!state) return;
    (void)tool_call_id;
    summary = format_tool_result_summary(tool_name, output_json);
    panel = panel_close_text(summary);
    tui_add(state, "panel", panel ? panel : "");
    if (summary) free(summary);
    if (panel) free(panel);
    strcpy(state->status, "tool finished");
    tui_redraw(state, "");
}

static void console_size(int *w, int *h)
{
    CONSOLE_SCREEN_BUFFER_INFO info;
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    if (GetConsoleScreenBufferInfo(out, &info)) {
        *w = info.srWindow.Right - info.srWindow.Left + 1;
        *h = info.srWindow.Bottom - info.srWindow.Top + 1;
    } else {
        *w = 80;
        *h = 25;
    }
    if (*w < 40) *w = 40;
    if (*h < 12) *h = 12;
}

static void put_at(int x, int y, const char *s)
{
    COORD pos;
    DWORD written;
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    pos.X = (SHORT)x;
    pos.Y = (SHORT)y;
    SetConsoleCursorPosition(out, pos);
    WriteConsoleA(out, s, (DWORD)strlen(s), &written, NULL);
}

static void set_attr(WORD attr)
{
    SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE), attr);
}

static void clear_screen(void)
{
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    CONSOLE_SCREEN_BUFFER_INFO info;
    DWORD cells, written;
    COORD home;
    home.X = 0;
    home.Y = 0;
    if (!GetConsoleScreenBufferInfo(out, &info)) {
        system("cls");
        return;
    }
    cells = (DWORD)info.dwSize.X * (DWORD)info.dwSize.Y;
    FillConsoleOutputCharacterA(out, ' ', cells, home, &written);
    FillConsoleOutputAttribute(out, info.wAttributes, cells, home, &written);
    SetConsoleCursorPosition(out, home);
}

static void fill_at(int x, int y, int width, char ch)
{
    char *buf;
    if (width <= 0) return;
    buf = (char *)malloc((size_t)width + 1u);
    if (!buf) return;
    memset(buf, ch, (size_t)width);
    buf[width] = 0;
    put_at(x, y, buf);
    free(buf);
}

static void put_trunc(int x, int y, int width, const char *s)
{
    char *buf;
    size_t n;
    if (width <= 0) return;
    buf = (char *)malloc((size_t)width + 1u);
    if (!buf) return;
    memset(buf, ' ', (size_t)width);
    buf[width] = 0;
    if (s) {
        n = strlen(s);
        if (n > (size_t)width) n = (size_t)width;
        memcpy(buf, s, n);
    }
    put_at(x, y, buf);
    free(buf);
}

static void draw_box(int x, int y, int w, int h, const char *title)
{
    int i;
    if (w < 2 || h < 2) return;
    put_at(x, y, "+");
    fill_at(x + 1, y, w - 2, '-');
    put_at(x + w - 1, y, "+");
    for (i = 1; i < h - 1; i++) {
        put_at(x, y + i, "|");
        fill_at(x + 1, y + i, w - 2, ' ');
        put_at(x + w - 1, y + i, "|");
    }
    put_at(x, y + h - 1, "+");
    fill_at(x + 1, y + h - 1, w - 2, '-');
    put_at(x + w - 1, y + h - 1, "+");
    if (title && title[0]) put_trunc(x + 2, y, w - 4, title);
}

static int count_wrapped_lines(const char *role, const char *text, int width)
{
    int lines = 1;
    int col = role ? (int)strlen(role) + 2 : 0;
    const char *p;
    if (width < 8) width = 8;
    for (p = text ? text : ""; *p; p++) {
        if (*p == '\r') continue;
        if (*p == '\n') {
            lines++;
            col = 2;
        } else {
            col++;
            if (col >= width) {
                lines++;
                col = 2;
            }
        }
    }
    return lines;
}

static int draw_wrapped_line(const char *prefix, const char *text, int x, int y, int width, int max_y)
{
    char *line;
    int col = 0;
    const char *p;
    if (y > max_y || width <= 0) return y;
    line = (char *)malloc((size_t)width + 1u);
    if (!line) return y;
    memset(line, ' ', (size_t)width);
    line[width] = 0;
    if (prefix) {
        while (*prefix && col < width) line[col++] = *prefix++;
    }
    for (p = text ? text : ""; ; p++) {
        if (*p == '\r') continue;
        if (*p == '\n' || *p == 0 || col >= width) {
            put_trunc(x, y++, width, line);
            memset(line, ' ', (size_t)width);
            line[width] = 0;
            col = 2;
            if (y > max_y || *p == 0) break;
            if (*p == '\n') continue;
        }
        if (*p != 0 && col < width) line[col++] = *p;
    }
    free(line);
    return y;
}

static void tui_redraw(struct tui_state *state, const char *input)
{
    int i, y, transcript_top, transcript_h, first;
    int total = 0, skip;
    char status[512];
    console_size(&state->width, &state->height);
    transcript_top = 2;
    transcript_h = state->height - 8;
    if (transcript_h < 3) transcript_h = 3;
    clear_screen();
    set_attr(FOREGROUND_RED | FOREGROUND_GREEN | FOREGROUND_BLUE | FOREGROUND_INTENSITY);
    put_trunc(0, 0, state->width, " psi coding agent - ReactOS console TUI");
    set_attr(FOREGROUND_RED | FOREGROUND_GREEN | FOREGROUND_BLUE);
    draw_box(0, 1, state->width, transcript_h + 2, " transcript ");
    draw_box(0, transcript_h + 4, state->width, 3, " input ");
    for (i = 0; i < (int)state->count; i++) {
        total += count_wrapped_lines(state->entries[i].role, state->entries[i].text, state->width - 4);
    }
    skip = total - transcript_h;
    if (skip < 0) skip = 0;
    y = transcript_top;
    for (i = 0; i < (int)state->count && y < transcript_top + transcript_h; i++) {
        int lines = count_wrapped_lines(state->entries[i].role, state->entries[i].text, state->width - 4);
        if (skip >= lines) {
            skip -= lines;
            continue;
        }
        first = skip > 0 ? skip : 0;
        if (first == 0) {
            char prefix[32];
            if (strcmp(state->entries[i].role, "panel") == 0) {
                y = draw_wrapped_line("", state->entries[i].text, 2, y, state->width - 4, transcript_top + transcript_h - 1);
            } else {
                sprintf(prefix, "%s> ", state->entries[i].role);
                y = draw_wrapped_line(prefix, state->entries[i].text, 2, y, state->width - 4, transcript_top + transcript_h - 1);
            }
        }
        skip = 0;
    }
    sprintf(status, " session:-  model:claude-opus-4-7  msg:%lu%s  %s",
        (unsigned long)state->count,
        state->busy ? "  working" : "",
        state->status);
    set_attr(BACKGROUND_BLUE | FOREGROUND_RED | FOREGROUND_GREEN | FOREGROUND_BLUE | FOREGROUND_INTENSITY);
    put_trunc(0, transcript_h + 3, state->width, status);
    set_attr(FOREGROUND_RED | FOREGROUND_GREEN | FOREGROUND_BLUE | FOREGROUND_INTENSITY);
    put_trunc(2, transcript_h + 5, state->width - 4, input ? input : "");
    set_attr(BACKGROUND_GREEN | FOREGROUND_RED | FOREGROUND_GREEN | FOREGROUND_BLUE | FOREGROUND_INTENSITY);
    put_trunc(0, state->height - 1, state->width, " Enter submit  /help  /quit ");
    set_attr(FOREGROUND_RED | FOREGROUND_GREEN | FOREGROUND_BLUE);
    {
        COORD pos;
        pos.X = 2 + (SHORT)strlen(input ? input : "");
        if (pos.X > state->width - 3) pos.X = (SHORT)(state->width - 3);
        pos.Y = (SHORT)(transcript_h + 5);
        SetConsoleCursorPosition(GetStdHandle(STD_OUTPUT_HANDLE), pos);
    }
}

static int run_fullscreen_tui(int max_tokens)
{
    struct tui_state state;
    char line[4096];
    DWORD old_mode = 0;
    HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
    memset(&state, 0, sizeof(state));
    strcpy(state.status, "ready");
    GetConsoleMode(in, &old_mode);
    tui_add(&state, "system", "ReactOS console backend. Type /help for commands.");
    for (;;) {
        tui_redraw(&state, "");
        if (fgets(line, sizeof(line), stdin) == NULL) break;
        strip_line(line);
        if (line[0] == 0) continue;
        if (strcmp(line, "/exit") == 0 || strcmp(line, "/quit") == 0) break;
        if (strcmp(line, "/help") == 0) {
            tui_add(&state, "system", "Commands: /help, /quit. Prompts use the same agent and ReactOS file/cmd tools as --agent.");
            continue;
        }
        tui_add(&state, "user", line);
        strcpy(state.status, "agent turn running");
        state.busy = 1;
        tui_redraw(&state, "");
        {
            int status = 0;
            struct agent_trace_observer observer;
            char *answer;
            observer.on_tool_call = tui_trace_tool_call;
            observer.on_tool_result = tui_trace_tool_result;
            observer.userdata = &state;
            answer = run_agent_capture(line, max_tokens, &status, &observer);
            state.busy = 0;
            strcpy(state.status, status == 0 ? "ready" : "agent failed");
            tui_add(&state, status == 0 ? "assistant" : "error", answer ? answer : "");
            if (answer) free(answer);
        }
    }
    if (old_mode) SetConsoleMode(in, old_mode);
    clear_screen();
    tui_free(&state);
    return 0;
}
#endif

static int run_tui(int max_tokens)
{
    char line[4096];
    int interactive = stdin_is_tty();
    if (interactive) {
#ifdef _WIN32
        return run_fullscreen_tui(max_tokens);
#else
        system("clear");
#endif
        printf("psi ReactOS TUI\n");
        printf("Type a prompt, or /exit to quit.\n\n");
    }
    for (;;) {
        if (interactive) {
            printf("psi> ");
            fflush(stdout);
        }
        if (fgets(line, sizeof(line), stdin) == NULL) break;
        strip_line(line);
        if (line[0] == 0) continue;
        if (strcmp(line, "/exit") == 0 || strcmp(line, "/quit") == 0) break;
        printf("assistant> ");
        fflush(stdout);
        {
            struct agent_trace_observer observer;
            observer.on_tool_call = stdout_trace_tool_call;
            observer.on_tool_result = stdout_trace_tool_result;
            observer.userdata = NULL;
            if (run_agent_with_trace(line, max_tokens, &observer) != 0) {
            printf("psi: agent request failed\n");
            return 1;
            }
        }
        if (interactive) putchar('\n');
    }
    return 0;
}

int main(int argc, char **argv)
{
    int i, max_tokens = 1024;
    if (argc >= 2 && strcmp(argv[1], "--version") == 0) {
        printf("psi 0.1.0 (ReactOS bridge client)\n");
        return 0;
    }
    if (argc >= 2 && strcmp(argv[1], "--probe-bridge") == 0) {
        return probe_bridge();
    }
    if (argc >= 3 && strcmp(argv[1], "--agent") == 0) {
        for (i = 3; i + 1 < argc; i++) {
            if (strcmp(argv[i], "--max-tokens") == 0) max_tokens = atoi(argv[++i]);
        }
        return run_agent(argv[2], max_tokens);
    }
    if (argc >= 2 && strcmp(argv[1], "--tui") == 0) {
        for (i = 2; i + 1 < argc; i++) {
            if (strcmp(argv[i], "--max-tokens") == 0) max_tokens = atoi(argv[++i]);
        }
        return run_tui(max_tokens);
    }
    printf("usage: psi --version | --probe-bridge | --agent TEXT [--max-tokens N] | --tui [--max-tokens N]\n");
    return 1;
}
