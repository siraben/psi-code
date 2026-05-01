/* Runtime mode dispatcher.
 *
 * Every non-TUI mode (print, eval, repl, system-prompt, agent, compact)
 * is implemented in lua/psi/modes.lua. This file is now just a thin
 * bridge: init VM + session, push the CLI options as a Lua table, call
 * psi.modes.run(opts), return its boolean status. TUI mode uses the same
 * Lua dispatcher but switches the terminal into raw ANSI mode first. */

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include "psi/abort.h"
#include "psi/runtime.h"
#include "psi/session.h"
#include "psi/vm.h"

/* Process-global so the SIGINT handler can reach it without args.
 * TUI mode runs its own UI-thread/worker split and never routes Ctrl-C
 * through these hooks; only CLI modes install them. */
static struct psi_abort_signal *g_print_abort = NULL;
static struct sigaction g_prev_sigint_sa;
static int g_sigint_installed = 0;

static void psi_print_sigint_handler(int sig) {
    (void)sig;
    if (g_print_abort != NULL) g_print_abort->flag = 1;
}

static void psi_install_sigint(struct psi_abort_signal *sig) {
    struct sigaction sa;
    g_print_abort = sig;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = psi_print_sigint_handler;
    sigemptyset(&sa.sa_mask);
    /* No SA_RESTART: we want blocking syscalls (read, waitpid) to return
     * EINTR so the abort-polling loops can notice promptly. */
    sa.sa_flags = 0;
    if (sigaction(SIGINT, &sa, &g_prev_sigint_sa) == 0) {
        g_sigint_installed = 1;
    }
}

static void psi_restore_sigint(void) {
    if (g_sigint_installed) {
        sigaction(SIGINT, &g_prev_sigint_sa, NULL);
        g_sigint_installed = 0;
    }
    g_print_abort = NULL;
}

static const char *psi_mode_name(enum psi_cli_mode mode) {
    switch (mode) {
        case PSI_CLI_MODE_PRINT:          return "print";
        case PSI_CLI_MODE_EVAL:           return "eval";
        case PSI_CLI_MODE_REPL:           return "repl";
        case PSI_CLI_MODE_SYSTEM_PROMPT:  return "system-prompt";
        case PSI_CLI_MODE_AGENT:          return "agent";
        case PSI_CLI_MODE_COMPACT:        return "compact";
        default:                          return NULL;
    }
}

static int psi_run_via_lua(const struct psi_cli_options *options) {
    struct psi_vm vm;
    struct psi_session session;
    const char *mode_name;
    int ok;
    int status;

    mode_name = psi_mode_name(options->mode);
    if (mode_name == NULL) return PSI_STATUS_ERROR;

    psi_session_init(&session);
    status = psi_vm_init(&vm, options->boot_file, stdin, stdout, stderr);
    if (status != PSI_STATUS_OK) {
        psi_session_free(&session);
        return status;
    }
    psi_vm_bind_session(&vm, &session);

    /* Ctrl-C → abort flag; curl xferinfo and process_run already poll it. */
    {
        static struct psi_abort_signal abort_signal;
        psi_abort_signal_init(&abort_signal);
        vm.host.abort_signal = &abort_signal;
        psi_install_sigint(&abort_signal);
    }

    lua_getglobal(vm.L, "psi");
    lua_getfield(vm.L, -1, "modes");
    lua_getfield(vm.L, -1, "run");
    lua_remove(vm.L, -2); /* drop modes */
    lua_remove(vm.L, -2); /* drop psi */
    if (lua_type(vm.L, -1) != LUA_TFUNCTION) {
        fprintf(stderr, "psi.modes.run is not a function\n");
        lua_pop(vm.L, 1);
        psi_vm_destroy(&vm);
        psi_session_free(&session);
        return PSI_STATUS_ERROR;
    }

    lua_newtable(vm.L);
    lua_pushstring(vm.L, mode_name);
    lua_setfield(vm.L, -2, "mode");
    if (options->payload != NULL) {
        lua_pushstring(vm.L, options->payload);
        lua_setfield(vm.L, -2, "payload");
    }
    if (options->session_file != NULL) {
        lua_pushstring(vm.L, options->session_file);
        lua_setfield(vm.L, -2, "session_file");
    }
    if (options->model != NULL) {
        lua_pushstring(vm.L, options->model);
        lua_setfield(vm.L, -2, "model");
    }
    if (options->thinking_level != NULL) {
        lua_pushstring(vm.L, options->thinking_level);
        lua_setfield(vm.L, -2, "thinking_level");
    }
    lua_pushinteger(vm.L, (lua_Integer)options->max_tokens);
    lua_setfield(vm.L, -2, "max_tokens");
    lua_pushinteger(vm.L, (lua_Integer)options->keep_recent);
    lua_setfield(vm.L, -2, "keep_recent");

    if (lua_pcall(vm.L, 1, 1, 0) != LUA_OK) {
        fprintf(stderr, "psi.modes.run error: %s\n", lua_tostring(vm.L, -1));
        lua_pop(vm.L, 1);
        psi_restore_sigint();
        psi_vm_destroy(&vm);
        psi_session_free(&session);
        return PSI_STATUS_ERROR;
    }
    ok = lua_toboolean(vm.L, -1);
    lua_pop(vm.L, 1);

    psi_restore_sigint();
    psi_vm_destroy(&vm);
    psi_session_free(&session);
    return ok ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

int psi_run_print_mode_dispatch(const struct psi_cli_options *options) {
    if (options->mode == PSI_CLI_MODE_TUI) {
        return psi_run_tui_mode(options);
    }
    return psi_run_via_lua(options);
}
