#ifndef PSI_ABORT_H
#define PSI_ABORT_H

#include <signal.h>
#include "psi/common.h"

/* Cancellation token for interrupting an in-flight turn.
 *
 * After the coroutine rewrite, the agent turn runs on the single
 * lua_State-owning thread; the only cross-thread readers are the
 * http_async.c helper pthread (inside curl's xferinfo callback)
 * and the fork()ed child processes spawned by psi_process_run_shell
 * (indirectly, via SIGTERM delivery from the main thread). For both
 * readers the requirement is "eventual visibility" — losing one poll
 * cycle before noticing cancellation is fine.
 *
 * The flag is also written from a SIGINT handler in cli_mode.c, so
 * its type must be `volatile sig_atomic_t`: that is the only type
 * C89 guarantees can be safely modified from a signal handler. */

struct psi_abort_signal {
    volatile sig_atomic_t flag;
};

void psi_abort_signal_init(struct psi_abort_signal *s);
void psi_abort_signal_trigger(struct psi_abort_signal *s);
int psi_abort_signal_is_triggered(const struct psi_abort_signal *s);
void psi_abort_signal_reset(struct psi_abort_signal *s);

#endif
