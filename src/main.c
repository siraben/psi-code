#include <stdio.h>
#include "psi/runtime.h"

extern int psi_run_print_mode_dispatch(const struct psi_cli_options *options);

int main(int argc, char **argv) {
    struct psi_cli_options options;

    if (psi_cli_parse(&options, argc, argv) != PSI_STATUS_OK) {
        psi_cli_usage(argv[0]);
        return 1;
    }

    switch (options.mode) {
        case PSI_CLI_MODE_HELP:
            psi_cli_usage(argv[0]);
            return 0;
        case PSI_CLI_MODE_VERSION:
            printf("%s\n", PSI_VERSION);
            return 0;
        case PSI_CLI_MODE_PRINT:
        case PSI_CLI_MODE_EVAL:
        case PSI_CLI_MODE_REPL:
        case PSI_CLI_MODE_SYSTEM_PROMPT:
        case PSI_CLI_MODE_AGENT:
        case PSI_CLI_MODE_COMPACT:
            return psi_run_print_mode_dispatch(&options) == PSI_STATUS_OK ? 0 : 1;
        default:
            psi_cli_usage(argv[0]);
            return 1;
    }
}
