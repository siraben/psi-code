#ifndef PSI_PROCESS_H
#define PSI_PROCESS_H

#include "psi/common.h"

struct psi_abort_signal;

/* Optional progress callback: fires for each chunk read from the child's
 * stdout/stderr before it is appended to the output buffer. Use for live
 * streaming of long-running tool output. `len` may be 0 on EOF. */
typedef void (*psi_process_progress_cb)(void *userdata, const char *chunk, size_t len);

/* If abort_signal is non-NULL and becomes triggered during the read
 * loop, the child is SIGTERM'd and the function returns PSI_STATUS_OK
 * with exit_status set to 130 (SIGINT convention). */
int psi_process_run_shell(
    const char *command,
    char **output_text,
    int *exit_status,
    int *truncated,
    psi_process_progress_cb on_chunk,
    void *userdata,
    struct psi_abort_signal *abort_signal
);

#endif
