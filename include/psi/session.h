#ifndef PSI_SESSION_H
#define PSI_SESSION_H

#include "psi/message.h"

struct psi_session {
    struct psi_message *messages;
    size_t count;
    size_t capacity;
};

void psi_session_init(struct psi_session *session);
void psi_session_free(struct psi_session *session);
int psi_session_append(struct psi_session *session, enum psi_message_role role, const char *text);

#endif

