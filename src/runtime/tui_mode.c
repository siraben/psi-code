#include <locale.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <termios.h>
#include <unistd.h>
#include <lua.h>
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

static int psi_tui_enter_terminal(void) {
    struct termios raw_attrs;

    if (tcgetattr(STDIN_FILENO, &psi_tui_original_termios) != 0) {
        perror("tcgetattr");
        return PSI_STATUS_ERROR;
    }
    psi_tui_has_original_termios = 1;
    raw_attrs = psi_tui_original_termios;
    raw_attrs.c_iflag &= (tcflag_t) ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    raw_attrs.c_oflag &= (tcflag_t) ~(OPOST);
    raw_attrs.c_cflag |= (tcflag_t)CS8;
    raw_attrs.c_lflag &= (tcflag_t) ~(ECHO | ICANON | IEXTEN | ISIG);
    raw_attrs.c_cc[VMIN] = 0;
    raw_attrs.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw_attrs) != 0) {
        perror("tcsetattr");
        return PSI_STATUS_ERROR;
    }
    fputs("\033[?1049h" PSI_TUI_ENABLE_MOUSE "\033[?25h\033[2J\033[H", stdout);
    fflush(stdout);
    return PSI_STATUS_OK;
}

static void psi_tui_leave_terminal(void) {
    fputs(PSI_TUI_DISABLE_MOUSE "\033[?2026l\033[0m\033[?25h\033[?1049l", stdout);
    fflush(stdout);
    if (psi_tui_has_original_termios) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &psi_tui_original_termios);
    }
}

void psi_tui_suspend_terminal(void) {
    if (psi_tui_has_original_termios) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &psi_tui_original_termios);
    }
    fputs(PSI_TUI_DISABLE_MOUSE "\033[?2026l\033[0m\033[?25h\033[?1049l", stdout);
    fflush(stdout);
}

void psi_tui_resume_terminal(void) {
    struct termios raw_attrs;

    if (!psi_tui_has_original_termios) {
        return;
    }
    raw_attrs = psi_tui_original_termios;
    raw_attrs.c_iflag &= (tcflag_t) ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    raw_attrs.c_oflag &= (tcflag_t) ~(OPOST);
    raw_attrs.c_cflag |= (tcflag_t)CS8;
    raw_attrs.c_lflag &= (tcflag_t) ~(ECHO | ICANON | IEXTEN | ISIG);
    raw_attrs.c_cc[VMIN] = 0;
    raw_attrs.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw_attrs);
    fputs("\033[?1049h" PSI_TUI_ENABLE_MOUSE "\033[?25h\033[2J\033[H", stdout);
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

static int psi_tui_run_lua(struct psi_vm *vm, const struct psi_cli_options *options) {
    int ok;

    lua_getglobal(vm->L, "psi");
    lua_getfield(vm->L, -1, "modes");
    lua_getfield(vm->L, -1, "run");
    lua_remove(vm->L, -2);
    lua_remove(vm->L, -2);
    if (lua_type(vm->L, -1) != LUA_TFUNCTION) {
        fprintf(stderr, "psi.modes.run is not a function\n");
        lua_pop(vm->L, 1);
        return PSI_STATUS_ERROR;
    }

    lua_newtable(vm->L);
    lua_pushstring(vm->L, "tui");
    lua_setfield(vm->L, -2, "mode");
    if (options->payload != NULL) {
        lua_pushstring(vm->L, options->payload);
        lua_setfield(vm->L, -2, "payload");
    }
    if (options->session_file != NULL) {
        lua_pushstring(vm->L, options->session_file);
        lua_setfield(vm->L, -2, "session_file");
    }
    if (options->model != NULL) {
        lua_pushstring(vm->L, options->model);
        lua_setfield(vm->L, -2, "model");
    }
    if (options->thinking_level != NULL) {
        lua_pushstring(vm->L, options->thinking_level);
        lua_setfield(vm->L, -2, "thinking_level");
    }
    lua_pushinteger(vm->L, (lua_Integer)options->max_tokens);
    lua_setfield(vm->L, -2, "max_tokens");
    lua_pushinteger(vm->L, (lua_Integer)options->keep_recent);
    lua_setfield(vm->L, -2, "keep_recent");

    if (lua_pcall(vm->L, 1, 1, 0) != LUA_OK) {
        fprintf(stderr, "psi.modes.run error: %s\n", lua_tostring(vm->L, -1));
        lua_pop(vm->L, 1);
        return PSI_STATUS_ERROR;
    }

    ok = lua_toboolean(vm->L, -1);
    lua_pop(vm->L, 1);
    return ok ? PSI_STATUS_OK : PSI_STATUS_ERROR;
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

    setlocale(LC_ALL, "");
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
    status = psi_tui_run_lua(&vm, options);
    psi_vm_set_tui_active(&vm, 0);

    psi_tui_leave_terminal();
    psi_tui_has_original_termios = 0;
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
