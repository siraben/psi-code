#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <argtable3.h>
#include "psi/runtime.h"

#ifndef PSI_ENABLE_TUI
#define PSI_ENABLE_TUI 0
#endif

#define PSI_CLI_ARGTABLE_CAP 15u

struct psi_cli_argtable {
    struct arg_lit *help;
    struct arg_lit *version;
    struct arg_lit *tui;
    struct arg_lit *repl;
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
    struct arg_end *end;
    void *table[PSI_CLI_ARGTABLE_CAP];
    size_t table_count;
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

static void psi_cli_argtable_add(struct psi_cli_argtable *args, void *arg) {
    if (args->table_count < PSI_CLI_ARGTABLE_CAP) {
        args->table[args->table_count++] = arg;
    }
}

static int psi_cli_build_argtable(struct psi_cli_argtable *args) {
    args->table_count = 0u;

    args->help = arg_lit0("h", "help", "show help");
    args->version = arg_lit0(NULL, "version", "show version");
    args->tui = arg_lit0(NULL, "tui", "run the full-screen interactive TUI");
    args->repl = arg_lit0(NULL, "repl", "run the interactive line editor shell");
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
    args->end = arg_end(20);

    psi_cli_argtable_add(args, args->help);
    psi_cli_argtable_add(args, args->version);
    psi_cli_argtable_add(args, args->tui);
    psi_cli_argtable_add(args, args->repl);
    psi_cli_argtable_add(args, args->print);
    psi_cli_argtable_add(args, args->eval);
    psi_cli_argtable_add(args, args->boot);
    psi_cli_argtable_add(args, args->system_prompt);
    psi_cli_argtable_add(args, args->agent);
    psi_cli_argtable_add(args, args->model);
    psi_cli_argtable_add(args, args->thinking);
    psi_cli_argtable_add(args, args->max_tokens);
    psi_cli_argtable_add(args, args->compact);
    psi_cli_argtable_add(args, args->session);
    psi_cli_argtable_add(args, args->end);

    if (args->table_count != PSI_CLI_ARGTABLE_CAP) {
        return PSI_STATUS_ERROR;
    }
    return arg_nullcheck(args->table) == 0 ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

static void psi_cli_free_argtable(struct psi_cli_argtable *args) {
    arg_freetable(args->table, args->table_count);
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
    count += args->repl->count > 0 ? 1 : 0;
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

    options->mode = PSI_ENABLE_TUI ? PSI_CLI_MODE_TUI : PSI_CLI_MODE_REPL;
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
    } else if (args.repl->count > 0) {
        options->mode = PSI_CLI_MODE_REPL;
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
