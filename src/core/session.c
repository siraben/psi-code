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
}

void psi_message_free(struct psi_message *message) {
    if (message == NULL) return;
    free(message->text);
    free(message->data_json);
    message->text = NULL;
    message->data_json = NULL;
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
    session->messages = NULL;
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
    struct psi_message *new_messages;
    size_t new_capacity;

    if (session == NULL) return PSI_STATUS_ERROR;

    if (session->count == session->capacity) {
        new_capacity = session->capacity == 0u ? 8u : session->capacity * 2u;
        new_messages = (struct psi_message *)realloc(
            session->messages, new_capacity * sizeof(struct psi_message));
        if (new_messages == NULL) return PSI_STATUS_ERROR;
        session->messages = new_messages;
        session->capacity = new_capacity;
    }

    psi_message_init_with_data(&session->messages[session->count], role, text, data_json);
    if ((text != NULL && session->messages[session->count].text == NULL) ||
        (data_json != NULL && session->messages[session->count].data_json == NULL)) {
        psi_message_free(&session->messages[session->count]);
        return PSI_STATUS_ERROR;
    }

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
