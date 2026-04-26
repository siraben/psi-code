#include <locale.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <ncurses.h>
#include <lua.h>
#include "psi/abort.h"
#include "psi/runtime.h"
#include "psi/session.h"
#include "psi/vm.h"

static int psi_tui_init_colors(void) {
    if (!has_colors()) {
        return PSI_STATUS_OK;
    }
    start_color();
    use_default_colors();
    init_pair(1, COLOR_BLUE, -1);
    init_pair(2, COLOR_CYAN, -1);
    init_pair(3, COLOR_WHITE, -1);
    init_pair(4, COLOR_YELLOW, -1);
    init_pair(5, COLOR_GREEN, -1);
    init_pair(6, COLOR_RED, -1);
    init_pair(7, -1, -1);
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
    initscr();
    raw();
    nonl();
    noecho();
    keypad(stdscr, TRUE);
    scrollok(stdscr, FALSE);
    set_escdelay(25);
    psi_tui_init_colors();

    status = psi_tui_run_lua(&vm, options);

    endwin();
    psi_vm_destroy(&vm);
    psi_session_free(&session);
    return status;
}
