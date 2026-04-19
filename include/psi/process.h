#ifndef PSI_PROCESS_H
#define PSI_PROCESS_H

#include "psi/common.h"

int psi_process_run_shell(const char *command, char **output_text, int *exit_status, int *truncated);

#endif
