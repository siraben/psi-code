#ifndef PSI_SESSION_H
#define PSI_SESSION_H

#include "psi/message.h"

/* Session state: a growable array of messages plus identity. The Lua
 * layer drives everything (JSONL I/O, compaction, fork) through the
 * psi.session_* FFI primitives declared in src/lua/vm.c; this C struct
 * is just the storage holding the current in-memory view. */

struct psi_session {
    struct psi_message *messages;
    size_t *token_prefix;
    size_t count;
    size_t capacity;
    char *id;
    char *path;
    char *parent_id;
};

void psi_session_init(struct psi_session *session);
void psi_session_free(struct psi_session *session);
int psi_session_append(struct psi_session *session, enum psi_message_role role, const char *text);
int psi_session_append_with_data(struct psi_session *session, enum psi_message_role role,
    const char *text, const char *data_json);
int psi_session_append_with_data_and_estimate(struct psi_session *session,
    enum psi_message_role role, const char *text, const char *data_json, size_t token_estimate);
int psi_session_set_id(struct psi_session *session, const char *id);
int psi_session_set_path(struct psi_session *session, const char *path);
int psi_session_set_parent_id(struct psi_session *session, const char *parent_id);
int psi_session_clear(struct psi_session *session);
enum psi_message_role psi_session_role_from_name(const char *role_name);
size_t psi_session_token_estimate_from(const struct psi_session *session, size_t start_index);
size_t psi_session_keep_recent_by_tokens(const struct psi_session *session, size_t target_tokens);

#endif
