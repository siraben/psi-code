#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
    struct psi_vm vm;
    struct psi_session session;
    char line[4096];
    char *output_text;
    int status;

    output_text = NULL;
    psi_session_init(&session);
    if (options->session_file != NULL) {
        if (psi_session_load(&session, options->session_file) != PSI_STATUS_OK) {
            fprintf(stderr, "failed to load session file: %s\n", options->session_file);
            psi_session_free(&session);
            return PSI_STATUS_ERROR;
        }
    }

    status = psi_vm_init(&vm, options->boot_file, stdin, stdout, stderr);
    if (status != PSI_STATUS_OK) {
        psi_session_free(&session);
        return status;
    }

    printf("psi repl\n");
    printf("type Scheme expressions, or :quit to exit\n");

    for (;;) {
        printf("psi> ");
        fflush(stdout);

        if (fgets(line, sizeof(line), stdin) == NULL) {
            break;
        }

        if (strcmp(line, ":quit\n") == 0 || strcmp(line, ":q\n") == 0) {
            break;
        }

        if (psi_session_append(&session, PSI_MESSAGE_USER, line) != PSI_STATUS_OK) {
            fprintf(stderr, "failed to append REPL input to session\n");
            status = PSI_STATUS_ERROR;
            break;
        }

        free(output_text);
        output_text = NULL;

        status = psi_vm_eval_to_string(&vm, line, &output_text);
        if (status != PSI_STATUS_OK) {
            free(output_text);
            output_text = NULL;
            continue;
        }

        if (psi_session_append(&session, PSI_MESSAGE_ASSISTANT, output_text) != PSI_STATUS_OK) {
            fprintf(stderr, "failed to append REPL output to session\n");
            status = PSI_STATUS_ERROR;
            break;
        }

        if (psi_session_save(&session) != PSI_STATUS_OK) {
            fprintf(stderr, "failed to save session file\n");
            status = PSI_STATUS_ERROR;
            break;
        }

        if (output_text != NULL) {
            printf("%s\n", output_text);
        }
    }

    free(output_text);
    psi_vm_destroy(&vm);
    psi_session_free(&session);
    return status == PSI_STATUS_OK ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

static int psi_run_by_mode(const struct psi_cli_options *options) {
    switch (options->mode) {
        case PSI_CLI_MODE_PRINT:
            return psi_run_print_mode(options);
        case PSI_CLI_MODE_EVAL:
            return psi_run_eval_mode(options);
        case PSI_CLI_MODE_REPL:
            return psi_run_repl(options);
        default:
            return PSI_STATUS_ERROR;
    }
}

int psi_run_print_mode_dispatch(const struct psi_cli_options *options) {
    return psi_run_by_mode(options);
}
