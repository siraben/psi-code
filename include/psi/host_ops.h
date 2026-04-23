#ifndef PSI_HOST_OPS_H
#define PSI_HOST_OPS_H

#include "psi/common.h"

/* Context shared between the agent loop and Lua FFI primitives.
 *
 * Each VM owns one host context (stored in the Lua state's extraspace).
 * The agent loop in anthropic.c stamps `active_observer` and
 * `active_tool_id` on it around each tool dispatch so FFI primitives
 * (psi.process_run, etc.) can stream progress back to the observer and
 * honor `abort_signal`. Outside of a dispatch, those three fields are
 * NULL. */

struct psi_session;
struct psi_vm;
struct psi_agent_observer;
struct psi_abort_signal;

/* Usage-mirror for the TUI status line. Written by the worker
 * thread via psi.set_usage() (through context.record_usage); read
 * by the TUI main thread when painting the footer.
 *
 * `volatile long` is enough here: on all supported 32-/64-bit
 * platforms `long` stores are single-word and therefore atomic;
 * the main thread may observe a momentary mix of old+new fields
 * across the six members for at most one store, which is
 * harmless for display. No mutex — locking would block the hot
 * redraw path while the worker is mid-HTTP-stream. */
struct psi_host_usage {
    volatile long input;
    volatile long output;
    volatile long cache_read;
    volatile long cache_write;
    volatile long total;
    volatile long context_window;
};

/* Host tick hook.
 *
 * psi.sched calls psi.host_tick() between coroutine resumes. If a
 * host has installed a hook here, it runs one iteration of its own
 * event loop (e.g. the TUI: non-blocking getch + dispatch +
 * redraw). Non-TUI hosts leave this NULL and psi.host_tick becomes
 * a no-op. */
typedef void (*psi_host_tick_fn)(void *userdata);

struct psi_host_context {
    struct psi_session *session;
    struct psi_vm *vm;
    struct psi_agent_observer *active_observer;
    const char *active_tool_id;
    struct psi_abort_signal *abort_signal;
    struct psi_host_usage usage;
    psi_host_tick_fn tick_hook;
    void *tick_userdata;
};

#endif
