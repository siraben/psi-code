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
int psi_process_run_shell(const char *command, char **output_text, int *exit_status, int *truncated,
    psi_process_progress_cb on_chunk, void *userdata, const struct psi_abort_signal *abort_signal);

int psi_process_run_argv(char *const argv[], char **output_text, int *exit_status, int *truncated,
    const struct psi_abort_signal *abort_signal);

/* ------------------------------------------------------------------
 * Async shell execution.
 *
 * Lua coroutines in the TUI must not block the main thread on shell
 * execution, so exec gets a begin/poll/finish split. begin forks
 * and exec's the child and returns immediately; poll drains one
 * chunk at a time from the pipe with a timeout; finish reaps the
 * child, frees the handle, and hands back the accumulated output.
 *
 * Typical usage from the Lua side (via psi.process_begin / _poll /
 * _finish → psi.sched.proc_poll):
 *
 *   local h = psi.process_begin(cmd)
 *   while true do
 *     local chunk, done = sched.proc_poll(h, 50)
 *     if chunk then parts[#parts+1] = chunk end
 *     if done then break end
 *   end
 *   local result = psi.process_finish(h)  -- table
 * ------------------------------------------------------------------ */

struct psi_process_handle;

/* Start the shell command. On success, *out owns the handle and the
 * child is already forked. On abort-signal-triggered return the
 * handle is still returned and finish will reap with status=130. */
int psi_process_begin(const char *command, const struct psi_abort_signal *abort_signal,
    struct psi_process_handle **out);

int psi_process_begin_argv(char *const argv[], const struct psi_abort_signal *abort_signal,
    struct psi_process_handle **out);

/* Start a process intended for stdio protocols: child stdin is a
 * writable pipe owned by the parent, child stdout is the pollable
 * output stream, and child stderr is kept out of the protocol stream. */
int psi_process_begin_stdio_argv(char *const argv[], const struct psi_abort_signal *abort_signal,
    struct psi_process_handle **out);

int psi_process_write(struct psi_process_handle *h, const char *data, size_t len);

int psi_process_close_stdin(struct psi_process_handle *h);

/* Best-effort termination for leaked or failed protocol children.
 * Closes child stdin and sends SIGTERM if the child has not been
 * reaped yet. The handle is still owned by the caller and must still
 * be passed to psi_process_finish. */
int psi_process_terminate(struct psi_process_handle *h);

/* Drain one read() worth of output.
 *
 * Returns:
 *    1  chunk available; *chunk owns heap bytes (caller free()s).
 *       *chunk_len is byte length (no trailing NUL).
 *    0  timeout elapsed; child still running; may poll again.
 *    2  child exited / EOF reached; call finish.
 *   -1  unrecoverable error (e.g. alloc failure); caller should
 *       stop polling and call finish to reap the child.
 *
 * NB: the "chunk available" code is deliberately 1 and the error
 * code is deliberately negative so a boolean `r == 1` branch can
 * never be entered on failure.
 */
int psi_process_poll(struct psi_process_handle *h, int timeout_ms, char **chunk, size_t *chunk_len);

/* Reap the child, close descriptors, free the handle. Returns
 * PSI_STATUS_OK with exit_status / truncated / output_text populated
 * (output_text is the concatenation of everything poll accumulated
 * internally — callers that drained every chunk via poll get a
 * separate reconstruction. output_text may be "" but is never NULL
 * on PSI_STATUS_OK; caller must free() it. */
int psi_process_finish(
    struct psi_process_handle *h, char **output_text, int *exit_status, int *truncated);

#endif
