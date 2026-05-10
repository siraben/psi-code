/* Process spawning + output capture for shell-style tools. POSIX
 * fork/exec on Unix; the _WIN32 arm is a placeholder for a future
 * CreateProcess port. The pollable begin/poll/finish triple lets the
 * Lua scheduler keep the TUI redraw loop running while a child runs. */

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

#ifndef PSI_ENABLE_MCP
#define PSI_ENABLE_MCP 0
#endif

static const size_t PSI_PROCESS_OUTPUT_MAX_BYTES = 262144u;

/* Per-iteration read() size when draining the child's stdout/stderr.
 * Also the per-chunk quantum fed to the progress callback.
 * #define so it's usable as an array dimension in C89. */
#define PSI_PROCESS_READ_CHUNK 4096

/* Fallback poll interval used by psi_process_poll when the caller
 * passes a longer timeout — we wake up at most every 20 ms so the
 * abort signal stays responsive. */
static const long PSI_PROCESS_POLL_DELAY_NS = 20L * 1000000L; /* 20 ms */

static int psi_process_append_bytes(
    char **buffer, size_t *length, size_t *capacity, const char *data, size_t bytes) {
    char *next_buffer;
    size_t next_capacity;
    size_t required;

    if (*length > (size_t)-1 - bytes - 1u)
        return PSI_STATUS_ERROR;
    required = *length + bytes + 1u;

    if (required <= *capacity) {
        memcpy(*buffer + *length, data, bytes);
        *length += bytes;
        (*buffer)[*length] = '\0';
        return PSI_STATUS_OK;
    }

    next_capacity = *capacity == 0u ? 4096u : *capacity;
    while (required > next_capacity) {
        if (next_capacity > (size_t)-1 / 2u)
            return PSI_STATUS_ERROR;
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
    int pipe_fd; /* read end of stdout/stderr pipe */
    int stdin_fd; /* write end of optional stdin pipe, or -1 */
    int aborted; /* 1 if abort_signal fired mid-run */
    int eof_seen; /* 1 if read() returned 0 */
    int reaped; /* 1 if waitpid already called */
    int wait_status; /* waitpid result */

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

static int psi_process_begin_exec(char *const argv[], const struct psi_abort_signal *abort_signal,
    int use_stdin_pipe, int protocol_stdout, const char *const *env_pairs, int env_count,
    struct psi_process_handle **out) {
    struct psi_process_handle *h;
    int pipe_fds[2];
    int stdin_fds[2];
    pid_t child_pid;
    int flags;

    if (out == NULL)
        return PSI_STATUS_ERROR;
    *out = NULL;
    if (argv == NULL || argv[0] == NULL)
        return PSI_STATUS_ERROR;

    stdin_fds[0] = -1;
    stdin_fds[1] = -1;
    if (pipe(pipe_fds) != 0)
        return PSI_STATUS_ERROR;
    if (use_stdin_pipe && pipe(stdin_fds) != 0) {
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        return PSI_STATUS_ERROR;
    }

    child_pid = fork();
    if (child_pid < 0) {
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        if (stdin_fds[0] >= 0)
            close(stdin_fds[0]);
        if (stdin_fds[1] >= 0)
            close(stdin_fds[1]);
        return PSI_STATUS_ERROR;
    }

    if (child_pid == 0) {
        /* Child: see psi_process_run_shell for the same logic and
         * the gcc -fanalyzer fd-leak suppression rationale. */
/* -Wanalyzer-fd-leak was added in gcc 13; older gccs (e.g. Alpine 3.14's
 * gcc 10) reject the pragma under -Werror=pragmas. */
#if defined(__GNUC__) && !defined(__clang__) && !defined(__TINYC__) && __GNUC__ >= 13
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wanalyzer-fd-leak"
#endif
        int devnull;
        /* New pgrp so abort can signal the whole tree, not just sh. */
        (void)setpgid(0, 0);
        signal(SIGPIPE, SIG_DFL);
        if (close(pipe_fds[0]) != 0)
            _exit(127);
        if (stdin_fds[1] >= 0 && close(stdin_fds[1]) != 0)
            _exit(127);
        /* Detach the child from the controlling TTY's input so that
         * keypresses (notably ESC, used in TUI mode to interrupt the
         * current turn) reach ncurses in the parent rather than
         * being consumed by the child. Without this redirect the
         * child inherits stdin = the parent's tty, which is in raw
         * mode under TUI and races with the parent's getch() for
         * each byte the user types. */
        if (use_stdin_pipe) {
            if (dup2(stdin_fds[0], 0) < 0)
                _exit(127);
            if (stdin_fds[0] > 2 && close(stdin_fds[0]) != 0)
                _exit(127);
        } else {
            devnull = open("/dev/null", O_RDONLY);
            if (devnull < 0)
                _exit(127);
            if (dup2(devnull, 0) < 0)
                _exit(127);
            if (devnull > 2 && close(devnull) != 0)
                _exit(127);
        }
        if (dup2(pipe_fds[1], 1) < 0)
            _exit(127);
        if (protocol_stdout) {
            devnull = open("/dev/null", O_WRONLY);
            if (devnull < 0)
                _exit(127);
            if (dup2(devnull, 2) < 0)
                _exit(127);
            if (devnull > 2 && close(devnull) != 0)
                _exit(127);
        } else {
            if (dup2(pipe_fds[1], 2) < 0)
                _exit(127);
        }
        if (close(pipe_fds[1]) != 0)
            _exit(127);
        {
            int ei;
            for (ei = 0; ei < env_count && env_pairs != NULL && env_pairs[ei] != NULL; ei++) {
                const char *pair = env_pairs[ei];
                const char *eq = strchr(pair, '=');
                if (eq != NULL && eq != pair) {
                    char key[256];
                    size_t klen = (size_t)(eq - pair);
                    if (klen < sizeof(key)) {
                        memcpy(key, pair, klen);
                        key[klen] = '\0';
                        setenv(key, eq + 1, 1);
                    }
                }
            }
        }
        execvp(argv[0], argv);
        _exit(127);
#if defined(__GNUC__) && !defined(__clang__) && !defined(__TINYC__) && __GNUC__ >= 13
#pragma GCC diagnostic pop
#endif
    }

    close(pipe_fds[1]);
    if (stdin_fds[0] >= 0)
        close(stdin_fds[0]);
    flags = fcntl(pipe_fds[0], F_GETFL, 0);
    if (flags != -1) {
        fcntl(pipe_fds[0], F_SETFL, flags | O_NONBLOCK);
    }
    if (stdin_fds[1] >= 0) {
        flags = fcntl(stdin_fds[1], F_GETFL, 0);
        if (flags != -1)
            fcntl(stdin_fds[1], F_SETFL, flags | O_NONBLOCK);
    }

    /* Mirror the child's setpgid so the group exists race-free; an
     * EACCES here means the child already exec'd, which is fine. */
    (void)setpgid(child_pid, child_pid);

    h = (struct psi_process_handle *)calloc(1u, sizeof(*h));
    if (h == NULL) {
        close(pipe_fds[0]);
        if (stdin_fds[1] >= 0)
            close(stdin_fds[1]);
        /* Can't reap child cleanly here; fall through to OS cleanup. */
        kill(-child_pid, SIGTERM);
        waitpid(child_pid, NULL, 0);
        return PSI_STATUS_ERROR;
    }
    h->child_pid = child_pid;
    h->pipe_fd = pipe_fds[0];
    h->stdin_fd = stdin_fds[1];
    h->abort_signal = abort_signal;
    *out = h;
    return PSI_STATUS_OK;
}

int psi_process_begin_argv(char *const argv[], const struct psi_abort_signal *abort_signal,
    struct psi_process_handle **out) {
    return psi_process_begin_exec(argv, abort_signal, 0, 0, NULL, 0, out);
}

int psi_process_begin_stdio_argv(char *const argv[], const char *const *env_pairs, int env_count,
    const struct psi_abort_signal *abort_signal, struct psi_process_handle **out) {
#if PSI_ENABLE_MCP
    return psi_process_begin_exec(argv, abort_signal, 1, 1, env_pairs, env_count, out);
#else
    PSI_UNUSED(argv);
    PSI_UNUSED(env_pairs);
    PSI_UNUSED(env_count);
    PSI_UNUSED(abort_signal);
    if (out != NULL)
        *out = NULL;
    return PSI_STATUS_ERROR;
#endif
}

int psi_process_begin(const char *command, const struct psi_abort_signal *abort_signal,
    struct psi_process_handle **out) {
    char *argv[4];
    argv[0] = (char *)"sh";
    argv[1] = (char *)"-lc";
    argv[2] = (char *)command;
    argv[3] = NULL;
    if (command == NULL)
        return PSI_STATUS_ERROR;
    return psi_process_begin_exec(argv, abort_signal, 0, 0, NULL, 0, out);
}

int psi_process_write(struct psi_process_handle *h, const char *data, size_t len) {
#if PSI_ENABLE_MCP
    size_t written;
    struct sigaction ignore_pipe;
    struct sigaction old_pipe;
    int have_old_pipe;
    int status;

    if (h == NULL || data == NULL)
        return PSI_STATUS_ERROR;
    if (h->stdin_fd < 0)
        return PSI_STATUS_ERROR;

    memset(&ignore_pipe, 0, sizeof(ignore_pipe));
    memset(&old_pipe, 0, sizeof(old_pipe));
    ignore_pipe.sa_handler = SIG_IGN;
    sigemptyset(&ignore_pipe.sa_mask);
    have_old_pipe = sigaction(SIGPIPE, &ignore_pipe, &old_pipe) == 0;

    status = PSI_STATUS_OK;
    written = 0u;
    while (written < len) {
        ssize_t n;
        if (psi_abort_signal_is_triggered(h->abort_signal) && !h->aborted) {
            h->aborted = 1;
            kill(-h->child_pid, SIGTERM);
            status = PSI_STATUS_ERROR;
            break;
        }
        n = write(h->stdin_fd, data + written, len - written);
        if (n > 0) {
            written += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct timespec delay;
            delay.tv_sec = 0;
            delay.tv_nsec = PSI_PROCESS_POLL_DELAY_NS;
            nanosleep(&delay, NULL);
            continue;
        }
        status = PSI_STATUS_ERROR;
        break;
    }

    if (have_old_pipe) {
        sigaction(SIGPIPE, &old_pipe, NULL);
    }
    return status;
#else
    PSI_UNUSED(h);
    PSI_UNUSED(data);
    PSI_UNUSED(len);
    return PSI_STATUS_ERROR;
#endif
}

int psi_process_close_stdin(struct psi_process_handle *h) {
#if PSI_ENABLE_MCP
    if (h == NULL)
        return PSI_STATUS_ERROR;
    if (h->stdin_fd >= 0) {
        close(h->stdin_fd);
        h->stdin_fd = -1;
    }
    return PSI_STATUS_OK;
#else
    PSI_UNUSED(h);
    return PSI_STATUS_ERROR;
#endif
}

int psi_process_try_write(
    struct psi_process_handle *h, const char *data, size_t len, size_t *written) {
#if PSI_ENABLE_MCP
    struct sigaction ignore_pipe;
    struct sigaction old_pipe;
    int have_old_pipe;
    int status;
    ssize_t n;

    if (written != NULL)
        *written = 0u;
    if (h == NULL || data == NULL)
        return PSI_STATUS_ERROR;
    if (h->stdin_fd < 0)
        return PSI_STATUS_ERROR;
    if (len == 0u)
        return PSI_STATUS_OK;

    if (psi_abort_signal_is_triggered(h->abort_signal) && !h->aborted) {
        h->aborted = 1;
        kill(-h->child_pid, SIGTERM);
        return PSI_STATUS_ERROR;
    }

    memset(&ignore_pipe, 0, sizeof(ignore_pipe));
    memset(&old_pipe, 0, sizeof(old_pipe));
    ignore_pipe.sa_handler = SIG_IGN;
    sigemptyset(&ignore_pipe.sa_mask);
    have_old_pipe = sigaction(SIGPIPE, &ignore_pipe, &old_pipe) == 0;

    status = PSI_STATUS_OK;
    n = write(h->stdin_fd, data, len);
    if (n > 0) {
        if (written != NULL)
            *written = (size_t)n;
    } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
        /* Caller retries after a cooperative yield. */
    } else {
        status = PSI_STATUS_ERROR;
    }

    if (have_old_pipe) {
        sigaction(SIGPIPE, &old_pipe, NULL);
    }
    return status;
#else
    PSI_UNUSED(h);
    PSI_UNUSED(data);
    PSI_UNUSED(len);
    if (written != NULL)
        *written = 0u;
    return PSI_STATUS_ERROR;
#endif
}

int psi_process_terminate(struct psi_process_handle *h) {
    if (h == NULL)
        return PSI_STATUS_ERROR;
    if (h->stdin_fd >= 0) {
        close(h->stdin_fd);
        h->stdin_fd = -1;
    }
    if (!h->reaped) {
        h->aborted = 1;
        kill(-h->child_pid, SIGTERM);
    }
    return PSI_STATUS_OK;
}

int psi_process_poll(
    struct psi_process_handle *h, int timeout_ms, char **chunk, size_t *chunk_len) {
    char read_buffer[PSI_PROCESS_READ_CHUNK];
    long total_waited_ns;
    long max_wait_ns;

    if (chunk != NULL)
        *chunk = NULL;
    if (chunk_len != NULL)
        *chunk_len = 0u;
    if (h == NULL)
        return 2;

    if (psi_abort_signal_is_triggered(h->abort_signal) && !h->aborted) {
        h->aborted = 1;
        /* Negative pid → signal the whole process group. */
        kill(-h->child_pid, SIGTERM);
    }

    /* Loop until either we produce a chunk, time runs out, or
     * the pipe hits EOF. Each iteration: one non-blocking read(),
     * optionally followed by a short nanosleep capped at the
     * remaining budget. */
    total_waited_ns = 0L;
    max_wait_ns = (timeout_ms > 0) ? (long)timeout_ms * 1000000L : 0L;

    for (;;) {
        ssize_t read_count;
        read_count = read(h->pipe_fd, read_buffer, sizeof(read_buffer));
        if (read_count > 0) {
            char *copy;
            size_t read_size;

            read_size = (size_t)read_count;
            if (read_size > sizeof(read_buffer))
                return -1;

            if (chunk != NULL) {
                copy = (char *)malloc(read_size + 1u);
                if (copy == NULL)
                    return -1;
                memcpy(copy, read_buffer, read_size);
                copy[read_size] = '\0';
                *chunk = copy;
            }
            if (chunk_len != NULL)
                *chunk_len = read_size;

            /* Also stash into the internal buffer so finish() can
             * reassemble even if the caller didn't consume every
             * chunk. Respect the 256 KiB ceiling; once full we
             * stop buffering but still return to the caller. */
            if (h->output_length < PSI_PROCESS_OUTPUT_MAX_BYTES) {
                size_t to_copy = read_size;
                if (h->output_length + to_copy > PSI_PROCESS_OUTPUT_MAX_BYTES) {
                    h->truncated = 1;
                    to_copy = PSI_PROCESS_OUTPUT_MAX_BYTES - h->output_length;
                }
                if (psi_process_append_bytes(&h->output_buffer, &h->output_length,
                        &h->output_capacity, read_buffer, to_copy) != PSI_STATUS_OK) {
                    /* Keep going — the caller's copy already has the bytes. */
                }
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
            if (timeout_ms <= 0)
                return 0; /* non-blocking */

            step_ns = PSI_PROCESS_POLL_DELAY_NS;
            if (max_wait_ns - total_waited_ns < step_ns) {
                step_ns = max_wait_ns - total_waited_ns;
            }
            if (step_ns <= 0L)
                return 0;

            delay.tv_sec = 0;
            delay.tv_nsec = step_ns;
            nanosleep(&delay, NULL);
            total_waited_ns += step_ns;

            if (psi_abort_signal_is_triggered(h->abort_signal) && !h->aborted) {
                h->aborted = 1;
                kill(-h->child_pid, SIGTERM);
            }
            continue;
        }
        /* Non-recoverable read error — treat as EOF. */
        h->eof_seen = 1;
        return 2;
    }
}

int psi_process_finish(
    struct psi_process_handle *h, char **output_text, int *exit_status, int *truncated) {
    if (h == NULL)
        return PSI_STATUS_ERROR;

    if (!h->reaped) {
        if (h->stdin_fd >= 0) {
            close(h->stdin_fd);
            h->stdin_fd = -1;
        }
        close(h->pipe_fd);
        /* On abort, poll for up to 500ms then escalate to SIGKILL,
         * capping abort latency at ~1.5s for SIGTERM-ignoring trees. */
        if (h->aborted) {
            int waited_ms;
            int sigkilled;
            sigkilled = 0;
            for (waited_ms = 0; waited_ms < 1500; waited_ms += 20) {
                pid_t r;
                struct timespec delay;
                r = waitpid(h->child_pid, &h->wait_status, WNOHANG);
                if (r == h->child_pid) {
                    h->reaped = 1;
                    break;
                }
                if (r < 0) {
                    h->reaped = 1; /* ECHILD: already harvested */
                    break;
                }
                if (!sigkilled && waited_ms >= 500) {
                    kill(-h->child_pid, SIGKILL);
                    sigkilled = 1;
                }
                delay.tv_sec = 0;
                delay.tv_nsec = 20L * 1000000L;
                nanosleep(&delay, NULL);
            }
        }
        if (!h->reaped) {
            if (waitpid(h->child_pid, &h->wait_status, 0) < 0) {
                /* Best-effort: carry on with whatever we have. */
            }
            h->reaped = 1;
        }
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
    if (truncated != NULL)
        *truncated = h->truncated;
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

struct psi_process_handle {
    int placeholder;
};

int psi_process_begin(const char *command, const struct psi_abort_signal *abort_signal,
    struct psi_process_handle **out) {
    PSI_UNUSED(command);
    PSI_UNUSED(abort_signal);
    if (out != NULL)
        *out = NULL;
    return PSI_STATUS_ERROR;
}
int psi_process_begin_argv(char *const argv[], const struct psi_abort_signal *abort_signal,
    struct psi_process_handle **out) {
    PSI_UNUSED(argv);
    PSI_UNUSED(abort_signal);
    if (out != NULL)
        *out = NULL;
    return PSI_STATUS_ERROR;
}
int psi_process_begin_stdio_argv(char *const argv[], const char *const *env_pairs, int env_count,
    const struct psi_abort_signal *abort_signal, struct psi_process_handle **out) {
    PSI_UNUSED(argv);
    PSI_UNUSED(env_pairs);
    PSI_UNUSED(env_count);
    PSI_UNUSED(abort_signal);
    if (out != NULL)
        *out = NULL;
    return PSI_STATUS_ERROR;
}
int psi_process_write(struct psi_process_handle *h, const char *data, size_t len) {
    PSI_UNUSED(h);
    PSI_UNUSED(data);
    PSI_UNUSED(len);
    return PSI_STATUS_ERROR;
}
int psi_process_close_stdin(struct psi_process_handle *h) {
    PSI_UNUSED(h);
    return PSI_STATUS_ERROR;
}
int psi_process_try_write(
    struct psi_process_handle *h, const char *data, size_t len, size_t *written) {
    PSI_UNUSED(h);
    PSI_UNUSED(data);
    PSI_UNUSED(len);
    if (written)
        *written = 0u;
    return PSI_STATUS_ERROR;
}
int psi_process_terminate(struct psi_process_handle *h) {
    PSI_UNUSED(h);
    return PSI_STATUS_ERROR;
}
int psi_process_poll(
    struct psi_process_handle *h, int timeout_ms, char **chunk, size_t *chunk_len) {
    PSI_UNUSED(h);
    PSI_UNUSED(timeout_ms);
    if (chunk)
        *chunk = NULL;
    if (chunk_len)
        *chunk_len = 0u;
    return 2;
}
int psi_process_finish(
    struct psi_process_handle *h, char **output_text, int *exit_status, int *truncated) {
    PSI_UNUSED(h);
    if (output_text)
        *output_text = psi_strdup("");
    if (exit_status)
        *exit_status = -1;
    if (truncated)
        *truncated = 0;
    return PSI_STATUS_OK;
}

#endif

/* ------------------------------------------------------------------
 * Blocking wrapper — drives the async state machine in a tight
 * loop. Keeps the existing progress-callback contract intact.
 * ------------------------------------------------------------------ */

int psi_process_run_shell(const char *command, char **output_text, int *exit_status, int *truncated,
    psi_process_progress_cb on_chunk, void *userdata, const struct psi_abort_signal *abort_signal) {
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
            if (on_chunk != NULL)
                on_chunk(userdata, chunk, chunk_len);
            free(chunk);
        }
        if (r == 2 || r < 0)
            break;
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

int psi_process_run_argv(char *const argv[], char **output_text, int *exit_status, int *truncated,
    const struct psi_abort_signal *abort_signal) {
#ifndef _WIN32
    struct psi_process_handle *h;

    if (argv == NULL || argv[0] == NULL || output_text == NULL || exit_status == NULL ||
        truncated == NULL) {
        return PSI_STATUS_ERROR;
    }

    if (psi_process_begin_argv(argv, abort_signal, &h) != PSI_STATUS_OK || h == NULL) {
        return PSI_STATUS_ERROR;
    }

    for (;;) {
        char *chunk;
        size_t chunk_len;
        int r;

        chunk = NULL;
        chunk_len = 0u;
        r = psi_process_poll(h, 20, &chunk, &chunk_len);
        free(chunk);
        if (r == 2 || r < 0)
            break;
    }

    return psi_process_finish(h, output_text, exit_status, truncated);
#else
    PSI_UNUSED(argv);
    PSI_UNUSED(abort_signal);
    if (output_text == NULL || exit_status == NULL || truncated == NULL) {
        return PSI_STATUS_ERROR;
    }
    *output_text = psi_strdup("");
    if (*output_text == NULL)
        return PSI_STATUS_ERROR;
    *exit_status = -1;
    *truncated = 0;
    return PSI_STATUS_OK;
#endif
}
