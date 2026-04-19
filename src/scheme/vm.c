#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "psi/session.h"
#include "psi/vm.h"

static struct psi_session *psi_current_session = NULL;

static sexp psi_foreign_version(sexp ctx, sexp self, sexp n) {
    PSI_UNUSED(self);
    PSI_UNUSED(n);
    return sexp_c_string(ctx, PSI_VERSION, -1);
}

static sexp psi_foreign_log(sexp ctx, sexp self, sexp n, sexp message) {
    PSI_UNUSED(self);
    PSI_UNUSED(n);

    if (!sexp_stringp(message)) {
        return sexp_type_exception(ctx, self, SEXP_STRING, message);
    }

    fprintf(stderr, "[psi] %.*s\n",
            (int)sexp_string_size(message),
            sexp_string_data(message));
    return SEXP_TRUE;
}

static sexp psi_foreign_session_message_count(sexp ctx, sexp self, sexp n) {
    PSI_UNUSED(ctx);
    PSI_UNUSED(self);
    PSI_UNUSED(n);

    if (psi_current_session == NULL) {
        return sexp_make_fixnum(0);
    }

    return sexp_make_fixnum((sexp_sint_t)psi_current_session->count);
}

static int psi_vm_extract_string(sexp ctx, sexp value, char **output_text) {
    sexp printed;
    char *copy;

    if (sexp_stringp(value)) {
        copy = psi_strdup_n(sexp_string_data(value), (size_t)sexp_string_size(value));
        if (copy == NULL) {
            fprintf(stderr, "out of memory while copying Scheme string\n");
            return PSI_STATUS_ERROR;
        }

        *output_text = copy;
        return PSI_STATUS_OK;
    }

    printed = sexp_write_to_string(ctx, value);
    if (sexp_exceptionp(printed)) {
        sexp_print_exception(ctx, printed, sexp_current_error_port(ctx));
        return PSI_STATUS_ERROR;
    }

    copy = psi_strdup_n(sexp_string_data(printed), (size_t)sexp_string_size(printed));
    if (copy == NULL) {
        fprintf(stderr, "out of memory while copying Scheme string\n");
        return PSI_STATUS_ERROR;
    }

    *output_text = copy;
    return PSI_STATUS_OK;
}

static int psi_vm_load_bootstrap(struct psi_vm *vm) {
    sexp path;
    sexp result;

    path = sexp_c_string(vm->ctx, vm->boot_file, -1);
    result = sexp_load(vm->ctx, path, vm->env);
    if (sexp_exceptionp(result)) {
        fprintf(stderr, "failed to load Scheme bootstrap: %s\n", vm->boot_file);
        sexp_print_exception(vm->ctx, result, sexp_current_error_port(vm->ctx));
        return PSI_STATUS_ERROR;
    }
    return PSI_STATUS_OK;
}

int psi_vm_init(struct psi_vm *vm, const char *boot_file, FILE *input, FILE *output, FILE *error_output) {
    if (vm == NULL) {
        return PSI_STATUS_ERROR;
    }

    memset(vm, 0, sizeof(*vm));
    vm->boot_file = boot_file;
    vm->session = NULL;

    sexp_scheme_init();
    vm->ctx = sexp_make_eval_context(NULL, NULL, NULL, 0, 0);
    if (vm->ctx == NULL) {
        fprintf(stderr, "failed to create Chibi context\n");
        return PSI_STATUS_ERROR;
    }

    sexp_load_standard_env(vm->ctx, NULL, SEXP_SEVEN);
    sexp_load_standard_ports(vm->ctx, NULL, input, output, error_output, 1);

    vm->env = sexp_context_env(vm->ctx);
    if (vm->env == NULL) {
        fprintf(stderr, "failed to get Chibi environment\n");
        sexp_destroy_context(vm->ctx);
        vm->ctx = NULL;
        return PSI_STATUS_ERROR;
    }

    sexp_define_foreign(vm->ctx, vm->env, "psi-version", 0, psi_foreign_version);
    sexp_define_foreign(vm->ctx, vm->env, "psi-log", 1, psi_foreign_log);
    sexp_define_foreign(vm->ctx, vm->env, "psi-session-message-count", 0, psi_foreign_session_message_count);

    return psi_vm_load_bootstrap(vm);
}

void psi_vm_destroy(struct psi_vm *vm) {
    if (vm == NULL || vm->ctx == NULL) {
        return;
    }

    sexp_destroy_context(vm->ctx);
    vm->ctx = NULL;
    vm->env = NULL;
    vm->session = NULL;
    psi_current_session = NULL;
}

void psi_vm_bind_session(struct psi_vm *vm, struct psi_session *session) {
    if (vm == NULL) {
        return;
    }

    vm->session = session;
    psi_current_session = session;
}

int psi_vm_eval_to_string(struct psi_vm *vm, const char *expression, char **output_text) {
    sexp result;

    if (vm == NULL || output_text == NULL) {
        return PSI_STATUS_ERROR;
    }

    *output_text = NULL;
    result = sexp_eval_string(vm->ctx, expression, -1, vm->env);
    if (sexp_exceptionp(result)) {
        sexp_print_exception(vm->ctx, result, sexp_current_error_port(vm->ctx));
        return PSI_STATUS_ERROR;
    }

    return psi_vm_extract_string(vm->ctx, result, output_text);
}

int psi_vm_call_string_procedure(struct psi_vm *vm, const char *procedure_name, const char *argument, char **output_text) {
    sexp symbol;
    sexp procedure;
    sexp args;
    sexp value;

    if (vm == NULL || procedure_name == NULL || output_text == NULL) {
        return PSI_STATUS_ERROR;
    }

    *output_text = NULL;

    symbol = sexp_intern(vm->ctx, procedure_name, -1);
    procedure = sexp_env_ref(vm->ctx, vm->env, symbol, SEXP_FALSE);
    if (procedure == SEXP_FALSE) {
        fprintf(stderr, "undefined Scheme procedure: %s\n", procedure_name);
        return PSI_STATUS_ERROR;
    }

    args = sexp_list1(vm->ctx, sexp_c_string(vm->ctx, argument ? argument : "", -1));
    value = sexp_apply(vm->ctx, procedure, args);
    if (sexp_exceptionp(value)) {
        sexp_print_exception(vm->ctx, value, sexp_current_error_port(vm->ctx));
        return PSI_STATUS_ERROR;
    }

    return psi_vm_extract_string(vm->ctx, value, output_text);
}
