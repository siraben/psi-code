#ifndef PSI_HOST_OPS_H
#define PSI_HOST_OPS_H

#include "psi/common.h"

struct psi_session;

enum psi_host_op_kind {
    PSI_HOST_OP_VERSION = 0,
    PSI_HOST_OP_LOG = 1,
    PSI_HOST_OP_SESSION_MESSAGE_COUNT = 2,
    PSI_HOST_OP_READ_FILE = 3,
    PSI_HOST_OP_TOOL_CALL = 4,
    PSI_HOST_OP_SYSTEM_PROMPT = 5
};

struct psi_host_context {
    struct psi_session *session;
};

struct psi_host_call {
    enum psi_host_op_kind kind;
    const char *name;
    const char *input_text;
    char *output_text;
    long output_number;
};

int psi_host_call(struct psi_host_context *context, struct psi_host_call *call);

#endif
