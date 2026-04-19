#ifndef PSI_ANTHROPIC_H
#define PSI_ANTHROPIC_H

#include "psi/common.h"
#include "psi/session.h"

struct psi_host_context;
struct psi_vm;

int psi_anthropic_agent_turn(
    struct psi_session *session,
    struct psi_vm *vm,
    struct psi_host_context *host,
    const char *user_text,
    struct psi_agent_observer *observer,
    const char *model,
    long max_tokens,
    char **output_text
);
int psi_anthropic_agent_turn_with_prompt(
    struct psi_session *session,
    struct psi_vm *vm,
    struct psi_host_context *host,
    const char *user_text,
    struct psi_agent_observer *observer,
    const char *model,
    long max_tokens,
    const char *system_prompt,
    char **output_text
);
int psi_anthropic_complete_text(
    const char *model,
    long max_tokens,
    const char *system_prompt,
    const char *user_text,
    char **output_text
);

#endif
