#include <stdlib.h>
#include <string.h>
#include "psi/session.h"

void psi_session_init(struct psi_session *session) {
    if (session == NULL) {
        return;
    }

    session->messages = NULL;
    session->count = 0u;
    session->capacity = 0u;
}

void psi_session_free(struct psi_session *session) {
    size_t index;

    if (session == NULL) {
        return;
    }

    for (index = 0u; index < session->count; index++) {
        psi_message_free(&session->messages[index]);
    }

    free(session->messages);
    session->messages = NULL;
    session->count = 0u;
    session->capacity = 0u;
}

int psi_session_append(struct psi_session *session, enum psi_message_role role, const char *text) {
    struct psi_message *new_messages;
    size_t new_capacity;

    if (session == NULL) {
        return PSI_STATUS_ERROR;
    }

    if (session->count == session->capacity) {
        new_capacity = session->capacity == 0u ? 8u : session->capacity * 2u;
        new_messages = (struct psi_message *)realloc(session->messages, new_capacity * sizeof(struct psi_message));
        if (new_messages == NULL) {
            return PSI_STATUS_ERROR;
        }
        session->messages = new_messages;
        session->capacity = new_capacity;
    }

    psi_message_init(&session->messages[session->count], role, text);
    if (session->messages[session->count].text == NULL) {
        return PSI_STATUS_ERROR;
    }

    session->count++;
    return PSI_STATUS_OK;
}

