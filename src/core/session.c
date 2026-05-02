/* Session + message storage primitives. JSONL I/O, compaction, and
 * fork are all implemented in lua/psi/session.lua — this file just
 * keeps the in-memory message array alive and the role enum mapped
 * to its JSON string form. */

#include <stdlib.h>
#include <string.h>
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

static size_t psi_calibrate_tokens(size_t pi_tokens) {
    const size_t max = (size_t)-1;

    /* Live OpenRouter probes across Claude, Gemini, and GPT showed chars/4
     * is close but slightly low on average. Target a mild ~5% overestimate:
     *   ceil(pi_tokens * 1.105)
     * which is equivalent to ceil((221*pi_tokens) / 200).
     */
    if (pi_tokens > (max - 199u) / 221u) return max;
    return (221u * pi_tokens + 199u) / 200u;
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
    psi_message_init_with_data_and_estimate(
        message, role, text, data_json, psi_calibrate_tokens(psi_estimate_tokens(text)));
}

void psi_message_init_with_data_and_estimate(
    struct psi_message *message,
    enum psi_message_role role,
    const char *text,
    const char *data_json,
    size_t token_estimate
) {
    if (message == NULL) return;
    message->role = role;
    message->text = text != NULL ? psi_strdup(text) : NULL;
    message->data_json = data_json != NULL ? psi_strdup(data_json) : NULL;
    message->token_estimate = token_estimate;
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
    return psi_session_append_with_data_and_estimate(
        session, role, text, data_json, psi_calibrate_tokens(psi_estimate_tokens(text)));
}

int psi_session_append_with_data_and_estimate(
    struct psi_session *session,
    enum psi_message_role role,
    const char *text,
    const char *data_json,
    size_t token_estimate
) {
    if (session == NULL) return PSI_STATUS_ERROR;

    if (session->count == session->capacity) {
        size_t max_messages = (size_t)-1 / sizeof(struct psi_message);
        size_t max_prefixes = ((size_t)-1 / sizeof(size_t)) - 1u;
        size_t new_capacity;
        struct psi_message *new_messages;
        size_t *new_prefix;

        if (session->capacity == 0u) {
            new_capacity = 8u;
        } else {
            if (session->capacity > max_messages / 2u ||
                session->capacity > max_prefixes / 2u) {
                return PSI_STATUS_ERROR;
            }
            new_capacity = session->capacity * 2u;
        }

        if (new_capacity > max_messages || new_capacity > max_prefixes) {
            return PSI_STATUS_ERROR;
        }

        new_messages = malloc(new_capacity * sizeof(*new_messages));
        if (new_messages == NULL) return PSI_STATUS_ERROR;

        new_prefix = malloc((new_capacity + 1u) * sizeof(*new_prefix));
        if (new_prefix == NULL) {
            free(new_messages);
            return PSI_STATUS_ERROR;
        }

        if (session->count > 0u) {
            memcpy(new_messages, session->messages, session->count * sizeof(*new_messages));
            memcpy(new_prefix, session->token_prefix, (session->count + 1u) * sizeof(*new_prefix));
        } else {
            new_prefix[0] = 0u;
        }

        free(session->messages);
        free(session->token_prefix);
        session->messages = new_messages;
        session->token_prefix = new_prefix;
        session->capacity = new_capacity;
    }

    psi_message_init_with_data_and_estimate(
        &session->messages[session->count], role, text, data_json, token_estimate);
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
