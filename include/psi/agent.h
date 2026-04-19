#ifndef PSI_AGENT_H
#define PSI_AGENT_H

#include "psi/abort.h"
#include "psi/common.h"
#include "psi/session.h"
#include "psi/vm.h"

struct psi_agent_observer {
    void *userdata;
    void (*on_assistant_text_delta)(void *userdata, const char *text);
    void (*on_tool_call)(void *userdata, const char *tool_call_id, const char *tool_name, const char *input_json);
    void (*on_tool_result)(void *userdata, const char *tool_call_id, const char *tool_name, const char *output_json);
    /* Fires from inside long-running tools (shell processes) as output chunks arrive.
     * Optional: may be NULL. `chunk` is not NUL-terminated; use `len`. */
    void (*on_tool_progress)(void *userdata, const char *tool_call_id, const char *chunk, size_t len);
};

struct psi_agent_runtime {
    struct psi_session session;
    struct psi_vm vm;
    const char *boot_file;
    const char *model;
    long max_tokens;
};

int psi_agent_runtime_init(
    struct psi_agent_runtime *runtime,
    const char *boot_file,
    FILE *input,
    FILE *output,
    FILE *error_output
);
void psi_agent_runtime_free(struct psi_agent_runtime *runtime);
int psi_agent_runtime_load_session(struct psi_agent_runtime *runtime, const char *path);
void psi_agent_runtime_configure(struct psi_agent_runtime *runtime, const char *model, long max_tokens);
int psi_agent_runtime_turn(struct psi_agent_runtime *runtime, const char *user_text, char **response_text);
int psi_agent_runtime_turn_with_observer(
    struct psi_agent_runtime *runtime,
    const char *user_text,
    struct psi_agent_observer *observer,
    struct psi_abort_signal *abort_signal,
    char **response_text
);
int psi_agent_runtime_compact(
    struct psi_agent_runtime *runtime,
    size_t keep_recent,
    struct psi_abort_signal *abort_signal,
    char **summary_text
);
int psi_agent_runtime_save(struct psi_agent_runtime *runtime);

#endif
