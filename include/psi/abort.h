#ifndef PSI_ABORT_H
#define PSI_ABORT_H

#include "psi/common.h"

/* Cancellation token for interrupting an in-flight turn.
 *
 * After the coroutine rewrite, the agent turn runs on the single
 * lua_State-owning thread; the only cross-thread readers are the
 * http_async.c helper pthread (inside curl's xferinfo callback)
 * and the fork()ed child processes spawned by psi_process_run_shell
 * (indirectly, via SIGTERM delivery from the main thread). For both
 * readers the requirement is "eventual visibility"—losing one poll
 * cycle before noticing cancellation is fine.
 *
 * `volatile int` is sufficient: the flag is a single word, writes
 * are word-aligned, and all hosts we support (x86, x86_64, ARM,
 * aarch64 via iSH ILP32 musl) give aligned int load/store atomicity
 * at the CPU level. No memory-order barrier is needed because the
 * reader doesn't use the flag to gate access to other data. */

struct psi_abort_signal {
    volatile int flag;
};

void psi_abort_signal_init(struct psi_abort_signal *s);
void psi_abort_signal_trigger(struct psi_abort_signal *s);
int psi_abort_signal_is_triggered(const struct psi_abort_signal *s);
void psi_abort_signal_reset(struct psi_abort_signal *s);

#endif
