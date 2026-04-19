#ifndef PSI_SESSION_H
#define PSI_SESSION_H

#include "psi/message.h"

struct psi_session {
    struct psi_message *messages;
    size_t count;
    size_t capacity;
    char *id;
    char *path;
};

void psi_session_init(struct psi_session *session);
void psi_session_free(struct psi_session *session);
int psi_session_append(struct psi_session *session, enum psi_message_role role, const char *text);
int psi_session_append_with_data(
    struct psi_session *session,
    enum psi_message_role role,
    const char *text,
    const char *data_json
);
int psi_session_load(struct psi_session *session, const char *path);
int psi_session_save(struct psi_session *session);
int psi_session_set_path(struct psi_session *session, const char *path);
int psi_session_compact(struct psi_session *session, size_t keep_recent, const char *summary_text);

#endif
