#ifndef PSI_VM_H
#define PSI_VM_H

#include <stdio.h>
#include <chibi/eval.h>
#include "psi/common.h"

struct psi_session;

struct psi_vm {
    sexp ctx;
    sexp env;
    const char *boot_file;
    struct psi_session *session;
};

int psi_vm_init(struct psi_vm *vm, const char *boot_file, FILE *input, FILE *output, FILE *error_output);
void psi_vm_destroy(struct psi_vm *vm);
void psi_vm_bind_session(struct psi_vm *vm, struct psi_session *session);
int psi_vm_eval_to_string(struct psi_vm *vm, const char *expression, char **output_text);
int psi_vm_call_string_procedure(struct psi_vm *vm, const char *procedure_name, const char *argument, char **output_text);

#endif
