#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *bridge_dirs[] = {
    "bridge:",
    "dh0:bridge",
    "DH0:bridge",
    "DH1:",
    NULL
};

static int write_file(const char *path, const char *data)
{
    FILE *f = fopen(path, "wb");
    if (!f) return 0;
    if (data && data[0] && fwrite(data, 1, strlen(data), f) != strlen(data)) {
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
    buf = (char *)malloc((size_t)n + 1);
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
    char *out = (char *)malloc(na + nb + nc + 1);
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
    const char *sep = (dir[strlen(dir) - 1] == ':' || dir[strlen(dir) - 1] == '/') ? "" : "/";
    prefix = join3(dir, sep, id);
    if (!prefix) return NULL;
    path = join3(prefix, ".", suffix);
    free(prefix);
    return path;
}

static char *json_escape(const char *s)
{
    size_t i, extra = 0;
    char *out, *p;
    for (i = 0; s[i]; i++) {
        if (s[i] == '"' || s[i] == '\\' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t') extra++;
    }
    out = (char *)malloc(strlen(s) + extra + 1);
    if (!out) return NULL;
    p = out;
    for (i = 0; s[i]; i++) {
        if (s[i] == '"' || s[i] == '\\') { *p++ = '\\'; *p++ = s[i]; }
        else if (s[i] == '\n') { *p++ = '\\'; *p++ = 'n'; }
        else if (s[i] == '\r') { *p++ = '\\'; *p++ = 'r'; }
        else if (s[i] == '\t') { *p++ = '\\'; *p++ = 't'; }
        else *p++ = s[i];
    }
    *p = 0;
    return out;
}

static char *json_unescape_slice(const char *start, const char *end)
{
    char *out = (char *)malloc((size_t)(end - start) + 1);
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

static char *str_dup(const char *s)
{
    char *out = (char *)malloc(strlen(s) + 1);
    if (out) strcpy(out, s);
    return out;
}

static char *replace_first(const char *text, const char *old_text, const char *new_text)
{
    const char *hit = strstr(text, old_text);
    char *out;
    size_t before, n;
    if (!hit) return NULL;
    before = (size_t)(hit - text);
    n = before + strlen(new_text) + strlen(hit + strlen(old_text)) + 1;
    out = (char *)malloc(n);
    if (!out) return NULL;
    memcpy(out, text, before);
    strcpy(out + before, new_text);
    strcat(out, hit + strlen(old_text));
    return out;
}

static char *execute_tool(const char *name, const char *input_json)
{
    char *path = json_get_string(input_json, "path");
    char *content = json_get_string(input_json, "content");
    char *text = NULL;
    char *esc = NULL;
    char *out = NULL;
    if (!path) return str_dup("{\"ok\":false,\"error\":\"missing path\"}");
    if (strcmp(name, "read") == 0) {
        text = read_file(path);
        if (!text) out = str_dup("{\"ok\":false,\"error\":\"could not read file\"}");
        else {
            esc = json_escape(text);
            out = (char *)malloc(strlen(esc) + strlen(path) + 64);
            if (out) sprintf(out, "{\"ok\":true,\"path\":\"%s\",\"text\":\"%s\"}", path, esc);
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
    if (text) free(text);
    if (esc) free(esc);
    return out ? out : str_dup("{\"ok\":false,\"error\":\"out of memory\"}");
}

static const char *tool_specs =
    ",\"tools\":["
    "{\"name\":\"read\",\"description\":\"Read a file from AmigaDOS path.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}},"
    "{\"name\":\"write\",\"description\":\"Write a full file to an AmigaDOS path.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}},"
    "{\"name\":\"edit\",\"description\":\"Replace exact text in a file at an AmigaDOS path.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"oldText\":{\"type\":\"string\"},\"newText\":{\"type\":\"string\"}},\"required\":[\"path\",\"oldText\",\"newText\"]}}"
    "]";

static char *make_request_body(const char *prompt, int max_tokens,
                               const char *tool_id, const char *tool_name,
                               const char *tool_input_json,
                               const char *tool_result_json)
{
    const char *prefix =
        "{\"model\":\"claude-sonnet-4-20250514\",\"max_tokens\":";
    const char *mid1 =
        ",\"stream\":true,\"system\":\"You are a concise Amiga CLI assistant. Use tools when file reading, writing, or editing is needed.\",\"messages\":[{\"role\":\"user\",\"content\":\"";
    const char *suffix1 = "\"}";
    const char *suffix2 = "}";
    char num[32];
    char *esc, *body, *tool_result_esc = NULL, *tool_input_esc = NULL;
    size_t n;
    sprintf(num, "%d", max_tokens > 0 ? max_tokens : 1024);
    esc = json_escape(prompt);
    if (!esc) return NULL;
    if (tool_result_json) tool_result_esc = json_escape(tool_result_json);
    if (tool_input_json) tool_input_esc = json_escape(tool_input_json);
    n = strlen(prefix) + strlen(num) + strlen(mid1) + strlen(esc) + strlen(suffix1)
        + strlen(tool_specs) + strlen(suffix2) + 512;
    if (tool_id) n += strlen(tool_id) * 2 + strlen(tool_name) + strlen(tool_input_json) + strlen(tool_result_esc);
    body = (char *)malloc(n);
    if (!body) { free(esc); if (tool_result_esc) free(tool_result_esc); if (tool_input_esc) free(tool_input_esc); return NULL; }
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
        strcat(body, tool_input_json);
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
    if (tool_result_esc) free(tool_result_esc);
    if (tool_input_esc) free(tool_input_esc);
    return body;
}

static void print_json_text(const char *s)
{
    fputs(s, stdout);
}

static void print_sse_text_deltas(const char *body)
{
    const char *p = body;
    int wrote = 0;
    while ((p = strstr(p, "\"type\":\"text_delta\",\"text\":\"")) != NULL) {
        const char *start = p + 28;
        const char *end = start;
        char *tmp;
        while (*end) {
            if (*end == '"' && (end == start || end[-1] != '\\')) break;
            end++;
        }
        tmp = (char *)malloc((size_t)(end - start) + 1);
        if (!tmp) return;
        memcpy(tmp, start, (size_t)(end - start));
        tmp[end - start] = 0;
        print_json_text(tmp);
        free(tmp);
        wrote = 1;
        p = end;
    }
    if (wrote) putchar('\n');
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

static int extract_tool_use(const char *body, char **id, char **name, char **input_json)
{
    const char *p = strstr(body, "\"type\":\"tool_use\"");
    const char *q = body;
    size_t cap = 256, len = 0;
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
        need = len + strlen(part) + 1;
        if (need > cap) {
            char *next;
            while (need > cap) cap *= 2;
            next = (char *)realloc(input, cap);
            if (!next) { free(part); free(input); return 0; }
            input = next;
        }
        strcpy(input + len, part);
        len += strlen(part);
        free(part);
        q += 16;
    }
    *input_json = input;
    return *id && *name && input[0] != 0;
}

static int probe_bridge(void)
{
    int i;
    for (i = 0; bridge_dirs[i]; i++) {
        char *path = bridge_path(bridge_dirs[i], "probe", "txt");
        int ok = path && write_file(path, "ok\n");
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
    int i, spin;
    char id[64];
    for (i = 0; bridge_dirs[i]; i++) {
        char *seq_path = bridge_path(bridge_dirs[i], "seq", "txt");
        char *seq_text = seq_path ? read_file(seq_path) : NULL;
        long seq = seq_text ? atol(seq_text) + 1 : 1;
        if (seq < 1) seq = 1;
        sprintf(id, "req-%ld", seq);
        if (seq_path) {
            char next_seq[32];
            sprintf(next_seq, "%ld\n", seq);
            write_file(seq_path, next_seq);
        }
        if (seq_text) free(seq_text);
        if (seq_path) free(seq_path);
        char *url = bridge_path(bridge_dirs[i], id, "url");
        char *headers = bridge_path(bridge_dirs[i], id, "headers");
        char *request = bridge_path(bridge_dirs[i], id, "request");
        char *ready = bridge_path(bridge_dirs[i], id, "ready");
        char *status = bridge_path(bridge_dirs[i], id, "status");
        char *resp = bridge_path(bridge_dirs[i], id, "body");
        int ok = url && headers && request && ready && status && resp &&
            write_file(url, "https://api.anthropic.com/v1/messages") &&
            write_file(headers, "content-type: application/json\nanthropic-version: 2023-06-01\nx-api-key: bridge\n") &&
            write_file(request, body) &&
            write_file(ready, "ready\n");
        if (url) free(url);
        if (headers) free(headers);
        if (request) free(request);
        if (ready) free(ready);
        if (ok) {
            for (spin = 0; spin < 600; spin++) {
                char *st = read_file(status);
                if (st) {
                    char *rb = read_file(resp);
                    if (strncmp(st, "200", 3) != 0) {
                        printf("psi: request failed: %s\n", st);
                        if (rb) printf("%s\n", rb);
                        free(st);
                        if (rb) free(rb);
                        free(status);
                        free(resp);
                        return NULL;
                    }
                    if (rb) {
                        free(st);
                        free(status);
                        free(resp);
                        return rb;
                    }
                    free(st);
                    free(status);
                    free(resp);
                    return NULL;
                }
                { volatile long delay; for (delay = 0; delay < 250000L; delay++) {} }
            }
            printf("psi: timed out waiting for bridge\n");
            free(status);
            free(resp);
            return NULL;
        }
        if (status) free(status);
        if (resp) free(resp);
    }
    printf("psi: could not write bridge request\n");
    return NULL;
}

static int run_agent(const char *prompt, int max_tokens)
{
    char *body = make_request_body(prompt, max_tokens, NULL, NULL, NULL, NULL);
    char *resp, *tool_id = NULL, *tool_name = NULL, *tool_input = NULL;
    int iter;
    if (!body) { printf("psi: out of memory\n"); return 1; }
    for (iter = 0; iter < 4; iter++) {
        resp = send_bridge_request(body);
        free(body);
        if (!resp) return 1;
        if (!extract_tool_use(resp, &tool_id, &tool_name, &tool_input)) {
            print_sse_text_deltas(resp);
            free(resp);
            return 0;
        }
        {
            char *result = execute_tool(tool_name, tool_input);
            body = make_request_body(prompt, max_tokens, tool_id, tool_name, tool_input, result);
            if (result) free(result);
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

int main(int argc, char **argv)
{
    int i, max_tokens = 1024;
    if (argc >= 2 && strcmp(argv[1], "--version") == 0) {
        printf("psi 0.1.0 (AmigaOS FS-UAE bridge client)\n");
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
    printf("usage: psi --version | --probe-bridge | --agent TEXT [--max-tokens N]\n");
    return 1;
}
