#include <stdlib.h>
#include "psi/message.h"

void psi_message_init(struct psi_message *message, enum psi_message_role role, const char *text) {
    if (message == NULL) {
        return;
    }

    message->role = role;
    message->text = psi_strdup(text);
}

void psi_message_free(struct psi_message *message) {
    if (message == NULL) {
        return;
    }

    free(message->text);
    message->text = NULL;
}

const char *psi_message_role_name(enum psi_message_role role) {
    switch (role) {
        case PSI_MESSAGE_USER:
            return "user";
        case PSI_MESSAGE_ASSISTANT:
            return "assistant";
        case PSI_MESSAGE_TOOL_CALL:
            return "tool-call";
        case PSI_MESSAGE_TOOL_RESULT:
            return "tool-result";
        case PSI_MESSAGE_CUSTOM:
            return "custom";
        case PSI_MESSAGE_BRANCH_SUMMARY:
            return "branch-summary";
        case PSI_MESSAGE_COMPACTION_SUMMARY:
            return "compaction-summary";
        default:
            return "unknown";
    }
}

