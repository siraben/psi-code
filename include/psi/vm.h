#ifndef PSI_VM_H
#define PSI_VM_H

#include <stdio.h>
#include <lua.h>
#include "psi/common.h"
#include "psi/host_ops.h"

struct psi_vm {
    lua_State *L;
    const char *boot_file;
    struct psi_host_context host;
    int tui_active;
    int tui_tick_callback_ref;
    int tui_tool_progress_callback_ref;
};

int psi_vm_init(struct psi_vm *vm, const char *boot_file, FILE *input, FILE *output,
    FILE *error_output, int load_extensions);
void psi_vm_destroy(struct psi_vm *vm);
void psi_vm_bind_session(struct psi_vm *vm, struct psi_session *session);
void psi_vm_set_tui_active(struct psi_vm *vm, int active);

/* Bridge into the Lua agent layer. The observer is wrapped as a Lua
 * table whose callbacks invoke the C function pointers. abort_signal
 * and max_tokens/model are forwarded into the Lua opts table. */
struct psi_agent_observer;
struct psi_abort_signal;
int psi_vm_run_agent_turn(struct psi_vm *vm, const char *user_text,
    struct psi_agent_observer *observer, struct psi_abort_signal *abort_signal, const char *model,
    long max_tokens, char **response_text);
int psi_vm_run_agent_compact(struct psi_vm *vm, size_t keep_recent,
    struct psi_abort_signal *abort_signal, const char *model, long max_tokens, char **summary_text);

/* Thin shims onto the Lua session module. Callers still work in C but
 * the actual JSONL I/O lives in lua/psi/session_manager.lua. */
int psi_vm_session_save(struct psi_vm *vm, const char *path);
int psi_vm_session_load(struct psi_vm *vm, const char *path);

/* Run psi.modes.run(opts) with the given CLI options packed into a Lua
 * table. Used by both CLI and TUI mode dispatchers. */
struct psi_cli_options;
int psi_vm_run_lua_mode(struct psi_vm *vm, const char *mode, const struct psi_cli_options *options);

#endif
