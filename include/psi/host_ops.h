#ifndef PSI_HOST_OPS_H
#define PSI_HOST_OPS_H

#include "psi/common.h"

struct psi_session;
struct psi_vm;

enum psi_host_op_kind {
    PSI_HOST_OP_VERSION = 0,
    PSI_HOST_OP_LOG = 1,
    PSI_HOST_OP_SESSION_MESSAGE_COUNT = 2,
    PSI_HOST_OP_READ_FILE = 3,
    PSI_HOST_OP_TOOL_CALL = 4
};

struct psi_host_context {
    struct psi_session *session;
    struct psi_vm *vm;
    /* Set by the agent loop while a tool is dispatching so primitives
     * (e.g. psi.process_run) can stream progress events back to the
     * observer. Both fields are NULL outside of tool dispatch. */
    struct psi_agent_observer *active_observer;
    const char *active_tool_id;
    /* Live cancellation token. Set at turn start, cleared at turn end.
     * FFI primitives check this and bail rather than continuing a
     * blocking op after the user pressed Esc. */
    struct psi_abort_signal *abort_signal;
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
