/* Runtime mode dispatcher.
 *
 * Every non-TUI mode (print, eval, repl, system-prompt, agent, compact)
 * is implemented in lua/psi/modes.lua. This file is now just a thin
 * bridge: init VM + session, push the CLI options as a Lua table, call
 * psi.modes.run(opts), return its boolean status. TUI mode uses the same
 * Lua dispatcher but switches the terminal into raw ANSI mode first. */

#include <ctype.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "psi/abort.h"
#include "psi/runtime.h"
#include "psi/session.h"
#include "psi/vm.h"

#ifdef PSI_HAVE_COSMO_DCE
extern const int __hostos;
#define PSI_COSMO_HOST_WINDOWS 4
#endif

/* Process-global so the SIGINT handler can reach it without args.
 * TUI mode runs its own UI-thread/worker split and never routes Ctrl-C
 * through these hooks; only CLI modes install them. */
static struct psi_abort_signal *g_print_abort = NULL;
static struct sigaction g_prev_sigint_sa;
static int g_sigint_installed = 0;

static void psi_print_sigint_handler(int sig) {
    (void)sig;
    if (g_print_abort != NULL)
        g_print_abort->flag = 1;
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
    case PSI_CLI_MODE_PRINT:
        return "print";
    case PSI_CLI_MODE_EVAL:
        return "eval";
    case PSI_CLI_MODE_REPL:
        return "repl";
    case PSI_CLI_MODE_SYSTEM_PROMPT:
        return "system-prompt";
    case PSI_CLI_MODE_AGENT:
        return "agent";
    case PSI_CLI_MODE_COMPACT:
        return "compact";
    default:
        return NULL;
    }
}

static int psi_env_truthy(const char *name) {
    const char *value = getenv(name);

    if (value == NULL || value[0] == '\0')
        return 0;
    return strcmp(value, "1") == 0 || strcmp(value, "on") == 0 || strcmp(value, "true") == 0 ||
        strcmp(value, "yes") == 0 || strcmp(value, "ON") == 0 || strcmp(value, "TRUE") == 0 ||
        strcmp(value, "YES") == 0;
}

static int psi_env_falsey(const char *name) {
    const char *value = getenv(name);

    if (value == NULL || value[0] == '\0')
        return 0;
    return strcmp(value, "0") == 0 || strcmp(value, "off") == 0 || strcmp(value, "false") == 0 ||
        strcmp(value, "no") == 0 || strcmp(value, "OFF") == 0 || strcmp(value, "FALSE") == 0 ||
        strcmp(value, "NO") == 0;
}

static int psi_env_nonempty(const char *name) {
    const char *value = getenv(name);
    return value != NULL && value[0] != '\0';
}

/* Case-insensitive ASCII substring search for terminal/environment probes. */
static int psi_ascii_contains_ci(const char *haystack, const char *needle) {
    size_t needle_len;
    size_t i;

    if (haystack == NULL || needle == NULL)
        return 0;
    needle_len = strlen(needle);
    if (needle_len == 0u)
        return 1;
    for (i = 0u; haystack[i] != '\0'; i++) {
        size_t j;
        for (j = 0u; j < needle_len; j++) {
            unsigned char a = (unsigned char)haystack[i + j];
            unsigned char b = (unsigned char)needle[j];
            if (a == (unsigned char)'\0')
                return 0;
            if (tolower(a) != tolower(b))
                break;
        }
        if (j == needle_len)
            return 1;
    }
    return 0;
}

static int psi_windows_environment(void) {
    const char *os;

#ifdef PSI_HAVE_COSMO_DCE
    if ((__hostos & PSI_COSMO_HOST_WINDOWS) != 0)
        return 1;
#endif
    os = getenv("OS");
    return os != NULL && strcmp(os, "Windows_NT") == 0;
}

static int psi_windows_ansi_terminal(void) {
    const char *term;
    const char *conemu;

    if (!psi_windows_environment())
        return 1;
    if (psi_env_falsey("PSI_ANSI"))
        return 0;
    if (psi_env_truthy("PSI_ANSI"))
        return 1;
    if (psi_env_nonempty("WT_SESSION") || psi_env_nonempty("ANSICON") ||
        psi_env_nonempty("MSYSTEM"))
        return 1;
    if (psi_ascii_contains_ci(getenv("TERM_PROGRAM"), "mintty"))
        return 1;

    conemu = getenv("ConEmuANSI");
    if (conemu != NULL &&
        (strcmp(conemu, "ON") == 0 || strcmp(conemu, "on") == 0 || strcmp(conemu, "1") == 0 ||
            strcmp(conemu, "true") == 0 || strcmp(conemu, "TRUE") == 0))
        return 1;

    term = getenv("TERM");
    if (term != NULL && term[0] != '\0' && strcmp(term, "dumb") != 0 &&
        (psi_ascii_contains_ci(term, "cygwin") || psi_ascii_contains_ci(term, "msys") ||
            psi_ascii_contains_ci(term, "mintty")))
        return 1;

    /* Windows 10+ conhost supports VT sequences once enabled by the
     * runtime. Do not force plain cmd.exe / PowerShell users to set an
     * env var just to keep the TUI. PSI_ANSI=0 remains the explicit
     * opt-out for older or redirected consoles. */
    return 1;
}

static int psi_run_via_lua(const struct psi_cli_options *options) {
    struct psi_vm vm;
    struct psi_session session;
    const char *mode_name;
    int status;

    mode_name = psi_mode_name(options->mode);
    if (mode_name == NULL)
        return PSI_STATUS_ERROR;

    psi_session_init(&session);
    /* Only the line-oriented interactive REPL may answer the
     * project-trust prompt at boot; one-shot modes default to
     * untrusted (see lua/psi/trust_manager.lua). */
    status = psi_vm_init(&vm, options->boot_file, stdin, stdout, stderr, options->load_extensions,
        options->mode == PSI_CLI_MODE_REPL);
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

    status = psi_vm_run_lua_mode(&vm, mode_name, options);

    psi_restore_sigint();
    psi_vm_destroy(&vm);
    psi_session_free(&session);
    return status;
}

int psi_run_print_mode_dispatch(const struct psi_cli_options *options) {
    if (options->mode == PSI_CLI_MODE_TUI) {
        if (!psi_windows_ansi_terminal()) {
            struct psi_cli_options fallback = *options;
            fprintf(stderr, "psi: ANSI/TUI disabled by PSI_ANSI=0; starting --repl instead\n");
            fflush(stderr);
            fallback.mode = PSI_CLI_MODE_REPL;
            return psi_run_via_lua(&fallback);
        }
        return psi_run_tui_mode(options);
    }
    return psi_run_via_lua(options);
}
