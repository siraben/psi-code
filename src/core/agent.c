#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "psi/agent.h"
#include "psi/vm.h"

int psi_agent_runtime_init(
    struct psi_agent_runtime *runtime,
    const char *boot_file,
    FILE *input,
    FILE *output,
    FILE *error_output
) {
    if (runtime == NULL) {
        return PSI_STATUS_ERROR;
    }

    psi_session_init(&runtime->session);
    runtime->boot_file = boot_file;
    runtime->model = NULL;
    runtime->max_tokens = 4096l;

    if (psi_vm_init(&runtime->vm, boot_file, input, output, error_output) != PSI_STATUS_OK) {
        psi_session_free(&runtime->session);
        return PSI_STATUS_ERROR;
    }
    psi_vm_bind_session(&runtime->vm, &runtime->session);
    return PSI_STATUS_OK;
}

void psi_agent_runtime_free(struct psi_agent_runtime *runtime) {
    if (runtime == NULL) return;
    psi_vm_destroy(&runtime->vm);
    psi_session_free(&runtime->session);
    runtime->boot_file = NULL;
    runtime->model = NULL;
    runtime->max_tokens = 4096l;
}

int psi_agent_runtime_load_session(struct psi_agent_runtime *runtime, const char *path) {
    if (runtime == NULL) return PSI_STATUS_ERROR;
    if (path == NULL) return PSI_STATUS_OK;
    return psi_session_load(&runtime->session, path);
}

void psi_agent_runtime_configure(struct psi_agent_runtime *runtime, const char *model, long max_tokens) {
    if (runtime == NULL) return;
    runtime->model = model;
    runtime->max_tokens = max_tokens > 0l ? max_tokens : 4096l;
}

int psi_agent_runtime_turn_with_observer(
    struct psi_agent_runtime *runtime,
    const char *user_text,
    struct psi_agent_observer *observer,
    struct psi_abort_signal *abort_signal,
    char **response_text
) {
    int status;

    if (runtime == NULL || user_text == NULL || response_text == NULL) {
        return PSI_STATUS_ERROR;
    }

    if (observer != NULL && observer->on_turn_start != NULL) {
        observer->on_turn_start(observer->userdata);
    }
    status = psi_vm_run_agent_turn(
        &runtime->vm, user_text, observer, abort_signal,
        runtime->model, runtime->max_tokens, response_text);
    if (observer != NULL && observer->on_turn_end != NULL) {
        observer->on_turn_end(observer->userdata);
    }
    return status;
}

int psi_agent_runtime_turn(struct psi_agent_runtime *runtime, const char *user_text, char **response_text) {
    return psi_agent_runtime_turn_with_observer(runtime, user_text, NULL, NULL, response_text);
}

int psi_agent_runtime_compact(
    struct psi_agent_runtime *runtime,
    size_t keep_recent,
    struct psi_abort_signal *abort_signal,
    char **summary_text
) {
    if (runtime == NULL) return PSI_STATUS_ERROR;
    return psi_vm_run_agent_compact(
        &runtime->vm, keep_recent, abort_signal,
        runtime->model, runtime->max_tokens, summary_text);
}

int psi_agent_runtime_save(struct psi_agent_runtime *runtime) {
    if (runtime == NULL) return PSI_STATUS_ERROR;
    return psi_session_save(&runtime->session);
}
