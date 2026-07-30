/* TUI mode entrypoint: switches the terminal into raw ANSI mode,
 * installs SIGWINCH/SIGTSTP handlers, and delegates the actual UI
 * loop to lua/psi/tui_runtime.lua. C only owns the terminal boundary;
 * Lua decides what gets drawn. */

#include <locale.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>
#include "psi/abort.h"
#include "psi/runtime.h"
#include "psi/session.h"
#include "psi/vm.h"

#ifndef PSI_ENABLE_TUI
#define PSI_ENABLE_TUI 0
#endif
#ifndef PSI_ENABLE_COLOR
#define PSI_ENABLE_COLOR 0
#endif

#if PSI_ENABLE_TUI

static struct termios psi_tui_original_termios;
static int psi_tui_has_original_termios = 0;
static int psi_tui_alt_screen_active = 0;
static int psi_tui_terminal_fd = -1;

struct psi_tui_stdio_guard {
    int active;
    int stdout_saved;
    int stderr_saved;
    int log_fd;
};

static struct psi_tui_stdio_guard psi_tui_guard = {0, -1, -1, -1};

#define PSI_TUI_ENABLE_MOUSE "\033[?1000h\033[?1006h"
#define PSI_TUI_DISABLE_MOUSE "\033[?1006l\033[?1000l"
#define PSI_TUI_ENTER_SEQ "\033[?1049h" PSI_TUI_ENABLE_MOUSE "\033[?25h\033[2J\033[H"
#define PSI_TUI_LEAVE_SEQ PSI_TUI_DISABLE_MOUSE "\033[?2026l\033[0m\033[?25h\033[?1049l"
#define PSI_TUI_LEAVE_INLINE_SEQ "\033[?2026l\033[0m\033[?25h"

static void psi_tui_close_on_exec(int fd) {
    int flags;

    if (fd < 0) {
        return;
    }
    flags = fcntl(fd, F_GETFD);
    if (flags >= 0) {
        fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
    }
}

void psi_tui_write_terminal(const char *text, size_t length) {
    size_t offset;

    if (text == NULL || length == 0u || psi_tui_terminal_fd < 0) {
        return;
    }
    offset = 0u;
    while (offset < length) {
        ssize_t written = write(psi_tui_terminal_fd, text + offset, length - offset);
        if (written > 0) {
            offset += (size_t)written;
        } else if (written < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
}

static int psi_tui_mkdirs(const char *path) {
    char copy[4096];
    char *cursor;

    if (path == NULL || path[0] == '\0' || strlen(path) >= sizeof(copy)) {
        return PSI_STATUS_ERROR;
    }
    memcpy(copy, path, strlen(path) + 1u);
    cursor = copy + (copy[0] == '/' ? 1 : 0);
    for (; *cursor != '\0'; cursor++) {
        if (*cursor == '/') {
            *cursor = '\0';
            if (copy[0] != '\0' && mkdir(copy, 0700) != 0 && errno != EEXIST) {
                return PSI_STATUS_ERROR;
            }
            *cursor = '/';
        }
    }
    if (mkdir(copy, 0700) != 0 && errno != EEXIST) {
        return PSI_STATUS_ERROR;
    }
    return PSI_STATUS_OK;
}

static int psi_tui_open_debug_log(void) {
    const char *xdg = getenv("XDG_STATE_HOME");
    const char *home = getenv("HOME");
    char directory[4096];
    char path[4096];
    struct stat st;
    int flags;
    int fd;

    if (xdg != NULL && xdg[0] != '\0') {
        if (snprintf(directory, sizeof(directory), "%s/psi", xdg) >= (int)sizeof(directory)) {
            return -1;
        }
    } else if (home != NULL && home[0] != '\0') {
        if (snprintf(directory, sizeof(directory), "%s/.local/state/psi", home) >=
            (int)sizeof(directory)) {
            return -1;
        }
    } else {
        return -1;
    }
    if (psi_tui_mkdirs(directory) != PSI_STATUS_OK ||
        snprintf(path, sizeof(path), "%s/debug.log", directory) >= (int)sizeof(path)) {
        return -1;
    }
    flags = O_WRONLY | O_CREAT | O_APPEND | O_NONBLOCK;
#ifdef O_CLOEXEC
    flags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
    fd = open(path, flags, 0600);
    if (fd >= 0) {
        if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_nlink != 1 ||
            fchmod(fd, 0600) != 0) {
            close(fd);
            return -1;
        }
    }
    return fd;
}

static void psi_tui_stdio_guard_end(void);

/* The redirected standard descriptors deliberately remain open until the
 * matching guard_end call restores them. GCC's analyzer does not model that
 * cross-function lifetime and reports the dup2 targets as leaked. */
#if defined(__GNUC__) && !defined(__clang__) && __GNUC__ >= 13
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wanalyzer-fd-leak"
#endif
static int psi_tui_stdio_guard_begin(void) {
    int log_fd;

    if (psi_tui_guard.active) {
        return PSI_STATUS_OK;
    }
    fflush(stdout);
    fflush(stderr);
    log_fd = psi_tui_open_debug_log();
    if (log_fd < 0) {
        log_fd = open("/dev/null", O_WRONLY);
    }
    if (log_fd < 0) {
        return PSI_STATUS_ERROR;
    }
    psi_tui_guard.stdout_saved = dup(STDOUT_FILENO);
    psi_tui_guard.stderr_saved = dup(STDERR_FILENO);
    psi_tui_close_on_exec(psi_tui_guard.stdout_saved);
    psi_tui_close_on_exec(psi_tui_guard.stderr_saved);
    psi_tui_guard.log_fd = log_fd;
    if (psi_tui_guard.stdout_saved < 0 || psi_tui_guard.stderr_saved < 0 ||
        dup2(log_fd, STDOUT_FILENO) < 0 || dup2(log_fd, STDERR_FILENO) < 0) {
        psi_tui_stdio_guard_end();
        return PSI_STATUS_ERROR;
    }
    psi_tui_guard.active = 1;
    return PSI_STATUS_OK;
}
#if defined(__GNUC__) && !defined(__clang__) && __GNUC__ >= 13
#pragma GCC diagnostic pop
#endif

static void psi_tui_stdio_guard_end(void) {
    fflush(stdout);
    fflush(stderr);
    if (psi_tui_guard.stdout_saved >= 0) {
        dup2(psi_tui_guard.stdout_saved, STDOUT_FILENO);
        close(psi_tui_guard.stdout_saved);
    }
    if (psi_tui_guard.stderr_saved >= 0) {
        dup2(psi_tui_guard.stderr_saved, STDERR_FILENO);
        close(psi_tui_guard.stderr_saved);
    }
    if (psi_tui_guard.log_fd >= 0) {
        close(psi_tui_guard.log_fd);
    }
    psi_tui_guard.active = 0;
    psi_tui_guard.stdout_saved = -1;
    psi_tui_guard.stderr_saved = -1;
    psi_tui_guard.log_fd = -1;
}

/* Lua decides whether to enter alt-screen (frame mode) or stay in the
 * primary screen (chat mode). Suspend/resume and the atexit cleanup read
 * this flag so chat-mode sessions don't corrupt the user's scrollback by
 * emitting alt-screen leave when none was ever entered. */
void psi_tui_set_alt_screen_active(int active) {
    psi_tui_alt_screen_active = active ? 1 : 0;
}

static void psi_tui_apply_raw_mode(struct termios *attrs) {
    attrs->c_iflag &= (tcflag_t) ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    attrs->c_oflag &= (tcflag_t) ~(OPOST);
    attrs->c_cflag |= (tcflag_t)CS8;
    attrs->c_lflag &= (tcflag_t) ~(ECHO | ICANON | IEXTEN | ISIG);
    attrs->c_cc[VMIN] = 0;
    attrs->c_cc[VTIME] = 0;
}

static void psi_tui_fprint_shell_quoted(FILE *out, const char *text) {
    const char *p;

    fputc('\'', out);
    for (p = text != NULL ? text : ""; *p != '\0'; p++) {
        if (*p == '\'') {
            fputs("'\\''", out);
        } else {
            fputc(*p, out);
        }
    }
    fputc('\'', out);
}

static void psi_tui_print_resume_command(const struct psi_session *session) {
    if (session == NULL) {
        return;
    }
    if (session->id != NULL && session->id[0] != '\0') {
        fputs("\nResume with: psi --session ", stdout);
        psi_tui_fprint_shell_quoted(stdout, session->id);
        fputc('\n', stdout);
        fflush(stdout);
        return;
    }
    if (session->path != NULL && session->path[0] != '\0') {
        fputs("\nResume with: psi --session ", stdout);
        psi_tui_fprint_shell_quoted(stdout, session->path);
        fputc('\n', stdout);
        fflush(stdout);
    }
}

static int psi_tui_enter_terminal(void) {
    struct termios raw_attrs;

    if (tcgetattr(STDIN_FILENO, &psi_tui_original_termios) != 0) {
        perror("tcgetattr");
        return PSI_STATUS_ERROR;
    }
    psi_tui_has_original_termios = 1;
    raw_attrs = psi_tui_original_termios;
    psi_tui_apply_raw_mode(&raw_attrs);
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw_attrs) != 0) {
        perror("tcsetattr");
        return PSI_STATUS_ERROR;
    }
    return PSI_STATUS_OK;
}

static void psi_tui_leave_terminal(void) {
    if (psi_tui_alt_screen_active) {
        fputs(PSI_TUI_LEAVE_SEQ, stdout);
        psi_tui_alt_screen_active = 0;
    } else {
        fputs(PSI_TUI_LEAVE_INLINE_SEQ, stdout);
    }
    fflush(stdout);
    if (psi_tui_has_original_termios) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &psi_tui_original_termios);
    }
    psi_tui_alt_screen_active = 0;
}

int psi_tui_suspend_terminal(void) {
    psi_tui_stdio_guard_end();
    if (psi_tui_alt_screen_active) {
        fputs(PSI_TUI_LEAVE_SEQ, stdout);
    } else {
        fputs(PSI_TUI_LEAVE_INLINE_SEQ, stdout);
    }
    fflush(stdout);
    if (psi_tui_has_original_termios &&
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &psi_tui_original_termios) != 0) {
        return PSI_STATUS_ERROR;
    }
    return PSI_STATUS_OK;
}

int psi_tui_resume_terminal(void) {
    struct termios raw_attrs;

    if (!psi_tui_has_original_termios) {
        return PSI_STATUS_ERROR;
    }
    raw_attrs = psi_tui_original_termios;
    psi_tui_apply_raw_mode(&raw_attrs);
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw_attrs) != 0) {
        return PSI_STATUS_ERROR;
    }
    if (psi_tui_alt_screen_active) {
        fputs(PSI_TUI_ENTER_SEQ, stdout);
        fflush(stdout);
    }
    return psi_tui_stdio_guard_begin();
}

static void psi_tui_atexit_restore(void) {
    psi_tui_stdio_guard_end();
    if (psi_tui_has_original_termios) {
        psi_tui_leave_terminal();
        psi_tui_has_original_termios = 0;
    }
    if (psi_tui_terminal_fd >= 0) {
        close(psi_tui_terminal_fd);
        psi_tui_terminal_fd = -1;
    }
}

static int psi_tui_install_atexit(void) {
    static int installed = 0;

    if (!installed) {
        if (atexit(psi_tui_atexit_restore) != 0) {
            return PSI_STATUS_ERROR;
        }
        installed = 1;
    }
    return PSI_STATUS_OK;
}

int psi_run_tui_mode(const struct psi_cli_options *options) {
    struct psi_vm vm;
    struct psi_session session;
    struct psi_abort_signal abort_signal;
    int status;

    if (!isatty(fileno(stdin)) || !isatty(fileno(stdout))) {
        fprintf(stderr, "TUI mode requires a terminal\n");
        return PSI_STATUS_ERROR;
    }

    psi_session_init(&session);
    status = psi_vm_init(&vm, options->boot_file, stdin, stdout, stderr, options->load_extensions,
        1, options->trust_override);
    if (status != PSI_STATUS_OK) {
        psi_session_free(&session);
        return status;
    }
    psi_vm_bind_session(&vm, &session);
    psi_abort_signal_init(&abort_signal);
    vm.host.abort_signal = &abort_signal;

    /* Adopt user's LC_CTYPE so wcwidth/iconv-style terminal text handling
     * works, but keep LC_NUMERIC at "C" so cJSON / printf("%f") emit
     * locale-neutral decimals (a German LC_NUMERIC=de_DE produces "1,5"
     * which would corrupt JSON bodies sent to providers). */
    setlocale(LC_CTYPE, "");
    status = psi_tui_install_atexit();
    if (status != PSI_STATUS_OK) {
        psi_vm_destroy(&vm);
        psi_session_free(&session);
        return status;
    }
    status = psi_tui_enter_terminal();
    if (status != PSI_STATUS_OK) {
        psi_vm_destroy(&vm);
        psi_session_free(&session);
        return status;
    }
    psi_tui_terminal_fd = dup(STDOUT_FILENO);
    psi_tui_close_on_exec(psi_tui_terminal_fd);
    if (psi_tui_terminal_fd < 0 || psi_tui_stdio_guard_begin() != PSI_STATUS_OK) {
        psi_tui_stdio_guard_end();
        psi_tui_leave_terminal();
        psi_tui_has_original_termios = 0;
        if (psi_tui_terminal_fd >= 0) {
            close(psi_tui_terminal_fd);
            psi_tui_terminal_fd = -1;
        }
        psi_vm_destroy(&vm);
        psi_session_free(&session);
        fprintf(stderr, "failed to establish TUI terminal ownership\n");
        return PSI_STATUS_ERROR;
    }

    psi_vm_set_tui_active(&vm, 1);
    status = psi_vm_run_lua_mode(&vm, "tui", options);
    psi_vm_set_tui_active(&vm, 0);

    psi_tui_stdio_guard_end();
    psi_tui_leave_terminal();
    psi_tui_has_original_termios = 0;
    close(psi_tui_terminal_fd);
    psi_tui_terminal_fd = -1;
    psi_tui_print_resume_command(&session);
    psi_vm_destroy(&vm);
    psi_session_free(&session);
    return status;
}

#else

int psi_run_tui_mode(const struct psi_cli_options *options) {
    PSI_UNUSED(options);
    fprintf(stderr, "TUI mode is not compiled in\n");
    return PSI_STATUS_ERROR;
}

#endif
