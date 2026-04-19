#ifndef PSI_PROCESS_H
#define PSI_PROCESS_H

#include "psi/common.h"

/* Optional progress callback: fires for each chunk read from the child's
 * stdout/stderr before it is appended to the output buffer. Use for live
 * streaming of long-running tool output. `len` may be 0 on EOF. */
typedef void (*psi_process_progress_cb)(void *userdata, const char *chunk, size_t len);

int psi_process_run_shell(
    const char *command,
    char **output_text,
    int *exit_status,
    int *truncated,
    psi_process_progress_cb on_chunk,
    void *userdata
);

#endif
