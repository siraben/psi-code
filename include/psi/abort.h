#ifndef PSI_ABORT_H
#define PSI_ABORT_H

#include "psi/common.h"

/* Cancellation token for interrupting an in-flight turn.
 *
 * The UI thread sets the flag (psi_abort_signal_trigger); the worker
 * thread and every blocking call reached from it polls
 * psi_abort_signal_is_triggered and unwinds cleanly. A volatile int
 * is sufficient here: the flag is a single word, writes are
 * word-aligned, and we only need "eventual visibility" — losing one
 * poll cycle before noticing cancellation is fine. */

struct psi_abort_signal {
    volatile int flag;
};

void psi_abort_signal_init(struct psi_abort_signal *s);
void psi_abort_signal_trigger(struct psi_abort_signal *s);
int  psi_abort_signal_is_triggered(const struct psi_abort_signal *s);
void psi_abort_signal_reset(struct psi_abort_signal *s);

#endif
