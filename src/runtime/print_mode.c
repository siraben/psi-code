#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <editline/readline.h>
#include "psi/agent.h"
#include "psi/runtime.h"
#include "psi/session.h"
#include "psi/vm.h"

static int psi_run_eval_mode(const struct psi_cli_options *options) {
    struct psi_vm vm;
    char *output_text;
    int status;

    output_text = NULL;
    status = psi_vm_init(&vm, options->boot_file, stdin, stdout, stderr);
    if (status != PSI_STATUS_OK) {
        return status;
    }

    status = psi_vm_eval_to_string(&vm, options->payload, &output_text);
    if (status == PSI_STATUS_OK && output_text != NULL) {
        printf("%s\n", output_text);
    }

    free(output_text);
    psi_vm_destroy(&vm);
    return status;
}

int psi_run_print_mode(const struct psi_cli_options *options) {
    struct psi_vm vm;
    struct psi_session session;
    char *reply_text;
    int status;

    reply_text = NULL;
    psi_session_init(&session);
    if (options->session_file != NULL) {
        if (psi_session_load(&session, options->session_file) != PSI_STATUS_OK) {
            fprintf(stderr, "failed to load session file: %s\n", options->session_file);
            psi_session_free(&session);
            return PSI_STATUS_ERROR;
        }
    }

    if (psi_session_append(&session, PSI_MESSAGE_USER, options->payload) != PSI_STATUS_OK) {
        fprintf(stderr, "failed to append user message\n");
        psi_session_free(&session);
        return PSI_STATUS_ERROR;
    }

    status = psi_vm_init(&vm, options->boot_file, stdin, stdout, stderr);
    if (status != PSI_STATUS_OK) {
        psi_session_free(&session);
        return status;
    }
    psi_vm_bind_session(&vm, &session);

    status = psi_vm_call_string_procedure(&vm, "psi-handle-print", options->payload, &reply_text);
    if (status != PSI_STATUS_OK) {
        psi_vm_destroy(&vm);
        psi_session_free(&session);
        free(reply_text);
        return status;
    }

    if (psi_session_append(&session, PSI_MESSAGE_ASSISTANT, reply_text) != PSI_STATUS_OK) {
        fprintf(stderr, "failed to append assistant message\n");
        psi_vm_destroy(&vm);
        psi_session_free(&session);
        free(reply_text);
        return PSI_STATUS_ERROR;
    }

    if (psi_session_save(&session) != PSI_STATUS_OK) {
        fprintf(stderr, "failed to save session file\n");
        psi_vm_destroy(&vm);
        psi_session_free(&session);
        free(reply_text);
        return PSI_STATUS_ERROR;
    }

    printf("%s\n", reply_text);

    psi_vm_destroy(&vm);
    psi_session_free(&session);
    free(reply_text);
    return PSI_STATUS_OK;
}

int psi_run_repl(const struct psi_cli_options *options) {
    struct psi_agent_runtime runtime;
    char *line;
    char *response_text;
    char *summary_text;
    long keep_recent;
    int status;

    line = NULL;
    response_text = NULL;
    summary_text = NULL;
    psi_agent_runtime_init(&runtime);
    psi_agent_runtime_configure(&runtime, options->model, options->max_tokens);
    if (options->session_file != NULL) {
        if (psi_agent_runtime_load_session(&runtime, options->session_file) != PSI_STATUS_OK) {
            fprintf(stderr, "failed to load session file: %s\n", options->session_file);
            psi_agent_runtime_free(&runtime);
            return PSI_STATUS_ERROR;
        }
    }

    printf("psi coding agent\n");
    printf("type a prompt to run the agent, /help for commands, or /quit to exit\n");

    status = PSI_STATUS_OK;
    for (;;) {
        line = readline("psi> ");
        if (line == NULL) {
            break;
        }

        if (strcmp(line, "/quit") == 0 || strcmp(line, "/q") == 0 ||
            strcmp(line, ":quit") == 0 || strcmp(line, ":q") == 0) {
            free(line);
            line = NULL;
            break;
        }

        if (strcmp(line, "/help") == 0) {
            printf("/help          show available commands\n");
            printf("/quit          exit the shell\n");
            printf("/compact [N]   summarize older context and keep the most recent N messages\n");
            printf("/system-prompt print the current coding-agent system prompt\n");
            printf("/session       show the current session message count\n");
            free(line);
            line = NULL;
            continue;
        }

        if (strcmp(line, "/system-prompt") == 0) {
            free(line);
            line = NULL;
            status = psi_run_system_prompt_mode(options);
            if (status != PSI_STATUS_OK) {
                break;
            }
            continue;
        }

        if (strcmp(line, "/session") == 0) {
            printf("session-messages: %lu\n", (unsigned long)runtime.session.count);
            free(line);
            line = NULL;
            continue;
        }

        if (strncmp(line, "/compact", 8) == 0 &&
            (line[8] == '\0' || line[8] == ' ' || line[8] == '\t')) {
            keep_recent = options->keep_recent;
            if (line[8] != '\0') {
                keep_recent = strtol(line + 8, NULL, 10);
                if (keep_recent < 0l) {
                    fprintf(stderr, "invalid keep count: %s\n", line + 8);
                    free(line);
                    line = NULL;
                    status = PSI_STATUS_ERROR;
                    break;
                }
            }
            free(line);
            line = NULL;

            free(summary_text);
            summary_text = NULL;
            status = psi_agent_runtime_compact(&runtime, (size_t)keep_recent, &summary_text);
            if (status != PSI_STATUS_OK) {
                fprintf(stderr, "failed to compact session\n");
                break;
            }
            if (psi_agent_runtime_save(&runtime) != PSI_STATUS_OK) {
                fprintf(stderr, "failed to save session file\n");
                status = PSI_STATUS_ERROR;
                break;
            }
            printf("compaction summary:\n%s\n", summary_text != NULL ? summary_text : "");
            continue;
        }

        if (line[0] != '\0') {
            add_history(line);
        }

        free(response_text);
        response_text = NULL;
        status = psi_agent_runtime_turn(&runtime, line, &response_text);
        free(line);
        line = NULL;
        if (status != PSI_STATUS_OK) {
            continue;
        }

        if (psi_agent_runtime_save(&runtime) != PSI_STATUS_OK) {
            fprintf(stderr, "failed to save session file\n");
            status = PSI_STATUS_ERROR;
            break;
        }
    }

    free(line);
    free(response_text);
    free(summary_text);
    psi_agent_runtime_free(&runtime);
    return status == PSI_STATUS_OK ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

int psi_run_system_prompt_mode(const struct psi_cli_options *options) {
    struct psi_vm vm;
    char *output_text;
    int status;

    output_text = NULL;
    status = psi_vm_init(&vm, options->boot_file, stdin, stdout, stderr);
    if (status != PSI_STATUS_OK) {
        return status;
    }

    status = psi_vm_call_procedure0_to_string(&vm, "psi-handle-system-prompt", &output_text);
    if (status == PSI_STATUS_OK && output_text != NULL) {
        printf("%s\n", output_text);
    }

    free(output_text);
    psi_vm_destroy(&vm);
    return status;
}

int psi_run_agent_mode(const struct psi_cli_options *options) {
    struct psi_agent_runtime runtime;
    char *response_text;
    int status;

    response_text = NULL;
    psi_agent_runtime_init(&runtime);
    psi_agent_runtime_configure(&runtime, options->model, options->max_tokens);
    if (options->session_file != NULL) {
        if (psi_agent_runtime_load_session(&runtime, options->session_file) != PSI_STATUS_OK) {
            fprintf(stderr, "failed to load session file: %s\n", options->session_file);
            psi_agent_runtime_free(&runtime);
            return PSI_STATUS_ERROR;
        }
    }

    status = psi_agent_runtime_turn(&runtime, options->payload, &response_text);
    if (status != PSI_STATUS_OK) {
        psi_agent_runtime_free(&runtime);
        free(response_text);
        return status;
    }

    if (psi_agent_runtime_save(&runtime) != PSI_STATUS_OK) {
        fprintf(stderr, "failed to save session file\n");
        psi_agent_runtime_free(&runtime);
        free(response_text);
        return PSI_STATUS_ERROR;
    }

    psi_agent_runtime_free(&runtime);
    free(response_text);
    return PSI_STATUS_OK;
}

int psi_run_compact_mode(const struct psi_cli_options *options) {
    struct psi_agent_runtime runtime;
    char *summary_text;
    int status;

    if (options->session_file == NULL) {
        fprintf(stderr, "--compact requires --session FILE\n");
        return PSI_STATUS_ERROR;
    }

    summary_text = NULL;
    psi_agent_runtime_init(&runtime);
    psi_agent_runtime_configure(&runtime, options->model, options->max_tokens);
    if (psi_agent_runtime_load_session(&runtime, options->session_file) != PSI_STATUS_OK) {
        fprintf(stderr, "failed to load session file: %s\n", options->session_file);
        psi_agent_runtime_free(&runtime);
        return PSI_STATUS_ERROR;
    }

    status = psi_agent_runtime_compact(&runtime, (size_t)options->keep_recent, &summary_text);
    if (status != PSI_STATUS_OK) {
        psi_agent_runtime_free(&runtime);
        free(summary_text);
        return status;
    }
    if (psi_agent_runtime_save(&runtime) != PSI_STATUS_OK) {
        fprintf(stderr, "failed to save session file\n");
        psi_agent_runtime_free(&runtime);
        free(summary_text);
        return PSI_STATUS_ERROR;
    }

    printf("%s\n", summary_text != NULL ? summary_text : "");
    psi_agent_runtime_free(&runtime);
    free(summary_text);
    return PSI_STATUS_OK;
}

static int psi_run_by_mode(const struct psi_cli_options *options) {
    switch (options->mode) {
        case PSI_CLI_MODE_PRINT:
            return psi_run_print_mode(options);
        case PSI_CLI_MODE_EVAL:
            return psi_run_eval_mode(options);
        case PSI_CLI_MODE_REPL:
            return psi_run_repl(options);
        case PSI_CLI_MODE_SYSTEM_PROMPT:
            return psi_run_system_prompt_mode(options);
        case PSI_CLI_MODE_AGENT:
            return psi_run_agent_mode(options);
        case PSI_CLI_MODE_COMPACT:
            return psi_run_compact_mode(options);
        default:
            return PSI_STATUS_ERROR;
    }
}

int psi_run_print_mode_dispatch(const struct psi_cli_options *options) {
    return psi_run_by_mode(options);
}
