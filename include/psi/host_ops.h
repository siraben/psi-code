#ifndef PSI_HOST_OPS_H
#define PSI_HOST_OPS_H

#include "psi/common.h"

/* Context shared between the agent loop and Lua FFI primitives.
 *
 * Each VM owns one host context (stored in the Lua state's extraspace).
 * The agent loop in anthropic.c stamps `active_observer` and
 * `active_tool_id` on it around each tool dispatch so FFI primitives
 * (psi.process_run, etc.) can stream progress back to the observer and
 * honor `abort_signal`. Outside of a dispatch, those three fields are
 * NULL. */

struct psi_session;
struct psi_vm;
struct psi_agent_observer;
struct psi_abort_signal;

struct psi_host_context {
    struct psi_session *session;
    struct psi_vm *vm;
    struct psi_agent_observer *active_observer;
    const char *active_tool_id;
    struct psi_abort_signal *abort_signal;
};

#endif
