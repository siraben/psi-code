/* Session + message storage primitives. JSONL I/O, compaction, and
 * fork are all implemented in lua/psi/session.lua — this file just
 * keeps the in-memory message array alive and the role enum mapped
 * to its JSON string form. */

#include <stdlib.h>
#include <string.h>
#include <cjson/cJSON.h>
#include "psi/common.h"
#include "psi/message.h"
#include "psi/session.h"

/* ---------- message primitives (formerly message.c) ---------- */

static size_t psi_estimate_tokens(const char *text) {
    size_t len;
    if (text == NULL || text[0] == '\0') return 0u;
    len = strlen(text);
    return (len + 3u) / 4u;
}

static size_t psi_token_chars_to_tokens(size_t chars) {
    return chars == 0u ? 0u : (chars + 3u) / 4u;
}

static const char *psi_json_string(const cJSON *object, const char *name) {
    cJSON *item;
    if (object == NULL) return NULL;
    item = cJSON_GetObjectItemCaseSensitive((cJSON *)object, name);
    return cJSON_IsString(item) ? item->valuestring : NULL;
}

static size_t psi_json_string_len(const cJSON *object, const char *name) {
    const char *value = psi_json_string(object, name);
    return value != NULL ? strlen(value) : 0u;
}

static size_t psi_json_printed_len(const cJSON *value) {
    char *encoded;
    size_t len;

    if (value == NULL) return 0u;
    encoded = cJSON_PrintUnformatted((cJSON *)value);
    if (encoded == NULL) return 0u;
    len = strlen(encoded);
    free(encoded);
    return len;
}

static size_t psi_estimate_content_chars(const cJSON *content, int mode) {
    size_t chars;
    int i;
    int n;

    if (cJSON_IsString((cJSON *)content)) {
        return content->valuestring != NULL ? strlen(content->valuestring) : 0u;
    }
    if (!cJSON_IsArray((cJSON *)content)) return 0u;

    chars = 0u;
    n = cJSON_GetArraySize((cJSON *)content);
    for (i = 0; i < n; i++) {
        cJSON *block = cJSON_GetArrayItem((cJSON *)content, i);
        const char *type = psi_json_string(block, "type");
        if (type == NULL) continue;
        if (strcmp(type, "text") == 0) {
            chars += psi_json_string_len(block, "text");
        } else if (mode == 1 && strcmp(type, "thinking") == 0) {
            chars += psi_json_string_len(block, "thinking");
        } else if (mode == 1 && strcmp(type, "toolCall") == 0) {
            const cJSON *args;
            chars += psi_json_string_len(block, "name");
            args = cJSON_GetObjectItemCaseSensitive(block, "arguments");
            chars += psi_json_printed_len(args);
        } else if (mode == 2 && strcmp(type, "image") == 0) {
            chars += 4800u;
        }
    }
    return chars;
}

static size_t psi_estimate_structured_tokens(
    enum psi_message_role in_memory_role,
    const char *text,
    const char *data_json
) {
    cJSON *body;
    cJSON *message;
    size_t chars;

    if (data_json == NULL || data_json[0] == '\0') return psi_estimate_tokens(text);

    body = cJSON_Parse(data_json);
    if (body == NULL || !cJSON_IsObject(body)) {
        cJSON_Delete(body);
        return psi_estimate_tokens(text);
    }

    message = cJSON_GetObjectItemCaseSensitive(body, "message");
    if (cJSON_IsObject(message)) {
        const char *role = psi_json_string(message, "role");
        const cJSON *content = cJSON_GetObjectItemCaseSensitive(message, "content");

        if (role != NULL && strcmp(role, "assistant") == 0) {
            chars = psi_estimate_content_chars(content, 1);
            cJSON_Delete(body);
            return psi_token_chars_to_tokens(chars);
        }
        if (role != NULL && strcmp(role, "toolResult") == 0) {
            chars = psi_estimate_content_chars(content, 2);
            cJSON_Delete(body);
            return psi_token_chars_to_tokens(chars);
        }
        if (role != NULL && strcmp(role, "bashExecution") == 0) {
            chars = psi_json_string_len(message, "command") + psi_json_string_len(message, "output");
            cJSON_Delete(body);
            return psi_token_chars_to_tokens(chars);
        }
        if (role != NULL && strcmp(role, "custom") == 0) {
            chars = psi_estimate_content_chars(content, 2);
            cJSON_Delete(body);
            return psi_token_chars_to_tokens(chars);
        }

        chars = psi_estimate_content_chars(content, 0);
        cJSON_Delete(body);
        return psi_token_chars_to_tokens(chars);
    }

    if (in_memory_role == PSI_MESSAGE_COMPACTION_SUMMARY ||
        in_memory_role == PSI_MESSAGE_BRANCH_SUMMARY) {
        chars = psi_json_string_len(body, "summary");
        cJSON_Delete(body);
        return psi_token_chars_to_tokens(chars != 0u ? chars : strlen(text ? text : ""));
    }

    cJSON_Delete(body);
    return psi_estimate_tokens(text);
}

void psi_message_init(struct psi_message *message, enum psi_message_role role, const char *text) {
    psi_message_init_with_data(message, role, text, NULL);
}

void psi_message_init_with_data(
    struct psi_message *message,
    enum psi_message_role role,
    const char *text,
    const char *data_json
) {
    if (message == NULL) return;
    message->role = role;
    message->text = text != NULL ? psi_strdup(text) : NULL;
    message->data_json = data_json != NULL ? psi_strdup(data_json) : NULL;
    message->token_estimate = psi_estimate_structured_tokens(role, text, data_json);
}

void psi_message_free(struct psi_message *message) {
    if (message == NULL) return;
    free(message->text);
    free(message->data_json);
    message->text = NULL;
    message->data_json = NULL;
    message->token_estimate = 0u;
}

const char *psi_message_role_name(enum psi_message_role role) {
    switch (role) {
        case PSI_MESSAGE_USER:               return "user";
        case PSI_MESSAGE_ASSISTANT:          return "assistant";
        case PSI_MESSAGE_TOOL_CALL:          return "tool-call";
        case PSI_MESSAGE_TOOL_RESULT:        return "tool-result";
        case PSI_MESSAGE_CUSTOM:             return "custom";
        case PSI_MESSAGE_BRANCH_SUMMARY:     return "branch-summary";
        case PSI_MESSAGE_COMPACTION_SUMMARY: return "compaction-summary";
        default:                             return "unknown";
    }
}

/* ---------- session storage ---------- */

static int psi_session_clear_messages(struct psi_session *session) {
    size_t index;

    for (index = 0u; index < session->count; index++) {
        psi_message_free(&session->messages[index]);
    }

    free(session->messages);
    free(session->token_prefix);
    session->messages = NULL;
    session->token_prefix = NULL;
    session->count = 0u;
    session->capacity = 0u;
    return PSI_STATUS_OK;
}

static int psi_session_set_string(char **dst, const char *value) {
    char *copy;

    if (value == NULL) {
        free(*dst);
        *dst = NULL;
        return PSI_STATUS_OK;
    }
    copy = psi_strdup(value);
    if (copy == NULL) return PSI_STATUS_ERROR;
    free(*dst);
    *dst = copy;
    return PSI_STATUS_OK;
}

void psi_session_init(struct psi_session *session) {
    if (session == NULL) return;
    session->messages = NULL;
    session->token_prefix = NULL;
    session->count = 0u;
    session->capacity = 0u;
    session->id = NULL;
    session->path = NULL;
    session->parent_id = NULL;
}

void psi_session_free(struct psi_session *session) {
    if (session == NULL) return;
    psi_session_clear_messages(session);
    free(session->id);
    free(session->path);
    free(session->parent_id);
    session->id = NULL;
    session->path = NULL;
    session->parent_id = NULL;
}

int psi_session_append(struct psi_session *session, enum psi_message_role role, const char *text) {
    return psi_session_append_with_data(session, role, text, NULL);
}

int psi_session_append_with_data(
    struct psi_session *session,
    enum psi_message_role role,
    const char *text,
    const char *data_json
) {
    if (session == NULL) return PSI_STATUS_ERROR;

    if (session->count == session->capacity) {
        size_t new_capacity = session->capacity == 0u ? 8u : session->capacity * 2u;
        struct psi_message *new_messages = (struct psi_message *)realloc(
            session->messages, new_capacity * sizeof(struct psi_message));
        size_t *new_prefix;
        if (new_messages == NULL) return PSI_STATUS_ERROR;
        session->messages = new_messages;
        new_prefix = (size_t *)realloc(session->token_prefix, (new_capacity + 1u) * sizeof(size_t));
        if (new_prefix == NULL) return PSI_STATUS_ERROR;
        session->token_prefix = new_prefix;
        if (session->count == 0u) session->token_prefix[0] = 0u;
        session->capacity = new_capacity;
    }

    psi_message_init_with_data(&session->messages[session->count], role, text, data_json);
    if ((text != NULL && session->messages[session->count].text == NULL) ||
        (data_json != NULL && session->messages[session->count].data_json == NULL)) {
        psi_message_free(&session->messages[session->count]);
        return PSI_STATUS_ERROR;
    }

    session->token_prefix[session->count + 1u] =
        session->token_prefix[session->count] + session->messages[session->count].token_estimate;
    session->count++;
    return PSI_STATUS_OK;
}

int psi_session_set_id(struct psi_session *session, const char *id) {
    if (session == NULL) return PSI_STATUS_ERROR;
    return psi_session_set_string(&session->id, id);
}

int psi_session_set_path(struct psi_session *session, const char *path) {
    if (session == NULL) return PSI_STATUS_ERROR;
    return psi_session_set_string(&session->path, path);
}

int psi_session_set_parent_id(struct psi_session *session, const char *parent_id) {
    if (session == NULL) return PSI_STATUS_ERROR;
    return psi_session_set_string(&session->parent_id, parent_id);
}

int psi_session_clear(struct psi_session *session) {
    if (session == NULL) return PSI_STATUS_ERROR;
    return psi_session_clear_messages(session);
}

enum psi_message_role psi_session_role_from_name(const char *role_name) {
    if (role_name == NULL) return PSI_MESSAGE_CUSTOM;
    if (strcmp(role_name, "user") == 0) return PSI_MESSAGE_USER;
    if (strcmp(role_name, "assistant") == 0) return PSI_MESSAGE_ASSISTANT;
    if (strcmp(role_name, "tool-call") == 0) return PSI_MESSAGE_TOOL_CALL;
    if (strcmp(role_name, "tool-result") == 0) return PSI_MESSAGE_TOOL_RESULT;
    if (strcmp(role_name, "branch-summary") == 0) return PSI_MESSAGE_BRANCH_SUMMARY;
    if (strcmp(role_name, "compaction-summary") == 0) return PSI_MESSAGE_COMPACTION_SUMMARY;
    return PSI_MESSAGE_CUSTOM;
}

size_t psi_session_token_estimate_from(const struct psi_session *session, size_t start_index) {
    if (session == NULL || session->count == 0u || session->token_prefix == NULL) return 0u;
    if (start_index < 1u) start_index = 1u;
    if (start_index > session->count) return 0u;
    return session->token_prefix[session->count] - session->token_prefix[start_index - 1u];
}

size_t psi_session_keep_recent_by_tokens(const struct psi_session *session, size_t target_tokens) {
    size_t total;
    size_t threshold;
    size_t lo;
    size_t hi;
    size_t start;

    if (session == NULL || session->count == 0u || session->token_prefix == NULL) return 0u;
    total = session->token_prefix[session->count];
    if (target_tokens >= total) return session->count;

    threshold = total - target_tokens;
    lo = 0u;
    hi = session->count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2u;
        if (session->token_prefix[mid] < threshold) lo = mid + 1u;
        else hi = mid;
    }

    start = lo + 1u;
    if (start > session->count) start = session->count;
    return session->count - start + 1u;
}
