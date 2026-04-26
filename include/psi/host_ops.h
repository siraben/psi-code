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

#define PSI_HOST_TUI_THEME_PAIR_COUNT 7

/* Usage-mirror for the TUI status line.
 *
 * Written by psi.set_usage() (from lua/psi/context.lua record_usage)
 * and read by psi.tui.status_line, both on the single main thread
 * that owns lua_State. The mirror predates the coroutine rewrite,
 * when a worker thread wrote and the main thread read concurrently —
 * the `volatile` qualifier protected against torn reads and
 * compiler reordering in that era. After the rewrite there is
 * exactly one thread touching these fields; `volatile` would only
 * cost us register keeping / constant folding. Plain `long`. */
struct psi_host_usage {
    long input;
    long output;
    long cache_read;
    long cache_write;
    long total;
    long context_window;
};

struct psi_host_tui_theme_pair {
    int fg;
    int bg;
    int is_set;
};

struct psi_host_tui_theme {
    int active;
    struct psi_host_tui_theme_pair pairs[PSI_HOST_TUI_THEME_PAIR_COUNT];
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
    struct psi_host_tui_theme tui_theme;
    psi_host_tick_fn tick_hook;
    void *tick_userdata;
};

#endif
