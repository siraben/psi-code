#ifndef PSI_VM_H
#define PSI_VM_H

#include <stdio.h>
#include <chibi/eval.h>
#include "psi/common.h"
#include "psi/host_ops.h"

struct psi_vm {
    sexp ctx;
    sexp env;
    const char *boot_file;
    struct psi_host_context host;
};

int psi_vm_init(struct psi_vm *vm, const char *boot_file, FILE *input, FILE *output, FILE *error_output);
void psi_vm_destroy(struct psi_vm *vm);
void psi_vm_bind_session(struct psi_vm *vm, struct psi_session *session);
int psi_vm_eval_to_string(struct psi_vm *vm, const char *expression, char **output_text);
int psi_vm_call_string_procedure(struct psi_vm *vm, const char *procedure_name, const char *argument, char **output_text);
int psi_vm_call_procedure0_to_string(struct psi_vm *vm, const char *procedure_name, char **output_text);
int psi_vm_tool_specs_json(struct psi_vm *vm, char **output_json);
int psi_vm_active_tool_specs_json(struct psi_vm *vm, const char *user_text, char **output_json);
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

#endif
