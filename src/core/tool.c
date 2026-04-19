#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cjson/cJSON.h>
#include "psi/common.h"
#include "psi/tool.h"

static const long PSI_TOOL_FILE_MAX_BYTES = 262144l;

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
    FILE *file;
    cJSON *root;

    path = cJSON_GetObjectItemCaseSensitive(input, "path");
    text = cJSON_GetObjectItemCaseSensitive(input, "text");
    if (!cJSON_IsString(path) || path->valuestring == NULL) {
        return psi_tool_error_json("write", "missing string field: path");
    }
    if (!cJSON_IsString(text) || text->valuestring == NULL) {
        return psi_tool_error_json("write", "missing string field: text");
    }

    file = fopen(path->valuestring, "wb");
    if (file == NULL) {
        return psi_tool_error_json("write", "could not open file for writing");
    }
    if (fwrite(text->valuestring, 1u, strlen(text->valuestring), file) != strlen(text->valuestring)) {
        fclose(file);
        return psi_tool_error_json("write", "could not write full file");
    }
    fclose(file);

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

static char *psi_tool_call_edit(cJSON *input) {
    const cJSON *path;
    const cJSON *old_text;
    const cJSON *new_text;
    char *original;
    char *edited;
    FILE *file;
    cJSON *root;

    path = cJSON_GetObjectItemCaseSensitive(input, "path");
    old_text = cJSON_GetObjectItemCaseSensitive(input, "oldText");
    new_text = cJSON_GetObjectItemCaseSensitive(input, "newText");
    if (!cJSON_IsString(path) || path->valuestring == NULL) {
        return psi_tool_error_json("edit", "missing string field: path");
    }
    if (!cJSON_IsString(old_text) || old_text->valuestring == NULL) {
        return psi_tool_error_json("edit", "missing string field: oldText");
    }
    if (!cJSON_IsString(new_text) || new_text->valuestring == NULL) {
        return psi_tool_error_json("edit", "missing string field: newText");
    }

    original = NULL;
    if (psi_tool_read_file_contents(path->valuestring, &original) != PSI_STATUS_OK) {
        return psi_tool_error_json("edit", "could not read file");
    }

    edited = psi_tool_replace_once(original, old_text->valuestring, new_text->valuestring);
    free(original);
    if (edited == NULL) {
        return psi_tool_error_json("edit", "target text not found");
    }

    file = fopen(path->valuestring, "wb");
    if (file == NULL) {
        free(edited);
        return psi_tool_error_json("edit", "could not open file for writing");
    }
    if (fwrite(edited, 1u, strlen(edited), file) != strlen(edited)) {
        fclose(file);
        free(edited);
        return psi_tool_error_json("edit", "could not write full file");
    }
    fclose(file);

    root = cJSON_CreateObject();
    if (root == NULL) {
        free(edited);
        return NULL;
    }
    cJSON_AddBoolToObject(root, "ok", 1);
    cJSON_AddStringToObject(root, "tool", "edit");
    cJSON_AddStringToObject(root, "path", path->valuestring);
    cJSON_AddNumberToObject(root, "replacements", 1.0);
    free(edited);
    return psi_tool_success_json(root);
}

static char *psi_tool_call_bash(cJSON *input) {
    const cJSON *command;
    cJSON *root;
    int status;

    command = cJSON_GetObjectItemCaseSensitive(input, "command");
    if (!cJSON_IsString(command) || command->valuestring == NULL) {
        return psi_tool_error_json("bash", "missing string field: command");
    }

    status = system(command->valuestring);

    root = cJSON_CreateObject();
    if (root == NULL) {
        return NULL;
    }
    cJSON_AddBoolToObject(root, "ok", 1);
    cJSON_AddStringToObject(root, "tool", "bash");
    cJSON_AddStringToObject(root, "command", command->valuestring);
    cJSON_AddNumberToObject(root, "status", (double)status);
    cJSON_AddStringToObject(root, "note", "uses C system(); shell semantics and status encoding are platform-dependent");
    return psi_tool_success_json(root);
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
    } else {
        *output_json = psi_tool_error_json(tool_name, "unknown tool");
    }

    cJSON_Delete(input);
    return *output_json != NULL ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}
