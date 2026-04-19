#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <curl/curl.h>
#include <cjson/cJSON.h>
#include "psi/anthropic.h"
#include "psi/common.h"
#include "psi/prompt.h"
#include "psi/tool.h"

struct psi_http_buffer {
    char *data;
    size_t length;
};

struct psi_stream_block {
    char *type;
    char *text;
    char *id;
    char *name;
    char *input_json;
};

struct psi_string_buffer {
    char *data;
    size_t length;
    size_t capacity;
};

struct psi_stream_state {
    struct psi_http_buffer raw_response;
    struct psi_string_buffer line_buffer;
    struct psi_string_buffer event_name;
    struct psi_string_buffer event_data;
    struct psi_stream_block *blocks;
    size_t block_count;
    size_t block_capacity;
    int wrote_text;
    char *error_message;
};

static void psi_string_buffer_init(struct psi_string_buffer *buffer) {
    buffer->data = NULL;
    buffer->length = 0u;
    buffer->capacity = 0u;
}

static void psi_string_buffer_free(struct psi_string_buffer *buffer) {
    free(buffer->data);
    buffer->data = NULL;
    buffer->length = 0u;
    buffer->capacity = 0u;
}

static int psi_string_buffer_reserve(struct psi_string_buffer *buffer, size_t extra) {
    size_t required;
    size_t next_capacity;
    char *next_data;

    required = buffer->length + extra + 1u;
    if (required <= buffer->capacity) {
        return PSI_STATUS_OK;
    }

    next_capacity = buffer->capacity == 0u ? 256u : buffer->capacity;
    while (next_capacity < required) {
        next_capacity *= 2u;
    }

    next_data = (char *)realloc(buffer->data, next_capacity);
    if (next_data == NULL) {
        return PSI_STATUS_ERROR;
    }

    buffer->data = next_data;
    buffer->capacity = next_capacity;
    return PSI_STATUS_OK;
}

static int psi_string_buffer_append(struct psi_string_buffer *buffer, const char *text) {
    size_t length;

    length = text != NULL ? strlen(text) : 0u;
    if (length == 0u) {
        return PSI_STATUS_OK;
    }

    if (psi_string_buffer_reserve(buffer, length) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    memcpy(buffer->data + buffer->length, text, length);
    buffer->length += length;
    buffer->data[buffer->length] = '\0';
    return PSI_STATUS_OK;
}

static int psi_string_buffer_append_n(struct psi_string_buffer *buffer, const char *text, size_t length) {
    if (length == 0u) {
        return PSI_STATUS_OK;
    }

    if (psi_string_buffer_reserve(buffer, length) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    memcpy(buffer->data + buffer->length, text, length);
    buffer->length += length;
    buffer->data[buffer->length] = '\0';
    return PSI_STATUS_OK;
}

static void psi_stream_block_free(struct psi_stream_block *block) {
    free(block->type);
    free(block->text);
    free(block->id);
    free(block->name);
    free(block->input_json);
    block->type = NULL;
    block->text = NULL;
    block->id = NULL;
    block->name = NULL;
    block->input_json = NULL;
}

static void psi_stream_state_init(struct psi_stream_state *state) {
    state->raw_response.data = NULL;
    state->raw_response.length = 0u;
    psi_string_buffer_init(&state->line_buffer);
    psi_string_buffer_init(&state->event_name);
    psi_string_buffer_init(&state->event_data);
    state->blocks = NULL;
    state->block_count = 0u;
    state->block_capacity = 0u;
    state->wrote_text = 0;
    state->error_message = NULL;
}

static void psi_stream_state_free(struct psi_stream_state *state) {
    size_t index;

    free(state->raw_response.data);
    psi_string_buffer_free(&state->line_buffer);
    psi_string_buffer_free(&state->event_name);
    psi_string_buffer_free(&state->event_data);
    for (index = 0u; index < state->block_count; index++) {
        psi_stream_block_free(&state->blocks[index]);
    }
    free(state->blocks);
    free(state->error_message);
}

static int psi_stream_ensure_block(struct psi_stream_state *state, size_t index) {
    struct psi_stream_block *next_blocks;
    size_t next_capacity;
    size_t scan;

    if (index < state->block_count) {
        return PSI_STATUS_OK;
    }

    next_capacity = state->block_capacity == 0u ? 8u : state->block_capacity;
    while (next_capacity <= index) {
        next_capacity *= 2u;
    }

    next_blocks = (struct psi_stream_block *)realloc(state->blocks, next_capacity * sizeof(struct psi_stream_block));
    if (next_blocks == NULL) {
        return PSI_STATUS_ERROR;
    }

    state->blocks = next_blocks;
    for (scan = state->block_count; scan < next_capacity; scan++) {
        state->blocks[scan].type = NULL;
        state->blocks[scan].text = NULL;
        state->blocks[scan].id = NULL;
        state->blocks[scan].name = NULL;
        state->blocks[scan].input_json = NULL;
    }
    state->block_capacity = next_capacity;
    state->block_count = index + 1u;
    return PSI_STATUS_OK;
}

static int psi_stream_append_raw(struct psi_http_buffer *buffer, const char *data, size_t length) {
    char *next_data;

    next_data = (char *)realloc(buffer->data, buffer->length + length + 1u);
    if (next_data == NULL) {
        return PSI_STATUS_ERROR;
    }

    buffer->data = next_data;
    memcpy(buffer->data + buffer->length, data, length);
    buffer->length += length;
    buffer->data[buffer->length] = '\0';
    return PSI_STATUS_OK;
}

static int psi_stream_dispatch_event(struct psi_stream_state *state) {
    cJSON *event;
    cJSON *content_block;
    cJSON *delta;
    cJSON *index_value;
    cJSON *type;
    cJSON *text;
    cJSON *partial_json;
    struct psi_stream_block *block;
    size_t index;
    char *next_text;

    if (state->event_data.data == NULL || state->event_data.length == 0u) {
        return PSI_STATUS_OK;
    }

    event = cJSON_Parse(state->event_data.data);
    if (event == NULL) {
        return PSI_STATUS_OK;
    }

    type = cJSON_GetObjectItemCaseSensitive(event, "type");
    if (!cJSON_IsString(type) || type->valuestring == NULL) {
        cJSON_Delete(event);
        return PSI_STATUS_OK;
    }

    if (strcmp(type->valuestring, "content_block_start") == 0) {
        index_value = cJSON_GetObjectItemCaseSensitive(event, "index");
        content_block = cJSON_GetObjectItemCaseSensitive(event, "content_block");
        if (cJSON_IsNumber(index_value) && cJSON_IsObject(content_block)) {
            index = (size_t)index_value->valuedouble;
            if (psi_stream_ensure_block(state, index) != PSI_STATUS_OK) {
                cJSON_Delete(event);
                return PSI_STATUS_ERROR;
            }
            block = &state->blocks[index];
            psi_stream_block_free(block);
            block->type = psi_strdup(cJSON_GetObjectItemCaseSensitive(content_block, "type")->valuestring);
            text = cJSON_GetObjectItemCaseSensitive(content_block, "text");
            if (cJSON_IsString(text) && text->valuestring != NULL) {
                block->text = psi_strdup(text->valuestring);
            }
            text = cJSON_GetObjectItemCaseSensitive(content_block, "id");
            if (cJSON_IsString(text) && text->valuestring != NULL) {
                block->id = psi_strdup(text->valuestring);
            }
            text = cJSON_GetObjectItemCaseSensitive(content_block, "name");
            if (cJSON_IsString(text) && text->valuestring != NULL) {
                block->name = psi_strdup(text->valuestring);
            }
        }
    } else if (strcmp(type->valuestring, "content_block_delta") == 0) {
        index_value = cJSON_GetObjectItemCaseSensitive(event, "index");
        delta = cJSON_GetObjectItemCaseSensitive(event, "delta");
        if (cJSON_IsNumber(index_value) && cJSON_IsObject(delta)) {
            index = (size_t)index_value->valuedouble;
            if (psi_stream_ensure_block(state, index) != PSI_STATUS_OK) {
                cJSON_Delete(event);
                return PSI_STATUS_ERROR;
            }
            block = &state->blocks[index];
            type = cJSON_GetObjectItemCaseSensitive(delta, "type");
            if (cJSON_IsString(type) && type->valuestring != NULL && strcmp(type->valuestring, "text_delta") == 0) {
                text = cJSON_GetObjectItemCaseSensitive(delta, "text");
                if (cJSON_IsString(text) && text->valuestring != NULL) {
                    next_text = (char *)realloc(
                        block->text,
                        (block->text != NULL ? strlen(block->text) : 0u) + strlen(text->valuestring) + 1u
                    );
                    if (next_text == NULL) {
                        cJSON_Delete(event);
                        return PSI_STATUS_ERROR;
                    }
                    if (block->text == NULL) {
                        next_text[0] = '\0';
                    }
                    block->text = next_text;
                    strcat(block->text, text->valuestring);
                    fputs(text->valuestring, stdout);
                    fflush(stdout);
                    state->wrote_text = 1;
                }
            } else if (cJSON_IsString(type) && type->valuestring != NULL &&
                       strcmp(type->valuestring, "input_json_delta") == 0) {
                partial_json = cJSON_GetObjectItemCaseSensitive(delta, "partial_json");
                if (cJSON_IsString(partial_json) && partial_json->valuestring != NULL) {
                    if (block->input_json == NULL) {
                        block->input_json = psi_strdup(partial_json->valuestring);
                    } else {
                        next_text = (char *)realloc(
                            block->input_json,
                            strlen(block->input_json) + strlen(partial_json->valuestring) + 1u
                        );
                        if (next_text == NULL) {
                            cJSON_Delete(event);
                            return PSI_STATUS_ERROR;
                        }
                        block->input_json = next_text;
                        strcat(block->input_json, partial_json->valuestring);
                    }
                }
            }
        }
    } else if (strcmp(type->valuestring, "error") == 0) {
        cJSON *error_obj;
        cJSON *message;
        error_obj = cJSON_GetObjectItemCaseSensitive(event, "error");
        message = error_obj != NULL ? cJSON_GetObjectItemCaseSensitive(error_obj, "message") : NULL;
        if (cJSON_IsString(message) && message->valuestring != NULL) {
            free(state->error_message);
            state->error_message = psi_strdup(message->valuestring);
        }
    }

    cJSON_Delete(event);
    return PSI_STATUS_OK;
}

static int psi_stream_process_bytes(struct psi_stream_state *state, const char *data, size_t length) {
    size_t offset;
    size_t line_length;
    const char *line_start;
    char *line_copy;

    if (psi_stream_append_raw(&state->raw_response, data, length) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    if (psi_string_buffer_append_n(&state->line_buffer, data, length) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    offset = 0u;
    while (offset < state->line_buffer.length) {
        line_start = state->line_buffer.data + offset;
        line_length = 0u;
        while (offset + line_length < state->line_buffer.length && line_start[line_length] != '\n') {
            line_length++;
        }
        if (offset + line_length >= state->line_buffer.length) {
            break;
        }

        line_copy = psi_strdup_n(line_start, line_length);
        if (line_copy == NULL) {
            return PSI_STATUS_ERROR;
        }
        if (line_length > 0u && line_copy[line_length - 1u] == '\r') {
            line_copy[line_length - 1u] = '\0';
        }

        if (line_copy[0] == '\0') {
            if (psi_stream_dispatch_event(state) != PSI_STATUS_OK) {
                free(line_copy);
                return PSI_STATUS_ERROR;
            }
            psi_string_buffer_free(&state->event_name);
            psi_string_buffer_init(&state->event_name);
            psi_string_buffer_free(&state->event_data);
            psi_string_buffer_init(&state->event_data);
        } else if (strncmp(line_copy, "event: ", 7) == 0) {
            psi_string_buffer_free(&state->event_name);
            psi_string_buffer_init(&state->event_name);
            if (psi_string_buffer_append(&state->event_name, line_copy + 7) != PSI_STATUS_OK) {
                free(line_copy);
                return PSI_STATUS_ERROR;
            }
        } else if (strncmp(line_copy, "data: ", 6) == 0) {
            if (state->event_data.length > 0u && psi_string_buffer_append(&state->event_data, "\n") != PSI_STATUS_OK) {
                free(line_copy);
                return PSI_STATUS_ERROR;
            }
            if (psi_string_buffer_append(&state->event_data, line_copy + 6) != PSI_STATUS_OK) {
                free(line_copy);
                return PSI_STATUS_ERROR;
            }
        }

        free(line_copy);
        offset += line_length + 1u;
    }

    if (offset > 0u) {
        memmove(
            state->line_buffer.data,
            state->line_buffer.data + offset,
            state->line_buffer.length - offset
        );
        state->line_buffer.length -= offset;
        state->line_buffer.data[state->line_buffer.length] = '\0';
    }

    return PSI_STATUS_OK;
}

static size_t psi_curl_stream_callback(void *contents, size_t size, size_t nmemb, void *userp) {
    size_t total_size;
    struct psi_stream_state *state;

    total_size = size * nmemb;
    state = (struct psi_stream_state *)userp;
    if (psi_stream_process_bytes(state, (const char *)contents, total_size) != PSI_STATUS_OK) {
        return 0u;
    }
    return total_size;
}

static int psi_stream_state_to_content(const struct psi_stream_state *state, cJSON **content_out) {
    cJSON *content;
    cJSON *block;
    cJSON *input;
    size_t index;

    content = cJSON_CreateArray();
    if (content == NULL) {
        return PSI_STATUS_ERROR;
    }

    for (index = 0u; index < state->block_count; index++) {
        if (state->blocks[index].type == NULL) {
            continue;
        }

        if (strcmp(state->blocks[index].type, "text") == 0) {
            block = cJSON_CreateObject();
            cJSON_AddStringToObject(block, "type", "text");
            cJSON_AddStringToObject(block, "text", state->blocks[index].text != NULL ? state->blocks[index].text : "");
            cJSON_AddItemToArray(content, block);
        } else if (strcmp(state->blocks[index].type, "tool_use") == 0) {
            block = cJSON_CreateObject();
            cJSON_AddStringToObject(block, "type", "tool_use");
            cJSON_AddStringToObject(block, "id", state->blocks[index].id != NULL ? state->blocks[index].id : "");
            cJSON_AddStringToObject(block, "name", state->blocks[index].name != NULL ? state->blocks[index].name : "");
            input = NULL;
            if (state->blocks[index].input_json != NULL && state->blocks[index].input_json[0] != '\0') {
                input = cJSON_Parse(state->blocks[index].input_json);
            }
            if (input == NULL) {
                input = cJSON_CreateObject();
            }
            cJSON_AddItemToObject(block, "input", input);
            cJSON_AddItemToArray(content, block);
        }
    }

    *content_out = content;
    return PSI_STATUS_OK;
}

static const char *psi_anthropic_env_or_default(const char *name, const char *fallback) {
    const char *value;

    value = getenv(name);
    if (value != NULL && value[0] != '\0') {
        return value;
    }
    return fallback;
}

static int psi_anthropic_extract_text(const cJSON *content, char **text_out) {
    const cJSON *block;
    const cJSON *type;
    const cJSON *text;
    struct psi_string_buffer buffer;
    int first_text;

    *text_out = NULL;
    psi_string_buffer_init(&buffer);
    first_text = 1;

    cJSON_ArrayForEach(block, content) {
        if (!cJSON_IsObject(block)) {
            continue;
        }

        type = cJSON_GetObjectItemCaseSensitive(block, "type");
        text = cJSON_GetObjectItemCaseSensitive(block, "text");
        if (cJSON_IsString(type) &&
            type->valuestring != NULL &&
            strcmp(type->valuestring, "text") == 0 &&
            cJSON_IsString(text) &&
            text->valuestring != NULL) {
            if (!first_text && psi_string_buffer_append(&buffer, "\n") != PSI_STATUS_OK) {
                psi_string_buffer_free(&buffer);
                return PSI_STATUS_ERROR;
            }
            if (psi_string_buffer_append(&buffer, text->valuestring) != PSI_STATUS_OK) {
                psi_string_buffer_free(&buffer);
                return PSI_STATUS_ERROR;
            }
            first_text = 0;
        }
    }

    if (buffer.data == NULL) {
        *text_out = psi_strdup("");
    } else {
        *text_out = buffer.data;
        buffer.data = NULL;
    }
    psi_string_buffer_free(&buffer);
    return *text_out != NULL ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

static int psi_anthropic_response_has_tool_use(const cJSON *content) {
    const cJSON *block;
    const cJSON *type;

    cJSON_ArrayForEach(block, content) {
        type = cJSON_GetObjectItemCaseSensitive(block, "type");
        if (cJSON_IsString(type) && type->valuestring != NULL && strcmp(type->valuestring, "tool_use") == 0) {
            return 1;
        }
    }

    return 0;
}

static int psi_anthropic_tool_result_is_error(const char *tool_output) {
    cJSON *root;
    cJSON *ok;
    int is_error;

    root = cJSON_Parse(tool_output);
    if (root == NULL) {
        return 1;
    }

    ok = cJSON_GetObjectItemCaseSensitive(root, "ok");
    is_error = !(cJSON_IsBool(ok) && cJSON_IsTrue(ok));
    cJSON_Delete(root);
    return is_error;
}

static int psi_anthropic_append_session_tool_call(struct psi_session *session, const cJSON *tool_use) {
    cJSON *entry;
    char *entry_text;
    const cJSON *id;
    const cJSON *name;
    const cJSON *input;
    int status;

    id = cJSON_GetObjectItemCaseSensitive(tool_use, "id");
    name = cJSON_GetObjectItemCaseSensitive(tool_use, "name");
    input = cJSON_GetObjectItemCaseSensitive(tool_use, "input");
    if (!cJSON_IsString(id) || id->valuestring == NULL || !cJSON_IsString(name) || name->valuestring == NULL) {
        return PSI_STATUS_ERROR;
    }

    entry = cJSON_CreateObject();
    if (entry == NULL) {
        return PSI_STATUS_ERROR;
    }
    cJSON_AddStringToObject(entry, "id", id->valuestring);
    cJSON_AddStringToObject(entry, "name", name->valuestring);
    cJSON_AddItemToObject(entry, "input", input != NULL ? cJSON_Duplicate(input, 1) : cJSON_CreateObject());
    entry_text = cJSON_PrintUnformatted(entry);
    cJSON_Delete(entry);
    if (entry_text == NULL) {
        return PSI_STATUS_ERROR;
    }

    status = psi_session_append(session, PSI_MESSAGE_TOOL_CALL, entry_text);
    free(entry_text);
    return status;
}

static int psi_anthropic_append_session_tool_result(
    struct psi_session *session,
    const char *tool_use_id,
    const char *tool_name,
    const char *tool_output
) {
    cJSON *entry;
    char *entry_text;
    int status;

    entry = cJSON_CreateObject();
    if (entry == NULL) {
        return PSI_STATUS_ERROR;
    }
    cJSON_AddStringToObject(entry, "tool_use_id", tool_use_id);
    cJSON_AddStringToObject(entry, "tool", tool_name);
    cJSON_AddStringToObject(entry, "content", tool_output);
    cJSON_AddBoolToObject(entry, "is_error", psi_anthropic_tool_result_is_error(tool_output));
    entry_text = cJSON_PrintUnformatted(entry);
    cJSON_Delete(entry);
    if (entry_text == NULL) {
        return PSI_STATUS_ERROR;
    }

    status = psi_session_append(session, PSI_MESSAGE_TOOL_RESULT, entry_text);
    free(entry_text);
    return status;
}

static int psi_anthropic_session_to_messages(const struct psi_session *session, cJSON **messages_out) {
    cJSON *messages;
    cJSON *message;
    cJSON *content;
    cJSON *parsed;
    cJSON *item;
    size_t index;

    messages = cJSON_CreateArray();
    if (messages == NULL) {
        return PSI_STATUS_ERROR;
    }

    index = 0u;
    while (index < session->count) {
        if (session->messages[index].role == PSI_MESSAGE_USER || session->messages[index].role == PSI_MESSAGE_ASSISTANT) {
            message = cJSON_CreateObject();
            content = cJSON_CreateString(session->messages[index].text ? session->messages[index].text : "");
            if (message == NULL || content == NULL) {
                cJSON_Delete(message);
                cJSON_Delete(content);
                cJSON_Delete(messages);
                return PSI_STATUS_ERROR;
            }
            cJSON_AddStringToObject(
                message,
                "role",
                session->messages[index].role == PSI_MESSAGE_USER ? "user" : "assistant"
            );
            cJSON_AddItemToObject(message, "content", content);
            cJSON_AddItemToArray(messages, message);
            index++;
            continue;
        }

        if (session->messages[index].role == PSI_MESSAGE_TOOL_CALL) {
            message = cJSON_CreateObject();
            content = cJSON_CreateArray();
            if (message == NULL || content == NULL) {
                cJSON_Delete(message);
                cJSON_Delete(content);
                cJSON_Delete(messages);
                return PSI_STATUS_ERROR;
            }
            cJSON_AddStringToObject(message, "role", "assistant");

            while (index < session->count && session->messages[index].role == PSI_MESSAGE_TOOL_CALL) {
                parsed = cJSON_Parse(session->messages[index].text);
                if (parsed != NULL) {
                    if (!cJSON_IsString(cJSON_GetObjectItemCaseSensitive(parsed, "id")) ||
                        !cJSON_IsString(cJSON_GetObjectItemCaseSensitive(parsed, "name"))) {
                        cJSON_Delete(parsed);
                        index++;
                        continue;
                    }
                    item = cJSON_CreateObject();
                    if (item == NULL) {
                        cJSON_Delete(parsed);
                        cJSON_Delete(message);
                        cJSON_Delete(content);
                        cJSON_Delete(messages);
                        return PSI_STATUS_ERROR;
                    }
                    cJSON_AddStringToObject(item, "type", "tool_use");
                    cJSON_AddStringToObject(
                        item,
                        "id",
                        cJSON_GetObjectItemCaseSensitive(parsed, "id")->valuestring
                    );
                    cJSON_AddStringToObject(
                        item,
                        "name",
                        cJSON_GetObjectItemCaseSensitive(parsed, "name")->valuestring
                    );
                    cJSON_AddItemToObject(
                        item,
                        "input",
                        cJSON_Duplicate(cJSON_GetObjectItemCaseSensitive(parsed, "input"), 1)
                    );
                    cJSON_AddItemToArray(content, item);
                    cJSON_Delete(parsed);
                }
                index++;
            }

            cJSON_AddItemToObject(message, "content", content);
            cJSON_AddItemToArray(messages, message);
            continue;
        }

        if (session->messages[index].role == PSI_MESSAGE_TOOL_RESULT) {
            message = cJSON_CreateObject();
            content = cJSON_CreateArray();
            if (message == NULL || content == NULL) {
                cJSON_Delete(message);
                cJSON_Delete(content);
                cJSON_Delete(messages);
                return PSI_STATUS_ERROR;
            }
            cJSON_AddStringToObject(message, "role", "user");

            while (index < session->count && session->messages[index].role == PSI_MESSAGE_TOOL_RESULT) {
                parsed = cJSON_Parse(session->messages[index].text);
                if (parsed != NULL) {
                    if (!cJSON_IsString(cJSON_GetObjectItemCaseSensitive(parsed, "tool_use_id")) ||
                        !cJSON_IsString(cJSON_GetObjectItemCaseSensitive(parsed, "content"))) {
                        cJSON_Delete(parsed);
                        index++;
                        continue;
                    }
                    item = cJSON_CreateObject();
                    if (item == NULL) {
                        cJSON_Delete(parsed);
                        cJSON_Delete(message);
                        cJSON_Delete(content);
                        cJSON_Delete(messages);
                        return PSI_STATUS_ERROR;
                    }
                    cJSON_AddStringToObject(item, "type", "tool_result");
                    cJSON_AddStringToObject(
                        item,
                        "tool_use_id",
                        cJSON_GetObjectItemCaseSensitive(parsed, "tool_use_id")->valuestring
                    );
                    cJSON_AddStringToObject(
                        item,
                        "content",
                        cJSON_GetObjectItemCaseSensitive(parsed, "content")->valuestring
                    );
                    cJSON_AddBoolToObject(
                        item,
                        "is_error",
                        cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(parsed, "is_error"))
                    );
                    cJSON_AddItemToArray(content, item);
                    cJSON_Delete(parsed);
                }
                index++;
            }

            cJSON_AddItemToObject(message, "content", content);
            cJSON_AddItemToArray(messages, message);
            continue;
        }

        index++;
    }

    *messages_out = messages;
    return PSI_STATUS_OK;
}

static int psi_anthropic_http_stream(
    const char *base_url,
    const char *api_key,
    const char *request_json,
    struct psi_stream_state *state,
    long *status_code
) {
    CURL *curl;
    CURLcode code;
    struct curl_slist *headers;
    char *url;
    const char *separator;
    size_t url_length;
    char *api_key_header;

    *status_code = 0l;
    curl = NULL;
    headers = NULL;

    separator = base_url[strlen(base_url) - 1u] == '/' ? "" : "/";
    url_length = strlen(base_url) + strlen(separator) + strlen("v1/messages") + 1u;
    url = (char *)malloc(url_length);
    if (url == NULL) {
        return PSI_STATUS_ERROR;
    }
    sprintf(url, "%s%sv1/messages", base_url, separator);

    api_key_header = (char *)malloc(strlen(api_key) + strlen("x-api-key: ") + 1u);
    if (api_key_header == NULL) {
        free(url);
        return PSI_STATUS_ERROR;
    }
    sprintf(api_key_header, "x-api-key: %s", api_key);

    code = curl_global_init(CURL_GLOBAL_DEFAULT);
    if (code != CURLE_OK) {
        free(api_key_header);
        free(url);
        return PSI_STATUS_ERROR;
    }

    curl = curl_easy_init();
    if (curl == NULL) {
        curl_global_cleanup();
        free(api_key_header);
        free(url);
        return PSI_STATUS_ERROR;
    }

    headers = curl_slist_append(headers, "content-type: application/json");
    headers = curl_slist_append(headers, "anthropic-version: 2023-06-01");
    headers = curl_slist_append(headers, api_key_header);

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, request_json);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)strlen(request_json));
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, psi_curl_stream_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, (void *)state);

    code = curl_easy_perform(curl);
    if (code == CURLE_OK) {
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, status_code);
    }

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    curl_global_cleanup();
    free(api_key_header);
    free(url);

    if (code != CURLE_OK) {
        return PSI_STATUS_ERROR;
    }
    return PSI_STATUS_OK;
}

static int psi_anthropic_build_request_json(
    const char *model,
    long max_tokens,
    const char *system_prompt,
    const cJSON *messages,
    const cJSON *tools,
    char **request_json
) {
    cJSON *request;

    request = cJSON_CreateObject();
    if (request == NULL) {
        return PSI_STATUS_ERROR;
    }

    cJSON_AddStringToObject(request, "model", model);
    cJSON_AddNumberToObject(request, "max_tokens", (double)max_tokens);
    cJSON_AddStringToObject(request, "system", system_prompt);
    cJSON_AddItemToObject(request, "messages", cJSON_Duplicate(messages, 1));
    cJSON_AddItemToObject(request, "tools", cJSON_Duplicate(tools, 1));
    cJSON_AddItemToObject(request, "tool_choice", cJSON_Parse("{\"type\":\"auto\"}"));
    cJSON_AddBoolToObject(request, "stream", 1);
    *request_json = cJSON_PrintUnformatted(request);
    cJSON_Delete(request);
    return *request_json != NULL ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

int psi_anthropic_agent_turn(
    struct psi_session *session,
    const char *model,
    long max_tokens,
    char **output_text
) {
    const char *api_key;
    const char *base_url;
    const char *resolved_model;
    cJSON *messages;
    cJSON *tools;
    cJSON *content;
    cJSON *assistant_message;
    cJSON *tool_results_message;
    cJSON *tool_results_content;
    cJSON *empty_input;
    cJSON *block;
    cJSON *type;
    cJSON *input;
    cJSON *tool_result_block;
    char *system_prompt;
    char *tools_json;
    char *request_json;
    char *assistant_text;
    char *input_json;
    char *tool_output;
    const cJSON *id;
    const cJSON *name;
    long status_code;
    int loop_count;
    struct psi_stream_state stream_state;

    if (session == NULL || output_text == NULL) {
        return PSI_STATUS_ERROR;
    }

    *output_text = NULL;
    system_prompt = NULL;
    tools_json = NULL;
    request_json = NULL;
    assistant_text = NULL;
    messages = NULL;
    tools = NULL;
    resolved_model = model != NULL ? model : psi_anthropic_env_or_default("PSI_ANTHROPIC_MODEL", "claude-opus-4-7");
    api_key = getenv("ANTHROPIC_API_KEY");
    base_url = psi_anthropic_env_or_default("PSI_ANTHROPIC_BASE_URL", "https://api.anthropic.com/");

    if (api_key == NULL || api_key[0] == '\0') {
        fprintf(stderr, "ANTHROPIC_API_KEY is not set\n");
        return PSI_STATUS_ERROR;
    }

    if (psi_build_system_prompt(&system_prompt) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }
    if (psi_tool_schemas_json(&tools_json) != PSI_STATUS_OK) {
        free(system_prompt);
        return PSI_STATUS_ERROR;
    }
    tools = cJSON_Parse(tools_json);
    free(tools_json);
    if (tools == NULL) {
        free(system_prompt);
        return PSI_STATUS_ERROR;
    }
    if (psi_anthropic_session_to_messages(session, &messages) != PSI_STATUS_OK) {
        free(system_prompt);
        cJSON_Delete(tools);
        return PSI_STATUS_ERROR;
    }

    loop_count = 0;
    while (loop_count < 32) {
        loop_count++;
        psi_stream_state_init(&stream_state);
        if (psi_anthropic_build_request_json(resolved_model, max_tokens, system_prompt, messages, tools, &request_json) != PSI_STATUS_OK) {
            free(system_prompt);
            cJSON_Delete(tools);
            cJSON_Delete(messages);
            return PSI_STATUS_ERROR;
        }

        if (psi_anthropic_http_stream(base_url, api_key, request_json, &stream_state, &status_code) != PSI_STATUS_OK) {
            free(request_json);
            psi_stream_state_free(&stream_state);
            free(system_prompt);
            cJSON_Delete(tools);
            cJSON_Delete(messages);
            return PSI_STATUS_ERROR;
        }
        free(request_json);
        request_json = NULL;

        if (status_code < 200l || status_code >= 300l) {
            fprintf(
                stderr,
                "Anthropic API request failed (%ld): %s\n",
                status_code,
                stream_state.raw_response.data != NULL ? stream_state.raw_response.data : ""
            );
            psi_stream_state_free(&stream_state);
            free(system_prompt);
            cJSON_Delete(tools);
            cJSON_Delete(messages);
            return PSI_STATUS_ERROR;
        }

        if (stream_state.error_message != NULL) {
            fprintf(stderr, "Anthropic stream error: %s\n", stream_state.error_message);
            psi_stream_state_free(&stream_state);
            free(system_prompt);
            cJSON_Delete(tools);
            cJSON_Delete(messages);
            return PSI_STATUS_ERROR;
        }

        if (psi_stream_state_to_content(&stream_state, &content) != PSI_STATUS_OK) {
            psi_stream_state_free(&stream_state);
            free(system_prompt);
            cJSON_Delete(tools);
            cJSON_Delete(messages);
            return PSI_STATUS_ERROR;
        }

        assistant_message = cJSON_CreateObject();
        cJSON_AddStringToObject(assistant_message, "role", "assistant");
        cJSON_AddItemToObject(assistant_message, "content", cJSON_Duplicate(content, 1));
        cJSON_AddItemToArray(messages, assistant_message);

        if (psi_anthropic_extract_text(content, &assistant_text) != PSI_STATUS_OK) {
            cJSON_Delete(content);
            psi_stream_state_free(&stream_state);
            free(system_prompt);
            cJSON_Delete(tools);
            cJSON_Delete(messages);
            return PSI_STATUS_ERROR;
        }

        if (!psi_anthropic_response_has_tool_use(content)) {
            if (psi_session_append(session, PSI_MESSAGE_ASSISTANT, assistant_text) != PSI_STATUS_OK) {
                free(assistant_text);
                cJSON_Delete(content);
                psi_stream_state_free(&stream_state);
                free(system_prompt);
                cJSON_Delete(tools);
                cJSON_Delete(messages);
                return PSI_STATUS_ERROR;
            }
            if (stream_state.wrote_text) {
                fputc('\n', stdout);
            }
            *output_text = assistant_text;
            cJSON_Delete(content);
            psi_stream_state_free(&stream_state);
            free(system_prompt);
            cJSON_Delete(tools);
            cJSON_Delete(messages);
            return PSI_STATUS_OK;
        }

        if (assistant_text[0] != '\0' && psi_session_append(session, PSI_MESSAGE_ASSISTANT, assistant_text) != PSI_STATUS_OK) {
            free(assistant_text);
            cJSON_Delete(content);
            psi_stream_state_free(&stream_state);
            free(system_prompt);
            cJSON_Delete(tools);
            cJSON_Delete(messages);
            return PSI_STATUS_ERROR;
        }
        free(assistant_text);
        assistant_text = NULL;

        tool_results_message = cJSON_CreateObject();
        tool_results_content = cJSON_CreateArray();
        cJSON_AddStringToObject(tool_results_message, "role", "user");
        cJSON_AddItemToObject(tool_results_message, "content", tool_results_content);

        cJSON_ArrayForEach(block, content) {
            type = cJSON_GetObjectItemCaseSensitive(block, "type");
            if (!cJSON_IsString(type) || type->valuestring == NULL || strcmp(type->valuestring, "tool_use") != 0) {
                continue;
            }

            if (psi_anthropic_append_session_tool_call(session, block) != PSI_STATUS_OK) {
                cJSON_Delete(tool_results_message);
                cJSON_Delete(content);
                psi_stream_state_free(&stream_state);
                free(system_prompt);
                cJSON_Delete(tools);
                cJSON_Delete(messages);
                return PSI_STATUS_ERROR;
            }

            id = cJSON_GetObjectItemCaseSensitive(block, "id");
            name = cJSON_GetObjectItemCaseSensitive(block, "name");
            input = cJSON_GetObjectItemCaseSensitive(block, "input");
            if (!cJSON_IsString(id) || id->valuestring == NULL || !cJSON_IsString(name) || name->valuestring == NULL) {
                cJSON_Delete(tool_results_message);
                cJSON_Delete(content);
                psi_stream_state_free(&stream_state);
                free(system_prompt);
                cJSON_Delete(tools);
                cJSON_Delete(messages);
                return PSI_STATUS_ERROR;
            }

            if (input == NULL) {
                empty_input = cJSON_CreateObject();
                input_json = cJSON_PrintUnformatted(empty_input);
                cJSON_Delete(empty_input);
            } else {
                input_json = cJSON_PrintUnformatted(input);
            }
            if (input_json == NULL) {
                cJSON_Delete(tool_results_message);
                cJSON_Delete(content);
                psi_stream_state_free(&stream_state);
                free(system_prompt);
                cJSON_Delete(tools);
                cJSON_Delete(messages);
                return PSI_STATUS_ERROR;
            }

            if (psi_tool_call_json(name->valuestring, input_json, &tool_output) != PSI_STATUS_OK) {
                free(input_json);
                cJSON_Delete(tool_results_message);
                cJSON_Delete(content);
                psi_stream_state_free(&stream_state);
                free(system_prompt);
                cJSON_Delete(tools);
                cJSON_Delete(messages);
                return PSI_STATUS_ERROR;
            }
            free(input_json);

            if (psi_anthropic_append_session_tool_result(session, id->valuestring, name->valuestring, tool_output) != PSI_STATUS_OK) {
                free(tool_output);
                cJSON_Delete(tool_results_message);
                cJSON_Delete(content);
                psi_stream_state_free(&stream_state);
                free(system_prompt);
                cJSON_Delete(tools);
                cJSON_Delete(messages);
                return PSI_STATUS_ERROR;
            }

            tool_result_block = cJSON_CreateObject();
            cJSON_AddStringToObject(tool_result_block, "type", "tool_result");
            cJSON_AddStringToObject(tool_result_block, "tool_use_id", id->valuestring);
            cJSON_AddStringToObject(tool_result_block, "content", tool_output);
            cJSON_AddBoolToObject(tool_result_block, "is_error", psi_anthropic_tool_result_is_error(tool_output));
            cJSON_AddItemToArray(tool_results_content, tool_result_block);
            free(tool_output);
        }

        cJSON_AddItemToArray(messages, tool_results_message);
        cJSON_Delete(content);
        psi_stream_state_free(&stream_state);
    }

    fprintf(stderr, "Anthropic tool loop exceeded 32 iterations\n");
    free(system_prompt);
    cJSON_Delete(tools);
    cJSON_Delete(messages);
    return PSI_STATUS_ERROR;
}
