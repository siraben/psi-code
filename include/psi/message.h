#ifndef PSI_MESSAGE_H
#define PSI_MESSAGE_H

#include "psi/common.h"

enum psi_message_role {
    PSI_MESSAGE_USER = 0,
    PSI_MESSAGE_ASSISTANT = 1,
    PSI_MESSAGE_TOOL_CALL = 2,
    PSI_MESSAGE_TOOL_RESULT = 3,
    PSI_MESSAGE_CUSTOM = 4,
    PSI_MESSAGE_BRANCH_SUMMARY = 5,
    PSI_MESSAGE_COMPACTION_SUMMARY = 6
};

struct psi_message {
    enum psi_message_role role;
    char *text;
    char *data_json;
    size_t token_estimate;
};

void psi_message_init(struct psi_message *message, enum psi_message_role role, const char *text);
void psi_message_init_with_data(
    struct psi_message *message,
    enum psi_message_role role,
    const char *text,
    const char *data_json
);
void psi_message_free(struct psi_message *message);
const char *psi_message_role_name(enum psi_message_role role);

#endif
