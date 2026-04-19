#ifndef PSI_RUNTIME_H
#define PSI_RUNTIME_H

#include "psi/common.h"

enum psi_cli_mode {
    PSI_CLI_MODE_HELP = 0,
    PSI_CLI_MODE_VERSION = 1,
    PSI_CLI_MODE_PRINT = 2,
    PSI_CLI_MODE_EVAL = 3,
    PSI_CLI_MODE_REPL = 4
};

struct psi_cli_options {
    enum psi_cli_mode mode;
    const char *payload;
    const char *boot_file;
    const char *session_file;
};

int psi_cli_parse(struct psi_cli_options *options, int argc, char **argv);
void psi_cli_usage(const char *program_name);
int psi_run_print_mode(const struct psi_cli_options *options);
int psi_run_repl(const struct psi_cli_options *options);

#endif
