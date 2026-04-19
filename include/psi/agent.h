#ifndef PSI_AGENT_H
#define PSI_AGENT_H

#include "psi/common.h"
#include "psi/session.h"

struct psi_agent_runtime {
    struct psi_session session;
    const char *model;
    long max_tokens;
};

void psi_agent_runtime_init(struct psi_agent_runtime *runtime);
void psi_agent_runtime_free(struct psi_agent_runtime *runtime);
int psi_agent_runtime_load_session(struct psi_agent_runtime *runtime, const char *path);
void psi_agent_runtime_configure(struct psi_agent_runtime *runtime, const char *model, long max_tokens);
int psi_agent_runtime_turn(struct psi_agent_runtime *runtime, const char *user_text, char **response_text);
int psi_agent_runtime_compact(
    struct psi_agent_runtime *runtime,
    size_t keep_recent,
    char **summary_text
);
int psi_agent_runtime_save(struct psi_agent_runtime *runtime);

#endif
