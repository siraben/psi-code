#ifndef PSI_RUNTIME_H
#define PSI_RUNTIME_H

#include "psi/common.h"

enum psi_cli_mode {
    PSI_CLI_MODE_HELP = 0,
    PSI_CLI_MODE_VERSION = 1,
    PSI_CLI_MODE_PRINT = 2,
    PSI_CLI_MODE_EVAL = 3,
    PSI_CLI_MODE_REPL = 4,
    PSI_CLI_MODE_SYSTEM_PROMPT = 5,
    PSI_CLI_MODE_AGENT = 6,
    PSI_CLI_MODE_COMPACT = 7,
    PSI_CLI_MODE_TUI = 8
};

struct psi_cli_options {
    enum psi_cli_mode mode;
    const char *payload;
    const char *boot_file;
    const char *session_file;
    const char *model;
    const char *thinking_level;
    const char *layout_mode;
    long max_tokens;
    long keep_recent;
    int resume;
};

int psi_cli_parse(struct psi_cli_options *options, int argc, char **argv);
void psi_cli_usage(const char *program_name);
int psi_run_tui_mode(const struct psi_cli_options *options);
int psi_run_print_mode_dispatch(const struct psi_cli_options *options);

#endif
