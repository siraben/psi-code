/* TUI mode entrypoint: switches the terminal into raw ANSI mode,
 * installs SIGWINCH/SIGTSTP handlers, and delegates the actual UI
 * loop to lua/psi/tui_runtime.lua. C only owns the terminal boundary;
 * Lua decides what gets drawn. */

#include <locale.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
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

#define PSI_TUI_ENABLE_MOUSE "\033[?1000h\033[?1006h"
#define PSI_TUI_DISABLE_MOUSE "\033[?1006l\033[?1000l"
#define PSI_TUI_ENTER_SEQ "\033[?1049h" PSI_TUI_ENABLE_MOUSE "\033[?25h\033[2J\033[H"
#define PSI_TUI_LEAVE_SEQ PSI_TUI_DISABLE_MOUSE "\033[?2026l\033[0m\033[?25h\033[?1049l"

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
    fputs(PSI_TUI_ENTER_SEQ, stdout);
    fflush(stdout);
    return PSI_STATUS_OK;
}

static void psi_tui_leave_terminal(void) {
    fputs(PSI_TUI_LEAVE_SEQ, stdout);
    fflush(stdout);
    if (psi_tui_has_original_termios) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &psi_tui_original_termios);
    }
}

void psi_tui_suspend_terminal(void) {
    if (psi_tui_has_original_termios) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &psi_tui_original_termios);
    }
    fputs(PSI_TUI_LEAVE_SEQ, stdout);
    fflush(stdout);
}

void psi_tui_resume_terminal(void) {
    struct termios raw_attrs;

    if (!psi_tui_has_original_termios) {
        return;
    }
    raw_attrs = psi_tui_original_termios;
    psi_tui_apply_raw_mode(&raw_attrs);
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw_attrs);
    fputs(PSI_TUI_ENTER_SEQ, stdout);
    fflush(stdout);
}

static void psi_tui_atexit_restore(void) {
    if (psi_tui_has_original_termios) {
        psi_tui_leave_terminal();
        psi_tui_has_original_termios = 0;
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
    status = psi_vm_init(&vm, options->boot_file, stdin, stdout, stderr);
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

    psi_vm_set_tui_active(&vm, 1);
    status = psi_vm_run_lua_mode(&vm, "tui", options);
    psi_vm_set_tui_active(&vm, 0);

    psi_tui_leave_terminal();
    psi_tui_has_original_termios = 0;
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
