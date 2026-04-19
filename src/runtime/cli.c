#include <stdio.h>
#include <string.h>
#include "psi/runtime.h"

static int psi_cli_needs_value(const char *flag, int index, int argc) {
    if (index + 1 >= argc) {
        fprintf(stderr, "missing value for %s\n", flag);
        return PSI_STATUS_ERROR;
    }
    return PSI_STATUS_OK;
}

int psi_cli_parse(struct psi_cli_options *options, int argc, char **argv) {
    int index;

    if (options == NULL) {
        return PSI_STATUS_ERROR;
    }

    options->mode = PSI_CLI_MODE_REPL;
    options->payload = NULL;
    options->boot_file = PSI_SCHEME_BOOT_FILE;

    for (index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--help") == 0 || strcmp(argv[index], "-h") == 0) {
            options->mode = PSI_CLI_MODE_HELP;
            return PSI_STATUS_OK;
        }
        if (strcmp(argv[index], "--version") == 0) {
            options->mode = PSI_CLI_MODE_VERSION;
            return PSI_STATUS_OK;
        }
        if (strcmp(argv[index], "--print") == 0) {
            if (psi_cli_needs_value("--print", index, argc) != PSI_STATUS_OK) {
                return PSI_STATUS_ERROR;
            }
            options->mode = PSI_CLI_MODE_PRINT;
            options->payload = argv[index + 1];
            index++;
            continue;
        }
        if (strcmp(argv[index], "--eval") == 0) {
            if (psi_cli_needs_value("--eval", index, argc) != PSI_STATUS_OK) {
                return PSI_STATUS_ERROR;
            }
            options->mode = PSI_CLI_MODE_EVAL;
            options->payload = argv[index + 1];
            index++;
            continue;
        }
        if (strcmp(argv[index], "--boot") == 0) {
            if (psi_cli_needs_value("--boot", index, argc) != PSI_STATUS_OK) {
                return PSI_STATUS_ERROR;
            }
            options->boot_file = argv[index + 1];
            index++;
            continue;
        }

        fprintf(stderr, "unknown argument: %s\n", argv[index]);
        return PSI_STATUS_ERROR;
    }

    return PSI_STATUS_OK;
}

void psi_cli_usage(const char *program_name) {
    printf("usage: %s [--help] [--version] [--boot FILE] [--eval EXPR] [--print TEXT]\n", program_name);
    printf("\n");
    printf("  --eval EXPR   evaluate a Scheme expression and print the result\n");
    printf("  --print TEXT  run the bootstrap print-mode handler\n");
    printf("  --boot FILE   override the Scheme bootstrap file\n");
}

