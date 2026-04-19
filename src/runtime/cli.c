#include <stdio.h>
#include <stdlib.h>
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
    options->session_file = NULL;
    options->model = NULL;
    options->max_tokens = 4096l;

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
        if (strcmp(argv[index], "--agent") == 0) {
            if (psi_cli_needs_value("--agent", index, argc) != PSI_STATUS_OK) {
                return PSI_STATUS_ERROR;
            }
            options->mode = PSI_CLI_MODE_AGENT;
            options->payload = argv[index + 1];
            index++;
            continue;
        }
        if (strcmp(argv[index], "--model") == 0) {
            if (psi_cli_needs_value("--model", index, argc) != PSI_STATUS_OK) {
                return PSI_STATUS_ERROR;
            }
            options->model = argv[index + 1];
            index++;
            continue;
        }
        if (strcmp(argv[index], "--max-tokens") == 0) {
            if (psi_cli_needs_value("--max-tokens", index, argc) != PSI_STATUS_OK) {
                return PSI_STATUS_ERROR;
            }
            options->max_tokens = strtol(argv[index + 1], NULL, 10);
            if (options->max_tokens <= 0l) {
                fprintf(stderr, "invalid value for --max-tokens: %s\n", argv[index + 1]);
                return PSI_STATUS_ERROR;
            }
            index++;
            continue;
        }
        if (strcmp(argv[index], "--system-prompt") == 0) {
            options->mode = PSI_CLI_MODE_SYSTEM_PROMPT;
            continue;
        }
        if (strcmp(argv[index], "--session") == 0) {
            if (psi_cli_needs_value("--session", index, argc) != PSI_STATUS_OK) {
                return PSI_STATUS_ERROR;
            }
            options->session_file = argv[index + 1];
            index++;
            continue;
        }

        fprintf(stderr, "unknown argument: %s\n", argv[index]);
        return PSI_STATUS_ERROR;
    }

    return PSI_STATUS_OK;
}

void psi_cli_usage(const char *program_name) {
    printf(
        "usage: %s [--help] [--version] [--boot FILE] [--eval EXPR] [--print TEXT] [--system-prompt] [--agent TEXT]\n",
        program_name
    );
    printf("\n");
    printf("  --eval EXPR   evaluate a Scheme expression and print the result\n");
    printf("  --print TEXT  run the bootstrap print-mode handler\n");
    printf("  --system-prompt  print the default coding-agent system prompt\n");
    printf("  --agent TEXT  run a single Anthropic-backed coding-agent turn\n");
    printf("  --model MODEL  model to use with --agent (default: env or claude-opus-4-7)\n");
    printf("  --max-tokens N  max output tokens for --agent (default: 4096)\n");
    printf("  --boot FILE   override the Scheme bootstrap file\n");
    printf("  --session FILE  load and save a JSONL session file\n");
}
