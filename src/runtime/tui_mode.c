#include <fcntl.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#if PSI_ENABLE_TUI
#include <ncurses.h>
#endif
#include <lua.h>
#include "psi/abort.h"
#include "psi/host_ops.h"
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

/* Redirect fd 2 to a per-session log while curses owns the terminal.
 *
 * Without this, any fprintf(stderr, ...) or io.stderr:write() lands as raw
 * bytes wherever the cursor happens to be, leaving sticky garbage on the
 * input prompt that ncurses won't redraw over (it didn't write those bytes
 * itself, so it doesn't track them in its line buffers).
 *
 * Path:
 *   $XDG_STATE_HOME/psi/tui-stderr.log  (or $HOME/.local/state/psi/...)
 *
 * Returns the duplicated original fd 2 on success so the caller can restore
 * it after endwin(). Returns -1 on any failure; in that case stderr is
 * untouched and we silently accept the corruption (better than failing the
 * TUI launch outright).
 */
static int psi_tui_redirect_stderr(void) {
    const char *xdg;
    const char *home;
    char path[1024];
    char dir[1024];
    int fd;
    int saved;
    size_t n;

    xdg = getenv("XDG_STATE_HOME");
    if (xdg != NULL && xdg[0] != '\0') {
        n = (size_t)snprintf(dir, sizeof(dir), "%s/psi", xdg);
    } else {
        home = getenv("HOME");
        if (home == NULL || home[0] == '\0') return -1;
        n = (size_t)snprintf(dir, sizeof(dir), "%s/.local/state/psi", home);
    }
    if (n == 0u || n >= sizeof(dir)) return -1;

    /* mkdir -p the parent chain ($HOME/.local, $HOME/.local/state, then psi). */
    {
        size_t i;
        for (i = 1u; i < n; i++) {
            if (dir[i] == '/') {
                dir[i] = '\0';
                (void)mkdir(dir, 0700);
                dir[i] = '/';
            }
        }
        (void)mkdir(dir, 0700);
    }

    n = (size_t)snprintf(path, sizeof(path), "%s/tui-stderr.log", dir);
    if (n == 0u || n >= sizeof(path)) return -1;

    /* O_TRUNC: a fresh log per TUI session keeps it scannable.
     * O_APPEND would defeat that on every relaunch. */
    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return -1;

    saved = dup(STDERR_FILENO);
    if (saved < 0) {
        close(fd);
        return -1;
    }

    if (dup2(fd, STDERR_FILENO) < 0) {
        close(fd);
        close(saved);
        return -1;
    }
    close(fd);
    return saved;
}

static void psi_tui_restore_stderr(int saved_fd) {
    if (saved_fd < 0) return;
    fflush(stderr);
    (void)dup2(saved_fd, STDERR_FILENO);
    close(saved_fd);
}

static int psi_tui_init_colors(const struct psi_host_context *host) {
#if PSI_ENABLE_COLOR
    int i;

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
    if (COLOR_PAIRS > 8) {
        init_pair(8, COLORS > 242 ? 242 : COLOR_BLACK, -1);
    }
    if (host != NULL && host->tui_theme.active) {
        for (i = 0; i < PSI_HOST_TUI_THEME_PAIR_COUNT && i + 1 < COLOR_PAIRS; i++) {
            const struct psi_host_tui_theme_pair *pair = &host->tui_theme.pairs[i];
            if (pair->is_set) {
                int fg = pair->fg >= 0 && pair->fg < COLORS ? pair->fg : -1;
                int bg = pair->bg >= 0 && pair->bg < COLORS ? pair->bg : -1;
                init_pair((short)(i + 1), (short)fg, (short)bg);
            }
        }
    }
#endif
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

    /* Redirect stderr to a log file BEFORE initscr() so even early curses
     * setup errors don't corrupt the screen. Restore AFTER endwin() so any
     * post-shutdown errors (Lua teardown, psi.modes.run error) reach the
     * user's terminal as before. */
    {
        int saved_stderr = psi_tui_redirect_stderr();

        initscr();
        raw();
        nonl();
        noecho();
        keypad(stdscr, TRUE);
        scrollok(stdscr, FALSE);
        set_escdelay(25);
        psi_tui_init_colors(&vm.host);

        psi_vm_set_tui_active(&vm, 1);
        status = psi_tui_run_lua(&vm, options);
        psi_vm_set_tui_active(&vm, 0);

        endwin();
        psi_tui_restore_stderr(saved_stderr);
    }
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
