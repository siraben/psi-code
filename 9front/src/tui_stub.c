/* Stub for psi_run_tui_mode on platforms without ncurses (9front).
 * TUI isn't supported here; refuse with a clear error when someone
 * passes --tui. */

#include <stdio.h>
#include "psi/common.h"
#include "psi/runtime.h"

int
psi_run_tui_mode(const struct psi_cli_options *options)
{
    (void)options;
    fprintf(stderr, "psi: --tui is not supported on this platform\n");
    return PSI_STATUS_ERROR;
}
