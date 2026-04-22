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

/* Poll interval when the child has produced no output yet. Keeps the
 * abort-signal check responsive without burning a CPU core. */
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
    int pipe_fds[2];
    pid_t child_pid;
    int wait_status;
    char read_buffer[PSI_PROCESS_READ_CHUNK];
    char *output_buffer;
    size_t output_length;
    size_t output_capacity;

    if (command == NULL || output_text == NULL || exit_status == NULL || truncated == NULL) {
        return PSI_STATUS_ERROR;
    }

    *output_text = NULL;
    *exit_status = -1;
    *truncated = 0;
    output_buffer = NULL;
    output_length = 0u;
    output_capacity = 0u;

    if (pipe(pipe_fds) != 0) {
        return PSI_STATUS_ERROR;
    }

    child_pid = fork();
    if (child_pid < 0) {
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        return PSI_STATUS_ERROR;
    }

    if (child_pid == 0) {
        /* Child: redirect stdout/stderr to the pipe; bail to 127 on
         * any setup failure so the parent observes a clean exit code
         * rather than a half-wired exec. 127 mirrors the shell
         * convention for "command not found / could not exec".
         *
         * gcc -fanalyzer flags the dup2 branches as potential fd
         * leaks (see [CWE-775]); this is a false positive in a fork
         * child that is about to _exit — the kernel releases all
         * descriptors on process exit. */
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
    /* Put the read end in non-blocking mode so we can poll the abort
     * signal while the child runs. Without this, a child that never
     * writes output would ignore Esc for its full lifetime. */
    {
        int flags = fcntl(pipe_fds[0], F_GETFL, 0);
        if (flags != -1) {
            fcntl(pipe_fds[0], F_SETFL, flags | O_NONBLOCK);
        }
    }
    {
        int aborted = 0;
        for (;;) {
            ssize_t read_count;
            if (psi_abort_signal_is_triggered(abort_signal)) {
                aborted = 1;
                kill(child_pid, SIGTERM);
                break;
            }
            read_count = read(pipe_fds[0], read_buffer, sizeof(read_buffer));
            if (read_count < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                    struct timespec delay;
                    delay.tv_sec = 0;
                    delay.tv_nsec = PSI_PROCESS_POLL_DELAY_NS;
                    nanosleep(&delay, NULL);
                    continue;
                }
                break;
            }
            if (read_count == 0) {
                break;
            }

            if (on_chunk != NULL) {
                on_chunk(userdata, read_buffer, (size_t)read_count);
            }

            if (output_length < PSI_PROCESS_OUTPUT_MAX_BYTES) {
                size_t to_copy = (size_t)read_count;
                if (output_length + to_copy > PSI_PROCESS_OUTPUT_MAX_BYTES) {
                    to_copy = PSI_PROCESS_OUTPUT_MAX_BYTES - output_length;
                    *truncated = 1;
                }
                if (psi_process_append_bytes(&output_buffer, &output_length, &output_capacity, read_buffer, to_copy) != PSI_STATUS_OK) {
                    close(pipe_fds[0]);
                    waitpid(child_pid, &wait_status, 0);
                    free(output_buffer);
                    return PSI_STATUS_ERROR;
                }
                if ((size_t)read_count > to_copy) {
                    *truncated = 1;
                }
            } else {
                *truncated = 1;
            }
        }
        close(pipe_fds[0]);

        if (waitpid(child_pid, &wait_status, 0) < 0) {
            free(output_buffer);
            return PSI_STATUS_ERROR;
        }

        if (aborted) {
            *exit_status = 130; /* SIGINT convention */
        } else if (WIFEXITED(wait_status)) {
            *exit_status = WEXITSTATUS(wait_status);
        } else if (WIFSIGNALED(wait_status)) {
            *exit_status = 128 + WTERMSIG(wait_status);
        } else {
            *exit_status = -1;
        }
    }

    if (output_buffer == NULL) {
        output_buffer = psi_strdup("");
        if (output_buffer == NULL) {
            return PSI_STATUS_ERROR;
        }
    }

    *output_text = output_buffer;
    return PSI_STATUS_OK;
#else
    /* Windows placeholder. psi is not production-tested on Windows;
     * the system() call spawns cmd.exe and performs its own shell
     * parsing, so this path is NOT equivalent to the POSIX fork+execl
     * implementation above and offers no abort-signal responsiveness,
     * no output capture, and no chunk streaming. It exists only so
     * the translation unit compiles on Windows toolchains during
     * experimental ports. */
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
