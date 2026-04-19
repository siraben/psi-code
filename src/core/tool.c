#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cjson/cJSON.h>
#include "psi/common.h"
#include "psi/process.h"
#include "psi/tool.h"

static const long PSI_TOOL_FILE_MAX_BYTES = 262144l;
static char *psi_tool_success_json(cJSON *root);

static const struct psi_tool_definition psi_builtin_tools[] = {
    {
        "read",
        "Read the contents of a file. Use this to inspect source files, configuration, and other project assets.",
        "Read file contents",
        {
            "Use read to examine files instead of cat or sed.",
            NULL
        }
    },
    {
        "bash",
        "Execute a shell command in the current working directory and return its output.",
        "Execute bash commands (ls, grep, find, tests, git, build commands)",
        {
            "Use bash for commands such as ls, rg, find, git, and tests.",
            NULL
        }
    },
    {
        "edit",
        "Edit a single file using exact text replacement. Prefer small, precise edits over broad rewrites.",
        "Make precise file edits with exact text replacement, including multiple disjoint edits in one call",
        {
            "Use edit for precise changes where old text can be matched exactly.",
            "When changing multiple separate locations in one file, use one edit call with multiple entries in edits[].",
            "Keep edits[].oldText as small as possible while still being unique in the file.",
            NULL
        }
    },
    {
        "write",
        "Write content to a file. Creates the file if it does not exist and overwrites it if it does.",
        "Create or overwrite files",
        {
            "Use write for new files or full rewrites.",
            NULL
        }
    },
    {
        "grep",
        "Search file contents for a pattern and return matching lines with file paths and line numbers.",
        "Search file contents for patterns (prefer this over broad shell grep)",
        {
            "Prefer grep over bash when searching file contents.",
            NULL
        }
    },
    {
        "find",
        "Find files by glob pattern relative to a directory.",
        "Find files by glob pattern",
        {
            "Prefer find over bash when locating files.",
            NULL
        }
    },
    {
        "ls",
        "List directory contents.",
        "List directory contents",
        {
            "Prefer ls over bash for a quick directory listing.",
            NULL
        }
    }
};

const struct psi_tool_definition *psi_tool_definitions(size_t *count) {
    if (count != NULL) {
        *count = sizeof(psi_builtin_tools) / sizeof(psi_builtin_tools[0]);
    }
    return psi_builtin_tools;
}

static char *psi_tool_error_json(const char *tool_name, const char *message) {
    cJSON *root;
    char *printed;

    root = cJSON_CreateObject();
    if (root == NULL) {
        return NULL;
    }

    cJSON_AddBoolToObject(root, "ok", 0);
    cJSON_AddStringToObject(root, "tool", tool_name ? tool_name : "unknown");
    cJSON_AddStringToObject(root, "error", message ? message : "unknown error");
    printed = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    return printed;
}

static char *psi_tool_shell_quote(const char *text) {
    size_t length;
    size_t index;
    size_t extra;
    char *quoted;
    char *out;

    if (text == NULL) {
        return psi_strdup("''");
    }

    length = strlen(text);
    extra = 2u;
    for (index = 0u; index < length; index++) {
        if (text[index] == '\'') {
            extra += 4u;
        } else {
            extra += 1u;
        }
    }

    quoted = (char *)malloc(extra + 1u);
    if (quoted == NULL) {
        return NULL;
    }

    out = quoted;
    *out++ = '\'';
    for (index = 0u; index < length; index++) {
        if (text[index] == '\'') {
            memcpy(out, "'\\''", 4u);
            out += 4;
        } else {
            *out++ = text[index];
        }
    }
    *out++ = '\'';
    *out = '\0';
    return quoted;
}

static int psi_tool_json_get_string(const cJSON *input, const char *field_name, const char **value_out) {
    const cJSON *field;

    field = cJSON_GetObjectItemCaseSensitive(input, field_name);
    if (!cJSON_IsString(field) || field->valuestring == NULL) {
        return PSI_STATUS_ERROR;
    }

    *value_out = field->valuestring;
    return PSI_STATUS_OK;
}

static long psi_tool_json_get_long(const cJSON *input, const char *field_name, long default_value) {
    const cJSON *field;

    field = cJSON_GetObjectItemCaseSensitive(input, field_name);
    if (cJSON_IsNumber(field)) {
        return (long)field->valuedouble;
    }
    return default_value;
}

static int psi_tool_json_get_bool(const cJSON *input, const char *field_name, int default_value) {
    const cJSON *field;

    field = cJSON_GetObjectItemCaseSensitive(input, field_name);
    if (cJSON_IsBool(field)) {
        return cJSON_IsTrue(field) ? 1 : 0;
    }
    return default_value;
}

static char *psi_tool_shell_command_json(
    const char *tool_name,
    const char *command,
    const char *path,
    int keep_output_on_error
) {
    cJSON *root;
    char *output_text;
    int exit_status;
    int truncated;

    output_text = NULL;
    exit_status = -1;
    truncated = 0;

    if (psi_process_run_shell(command, &output_text, &exit_status, &truncated) != PSI_STATUS_OK) {
        return psi_tool_error_json(tool_name, "failed to execute command");
    }

    root = cJSON_CreateObject();
    if (root == NULL) {
        free(output_text);
        return NULL;
    }
    cJSON_AddBoolToObject(root, "ok", exit_status == 0 ? 1 : 0);
    cJSON_AddStringToObject(root, "tool", tool_name);
    if (path != NULL) {
        cJSON_AddStringToObject(root, "path", path);
    }
    cJSON_AddStringToObject(root, "command", command);
    if (keep_output_on_error || exit_status == 0 || (output_text != NULL && output_text[0] != '\0')) {
        cJSON_AddStringToObject(root, "output", output_text != NULL ? output_text : "");
    }
    cJSON_AddNumberToObject(root, "status", (double)exit_status);
    cJSON_AddBoolToObject(root, "truncated", truncated);
    free(output_text);
    return psi_tool_success_json(root);
}

static char *psi_tool_success_json(cJSON *root) {
    char *printed;

    printed = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    return printed;
}

static int psi_tool_read_file_contents(const char *path, char **text_out) {
    FILE *file;
    long size;
    size_t read_size;
    char *buffer;

    *text_out = NULL;
    file = fopen(path, "rb");
    if (file == NULL) {
        return PSI_STATUS_ERROR;
    }

    if (fseek(file, 0l, SEEK_END) != 0) {
        fclose(file);
        return PSI_STATUS_ERROR;
    }

    size = ftell(file);
    if (size < 0l || size > PSI_TOOL_FILE_MAX_BYTES) {
        fclose(file);
        return PSI_STATUS_ERROR;
    }

    if (fseek(file, 0l, SEEK_SET) != 0) {
        fclose(file);
        return PSI_STATUS_ERROR;
    }

    buffer = (char *)malloc((size_t)size + 1u);
    if (buffer == NULL) {
        fclose(file);
        return PSI_STATUS_ERROR;
    }

    read_size = fread(buffer, 1u, (size_t)size, file);
    fclose(file);
    if (read_size != (size_t)size) {
        free(buffer);
        return PSI_STATUS_ERROR;
    }

    buffer[size] = '\0';
    *text_out = buffer;
    return PSI_STATUS_OK;
}

static int psi_tool_write_file_contents(const char *path, const char *text) {
    FILE *file;
    size_t length;

    file = fopen(path, "wb");
    if (file == NULL) {
        return PSI_STATUS_ERROR;
    }

    length = strlen(text);
    if (fwrite(text, 1u, length, file) != length) {
        fclose(file);
        return PSI_STATUS_ERROR;
    }

    fclose(file);
    return PSI_STATUS_OK;
}

static char *psi_tool_call_read(cJSON *input) {
    const cJSON *path;
    cJSON *root;
    char *text;

    path = cJSON_GetObjectItemCaseSensitive(input, "path");
    if (!cJSON_IsString(path) || path->valuestring == NULL) {
        return psi_tool_error_json("read", "missing string field: path");
    }

    text = NULL;
    if (psi_tool_read_file_contents(path->valuestring, &text) != PSI_STATUS_OK) {
        return psi_tool_error_json("read", "could not read file");
    }

    root = cJSON_CreateObject();
    if (root == NULL) {
        free(text);
        return NULL;
    }
    cJSON_AddBoolToObject(root, "ok", 1);
    cJSON_AddStringToObject(root, "tool", "read");
    cJSON_AddStringToObject(root, "path", path->valuestring);
    cJSON_AddStringToObject(root, "text", text);
    free(text);
    return psi_tool_success_json(root);
}

static char *psi_tool_call_write(cJSON *input) {
    const cJSON *path;
    const cJSON *text;
    cJSON *root;

    path = cJSON_GetObjectItemCaseSensitive(input, "path");
    text = cJSON_GetObjectItemCaseSensitive(input, "content");
    if (!cJSON_IsString(text) || text->valuestring == NULL) {
        text = cJSON_GetObjectItemCaseSensitive(input, "text");
    }
    if (!cJSON_IsString(path) || path->valuestring == NULL) {
        return psi_tool_error_json("write", "missing string field: path");
    }
    if (!cJSON_IsString(text) || text->valuestring == NULL) {
        return psi_tool_error_json("write", "missing string field: content");
    }

    if (psi_tool_write_file_contents(path->valuestring, text->valuestring) != PSI_STATUS_OK) {
        return psi_tool_error_json("write", "could not write full file");
    }

    root = cJSON_CreateObject();
    if (root == NULL) {
        return NULL;
    }
    cJSON_AddBoolToObject(root, "ok", 1);
    cJSON_AddStringToObject(root, "tool", "write");
    cJSON_AddStringToObject(root, "path", path->valuestring);
    cJSON_AddNumberToObject(root, "bytes_written", (double)strlen(text->valuestring));
    return psi_tool_success_json(root);
}

static char *psi_tool_replace_once(const char *original, const char *old_text, const char *new_text) {
    const char *match;
    size_t prefix_length;
    size_t old_length;
    size_t new_length;
    size_t original_length;
    char *result;

    match = strstr(original, old_text);
    if (match == NULL) {
        return NULL;
    }

    prefix_length = (size_t)(match - original);
    old_length = strlen(old_text);
    new_length = strlen(new_text);
    original_length = strlen(original);

    result = (char *)malloc(prefix_length + new_length + (original_length - prefix_length - old_length) + 1u);
    if (result == NULL) {
        return NULL;
    }

    memcpy(result, original, prefix_length);
    memcpy(result + prefix_length, new_text, new_length);
    memcpy(result + prefix_length + new_length, match + old_length, original_length - prefix_length - old_length);
    result[prefix_length + new_length + (original_length - prefix_length - old_length)] = '\0';
    return result;
}

static char *psi_tool_apply_edits(const char *original, const cJSON *edits, double *replacement_count) {
    char *current_text;
    char *next_text;
    const cJSON *edit_entry;
    const cJSON *old_text;
    const cJSON *new_text;

    current_text = psi_strdup(original);
    if (current_text == NULL) {
        return NULL;
    }

    *replacement_count = 0.0;
    cJSON_ArrayForEach(edit_entry, edits) {
        if (!cJSON_IsObject(edit_entry)) {
            free(current_text);
            return NULL;
        }

        old_text = cJSON_GetObjectItemCaseSensitive(edit_entry, "oldText");
        new_text = cJSON_GetObjectItemCaseSensitive(edit_entry, "newText");
        if (!cJSON_IsString(old_text) || old_text->valuestring == NULL ||
            !cJSON_IsString(new_text) || new_text->valuestring == NULL) {
            free(current_text);
            return NULL;
        }

        next_text = psi_tool_replace_once(current_text, old_text->valuestring, new_text->valuestring);
        free(current_text);
        if (next_text == NULL) {
            return NULL;
        }

        current_text = next_text;
        *replacement_count += 1.0;
    }

    return current_text;
}

static char *psi_tool_call_edit(cJSON *input) {
    const cJSON *path;
    const cJSON *old_text;
    const cJSON *new_text;
    const cJSON *edits;
    char *original;
    char *edited;
    cJSON *root;
    double replacements;

    path = cJSON_GetObjectItemCaseSensitive(input, "path");
    old_text = cJSON_GetObjectItemCaseSensitive(input, "oldText");
    new_text = cJSON_GetObjectItemCaseSensitive(input, "newText");
    edits = cJSON_GetObjectItemCaseSensitive(input, "edits");
    if (!cJSON_IsString(path) || path->valuestring == NULL) {
        return psi_tool_error_json("edit", "missing string field: path");
    }

    original = NULL;
    if (psi_tool_read_file_contents(path->valuestring, &original) != PSI_STATUS_OK) {
        return psi_tool_error_json("edit", "could not read file");
    }

    replacements = 0.0;
    if (cJSON_IsArray(edits)) {
        edited = psi_tool_apply_edits(original, edits, &replacements);
    } else {
        if (!cJSON_IsString(old_text) || old_text->valuestring == NULL) {
            free(original);
            return psi_tool_error_json("edit", "missing string field: oldText");
        }
        if (!cJSON_IsString(new_text) || new_text->valuestring == NULL) {
            free(original);
            return psi_tool_error_json("edit", "missing string field: newText");
        }
        edited = psi_tool_replace_once(original, old_text->valuestring, new_text->valuestring);
        replacements = 1.0;
    }
    free(original);
    if (edited == NULL) {
        return psi_tool_error_json("edit", "target text not found");
    }

    if (psi_tool_write_file_contents(path->valuestring, edited) != PSI_STATUS_OK) {
        free(edited);
        return psi_tool_error_json("edit", "could not write full file");
    }

    root = cJSON_CreateObject();
    if (root == NULL) {
        free(edited);
        return NULL;
    }
    cJSON_AddBoolToObject(root, "ok", 1);
    cJSON_AddStringToObject(root, "tool", "edit");
    cJSON_AddStringToObject(root, "path", path->valuestring);
    cJSON_AddNumberToObject(root, "replacements", replacements);
    free(edited);
    return psi_tool_success_json(root);
}

static char *psi_tool_call_bash(cJSON *input) {
    const cJSON *command;
    char *result;

    command = cJSON_GetObjectItemCaseSensitive(input, "command");
    if (!cJSON_IsString(command) || command->valuestring == NULL) {
        return psi_tool_error_json("bash", "missing string field: command");
    }

    result = psi_tool_shell_command_json("bash", command->valuestring, NULL, 1);
    return result;
}

static char *psi_tool_call_grep(cJSON *input) {
    const char *pattern;
    const cJSON *path_value;
    const cJSON *glob_value;
    char *quoted_pattern;
    char *quoted_path;
    char *quoted_glob;
    char command[4096];
    long limit;
    long context;
    int ignore_case;
    int literal;
    const char *path;

    if (psi_tool_json_get_string(input, "pattern", &pattern) != PSI_STATUS_OK) {
        return psi_tool_error_json("grep", "missing string field: pattern");
    }

    path_value = cJSON_GetObjectItemCaseSensitive(input, "path");
    glob_value = cJSON_GetObjectItemCaseSensitive(input, "glob");
    path = cJSON_IsString(path_value) && path_value->valuestring != NULL ? path_value->valuestring : ".";
    limit = psi_tool_json_get_long(input, "limit", 100l);
    context = psi_tool_json_get_long(input, "context", 0l);
    ignore_case = psi_tool_json_get_bool(input, "ignoreCase", 0);
    literal = psi_tool_json_get_bool(input, "literal", 0);

    quoted_pattern = psi_tool_shell_quote(pattern);
    quoted_path = psi_tool_shell_quote(path);
    quoted_glob = cJSON_IsString(glob_value) && glob_value->valuestring != NULL ? psi_tool_shell_quote(glob_value->valuestring) : NULL;
    if (quoted_pattern == NULL || quoted_path == NULL || (cJSON_IsString(glob_value) && glob_value->valuestring != NULL && quoted_glob == NULL)) {
        free(quoted_pattern);
        free(quoted_path);
        free(quoted_glob);
        return psi_tool_error_json("grep", "out of memory while preparing command");
    }

    sprintf(command, "command -v rg >/dev/null 2>&1 || { echo 'rg is required for grep' >&2; exit 127; }; rg -n --no-heading --color never --hidden --max-count %ld", limit);
    if (context > 0l) {
        sprintf(command + strlen(command), " -C %ld", context);
    }
    if (ignore_case) {
        strcat(command, " -i");
    }
    if (literal) {
        strcat(command, " -F");
    }
    if (quoted_glob != NULL) {
        strcat(command, " --glob ");
        strcat(command, quoted_glob);
    }
    strcat(command, " ");
    strcat(command, quoted_pattern);
    strcat(command, " ");
    strcat(command, quoted_path);

    free(quoted_pattern);
    free(quoted_path);
    free(quoted_glob);
    return psi_tool_shell_command_json("grep", command, path, 1);
}

static char *psi_tool_call_find(cJSON *input) {
    const char *pattern;
    const cJSON *path_value;
    char *quoted_pattern;
    char *quoted_path;
    char command[4096];
    long limit;
    const char *path;

    if (psi_tool_json_get_string(input, "pattern", &pattern) != PSI_STATUS_OK) {
        return psi_tool_error_json("find", "missing string field: pattern");
    }

    path_value = cJSON_GetObjectItemCaseSensitive(input, "path");
    path = cJSON_IsString(path_value) && path_value->valuestring != NULL ? path_value->valuestring : ".";
    limit = psi_tool_json_get_long(input, "limit", 1000l);

    quoted_pattern = psi_tool_shell_quote(pattern);
    quoted_path = psi_tool_shell_quote(path);
    if (quoted_pattern == NULL || quoted_path == NULL) {
        free(quoted_pattern);
        free(quoted_path);
        return psi_tool_error_json("find", "out of memory while preparing command");
    }

    sprintf(
        command,
        "command -v fd >/dev/null 2>&1 || { echo 'fd is required for find' >&2; exit 127; }; fd --hidden --max-results %ld --glob %s %s",
        limit,
        quoted_pattern,
        quoted_path
    );

    free(quoted_pattern);
    free(quoted_path);
    return psi_tool_shell_command_json("find", command, path, 1);
}

static char *psi_tool_call_ls(cJSON *input) {
    const cJSON *path_value;
    char *quoted_path;
    char command[4096];
    long limit;
    const char *path;

    path_value = cJSON_GetObjectItemCaseSensitive(input, "path");
    path = cJSON_IsString(path_value) && path_value->valuestring != NULL ? path_value->valuestring : ".";
    limit = psi_tool_json_get_long(input, "limit", 500l);

    quoted_path = psi_tool_shell_quote(path);
    if (quoted_path == NULL) {
        return psi_tool_error_json("ls", "out of memory while preparing command");
    }

    sprintf(command, "ls -1A %s | sed -n '1,%ldp'", quoted_path, limit);
    free(quoted_path);
    return psi_tool_shell_command_json("ls", command, path, 1);
}

int psi_tool_schemas_json(char **output_json) {
    cJSON *tools;
    cJSON *tool;
    cJSON *schema;
    cJSON *properties;
    cJSON *required;

    if (output_json == NULL) {
        return PSI_STATUS_ERROR;
    }

    *output_json = NULL;
    tools = cJSON_CreateArray();
    if (tools == NULL) {
        return PSI_STATUS_ERROR;
    }

    tool = cJSON_CreateObject();
    schema = cJSON_CreateObject();
    properties = cJSON_CreateObject();
    required = cJSON_CreateArray();
    cJSON_AddStringToObject(tool, "name", "read");
    cJSON_AddStringToObject(tool, "description", psi_builtin_tools[0].description);
    cJSON_AddStringToObject(schema, "type", "object");
    cJSON_AddItemToObject(schema, "properties", properties);
    cJSON_AddItemToObject(schema, "required", required);
    cJSON_AddItemToObject(properties, "path", cJSON_Parse("{\"type\":\"string\"}"));
    cJSON_AddItemToArray(required, cJSON_CreateString("path"));
    cJSON_AddItemToObject(tool, "input_schema", schema);
    cJSON_AddItemToArray(tools, tool);

    tool = cJSON_CreateObject();
    schema = cJSON_CreateObject();
    properties = cJSON_CreateObject();
    required = cJSON_CreateArray();
    cJSON_AddStringToObject(tool, "name", "grep");
    cJSON_AddStringToObject(tool, "description", psi_builtin_tools[4].description);
    cJSON_AddStringToObject(schema, "type", "object");
    cJSON_AddItemToObject(schema, "properties", properties);
    cJSON_AddItemToObject(schema, "required", required);
    cJSON_AddItemToObject(properties, "pattern", cJSON_Parse("{\"type\":\"string\"}"));
    cJSON_AddItemToObject(properties, "path", cJSON_Parse("{\"type\":\"string\"}"));
    cJSON_AddItemToObject(properties, "glob", cJSON_Parse("{\"type\":\"string\"}"));
    cJSON_AddItemToObject(properties, "ignoreCase", cJSON_Parse("{\"type\":\"boolean\"}"));
    cJSON_AddItemToObject(properties, "literal", cJSON_Parse("{\"type\":\"boolean\"}"));
    cJSON_AddItemToObject(properties, "context", cJSON_Parse("{\"type\":\"number\"}"));
    cJSON_AddItemToObject(properties, "limit", cJSON_Parse("{\"type\":\"number\"}"));
    cJSON_AddItemToArray(required, cJSON_CreateString("pattern"));
    cJSON_AddItemToObject(tool, "input_schema", schema);
    cJSON_AddItemToArray(tools, tool);

    tool = cJSON_CreateObject();
    schema = cJSON_CreateObject();
    properties = cJSON_CreateObject();
    required = cJSON_CreateArray();
    cJSON_AddStringToObject(tool, "name", "find");
    cJSON_AddStringToObject(tool, "description", psi_builtin_tools[5].description);
    cJSON_AddStringToObject(schema, "type", "object");
    cJSON_AddItemToObject(schema, "properties", properties);
    cJSON_AddItemToObject(schema, "required", required);
    cJSON_AddItemToObject(properties, "pattern", cJSON_Parse("{\"type\":\"string\"}"));
    cJSON_AddItemToObject(properties, "path", cJSON_Parse("{\"type\":\"string\"}"));
    cJSON_AddItemToObject(properties, "limit", cJSON_Parse("{\"type\":\"number\"}"));
    cJSON_AddItemToArray(required, cJSON_CreateString("pattern"));
    cJSON_AddItemToObject(tool, "input_schema", schema);
    cJSON_AddItemToArray(tools, tool);

    tool = cJSON_CreateObject();
    schema = cJSON_CreateObject();
    properties = cJSON_CreateObject();
    required = cJSON_CreateArray();
    cJSON_AddStringToObject(tool, "name", "ls");
    cJSON_AddStringToObject(tool, "description", psi_builtin_tools[6].description);
    cJSON_AddStringToObject(schema, "type", "object");
    cJSON_AddItemToObject(schema, "properties", properties);
    cJSON_AddItemToObject(schema, "required", required);
    cJSON_AddItemToObject(properties, "path", cJSON_Parse("{\"type\":\"string\"}"));
    cJSON_AddItemToObject(properties, "limit", cJSON_Parse("{\"type\":\"number\"}"));
    cJSON_AddItemToObject(tool, "input_schema", schema);
    cJSON_AddItemToArray(tools, tool);

    tool = cJSON_CreateObject();
    schema = cJSON_CreateObject();
    properties = cJSON_CreateObject();
    required = cJSON_CreateArray();
    cJSON_AddStringToObject(tool, "name", "bash");
    cJSON_AddStringToObject(tool, "description", psi_builtin_tools[1].description);
    cJSON_AddStringToObject(schema, "type", "object");
    cJSON_AddItemToObject(schema, "properties", properties);
    cJSON_AddItemToObject(schema, "required", required);
    cJSON_AddItemToObject(properties, "command", cJSON_Parse("{\"type\":\"string\"}"));
    cJSON_AddItemToObject(properties, "timeout", cJSON_Parse("{\"type\":\"number\"}"));
    cJSON_AddItemToArray(required, cJSON_CreateString("command"));
    cJSON_AddItemToObject(tool, "input_schema", schema);
    cJSON_AddItemToArray(tools, tool);

    tool = cJSON_CreateObject();
    schema = cJSON_CreateObject();
    properties = cJSON_CreateObject();
    required = cJSON_CreateArray();
    cJSON_AddStringToObject(tool, "name", "edit");
    cJSON_AddStringToObject(tool, "description", psi_builtin_tools[2].description);
    cJSON_AddStringToObject(schema, "type", "object");
    cJSON_AddItemToObject(schema, "properties", properties);
    cJSON_AddItemToObject(schema, "required", required);
    cJSON_AddItemToObject(properties, "path", cJSON_Parse("{\"type\":\"string\"}"));
    cJSON_AddItemToObject(
        properties,
        "edits",
        cJSON_Parse(
            "{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"oldText\":{\"type\":\"string\"},\"newText\":{\"type\":\"string\"}},\"required\":[\"oldText\",\"newText\"]}}"
        )
    );
    cJSON_AddItemToArray(required, cJSON_CreateString("path"));
    cJSON_AddItemToArray(required, cJSON_CreateString("edits"));
    cJSON_AddItemToObject(tool, "input_schema", schema);
    cJSON_AddItemToArray(tools, tool);

    tool = cJSON_CreateObject();
    schema = cJSON_CreateObject();
    properties = cJSON_CreateObject();
    required = cJSON_CreateArray();
    cJSON_AddStringToObject(tool, "name", "write");
    cJSON_AddStringToObject(tool, "description", psi_builtin_tools[3].description);
    cJSON_AddStringToObject(schema, "type", "object");
    cJSON_AddItemToObject(schema, "properties", properties);
    cJSON_AddItemToObject(schema, "required", required);
    cJSON_AddItemToObject(properties, "path", cJSON_Parse("{\"type\":\"string\"}"));
    cJSON_AddItemToObject(properties, "content", cJSON_Parse("{\"type\":\"string\"}"));
    cJSON_AddItemToArray(required, cJSON_CreateString("path"));
    cJSON_AddItemToArray(required, cJSON_CreateString("content"));
    cJSON_AddItemToObject(tool, "input_schema", schema);
    cJSON_AddItemToArray(tools, tool);

    *output_json = cJSON_PrintUnformatted(tools);
    cJSON_Delete(tools);
    return *output_json != NULL ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

int psi_tool_call_json(const char *tool_name, const char *input_json, char **output_json) {
    cJSON *input;

    if (output_json == NULL) {
        return PSI_STATUS_ERROR;
    }
    *output_json = NULL;

    if (tool_name == NULL || input_json == NULL) {
        *output_json = psi_tool_error_json(tool_name, "missing tool name or JSON input");
        return *output_json != NULL ? PSI_STATUS_OK : PSI_STATUS_ERROR;
    }

    input = cJSON_Parse(input_json);
    if (input == NULL || !cJSON_IsObject(input)) {
        if (input != NULL) {
            cJSON_Delete(input);
        }
        *output_json = psi_tool_error_json(tool_name, "invalid JSON object input");
        return *output_json != NULL ? PSI_STATUS_OK : PSI_STATUS_ERROR;
    }

    if (strcmp(tool_name, "read") == 0) {
        *output_json = psi_tool_call_read(input);
    } else if (strcmp(tool_name, "write") == 0) {
        *output_json = psi_tool_call_write(input);
    } else if (strcmp(tool_name, "edit") == 0) {
        *output_json = psi_tool_call_edit(input);
    } else if (strcmp(tool_name, "bash") == 0) {
        *output_json = psi_tool_call_bash(input);
    } else if (strcmp(tool_name, "grep") == 0) {
        *output_json = psi_tool_call_grep(input);
    } else if (strcmp(tool_name, "find") == 0) {
        *output_json = psi_tool_call_find(input);
    } else if (strcmp(tool_name, "ls") == 0) {
        *output_json = psi_tool_call_ls(input);
    } else {
        *output_json = psi_tool_error_json(tool_name, "unknown tool");
    }

    cJSON_Delete(input);
    return *output_json != NULL ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}
