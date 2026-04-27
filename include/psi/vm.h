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
};

int psi_vm_init(struct psi_vm *vm, const char *boot_file, FILE *input, FILE *output, FILE *error_output);
void psi_vm_destroy(struct psi_vm *vm);
void psi_vm_bind_session(struct psi_vm *vm, struct psi_session *session);
int psi_vm_eval_to_string(struct psi_vm *vm, const char *expression, char **output_text);
int psi_vm_call_string_procedure(struct psi_vm *vm, const char *procedure_name, const char *argument, char **output_text);
int psi_vm_call_procedure0_to_string(struct psi_vm *vm, const char *procedure_name, char **output_text);

/* Render a single TUI transcript line through psi.markdown.render_line,
 * returning the ANSI-escape-bearing result. `in_code_fence` passes the
 * fence flag the TUI tracks across wrapped lines. */
int psi_vm_markdown_render_line(struct psi_vm *vm, const char *text, int in_code_fence, char **output_text);

/* Build the TUI status line + hint line by calling
 * psi.tui.status_line / psi.tui.footer_hint with a JSON arg table,
 * plus split-bar helpers for header/footer chrome. */
int psi_vm_tui_status_line(struct psi_vm *vm, const char *arg_json, char **output_text);
int psi_vm_tui_footer_hint(struct psi_vm *vm, const char *arg_json, char **output_text);
int psi_vm_tui_workspace_line(struct psi_vm *vm, const char *cwd, char **output_text);
int psi_vm_tui_status_bar(struct psi_vm *vm, const char *arg_json, char **output_text);
int psi_vm_tui_workspace_bar(struct psi_vm *vm, const char *cwd, char **output_text);
int psi_vm_tui_render_busy_status(struct psi_vm *vm, const char *label, long phase, char **output_text);
int psi_vm_render_event_json(
    struct psi_vm *vm,
    const char *event_name,
    const char *payload_json,
    char **output_text
);
int psi_vm_parse_command(
    struct psi_vm *vm,
    const char *line,
    char **action_name,
    char **action_text,
    long *action_number
);
int psi_vm_build_compaction_request(
    struct psi_vm *vm,
    long keep_recent,
    char **system_prompt,
    char **user_prompt
);
int psi_vm_dispatch_tool_json(
    struct psi_vm *vm,
    const char *tool_name,
    const char *input_json,
    char **output_json
);
int psi_vm_session_compact(
    struct psi_vm *vm,
    long keep_recent,
    const char *summary_text
);

/* Bridge into the Lua agent layer. The observer is wrapped as a Lua
 * table whose callbacks invoke the C function pointers. abort_signal
 * and max_tokens/model are forwarded into the Lua opts table. */
struct psi_agent_observer;
struct psi_abort_signal;
int psi_vm_run_agent_turn(
    struct psi_vm *vm,
    const char *user_text,
    struct psi_agent_observer *observer,
    struct psi_abort_signal *abort_signal,
    const char *model,
    long max_tokens,
    char **response_text
);
int psi_vm_run_agent_compact(
    struct psi_vm *vm,
    size_t keep_recent,
    struct psi_abort_signal *abort_signal,
    const char *model,
    long max_tokens,
    char **summary_text
);

/* Thin shims onto the Lua session module. Callers still work in C but
 * the actual JSONL I/O lives in lua/psi/session.lua. */
int psi_vm_session_save(struct psi_vm *vm, const char *path);
int psi_vm_session_load(struct psi_vm *vm, const char *path);

#endif
