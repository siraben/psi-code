#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifndef _WIN32
#include <fcntl.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#endif
#include "psi/abort.h"
#include "psi/common.h"
#include "psi/process.h"

static const size_t PSI_PROCESS_OUTPUT_MAX_BYTES = 262144u;

/* Per-iteration read() size when draining the child's stdout/stderr.
 * Also the per-chunk quantum fed to the progress callback.
 * #define so it's usable as an array dimension in C89. */
#define PSI_PROCESS_READ_CHUNK 4096

/* Fallback poll interval used by psi_process_poll when the caller
 * passes a longer timeout — we wake up at most every 20 ms so the
 * abort signal stays responsive. */
static const long PSI_PROCESS_POLL_DELAY_NS = 20L * 1000000L; /* 20 ms */

static int psi_process_append_bytes(char **buffer, size_t *length, size_t *capacity, const char *data, size_t bytes) {
    char *next_buffer;
    size_t next_capacity;

    if (*length + bytes + 1u <= *capacity) {
        memcpy(*buffer + *length, data, bytes);
        *length += bytes;
        (*buffer)[*length] = '\0';
        return PSI_STATUS_OK;
    }

    next_capacity = *capacity == 0u ? 4096u : *capacity;
    while (*length + bytes + 1u > next_capacity) {
        next_capacity *= 2u;
    }

    next_buffer = (char *)realloc(*buffer, next_capacity);
    if (next_buffer == NULL) {
        return PSI_STATUS_ERROR;
    }

    *buffer = next_buffer;
    *capacity = next_capacity;
    memcpy(*buffer + *length, data, bytes);
    *length += bytes;
    (*buffer)[*length] = '\0';
    return PSI_STATUS_OK;
}

/* ------------------------------------------------------------------
 * Async handle.
 *
 * Lua-driven callers use this through begin/poll/finish. The
 * blocking psi_process_run_shell is a thin wrapper that drives the
 * same state machine in a tight loop.
 * ------------------------------------------------------------------ */

#ifndef _WIN32

struct psi_process_handle {
    pid_t child_pid;
    int pipe_fd;              /* read end of stdout/stderr pipe */
    int aborted;              /* 1 if abort_signal fired mid-run */
    int eof_seen;             /* 1 if read() returned 0 */
    int reaped;               /* 1 if waitpid already called */
    int wait_status;          /* waitpid result */

    /* Accumulated output. Grows up to PSI_PROCESS_OUTPUT_MAX_BYTES
     * then `truncated` is set to 1 and further bytes are dropped
     * from the buffer (though poll still returns them to the caller
     * so live rendering keeps working). */
    char *output_buffer;
    size_t output_length;
    size_t output_capacity;
    int truncated;

    const struct psi_abort_signal *abort_signal;
};

int psi_process_begin(
    const char *command,
    const struct psi_abort_signal *abort_signal,
    struct psi_process_handle **out
) {
    struct psi_process_handle *h;
    int pipe_fds[2];
    pid_t child_pid;
    int flags;

    if (out == NULL) return PSI_STATUS_ERROR;
    *out = NULL;
    if (command == NULL) return PSI_STATUS_ERROR;

    if (pipe(pipe_fds) != 0) return PSI_STATUS_ERROR;

    child_pid = fork();
    if (child_pid < 0) {
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        return PSI_STATUS_ERROR;
    }

    if (child_pid == 0) {
        /* Child: see psi_process_run_shell for the same logic and
         * the gcc -fanalyzer fd-leak suppression rationale. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wanalyzer-fd-leak"
        if (close(pipe_fds[0]) != 0) _exit(127);
        if (dup2(pipe_fds[1], 1) < 0) _exit(127);
        if (dup2(pipe_fds[1], 2) < 0) _exit(127);
        if (close(pipe_fds[1]) != 0) _exit(127);
        execl("/bin/sh", "sh", "-lc", command, (char *)0);
        _exit(127);
#pragma GCC diagnostic pop
    }

    close(pipe_fds[1]);
    flags = fcntl(pipe_fds[0], F_GETFL, 0);
    if (flags != -1) {
        fcntl(pipe_fds[0], F_SETFL, flags | O_NONBLOCK);
    }

    h = (struct psi_process_handle *)calloc(1u, sizeof(*h));
    if (h == NULL) {
        close(pipe_fds[0]);
        /* Can't reap child cleanly here; fall through to OS cleanup. */
        kill(child_pid, SIGTERM);
        waitpid(child_pid, NULL, 0);
        return PSI_STATUS_ERROR;
    }
    h->child_pid = child_pid;
    h->pipe_fd = pipe_fds[0];
    h->abort_signal = abort_signal;
    *out = h;
    return PSI_STATUS_OK;
}

int psi_process_poll(
    struct psi_process_handle *h,
    int timeout_ms,
    char **chunk, size_t *chunk_len
) {
    char read_buffer[PSI_PROCESS_READ_CHUNK];
    ssize_t read_count;
    long total_waited_ns;
    long max_wait_ns;

    if (chunk != NULL) *chunk = NULL;
    if (chunk_len != NULL) *chunk_len = 0u;
    if (h == NULL) return 2;

    if (psi_abort_signal_is_triggered(h->abort_signal) && !h->aborted) {
        h->aborted = 1;
        kill(h->child_pid, SIGTERM);
    }

    /* Loop until either we produce a chunk, time runs out, or
     * the pipe hits EOF. Each iteration: one non-blocking read(),
     * optionally followed by a short nanosleep capped at the
     * remaining budget. */
    total_waited_ns = 0L;
    max_wait_ns = (timeout_ms > 0) ? (long)timeout_ms * 1000000L : 0L;

    for (;;) {
        read_count = read(h->pipe_fd, read_buffer, sizeof(read_buffer));
        if (read_count > 0) {
            char *copy;

            if (chunk != NULL) {
                copy = (char *)malloc((size_t)read_count);
                if (copy == NULL) return PSI_STATUS_ERROR;
                memcpy(copy, read_buffer, (size_t)read_count);
                *chunk = copy;
            }
            if (chunk_len != NULL) *chunk_len = (size_t)read_count;

            /* Also stash into the internal buffer so finish() can
             * reassemble even if the caller didn't consume every
             * chunk. Respect the 256 KiB ceiling; once full we
             * stop buffering but still return to the caller. */
            if (h->output_length < PSI_PROCESS_OUTPUT_MAX_BYTES) {
                size_t to_copy = (size_t)read_count;
                if (h->output_length + to_copy > PSI_PROCESS_OUTPUT_MAX_BYTES) {
                    to_copy = PSI_PROCESS_OUTPUT_MAX_BYTES - h->output_length;
                    h->truncated = 1;
                }
                if (psi_process_append_bytes(&h->output_buffer, &h->output_length, &h->output_capacity, read_buffer, to_copy) != PSI_STATUS_OK) {
                    /* Keep going — the caller's copy already has the bytes. */
                }
                if ((size_t)read_count > to_copy) h->truncated = 1;
            } else {
                h->truncated = 1;
            }
            return 1;
        }

        if (read_count == 0) {
            h->eof_seen = 1;
            return 2;
        }

        /* read_count < 0 */
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            struct timespec delay;
            long step_ns;

            if (h->aborted) {
                /* Child has been SIGTERM'd but hasn't closed the pipe
                 * yet. Treat this as "done" after the abort flag
                 * so the poll loop doesn't spin. */
                h->eof_seen = 1;
                return 2;
            }
            if (timeout_ms <= 0) return 0; /* non-blocking */

            step_ns = PSI_PROCESS_POLL_DELAY_NS;
            if (max_wait_ns - total_waited_ns < step_ns) {
                step_ns = max_wait_ns - total_waited_ns;
            }
            if (step_ns <= 0L) return 0;

            delay.tv_sec = 0;
            delay.tv_nsec = step_ns;
            nanosleep(&delay, NULL);
            total_waited_ns += step_ns;

            if (psi_abort_signal_is_triggered(h->abort_signal) && !h->aborted) {
                h->aborted = 1;
                kill(h->child_pid, SIGTERM);
            }
            continue;
        }
        /* Non-recoverable read error — treat as EOF. */
        h->eof_seen = 1;
        return 2;
    }
}

int psi_process_finish(
    struct psi_process_handle *h,
    char **output_text,
    int *exit_status,
    int *truncated
) {
    if (h == NULL) return PSI_STATUS_ERROR;

    if (!h->reaped) {
        close(h->pipe_fd);
        if (waitpid(h->child_pid, &h->wait_status, 0) < 0) {
            /* Best-effort: carry on with whatever we have. */
        }
        h->reaped = 1;
    }

    if (exit_status != NULL) {
        if (h->aborted) {
            *exit_status = 130;
        } else if (WIFEXITED(h->wait_status)) {
            *exit_status = WEXITSTATUS(h->wait_status);
        } else if (WIFSIGNALED(h->wait_status)) {
            *exit_status = 128 + WTERMSIG(h->wait_status);
        } else {
            *exit_status = -1;
        }
    }
    if (truncated != NULL) *truncated = h->truncated;
    if (output_text != NULL) {
        if (h->output_buffer == NULL) {
            *output_text = psi_strdup("");
            if (*output_text == NULL) {
                free(h->output_buffer);
                free(h);
                return PSI_STATUS_ERROR;
            }
        } else {
            *output_text = h->output_buffer;
            h->output_buffer = NULL; /* caller owns */
        }
    } else {
        free(h->output_buffer);
    }
    free(h);
    return PSI_STATUS_OK;
}

#else /* _WIN32 */

struct psi_process_handle { int unused; };

int psi_process_begin(const char *cmd, const struct psi_abort_signal *a, struct psi_process_handle **out) {
    PSI_UNUSED(cmd); PSI_UNUSED(a);
    if (out != NULL) *out = NULL;
    return PSI_STATUS_ERROR;
}
int psi_process_poll(struct psi_process_handle *h, int ms, char **c, size_t *n) {
    PSI_UNUSED(h); PSI_UNUSED(ms);
    if (c) *c = NULL; if (n) *n = 0u;
    return 2;
}
int psi_process_finish(struct psi_process_handle *h, char **out, int *ex, int *tr) {
    PSI_UNUSED(h);
    if (out) *out = psi_strdup("");
    if (ex) *ex = -1;
    if (tr) *tr = 0;
    return PSI_STATUS_OK;
}

#endif

/* ------------------------------------------------------------------
 * Blocking wrapper — drives the async state machine in a tight
 * loop. Keeps the existing progress-callback contract intact.
 * ------------------------------------------------------------------ */

int psi_process_run_shell(
    const char *command,
    char **output_text,
    int *exit_status,
    int *truncated,
    psi_process_progress_cb on_chunk,
    void *userdata,
    const struct psi_abort_signal *abort_signal
) {
#ifndef _WIN32
    struct psi_process_handle *h;

    if (command == NULL || output_text == NULL || exit_status == NULL || truncated == NULL) {
        return PSI_STATUS_ERROR;
    }

    if (psi_process_begin(command, abort_signal, &h) != PSI_STATUS_OK || h == NULL) {
        return PSI_STATUS_ERROR;
    }

    for (;;) {
        char *chunk;
        size_t chunk_len;
        int r;

        chunk = NULL;
        chunk_len = 0u;
        r = psi_process_poll(h, 20 /* ms */, &chunk, &chunk_len);
        if (r == 1 && chunk != NULL) {
            if (on_chunk != NULL) on_chunk(userdata, chunk, chunk_len);
            free(chunk);
        }
        if (r == 2) break;
    }

    return psi_process_finish(h, output_text, exit_status, truncated);
#else
    int status;

    PSI_UNUSED(on_chunk);
    PSI_UNUSED(userdata);
    PSI_UNUSED(abort_signal);
    if (command == NULL || output_text == NULL || exit_status == NULL || truncated == NULL) {
        return PSI_STATUS_ERROR;
    }

    status = system(command);
    *output_text = psi_strdup("");
    if (*output_text == NULL) {
        return PSI_STATUS_ERROR;
    }
    *exit_status = status;
    *truncated = 0;
    return PSI_STATUS_OK;
#endif
}
