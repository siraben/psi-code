#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "psi/agent.h"
#include "psi/anthropic.h"

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
    if (runtime == NULL) {
        return;
    }

    psi_vm_destroy(&runtime->vm);
    psi_session_free(&runtime->session);
    runtime->boot_file = NULL;
    runtime->model = NULL;
    runtime->max_tokens = 4096l;
}

int psi_agent_runtime_load_session(struct psi_agent_runtime *runtime, const char *path) {
    if (runtime == NULL) {
        return PSI_STATUS_ERROR;
    }

    if (path == NULL) {
        return PSI_STATUS_OK;
    }
    return psi_session_load(&runtime->session, path);
}

void psi_agent_runtime_configure(struct psi_agent_runtime *runtime, const char *model, long max_tokens) {
    if (runtime == NULL) {
        return;
    }

    runtime->model = model;
    runtime->max_tokens = max_tokens > 0l ? max_tokens : 4096l;
}

int psi_agent_runtime_turn_with_observer(
    struct psi_agent_runtime *runtime,
    const char *user_text,
    struct psi_agent_observer *observer,
    char **response_text
) {
    char *system_prompt;
    int status;

    if (runtime == NULL || user_text == NULL || response_text == NULL) {
        return PSI_STATUS_ERROR;
    }

    *response_text = NULL;
    if (psi_session_append(&runtime->session, PSI_MESSAGE_USER, user_text) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    system_prompt = NULL;
    status = psi_vm_call_procedure0_to_string(&runtime->vm, "psi-build-system-prompt", &system_prompt);
    if (status != PSI_STATUS_OK) {
        free(system_prompt);
        return status;
    }

    status = psi_anthropic_agent_turn_with_prompt(
        &runtime->session,
        &runtime->vm,
        &runtime->vm.host,
        user_text,
        observer,
        runtime->model,
        runtime->max_tokens,
        system_prompt,
        response_text
    );
    free(system_prompt);
    return status;
}

int psi_agent_runtime_turn(struct psi_agent_runtime *runtime, const char *user_text, char **response_text) {
    return psi_agent_runtime_turn_with_observer(runtime, user_text, NULL, response_text);
}

int psi_agent_runtime_compact(
    struct psi_agent_runtime *runtime,
    size_t keep_recent,
    char **summary_text
) {
    char *system_prompt;
    char *user_prompt;
    char *summary;
    int status;

    if (runtime == NULL) {
        return PSI_STATUS_ERROR;
    }

    if (runtime->session.count <= keep_recent + 1u) {
        if (summary_text != NULL) {
            *summary_text = psi_strdup("session is already small enough");
            if (*summary_text == NULL) {
                return PSI_STATUS_ERROR;
            }
        }
        return PSI_STATUS_OK;
    }

    system_prompt = NULL;
    user_prompt = NULL;
    summary = NULL;
    status = psi_vm_build_compaction_request(&runtime->vm, (long)keep_recent, &system_prompt, &user_prompt);
    if (status != PSI_STATUS_OK) {
        free(system_prompt);
        free(user_prompt);
        return status;
    }

    status = psi_anthropic_complete_text(
        runtime->model,
        runtime->max_tokens < 1024l ? runtime->max_tokens : 1024l,
        system_prompt,
        user_prompt,
        &summary
    );
    free(system_prompt);
    free(user_prompt);
    if (status != PSI_STATUS_OK) {
        return status;
    }

    status = psi_session_compact(&runtime->session, keep_recent, summary);
    if (status != PSI_STATUS_OK) {
        free(summary);
        return status;
    }

    if (summary_text != NULL) {
        *summary_text = summary;
    } else {
        free(summary);
    }
    return PSI_STATUS_OK;
}

int psi_agent_runtime_save(struct psi_agent_runtime *runtime) {
    if (runtime == NULL) {
        return PSI_STATUS_ERROR;
    }
    return psi_session_save(&runtime->session);
}
