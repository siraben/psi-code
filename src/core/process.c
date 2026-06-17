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

#if !defined(_WIN32) && defined(PSI_HAVE_COSMO_DCE)
#include <stdint.h>
#include "libc/nt/accounting.h"
#include "libc/nt/enum/processcreationflags.h"
#include "libc/nt/enum/startf.h"
#include "libc/nt/enum/wait.h"
#include "libc/nt/files.h"
#include "libc/nt/ipc.h"
#include "libc/nt/process.h"
#include "libc/nt/runtime.h"
#include "libc/nt/struct/processinformation.h"
#include "libc/nt/struct/securityattributes.h"
#include "libc/nt/struct/startupinfo.h"
extern const int __hostos;
uint32_t WaitForSingleObject(int64_t hHandle, uint32_t dwMilliseconds);
#define PSI_COSMO_HOST_WINDOWS 4
#define PSI_NT_WAIT_NONBLOCKING 0u
#define PSI_NT_WAIT_FOREVER 0xffffffffu
#endif

#ifndef PSI_ENABLE_MCP
#define PSI_ENABLE_MCP 0
#endif

static const size_t PSI_PROCESS_OUTPUT_MAX_BYTES = 262144u;
static const int PSI_PROCESS_ABORT_EXIT_STATUS = 130;
static const int PSI_PROCESS_ABORT_WAIT_LIMIT_MS = 1500;
static const int PSI_PROCESS_ABORT_ESCALATE_MS = 500;
#define PSI_PROCESS_MS_TO_NS 1000000L

/* Per-iteration read() size when draining the child's stdout/stderr.
 * Also the per-chunk quantum fed to the progress callback.
 * #define so it's usable as an array dimension in C89. */
#define PSI_PROCESS_READ_CHUNK 4096

/* Fallback poll interval used by psi_process_poll when the caller
 * passes a longer timeout — we wake up at most every 20 ms so the
 * abort signal stays responsive. */
#define PSI_PROCESS_POLL_DELAY_MS 20
#define PSI_PROCESS_POLL_DELAY_NS ((long)PSI_PROCESS_POLL_DELAY_MS * PSI_PROCESS_MS_TO_NS)

#if !defined(_WIN32) && defined(PSI_HAVE_COSMO_DCE)
static const uint32_t PSI_PROCESS_TASKKILL_TIMEOUT_MS = 5000u;
static const uint32_t PSI_PROCESS_CREATE_FAILURE_EXIT_STATUS = 1u;
static const int64_t PSI_NT_INVALID_HANDLE = -1;
static const int PSI_NT_INHERIT_HANDLES = 1;
static const int PSI_NT_NO_INHERIT_HANDLES = 0;
static const uint32_t PSI_UTF8_ASCII_LIMIT = 0x80u;
static const uint32_t PSI_UTF8_CONT_MASK = 0xc0u;
static const uint32_t PSI_UTF8_CONT_TAG = 0x80u;
static const uint32_t PSI_UTF8_TWO_MASK = 0xe0u;
static const uint32_t PSI_UTF8_TWO_TAG = 0xc0u;
static const uint32_t PSI_UTF8_TWO_MIN = 0x80u;
static const uint32_t PSI_UTF8_THREE_MASK = 0xf0u;
static const uint32_t PSI_UTF8_THREE_TAG = 0xe0u;
static const uint32_t PSI_UTF8_THREE_MIN = 0x800u;
static const uint32_t PSI_UTF8_FOUR_MASK = 0xf8u;
static const uint32_t PSI_UTF8_FOUR_TAG = 0xf0u;
static const uint32_t PSI_UTF16_BMP_LIMIT = 0xffffu;
static const uint32_t PSI_UTF16_SURROGATE_BASE = 0x10000u;
static const uint32_t PSI_UTF16_SURROGATE_MAX = 0x10ffffu;
static const uint32_t PSI_UTF16_HIGH_SURROGATE_MIN = 0xd800u;
static const uint32_t PSI_UTF16_LOW_SURROGATE_MIN = 0xdc00u;
static const uint32_t PSI_UTF16_LOW_SURROGATE_MAX = 0xdfffu;
static const uint32_t PSI_UTF16_SURROGATE_MASK = 0x3ffu;
static const int PSI_UTF16_SURROGATE_SHIFT = 10;
static const uint32_t PSI_UNICODE_REPLACEMENT = 0xfffdu;
static const uint32_t PSI_UTF8_PAYLOAD_ONE = 0x3fu;
static const uint32_t PSI_UTF8_PAYLOAD_TWO = 0x1fu;
static const uint32_t PSI_UTF8_PAYLOAD_THREE = 0x0fu;
static const uint32_t PSI_UTF8_PAYLOAD_FOUR = 0x07u;
#endif

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

    next_buffer = (char *)malloc(next_capacity);
    if (next_buffer == NULL) {
        return PSI_STATUS_ERROR;
    }

    if (*buffer != NULL && *length > 0u)
        memcpy(next_buffer, *buffer, *length);
    free(*buffer);
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

#ifdef PSI_HAVE_COSMO_DCE
static int psi_process_host_windows(void) {
    if ((__hostos & PSI_COSMO_HOST_WINDOWS) != 0)
        return 1;
    return 0;
}
#endif

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
#ifdef PSI_HAVE_COSMO_DCE
    int nt_child;
    int64_t nt_process;
    int64_t nt_thread;
    int64_t nt_stdout;
    uint32_t nt_pid;
#endif
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

#ifdef PSI_HAVE_COSMO_DCE
static int psi_process_ascii_equal_ci(const char *a, const char *b) {
    unsigned char ca;
    unsigned char cb;

    if (a == NULL || b == NULL)
        return 0;
    while (*a != '\0' && *b != '\0') {
        ca = (unsigned char)*a;
        cb = (unsigned char)*b;
        if (ca >= (unsigned char)'A' && ca <= (unsigned char)'Z')
            ca = (unsigned char)(ca - (unsigned char)'A' + (unsigned char)'a');
        if (cb >= (unsigned char)'A' && cb <= (unsigned char)'Z')
            cb = (unsigned char)(cb - (unsigned char)'A' + (unsigned char)'a');
        if (ca != cb)
            return 0;
        a++;
        b++;
    }
    return *a == '\0' && *b == '\0';
}

static const char *psi_process_basename(const char *path) {
    const char *base;
    const char *p;

    if (path == NULL)
        return "";
    base = path;
    for (p = path; *p != '\0'; p++) {
        if (*p == '/' || *p == '\\')
            base = p + 1;
    }
    return base;
}

static int psi_process_is_cmd_exe(const char *path) {
    const char *base = psi_process_basename(path);
    return psi_process_ascii_equal_ci(base, "cmd.exe") || psi_process_ascii_equal_ci(base, "cmd");
}

static int psi_process_is_cmd_command_switch(const char *arg) {
    return psi_process_ascii_equal_ci(arg, "/c") || psi_process_ascii_equal_ci(arg, "/k");
}

static int psi_process_is_windows_abs_path(const char *path) {
    unsigned char drive;

    if (path == NULL || path[0] == '\0')
        return 0;
    drive = (unsigned char)path[0];
    if (((drive >= (unsigned char)'A' && drive <= (unsigned char)'Z') ||
            (drive >= (unsigned char)'a' && drive <= (unsigned char)'z')) &&
        path[1] == ':' && (path[2] == '\\' || path[2] == '/')) {
        return 1;
    }
    return (path[0] == '\\' || path[0] == '/') && (path[1] == '\\' || path[1] == '/') &&
        path[2] != '\0';
}

static char *psi_process_copy_unquoted_path(const char *path) {
    size_t len;

    if (path == NULL || path[0] == '\0')
        return NULL;
    len = strlen(path);
    if (len >= 2u && path[0] == '"' && path[len - 1u] == '"')
        return psi_strdup_n(path + 1, len - 2u);
    return psi_strdup(path);
}

static char *psi_process_join_system_cmd(const char *root) {
    static const char suffix[] = "\\System32\\cmd.exe";
    size_t len;
    size_t root_len;
    char *out;

    if (!psi_process_is_windows_abs_path(root))
        return NULL;
    root_len = strlen(root);
    while (root_len > 0u && (root[root_len - 1u] == '\\' || root[root_len - 1u] == '/'))
        root_len--;
    len = root_len + sizeof(suffix);
    out = (char *)malloc(len);
    if (out == NULL)
        return NULL;
    memcpy(out, root, root_len);
    memcpy(out + root_len, suffix, sizeof(suffix));
    return out;
}

static char *psi_process_resolve_windows_cmd_path(void) {
    char *candidate;
    const char *env;

    candidate = psi_process_copy_unquoted_path(getenv("ComSpec"));
    if (candidate != NULL && psi_process_is_windows_abs_path(candidate) &&
        psi_process_is_cmd_exe(candidate)) {
        return candidate;
    }
    free(candidate);

    env = getenv("SystemRoot");
    candidate = psi_process_join_system_cmd(env);
    if (candidate != NULL)
        return candidate;

    return psi_strdup("C:\\Windows\\System32\\cmd.exe");
}

static int psi_process_cmd_tail_index(char *const argv[]) {
    int i;

    if (!psi_process_host_windows() || argv == NULL || !psi_process_is_cmd_exe(argv[0]))
        return -1;

    for (i = 1; argv[i] != NULL; i++) {
        if (psi_process_is_cmd_command_switch(argv[i]) && argv[i + 1] != NULL)
            return i + 1;
    }
    return -1;
}

struct psi_process_strbuf {
    char *data;
    size_t length;
    size_t capacity;
};

static int psi_process_strbuf_append(struct psi_process_strbuf *b, const char *s, size_t len) {
    return psi_process_append_bytes(&b->data, &b->length, &b->capacity, s, len);
}

static int psi_process_strbuf_append_char(struct psi_process_strbuf *b, char c) {
    return psi_process_strbuf_append(b, &c, 1u);
}

static int psi_process_windows_arg_needs_quotes(const char *arg) {
    const unsigned char *p;

    if (arg == NULL || *arg == '\0')
        return 1;
    for (p = (const unsigned char *)arg; *p != '\0'; p++) {
        if (*p <= (unsigned char)' ' || *p == (unsigned char)'"')
            return 1;
    }
    return 0;
}

static int psi_process_windows_append_quoted_arg(struct psi_process_strbuf *b, const char *arg) {
    size_t backslashes;
    const char *p;

    if (!psi_process_windows_arg_needs_quotes(arg))
        return psi_process_strbuf_append(b, arg, strlen(arg));

    if (psi_process_strbuf_append_char(b, '"') != PSI_STATUS_OK)
        return PSI_STATUS_ERROR;

    backslashes = 0u;
    for (p = arg; *p != '\0'; p++) {
        if (*p == '\\') {
            backslashes++;
            continue;
        }
        if (*p == '"') {
            while (backslashes > 0u) {
                if (psi_process_strbuf_append(b, "\\\\", 2u) != PSI_STATUS_OK)
                    return PSI_STATUS_ERROR;
                backslashes--;
            }
            if (psi_process_strbuf_append(b, "\\\"", 2u) != PSI_STATUS_OK)
                return PSI_STATUS_ERROR;
            continue;
        }
        while (backslashes > 0u) {
            if (psi_process_strbuf_append_char(b, '\\') != PSI_STATUS_OK)
                return PSI_STATUS_ERROR;
            backslashes--;
        }
        if (psi_process_strbuf_append_char(b, *p) != PSI_STATUS_OK)
            return PSI_STATUS_ERROR;
    }

    while (backslashes > 0u) {
        if (psi_process_strbuf_append(b, "\\\\", 2u) != PSI_STATUS_OK)
            return PSI_STATUS_ERROR;
        backslashes--;
    }

    return psi_process_strbuf_append_char(b, '"');
}

static int psi_process_windows_build_cmdline(
    char *const argv[], int raw_tail_index, const char *argv0_override, char **out_cmdline) {
    struct psi_process_strbuf b;
    const char *arg;
    int i;

    if (out_cmdline != NULL)
        *out_cmdline = NULL;
    if (argv == NULL || argv[0] == NULL || out_cmdline == NULL)
        return PSI_STATUS_ERROR;

    memset(&b, 0, sizeof(b));
    for (i = 0; argv[i] != NULL; i++) {
        arg = (i == 0 && argv0_override != NULL) ? argv0_override : argv[i];
        if (i > 0 && psi_process_strbuf_append_char(&b, ' ') != PSI_STATUS_OK)
            goto error;
        if (raw_tail_index >= 0 && i >= raw_tail_index) {
            if (psi_process_strbuf_append(&b, arg, strlen(arg)) != PSI_STATUS_OK)
                goto error;
        } else if (psi_process_windows_append_quoted_arg(&b, arg) != PSI_STATUS_OK) {
            goto error;
        }
    }

    if (b.data == NULL && psi_process_strbuf_append_char(&b, '\0') != PSI_STATUS_OK)
        goto error;
    *out_cmdline = b.data;
    return PSI_STATUS_OK;

error:
    free(b.data);
    return PSI_STATUS_ERROR;
}

static int psi_process_utf8_continuation(unsigned char c) {
    return ((uint32_t)c & PSI_UTF8_CONT_MASK) == PSI_UTF8_CONT_TAG;
}

/* CreateProcess takes mutable UTF-16 command strings. Decode just enough
 * UTF-8 here to feed that API, replacing malformed or overlong sequences
 * with U+FFFD so a bad byte in tool text does not block process spawning. */
static char16_t *psi_process_utf8_to_utf16(const char *s) {
    size_t len;
    size_t i = 0u;
    size_t j = 0u;
    char16_t *out;

    if (s == NULL)
        return NULL;
    len = strlen(s);
    out = (char16_t *)malloc((len + 1u) * sizeof(*out));
    if (out == NULL)
        return NULL;

    while (i < len) {
        uint32_t cp;
        unsigned char c = (unsigned char)s[i++];

        if ((uint32_t)c < PSI_UTF8_ASCII_LIMIT) {
            cp = c;
        } else if (((uint32_t)c & PSI_UTF8_TWO_MASK) == PSI_UTF8_TWO_TAG && i < len &&
            psi_process_utf8_continuation((unsigned char)s[i])) {
            cp = ((uint32_t)(c & PSI_UTF8_PAYLOAD_TWO) << 6) |
                (uint32_t)((unsigned char)s[i++] & PSI_UTF8_PAYLOAD_ONE);
            if (cp < PSI_UTF8_TWO_MIN)
                cp = PSI_UNICODE_REPLACEMENT;
        } else if (((uint32_t)c & PSI_UTF8_THREE_MASK) == PSI_UTF8_THREE_TAG && i + 1u < len &&
            psi_process_utf8_continuation((unsigned char)s[i]) &&
            psi_process_utf8_continuation((unsigned char)s[i + 1u])) {
            cp = ((uint32_t)(c & PSI_UTF8_PAYLOAD_THREE) << 12) |
                ((uint32_t)((unsigned char)s[i] & PSI_UTF8_PAYLOAD_ONE) << 6) |
                (uint32_t)((unsigned char)s[i + 1u] & PSI_UTF8_PAYLOAD_ONE);
            i += 2u;
            if (cp < PSI_UTF8_THREE_MIN ||
                (cp >= PSI_UTF16_HIGH_SURROGATE_MIN && cp <= PSI_UTF16_LOW_SURROGATE_MAX))
                cp = PSI_UNICODE_REPLACEMENT;
        } else if (((uint32_t)c & PSI_UTF8_FOUR_MASK) == PSI_UTF8_FOUR_TAG && i + 2u < len &&
            psi_process_utf8_continuation((unsigned char)s[i]) &&
            psi_process_utf8_continuation((unsigned char)s[i + 1u]) &&
            psi_process_utf8_continuation((unsigned char)s[i + 2u])) {
            cp = ((uint32_t)(c & PSI_UTF8_PAYLOAD_FOUR) << 18) |
                ((uint32_t)((unsigned char)s[i] & PSI_UTF8_PAYLOAD_ONE) << 12) |
                ((uint32_t)((unsigned char)s[i + 1u] & PSI_UTF8_PAYLOAD_ONE) << 6) |
                (uint32_t)((unsigned char)s[i + 2u] & PSI_UTF8_PAYLOAD_ONE);
            i += 3u;
            if (cp < PSI_UTF16_SURROGATE_BASE || cp > PSI_UTF16_SURROGATE_MAX)
                cp = PSI_UNICODE_REPLACEMENT;
        } else {
            cp = PSI_UNICODE_REPLACEMENT;
        }

        if (cp <= PSI_UTF16_BMP_LIMIT) {
            out[j++] = (char16_t)cp;
        } else {
            cp -= PSI_UTF16_SURROGATE_BASE;
            out[j++] = (char16_t)(PSI_UTF16_HIGH_SURROGATE_MIN + (cp >> PSI_UTF16_SURROGATE_SHIFT));
            out[j++] = (char16_t)(PSI_UTF16_LOW_SURROGATE_MIN + (cp & PSI_UTF16_SURROGATE_MASK));
        }
    }
    out[j] = 0;
    return out;
}

static int psi_process_windows_taskkill_tree(uint32_t pid) {
    struct NtStartupInfo si;
    struct NtProcessInformation pi;
    char *cmd_path;
    char *cmdline_utf8;
    char16_t *application_utf16;
    char16_t *cmdline_utf16;
    char pidbuf[32];
    char tail[96];
    char *argv[5];
    uint32_t exit_code;
    int ok;

    if (pid == 0u)
        return PSI_STATUS_ERROR;

    snprintf(pidbuf, sizeof(pidbuf), "%lu", (unsigned long)pid);
    snprintf(tail, sizeof(tail), "taskkill /F /T /PID %s >NUL 2>NUL", pidbuf);

    cmd_path = psi_process_resolve_windows_cmd_path();
    if (cmd_path == NULL)
        return PSI_STATUS_ERROR;

    argv[0] = (char *)"cmd.exe";
    argv[1] = (char *)"/d";
    argv[2] = (char *)"/c";
    argv[3] = tail;
    argv[4] = NULL;

    application_utf16 = psi_process_utf8_to_utf16(cmd_path);
    cmdline_utf8 = NULL;
    cmdline_utf16 = NULL;
    if (application_utf16 == NULL ||
        psi_process_windows_build_cmdline(argv, 3, cmd_path, &cmdline_utf8) != PSI_STATUS_OK) {
        free(cmd_path);
        free(application_utf16);
        return PSI_STATUS_ERROR;
    }
    free(cmd_path);
    cmdline_utf16 = psi_process_utf8_to_utf16(cmdline_utf8);
    free(cmdline_utf8);
    if (cmdline_utf16 == NULL) {
        free(application_utf16);
        return PSI_STATUS_ERROR;
    }

    memset(&si, 0, sizeof(si));
    memset(&pi, 0, sizeof(pi));
    si.cb = sizeof(si);
    ok = CreateProcess(application_utf16, cmdline_utf16, NULL, NULL, PSI_NT_NO_INHERIT_HANDLES,
        kNtCreateNoWindow, NULL, NULL, &si, &pi);
    free(application_utf16);
    free(cmdline_utf16);
    if (!ok)
        return PSI_STATUS_ERROR;

    WaitForSingleObject(pi.hProcess, PSI_PROCESS_TASKKILL_TIMEOUT_MS);
    exit_code = PSI_PROCESS_CREATE_FAILURE_EXIT_STATUS;
    GetExitCodeProcess(pi.hProcess, &exit_code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return exit_code == 0u ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

static void psi_process_windows_terminate_tree(struct psi_process_handle *h, uint32_t code) {
    if (h == NULL)
        return;
    if (h->nt_pid != 0u && psi_process_windows_taskkill_tree(h->nt_pid) == PSI_STATUS_OK)
        return;
    TerminateProcess(h->nt_process, code);
}

static int psi_process_begin_windows_cmdline(char *const argv[], int raw_tail_index,
    const struct psi_abort_signal *abort_signal, struct psi_process_handle **out) {
    struct NtSecurityAttributes sa;
    struct NtStartupInfo si;
    struct NtProcessInformation pi;
    struct psi_process_handle *h;
    char *application_utf8 = NULL;
    char16_t *application_utf16 = NULL;
    char *cmdline_utf8 = NULL;
    char16_t *cmdline_utf16 = NULL;
    int64_t stdout_read = PSI_NT_INVALID_HANDLE;
    int64_t stdout_write = PSI_NT_INVALID_HANDLE;
    int64_t stdin_read = PSI_NT_INVALID_HANDLE;
    int64_t stdin_write = PSI_NT_INVALID_HANDLE;
    int ok;

    if (out == NULL)
        return PSI_STATUS_ERROR;
    *out = NULL;

    if (psi_process_is_cmd_exe(argv[0])) {
        application_utf8 = psi_process_resolve_windows_cmd_path();
    } else {
        application_utf8 = psi_strdup(argv[0]);
    }
    if (application_utf8 == NULL)
        return PSI_STATUS_ERROR;
    application_utf16 = psi_process_utf8_to_utf16(application_utf8);
    if (application_utf16 == NULL)
        goto error;

    if (psi_process_windows_build_cmdline(argv, raw_tail_index, application_utf8, &cmdline_utf8) !=
        PSI_STATUS_OK) {
        goto error;
    }
    cmdline_utf16 = psi_process_utf8_to_utf16(cmdline_utf8);
    free(cmdline_utf8);
    if (cmdline_utf16 == NULL)
        goto error;

    memset(&sa, 0, sizeof(sa));
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = PSI_NT_INHERIT_HANDLES;
    if (!CreatePipe(&stdout_read, &stdout_write, &sa, 0) ||
        !SetHandleInformation(stdout_read, kNtHandleFlagInherit, 0) ||
        !CreatePipe(&stdin_read, &stdin_write, &sa, 0) ||
        !SetHandleInformation(stdin_write, kNtHandleFlagInherit, 0)) {
        goto error;
    }

    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = kNtStartfUsestdhandles;
    si.hStdInput = stdin_read;
    si.hStdOutput = stdout_write;
    si.hStdError = stdout_write;
    memset(&pi, 0, sizeof(pi));

    ok = CreateProcess(application_utf16, cmdline_utf16, NULL, NULL, PSI_NT_INHERIT_HANDLES,
        kNtCreateNoWindow | kNtCreateNewProcessGroup, NULL, NULL, &si, &pi);
    free(application_utf8);
    application_utf8 = NULL;
    free(application_utf16);
    application_utf16 = NULL;
    free(cmdline_utf16);
    cmdline_utf16 = NULL;
    if (!ok)
        goto error;

    CloseHandle(stdout_write);
    CloseHandle(stdin_read);
    CloseHandle(stdin_write);

    h = (struct psi_process_handle *)calloc(1u, sizeof(*h));
    if (h == NULL) {
        TerminateProcess(pi.hProcess, PSI_PROCESS_CREATE_FAILURE_EXIT_STATUS);
        CloseHandle(stdout_read);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return PSI_STATUS_ERROR;
    }
    h->child_pid = -1;
    h->pipe_fd = -1;
    h->stdin_fd = -1;
    h->abort_signal = abort_signal;
    h->nt_child = 1;
    h->nt_process = pi.hProcess;
    h->nt_thread = pi.hThread;
    h->nt_stdout = stdout_read;
    h->nt_pid = pi.dwProcessId;
    *out = h;
    return PSI_STATUS_OK;

error:
    free(application_utf8);
    free(application_utf16);
    free(cmdline_utf16);
    if (stdout_read != PSI_NT_INVALID_HANDLE)
        CloseHandle(stdout_read);
    if (stdout_write != PSI_NT_INVALID_HANDLE)
        CloseHandle(stdout_write);
    if (stdin_read != PSI_NT_INVALID_HANDLE)
        CloseHandle(stdin_read);
    if (stdin_write != PSI_NT_INVALID_HANDLE)
        CloseHandle(stdin_write);
    return PSI_STATUS_ERROR;
}
#endif

int psi_process_begin_argv(char *const argv[], const struct psi_abort_signal *abort_signal,
    struct psi_process_handle **out) {
#ifdef PSI_HAVE_COSMO_DCE
    int cmd_tail_index;

    cmd_tail_index = psi_process_cmd_tail_index(argv);
    if (cmd_tail_index >= 0)
        return psi_process_begin_windows_cmdline(argv, cmd_tail_index, abort_signal, out);
#endif
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
    char *argv[5];

    if (command == NULL || out == NULL)
        return PSI_STATUS_ERROR;
#ifdef PSI_HAVE_COSMO_DCE
    if (psi_process_host_windows()) {
        argv[0] = (char *)"cmd.exe";
        argv[1] = (char *)"/d";
        argv[2] = (char *)"/c";
        argv[3] = (char *)command;
        argv[4] = NULL;
        return psi_process_begin_argv(argv, abort_signal, out);
    }
#endif

    argv[0] = (char *)"sh";
    argv[1] = (char *)"-lc";
    argv[2] = (char *)command;
    argv[3] = NULL;
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
#ifdef PSI_HAVE_COSMO_DCE
    if (h->nt_child) {
        if (!h->reaped) {
            h->aborted = 1;
            psi_process_windows_terminate_tree(h, (uint32_t)PSI_PROCESS_ABORT_EXIT_STATUS);
        }
        return PSI_STATUS_OK;
    }
#endif
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

static int psi_process_try_reap(struct psi_process_handle *h) {
    pid_t r;

    if (h == NULL)
        return 0;
    if (h->reaped)
        return 1;

    r = waitpid(h->child_pid, &h->wait_status, WNOHANG);
    if (r == h->child_pid) {
        h->reaped = 1;
        return 1;
    }
    if (r < 0) {
        h->reaped = 1;
        return 1;
    }
    return 0;
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

#ifdef PSI_HAVE_COSMO_DCE
    if (h->nt_child) {
        uint32_t available;
        uint32_t bytes_read;
        uint32_t wait_result;
        long step_ms;

        if (psi_abort_signal_is_triggered(h->abort_signal) && !h->aborted) {
            h->aborted = 1;
            psi_process_windows_terminate_tree(h, (uint32_t)PSI_PROCESS_ABORT_EXIT_STATUS);
        }

        total_waited_ns = 0L;
        max_wait_ns = (timeout_ms > 0) ? (long)timeout_ms * PSI_PROCESS_MS_TO_NS : 0L;

        for (;;) {
            available = 0u;
            if (!PeekNamedPipe(h->nt_stdout, NULL, 0, NULL, &available, NULL)) {
                h->eof_seen = 1;
                return 2;
            }
            if (available > 0u) {
                char *copy;
                size_t read_size;
                uint32_t want;

                want = available > sizeof(read_buffer) ? (uint32_t)sizeof(read_buffer) : available;
                bytes_read = 0u;
                if (!ReadFile(h->nt_stdout, read_buffer, want, &bytes_read, NULL) ||
                    bytes_read == 0u) {
                    h->eof_seen = 1;
                    return 2;
                }
                read_size = (size_t)bytes_read;
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
                if (h->output_length < PSI_PROCESS_OUTPUT_MAX_BYTES) {
                    size_t to_copy;
                    to_copy = read_size;
                    if (h->output_length + to_copy > PSI_PROCESS_OUTPUT_MAX_BYTES) {
                        h->truncated = 1;
                        to_copy = PSI_PROCESS_OUTPUT_MAX_BYTES - h->output_length;
                    }
                    (void)psi_process_append_bytes(&h->output_buffer, &h->output_length,
                        &h->output_capacity, read_buffer, to_copy);
                } else {
                    h->truncated = 1;
                }
                return 1;
            }

            wait_result = WaitForSingleObject(h->nt_process, PSI_NT_WAIT_NONBLOCKING);
            if (wait_result != kNtWaitTimeout) {
                h->eof_seen = 1;
                return 2;
            }
            if (h->aborted) {
                h->eof_seen = 1;
                return 2;
            }
            if (timeout_ms <= 0)
                return 0;

            step_ms = PSI_PROCESS_POLL_DELAY_NS / PSI_PROCESS_MS_TO_NS;
            if ((max_wait_ns - total_waited_ns) / PSI_PROCESS_MS_TO_NS < step_ms)
                step_ms = (max_wait_ns - total_waited_ns) / PSI_PROCESS_MS_TO_NS;
            if (step_ms <= 0L)
                return 0;
            WaitForSingleObject(h->nt_process, (uint32_t)step_ms);
            total_waited_ns += step_ms * PSI_PROCESS_MS_TO_NS;

            if (psi_abort_signal_is_triggered(h->abort_signal) && !h->aborted) {
                h->aborted = 1;
                psi_process_windows_terminate_tree(h, (uint32_t)PSI_PROCESS_ABORT_EXIT_STATUS);
            }
        }
    }
#endif

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
    max_wait_ns = (timeout_ms > 0) ? (long)timeout_ms * PSI_PROCESS_MS_TO_NS : 0L;

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

            if (psi_process_try_reap(h)) {
                h->eof_seen = 1;
                return 2;
            }
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

#ifdef PSI_HAVE_COSMO_DCE
    if (h->nt_child) {
        uint32_t code;
        char *chunk;
        size_t chunk_len;

        chunk = NULL;
        chunk_len = 0u;
        while (psi_process_poll(h, 0, &chunk, &chunk_len) == 1) {
            free(chunk);
            chunk = NULL;
        }
        if (!h->reaped) {
            WaitForSingleObject(h->nt_process, PSI_NT_WAIT_FOREVER);
            h->reaped = 1;
        }
        while (psi_process_poll(h, 0, &chunk, &chunk_len) == 1) {
            free(chunk);
            chunk = NULL;
        }
        if (h->nt_stdout != -1) {
            CloseHandle(h->nt_stdout);
            h->nt_stdout = -1;
        }
        if (exit_status != NULL) {
            code = PSI_NT_WAIT_FOREVER;
            if (h->aborted) {
                *exit_status = PSI_PROCESS_ABORT_EXIT_STATUS;
            } else if (GetExitCodeProcess(h->nt_process, &code)) {
                *exit_status = (int)(int32_t)code;
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
                    if (h->nt_thread != -1)
                        CloseHandle(h->nt_thread);
                    if (h->nt_process != -1)
                        CloseHandle(h->nt_process);
                    free(h);
                    return PSI_STATUS_ERROR;
                }
            } else {
                *output_text = h->output_buffer;
                h->output_buffer = NULL;
            }
        } else {
            free(h->output_buffer);
        }
        if (h->nt_thread != -1)
            CloseHandle(h->nt_thread);
        if (h->nt_process != -1)
            CloseHandle(h->nt_process);
        free(h);
        return PSI_STATUS_OK;
    }
#endif

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
            for (waited_ms = 0; waited_ms < PSI_PROCESS_ABORT_WAIT_LIMIT_MS;
                waited_ms += PSI_PROCESS_POLL_DELAY_MS) {
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
                if (!sigkilled && waited_ms >= PSI_PROCESS_ABORT_ESCALATE_MS) {
                    kill(-h->child_pid, SIGKILL);
                    sigkilled = 1;
                }
                delay.tv_sec = 0;
                delay.tv_nsec = PSI_PROCESS_POLL_DELAY_NS;
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
            *exit_status = PSI_PROCESS_ABORT_EXIT_STATUS;
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
