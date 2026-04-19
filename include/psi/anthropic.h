#ifndef PSI_ANTHROPIC_H
#define PSI_ANTHROPIC_H

#include "psi/common.h"
#include "psi/session.h"

int psi_anthropic_agent_turn(
    struct psi_session *session,
    const char *model,
    long max_tokens,
    char **output_text
);
int psi_anthropic_agent_turn_with_prompt(
    struct psi_session *session,
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
