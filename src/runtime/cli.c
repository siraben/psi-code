#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <argtable3.h>
#include "psi/runtime.h"

struct psi_cli_argtable {
    struct arg_lit *help;
    struct arg_lit *version;
    struct arg_lit *tui;
    struct arg_str *print;
    struct arg_str *eval;
    struct arg_str *boot;
    struct arg_lit *system_prompt;
    struct arg_str *agent;
    struct arg_str *model;
    struct arg_str *thinking;
    struct arg_int *max_tokens;
    struct arg_int *compact;
    struct arg_str *session;
    struct arg_lit *resume;
    struct arg_end *end;
    void *table[15];
};

static int psi_cli_valid_thinking(const char *level) {
    if (level == NULL) return 0;
    return strcmp(level, "off") == 0 ||
           strcmp(level, "minimal") == 0 ||
           strcmp(level, "low") == 0 ||
           strcmp(level, "medium") == 0 ||
           strcmp(level, "high") == 0 ||
           strcmp(level, "xhigh") == 0;
}

static int psi_cli_build_argtable(struct psi_cli_argtable *args) {
    args->help = arg_lit0("h", "help", "show help");
    args->version = arg_lit0(NULL, "version", "show version");
    args->tui = arg_lit0(NULL, "tui", "run the full-screen interactive TUI");
    args->print = arg_str0(NULL, "print", "TEXT", "run the bootstrap print-mode handler");
    args->eval = arg_str0(NULL, "eval", "EXPR", "evaluate a Lua expression and print the result");
    args->boot = arg_str0(NULL, "boot", "FILE", "override the Lua bootstrap file");
    args->system_prompt = arg_lit0(NULL, "system-prompt", "print the default coding-agent system prompt");
    args->agent = arg_str0(NULL, "agent", "TEXT", "run a single Anthropic-backed coding-agent turn");
    args->model = arg_str0(NULL, "model", "MODEL", "model to use with --agent");
    args->thinking = arg_str0(NULL, "thinking", "LEVEL", "thinking level: off, minimal, low, medium, high, xhigh");
    args->max_tokens = arg_int0(NULL, "max-tokens", "N", "max output tokens for --agent");
    args->compact = arg_int0(NULL, "compact", "N", "compact the current session, keeping the most recent N messages");
    args->session = arg_str0(NULL, "session", "FILE", "load and save a JSONL session file");
    args->resume = arg_lit0("r", "resume", "resume a session for the current directory");
    args->end = arg_end(20);

    args->table[0] = args->help;
    args->table[1] = args->version;
    args->table[2] = args->tui;
    args->table[3] = args->print;
    args->table[4] = args->eval;
    args->table[5] = args->boot;
    args->table[6] = args->system_prompt;
    args->table[7] = args->agent;
    args->table[8] = args->model;
    args->table[9] = args->thinking;
    args->table[10] = args->max_tokens;
    args->table[11] = args->compact;
    args->table[12] = args->session;
    args->table[13] = args->resume;
    args->table[14] = args->end;

    return arg_nullcheck(args->table) == 0 ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

static void psi_cli_free_argtable(struct psi_cli_argtable *args) {
    arg_freetable(args->table, sizeof(args->table) / sizeof(args->table[0]));
}

static int psi_cli_normalize_argv(int argc, char **argv, int *normalized_argc, char ***normalized_argv) {
    char **copy;
    int index;
    int out_index;

    copy = (char **)malloc((size_t)(argc + 2) * sizeof(char *));
    if (copy == NULL) {
        return PSI_STATUS_ERROR;
    }

    out_index = 0;
    for (index = 0; index < argc; index++) {
        copy[out_index++] = argv[index];
        if (strcmp(argv[index], "--compact") == 0 &&
            (index + 1 >= argc || argv[index + 1][0] == '-')) {
            copy[out_index++] = "12";
        }
    }

    *normalized_argc = out_index;
    *normalized_argv = copy;
    return PSI_STATUS_OK;
}

static int psi_cli_count_modes(const struct psi_cli_argtable *args) {
    int count;

    count = 0;
    count += args->print->count > 0 ? 1 : 0;
    count += args->eval->count > 0 ? 1 : 0;
    count += args->system_prompt->count > 0 ? 1 : 0;
    count += args->agent->count > 0 ? 1 : 0;
    count += args->compact->count > 0 ? 1 : 0;
    count += args->tui->count > 0 ? 1 : 0;
    return count;
}

int psi_cli_parse(struct psi_cli_options *options, int argc, char **argv) {
    struct psi_cli_argtable args;
    int normalized_argc;
    char **normalized_argv;
    int parse_errors;
    int mode_count;

    if (options == NULL) {
        return PSI_STATUS_ERROR;
    }

    options->mode = PSI_CLI_MODE_REPL;
    options->payload = NULL;
    /* Default: use the compile-time path if set. psi_vm_init falls
     * back to the embedded boot.lua when the file doesn't exist on
     * disk, so a portable static binary still works on machines
     * where PSI_LUA_BOOT_FILE's directory doesn't exist. */
    options->boot_file = PSI_LUA_BOOT_FILE;
    options->session_file = NULL;
    options->model = NULL;
    options->thinking_level = NULL;
    options->max_tokens = 16384l;
    options->keep_recent = 12l;
    options->resume = 0;

    if (psi_cli_build_argtable(&args) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    normalized_argc = 0;
    normalized_argv = NULL;
    if (psi_cli_normalize_argv(argc, argv, &normalized_argc, &normalized_argv) != PSI_STATUS_OK) {
        psi_cli_free_argtable(&args);
        return PSI_STATUS_ERROR;
    }

    parse_errors = arg_parse(normalized_argc, normalized_argv, args.table);
    free((void *)normalized_argv);
    if (parse_errors > 0) {
        arg_print_errors(stderr, args.end, argv[0]);
        psi_cli_free_argtable(&args);
        return PSI_STATUS_ERROR;
    }

    if (args.help->count > 0) {
        options->mode = PSI_CLI_MODE_HELP;
        psi_cli_free_argtable(&args);
        return PSI_STATUS_OK;
    }
    if (args.version->count > 0) {
        options->mode = PSI_CLI_MODE_VERSION;
        psi_cli_free_argtable(&args);
        return PSI_STATUS_OK;
    }

    mode_count = psi_cli_count_modes(&args);
    if (mode_count > 1) {
        fprintf(stderr, "choose only one primary mode flag\n");
        psi_cli_free_argtable(&args);
        return PSI_STATUS_ERROR;
    }

    if (args.print->count > 0) {
        options->mode = PSI_CLI_MODE_PRINT;
        options->payload = args.print->sval[0];
    } else if (args.tui->count > 0) {
        options->mode = PSI_CLI_MODE_TUI;
    } else if (args.eval->count > 0) {
        options->mode = PSI_CLI_MODE_EVAL;
        options->payload = args.eval->sval[0];
    } else if (args.system_prompt->count > 0) {
        options->mode = PSI_CLI_MODE_SYSTEM_PROMPT;
    } else if (args.agent->count > 0) {
        options->mode = PSI_CLI_MODE_AGENT;
        options->payload = args.agent->sval[0];
    } else if (args.compact->count > 0) {
        options->mode = PSI_CLI_MODE_COMPACT;
        options->keep_recent = (long)args.compact->ival[0];
    }

    if (args.boot->count > 0) {
        options->boot_file = args.boot->sval[0];
    }
    if (args.session->count > 0) {
        options->session_file = args.session->sval[0];
    }
    if (args.resume->count > 0) {
        options->resume = 1;
    }
    if (args.model->count > 0) {
        options->model = args.model->sval[0];
    }
    if (args.thinking->count > 0) {
        if (!psi_cli_valid_thinking(args.thinking->sval[0])) {
            fprintf(stderr, "invalid value for --thinking\n");
            psi_cli_free_argtable(&args);
            return PSI_STATUS_ERROR;
        }
        options->thinking_level = args.thinking->sval[0];
    }
    if (args.max_tokens->count > 0) {
        options->max_tokens = (long)args.max_tokens->ival[0];
    }
    psi_cli_free_argtable(&args);

    if (options->max_tokens <= 0l) {
        fprintf(stderr, "invalid value for --max-tokens\n");
        return PSI_STATUS_ERROR;
    }
    if (options->keep_recent < 0l) {
        fprintf(stderr, "invalid value for --compact\n");
        return PSI_STATUS_ERROR;
    }

    return PSI_STATUS_OK;
}

void psi_cli_usage(const char *program_name) {
    struct psi_cli_argtable args;

    if (psi_cli_build_argtable(&args) != PSI_STATUS_OK) {
        fprintf(stderr, "failed to build CLI help\n");
        return;
    }

    fprintf(stdout, "usage: %s", program_name);
    arg_print_syntax(stdout, args.table, "\n");
    fprintf(stdout, "\n");
    arg_print_glossary(stdout, args.table, "  %-24s %s\n");
    fprintf(stdout, "\n");
    fprintf(stdout, "  --compact without N defaults to 12.\n");

    psi_cli_free_argtable(&args);
}
