#include "psi/abort.h"

void psi_abort_signal_init(struct psi_abort_signal *s) {
    if (s == NULL) return;
    s->flag = 0;
}

void psi_abort_signal_trigger(struct psi_abort_signal *s) {
    if (s == NULL) return;
    s->flag = 1;
}

int psi_abort_signal_is_triggered(const struct psi_abort_signal *s) {
    return s != NULL && s->flag != 0;
}

void psi_abort_signal_reset(struct psi_abort_signal *s) {
    if (s == NULL) return;
    s->flag = 0;
}
