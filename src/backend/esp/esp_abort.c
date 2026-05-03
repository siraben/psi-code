/* Abort signal helper for the ESP backend.
 *
 * The abort flag itself lives in struct psi_abort_signal, defined in
 * psi/abort.h. The desktop build sets it from a SIGINT handler; on
 * ESP-IDF there are no POSIX signals, so the WebSocket handler calls
 * this function instead when the client sends an "abort" frame.
 *
 * The flag is a volatile int and is read by Lua via psi.is_aborted();
 * setting it from any task is race-free under the same single-writer
 * pattern the curl async backend already relies on. */

#include "psi/abort.h"
#include "psi/esp_runtime.h"

void psi_esp_request_abort(struct psi_abort_signal *abort_signal) {
    if (abort_signal == NULL)
        return;
    psi_abort_signal_trigger(abort_signal);
}
