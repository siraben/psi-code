#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cjson/cJSON.h>
#include "psi/host_ops.h"
#include "psi/process.h"
#include "psi/prompt.h"
#include "psi/session.h"
#include "psi/vm.h"

static const long PSI_VM_FILE_WRITE_MAX_BYTES = 16777216l; /* 16 MiB */

static struct psi_host_context *psi_current_host = NULL;

static sexp psi_foreign_version(sexp ctx, sexp self, sexp n) {
    struct psi_host_call call;
    int status;

    PSI_UNUSED(self);
    PSI_UNUSED(n);
    call.kind = PSI_HOST_OP_VERSION;
    call.input_text = NULL;
    status = psi_host_call(psi_current_host, &call);
    if (status != PSI_STATUS_OK || call.output_text == NULL) {
        return sexp_user_exception(ctx, self, "host version operation failed", SEXP_FALSE);
    }

    self = sexp_c_string(ctx, call.output_text, -1);
    free(call.output_text);
    return self;
}

static sexp psi_foreign_log(sexp ctx, sexp self, sexp n, sexp message) {
    struct psi_host_call call;

    PSI_UNUSED(self);
    PSI_UNUSED(n);

    if (!sexp_stringp(message)) {
        return sexp_type_exception(ctx, self, SEXP_STRING, message);
    }

    call.kind = PSI_HOST_OP_LOG;
    call.input_text = psi_strdup_n(sexp_string_data(message), (size_t)sexp_string_size(message));
    if (call.input_text == NULL) {
        return sexp_user_exception(ctx, self, "out of memory while preparing log input", message);
    }
    if (psi_host_call(psi_current_host, &call) != PSI_STATUS_OK) {
        free((char *)call.input_text);
        return sexp_user_exception(ctx, self, "host log operation failed", message);
    }
    free((char *)call.input_text);
    return SEXP_TRUE;
}

static sexp psi_foreign_session_message_count(sexp ctx, sexp self, sexp n) {
    struct psi_host_call call;
    int status;

    PSI_UNUSED(ctx);
    PSI_UNUSED(self);
    PSI_UNUSED(n);

    call.kind = PSI_HOST_OP_SESSION_MESSAGE_COUNT;
    call.input_text = NULL;
    status = psi_host_call(psi_current_host, &call);
    if (status != PSI_STATUS_OK) {
        return sexp_user_exception(ctx, self, "host session-count operation failed", SEXP_FALSE);
    }

    return sexp_make_fixnum((sexp_sint_t)call.output_number);
}

static sexp psi_foreign_read_file(sexp ctx, sexp self, sexp n, sexp path) {
    struct psi_host_call call;
    sexp path_value;
    int status;

    PSI_UNUSED(n);

    if (!sexp_stringp(path)) {
        return sexp_type_exception(ctx, self, SEXP_STRING, path);
    }

    call.kind = PSI_HOST_OP_READ_FILE;
    call.input_text = psi_strdup_n(sexp_string_data(path), (size_t)sexp_string_size(path));
    if (call.input_text == NULL) {
        return sexp_user_exception(ctx, self, "out of memory while preparing file path", path);
    }

    path_value = sexp_c_string(ctx, call.input_text, -1);
    status = psi_host_call(psi_current_host, &call);
    free((char *)call.input_text);
    if (status != PSI_STATUS_OK || call.output_text == NULL) {
        return sexp_file_exception(ctx, self, "host read-file operation failed", path_value);
    }

    path_value = sexp_c_string(ctx, call.output_text, -1);
    free(call.output_text);
    return path_value;
}

static sexp psi_vm_make_alist_entry(sexp ctx, const char *key, sexp value) {
    return sexp_cons(ctx, sexp_intern(ctx, key, -1), value);
}

static char *psi_vm_symbol_name_copy(sexp ctx, sexp symbol) {
    sexp string_value;

    string_value = sexp_symbol_to_string(ctx, symbol);
    if (!sexp_stringp(string_value)) {
        return NULL;
    }
    return psi_strdup_n(sexp_string_data(string_value), (size_t)sexp_string_size(string_value));
}

static int psi_vm_is_alist(sexp value) {
    sexp rest;

    if (!sexp_pairp(value)) {
        return 0;
    }

    rest = value;
    while (sexp_pairp(rest)) {
        sexp entry;
        sexp key;

        entry = sexp_car(rest);
        if (!sexp_pairp(entry)) {
            return 0;
        }
        key = sexp_car(entry);
        if (!sexp_symbolp(key) && !sexp_stringp(key)) {
            return 0;
        }
        rest = sexp_cdr(rest);
    }

    return rest == SEXP_NULL;
}

static cJSON *psi_vm_sexp_to_cjson(sexp ctx, sexp value) {
    cJSON *node;
    sexp rest;

    if (value == SEXP_NULL) {
        return cJSON_CreateArray();
    }
    if (sexp_stringp(value)) {
        char *copy;
        cJSON *string_json;

        copy = psi_strdup_n(sexp_string_data(value), (size_t)sexp_string_size(value));
        if (copy == NULL) {
            return NULL;
        }
        string_json = cJSON_CreateString(copy);
        free(copy);
        return string_json;
    }
    if (sexp_booleanp(value)) {
        return cJSON_CreateBool(value == SEXP_TRUE ? 1 : 0);
    }
    if (sexp_fixnump(value)) {
        return cJSON_CreateNumber((double)sexp_unbox_fixnum(value));
    }
    if (sexp_flonump(value)) {
        return cJSON_CreateNumber((double)sexp_flonum_value(value));
    }
    if (sexp_symbolp(value)) {
        char *key_name;
        cJSON *symbol_json;

        key_name = psi_vm_symbol_name_copy(ctx, value);
        if (key_name == NULL) {
            return NULL;
        }
        symbol_json = cJSON_CreateString(key_name);
        free(key_name);
        return symbol_json;
    }
    if (sexp_pairp(value)) {
        if (psi_vm_is_alist(value)) {
            cJSON *object;

            object = cJSON_CreateObject();
            if (object == NULL) {
                return NULL;
            }
            rest = value;
            while (sexp_pairp(rest)) {
                sexp entry;
                sexp key;
                sexp item_value;
                char *key_name;
                cJSON *item_json;

                entry = sexp_car(rest);
                key = sexp_car(entry);
                item_value = sexp_cdr(entry);
                key_name = sexp_symbolp(key) ? psi_vm_symbol_name_copy(ctx, key) :
                    psi_strdup_n(sexp_string_data(key), (size_t)sexp_string_size(key));
                item_json = psi_vm_sexp_to_cjson(ctx, item_value);
                if (key_name == NULL || item_json == NULL) {
                    free(key_name);
                    cJSON_Delete(item_json);
                    cJSON_Delete(object);
                    return NULL;
                }
                cJSON_AddItemToObject(object, key_name, item_json);
                free(key_name);
                rest = sexp_cdr(rest);
            }
            return object;
        }

        node = cJSON_CreateArray();
        if (node == NULL) {
            return NULL;
        }
        rest = value;
        while (sexp_pairp(rest)) {
            cJSON *item_json;

            item_json = psi_vm_sexp_to_cjson(ctx, sexp_car(rest));
            if (item_json == NULL) {
                cJSON_Delete(node);
                return NULL;
            }
            cJSON_AddItemToArray(node, item_json);
            rest = sexp_cdr(rest);
        }
        if (rest != SEXP_NULL) {
            cJSON *tail_json;

            tail_json = psi_vm_sexp_to_cjson(ctx, rest);
            if (tail_json == NULL) {
                cJSON_Delete(node);
                return NULL;
            }
            cJSON_AddItemToArray(node, tail_json);
        }
        return node;
    }

    return cJSON_CreateNull();
}

static sexp psi_vm_cjson_to_sexp(sexp ctx, const cJSON *value) {
    const cJSON *item;
    sexp result;

    if (cJSON_IsObject(value)) {
        result = SEXP_NULL;
        item = value->child;
        while (item != NULL) {
            sexp_push(
                ctx,
                result,
                psi_vm_make_alist_entry(ctx, item->string, psi_vm_cjson_to_sexp(ctx, item))
            );
            item = item->next;
        }
        return result;
    }
    if (cJSON_IsArray(value)) {
        int index;
        int count;

        result = SEXP_NULL;
        count = cJSON_GetArraySize((cJSON *)value);
        for (index = count - 1; index >= 0; index--) {
            sexp_push(ctx, result, psi_vm_cjson_to_sexp(ctx, cJSON_GetArrayItem((cJSON *)value, index)));
        }
        return result;
    }
    if (cJSON_IsString(value) && value->valuestring != NULL) {
        return sexp_c_string(ctx, value->valuestring, -1);
    }
    if (cJSON_IsBool(value)) {
        return cJSON_IsTrue(value) ? SEXP_TRUE : SEXP_FALSE;
    }
    if (cJSON_IsNumber(value)) {
        if (value->valuedouble == (double)((long)value->valuedouble)) {
            return sexp_make_fixnum((sexp_sint_t)((long)value->valuedouble));
        }
        return sexp_make_flonum(ctx, value->valuedouble);
    }
    if (cJSON_IsNull(value)) {
        return SEXP_FALSE;
    }
    return SEXP_FALSE;
}

static sexp psi_foreign_tool_call(sexp ctx, sexp self, sexp n, sexp tool_name, sexp input_value) {
    struct psi_host_call call;
    char *name_copy;
    char *input_copy;
    cJSON *input_json;
    cJSON *output_json;
    sexp result_value;
    int status;

    PSI_UNUSED(n);

    if (!sexp_stringp(tool_name)) {
        return sexp_type_exception(ctx, self, SEXP_STRING, tool_name);
    }

    name_copy = psi_strdup_n(sexp_string_data(tool_name), (size_t)sexp_string_size(tool_name));
    if (sexp_stringp(input_value)) {
        input_json = cJSON_ParseWithLength(sexp_string_data(input_value), (size_t)sexp_string_size(input_value));
    } else {
        input_json = psi_vm_sexp_to_cjson(ctx, input_value);
    }
    if (input_json == NULL) {
        free(name_copy);
        return sexp_user_exception(ctx, self, "invalid structured tool input", input_value);
    }
    input_copy = cJSON_PrintUnformatted(input_json);
    cJSON_Delete(input_json);
    if (name_copy == NULL || input_copy == NULL) {
        free(name_copy);
        free(input_copy);
        return sexp_user_exception(ctx, self, "out of memory while preparing tool call", SEXP_FALSE);
    }

    call.kind = PSI_HOST_OP_TOOL_CALL;
    call.name = name_copy;
    call.input_text = input_copy;
    status = psi_host_call(psi_current_host, &call);
    free(name_copy);
    free(input_copy);
    if (status != PSI_STATUS_OK || call.output_text == NULL) {
        return sexp_user_exception(ctx, self, "host tool-call operation failed", SEXP_FALSE);
    }

    output_json = cJSON_Parse(call.output_text);
    if (output_json == NULL) {
        result_value = sexp_c_string(ctx, call.output_text, -1);
    } else {
        result_value = psi_vm_cjson_to_sexp(ctx, output_json);
        cJSON_Delete(output_json);
    }
    free(call.output_text);
    return result_value;
}

static sexp psi_foreign_current_date(sexp ctx, sexp self, sexp n) {
    char *date_text;
    sexp result;

    PSI_UNUSED(self);
    PSI_UNUSED(n);

    date_text = psi_prompt_current_date();
    if (date_text == NULL) {
        return sexp_user_exception(ctx, self, "failed to get current date", SEXP_FALSE);
    }
    result = sexp_c_string(ctx, date_text, -1);
    free(date_text);
    return result;
}

static sexp psi_foreign_current_working_directory(sexp ctx, sexp self, sexp n) {
    char *cwd;
    sexp result;

    PSI_UNUSED(self);
    PSI_UNUSED(n);

    cwd = psi_prompt_current_working_directory();
    if (cwd == NULL) {
        return sexp_user_exception(ctx, self, "failed to get current working directory", SEXP_FALSE);
    }
    result = sexp_c_string(ctx, cwd, -1);
    free(cwd);
    return result;
}

static sexp psi_foreign_parent_directory(sexp ctx, sexp self, sexp n, sexp path) {
    char *path_copy;
    char *parent;
    sexp result;

    PSI_UNUSED(self);
    PSI_UNUSED(n);

    if (!sexp_stringp(path)) {
        return sexp_type_exception(ctx, self, SEXP_STRING, path);
    }

    path_copy = psi_strdup_n(sexp_string_data(path), (size_t)sexp_string_size(path));
    if (path_copy == NULL) {
        return sexp_user_exception(ctx, self, "out of memory while preparing path", path);
    }
    parent = psi_prompt_parent_directory(path_copy);
    free(path_copy);
    if (parent == NULL) {
        return sexp_user_exception(ctx, self, "failed to get parent directory", SEXP_FALSE);
    }
    result = sexp_c_string(ctx, parent, -1);
    free(parent);
    return result;
}

static sexp psi_foreign_file_exists(sexp ctx, sexp self, sexp n, sexp path) {
    char *path_copy;
    int exists;

    PSI_UNUSED(ctx);
    PSI_UNUSED(self);
    PSI_UNUSED(n);

    if (!sexp_stringp(path)) {
        return sexp_type_exception(ctx, self, SEXP_STRING, path);
    }

    path_copy = psi_strdup_n(sexp_string_data(path), (size_t)sexp_string_size(path));
    if (path_copy == NULL) {
        return sexp_user_exception(ctx, self, "out of memory while preparing path", path);
    }
    exists = psi_prompt_file_exists(path_copy);
    free(path_copy);
    return exists ? SEXP_TRUE : SEXP_FALSE;
}

static sexp psi_foreign_runtime_info(sexp ctx, sexp self, sexp n) {
    static const char *psi_runtime_primitives[] = {
        "psi-version",
        "psi-log",
        "psi-session-message-count",
        "psi-read-file",
        "psi-tool-call",
        "psi-current-date",
        "psi-current-working-directory",
        "psi-parent-directory",
        "psi-file-exists?",
        "psi-runtime-info",
        "psi-session-messages",
        NULL
    };
    char *date_text;
    char *cwd;
    sexp result;
    sexp primitive_names;
    size_t index;

    PSI_UNUSED(self);
    PSI_UNUSED(n);

    date_text = psi_prompt_current_date();
    cwd = psi_prompt_current_working_directory();
    if (date_text == NULL || cwd == NULL) {
        free(date_text);
        free(cwd);
        return sexp_user_exception(ctx, self, "failed to collect runtime info", SEXP_FALSE);
    }

    primitive_names = SEXP_NULL;
    for (index = 0u; psi_runtime_primitives[index] != NULL; index++) {
        sexp_push(ctx, primitive_names, sexp_c_string(ctx, psi_runtime_primitives[index], -1));
    }

    result = SEXP_NULL;
    sexp_push(ctx, result, psi_vm_make_alist_entry(ctx, "primitives", primitive_names));
    sexp_push(
        ctx,
        result,
        psi_vm_make_alist_entry(
            ctx,
            "session-message-count",
            sexp_make_fixnum(
                (sexp_sint_t)(psi_current_host != NULL && psi_current_host->session != NULL ?
                    psi_current_host->session->count : 0u)
            )
        )
    );
    sexp_push(ctx, result, psi_vm_make_alist_entry(ctx, "current-working-directory", sexp_c_string(ctx, cwd, -1)));
    sexp_push(ctx, result, psi_vm_make_alist_entry(ctx, "current-date", sexp_c_string(ctx, date_text, -1)));
    sexp_push(
        ctx,
        result,
        psi_vm_make_alist_entry(
            ctx,
            "boot-file",
            psi_current_host != NULL && psi_current_host->vm != NULL && psi_current_host->vm->boot_file != NULL ?
                sexp_c_string(ctx, psi_current_host->vm->boot_file, -1) :
                SEXP_FALSE
        )
    );
    sexp_push(ctx, result, psi_vm_make_alist_entry(ctx, "version", sexp_c_string(ctx, PSI_VERSION, -1)));

    free(date_text);
    free(cwd);
    return result;
}

static sexp psi_foreign_session_messages(sexp ctx, sexp self, sexp n) {
    struct psi_session *session;
    sexp result;
    sexp entry;
    size_t index;

    PSI_UNUSED(self);
    PSI_UNUSED(n);

    session = psi_current_host != NULL ? psi_current_host->session : NULL;
    if (session == NULL) {
        return SEXP_NULL;
    }

    result = SEXP_NULL;
    for (index = session->count; index > 0u; index--) {
        entry = SEXP_NULL;
        sexp_push(
            ctx,
            entry,
            psi_vm_make_alist_entry(
                ctx,
                "data",
                session->messages[index - 1u].data_json != NULL ?
                    sexp_c_string(ctx, session->messages[index - 1u].data_json, -1) :
                    SEXP_FALSE
            )
        );
        sexp_push(
            ctx,
            entry,
            psi_vm_make_alist_entry(
                ctx,
                "text",
                session->messages[index - 1u].text != NULL ?
                    sexp_c_string(ctx, session->messages[index - 1u].text, -1) :
                    sexp_c_string(ctx, "", -1)
            )
        );
        sexp_push(
            ctx,
            entry,
            psi_vm_make_alist_entry(
                ctx,
                "role",
                sexp_c_string(ctx, psi_message_role_name(session->messages[index - 1u].role), -1)
            )
        );
        sexp_push(ctx, result, entry);
    }

    return result;
}

static sexp psi_foreign_process_run(sexp ctx, sexp self, sexp n, sexp command) {
    char *command_copy;
    char *output_text;
    int exit_status;
    int truncated;
    sexp result;

    PSI_UNUSED(n);

    if (!sexp_stringp(command)) {
        return sexp_type_exception(ctx, self, SEXP_STRING, command);
    }

    command_copy = psi_strdup_n(sexp_string_data(command), (size_t)sexp_string_size(command));
    if (command_copy == NULL) {
        return sexp_user_exception(ctx, self, "out of memory while preparing command", command);
    }

    output_text = NULL;
    exit_status = -1;
    truncated = 0;
    if (psi_process_run_shell(command_copy, &output_text, &exit_status, &truncated) != PSI_STATUS_OK) {
        free(command_copy);
        free(output_text);
        return sexp_user_exception(ctx, self, "failed to run shell command", command);
    }
    free(command_copy);

    result = SEXP_NULL;
    sexp_push(ctx, result, psi_vm_make_alist_entry(ctx, "truncated", truncated ? SEXP_TRUE : SEXP_FALSE));
    sexp_push(ctx, result, psi_vm_make_alist_entry(ctx, "status", sexp_make_fixnum((sexp_sint_t)exit_status)));
    sexp_push(
        ctx,
        result,
        psi_vm_make_alist_entry(ctx, "output", sexp_c_string(ctx, output_text != NULL ? output_text : "", -1))
    );
    free(output_text);
    return result;
}

static sexp psi_foreign_file_write(sexp ctx, sexp self, sexp n, sexp path, sexp content) {
    FILE *file;
    size_t length;

    PSI_UNUSED(n);

    if (!sexp_stringp(path)) {
        return sexp_type_exception(ctx, self, SEXP_STRING, path);
    }
    if (!sexp_stringp(content)) {
        return sexp_type_exception(ctx, self, SEXP_STRING, content);
    }

    length = (size_t)sexp_string_size(content);
    if ((long)length > PSI_VM_FILE_WRITE_MAX_BYTES) {
        return SEXP_FALSE;
    }

    {
        char *path_copy;

        path_copy = psi_strdup_n(sexp_string_data(path), (size_t)sexp_string_size(path));
        if (path_copy == NULL) {
            return sexp_user_exception(ctx, self, "out of memory while preparing path", path);
        }

        file = fopen(path_copy, "wb");
        free(path_copy);
    }
    if (file == NULL) {
        return SEXP_FALSE;
    }

    if (length > 0u && fwrite(sexp_string_data(content), 1u, length, file) != length) {
        fclose(file);
        return SEXP_FALSE;
    }
    if (fclose(file) != 0) {
        return SEXP_FALSE;
    }
    return SEXP_TRUE;
}

static sexp psi_foreign_session_append_bang(sexp ctx, sexp self, sexp n, sexp role, sexp text, sexp data) {
    struct psi_session *session;
    char *role_copy;
    char *text_copy;
    char *data_copy;
    enum psi_message_role role_kind;
    int status;

    PSI_UNUSED(n);

    if (!sexp_stringp(role)) {
        return sexp_type_exception(ctx, self, SEXP_STRING, role);
    }
    if (!sexp_stringp(text)) {
        return sexp_type_exception(ctx, self, SEXP_STRING, text);
    }

    session = psi_current_host != NULL ? psi_current_host->session : NULL;
    if (session == NULL) {
        return SEXP_FALSE;
    }

    role_copy = psi_strdup_n(sexp_string_data(role), (size_t)sexp_string_size(role));
    text_copy = psi_strdup_n(sexp_string_data(text), (size_t)sexp_string_size(text));
    data_copy = sexp_stringp(data)
        ? psi_strdup_n(sexp_string_data(data), (size_t)sexp_string_size(data))
        : NULL;
    if (role_copy == NULL || text_copy == NULL ||
        (sexp_stringp(data) && data_copy == NULL)) {
        free(role_copy);
        free(text_copy);
        free(data_copy);
        return sexp_user_exception(ctx, self, "out of memory while preparing session entry", SEXP_FALSE);
    }

    role_kind = psi_session_role_from_name(role_copy);
    status = psi_session_append_with_data(session, role_kind, text_copy, data_copy);
    free(role_copy);
    free(text_copy);
    free(data_copy);
    return status == PSI_STATUS_OK ? SEXP_TRUE : SEXP_FALSE;
}

static sexp psi_foreign_session_clear_bang(sexp ctx, sexp self, sexp n) {
    struct psi_session *session;

    PSI_UNUSED(ctx);
    PSI_UNUSED(self);
    PSI_UNUSED(n);

    session = psi_current_host != NULL ? psi_current_host->session : NULL;
    if (session == NULL) {
        return SEXP_FALSE;
    }
    return psi_session_clear(session) == PSI_STATUS_OK ? SEXP_TRUE : SEXP_FALSE;
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

static int psi_vm_call_procedure1(struct psi_vm *vm, const char *procedure_name, sexp argument, sexp *value_out) {
    sexp symbol;
    sexp procedure;
    sexp args;
    sexp value;

    if (vm == NULL || procedure_name == NULL || value_out == NULL) {
        return PSI_STATUS_ERROR;
    }

    symbol = sexp_intern(vm->ctx, procedure_name, -1);
    procedure = sexp_env_ref(vm->ctx, vm->env, symbol, SEXP_FALSE);
    if (procedure == SEXP_FALSE) {
        fprintf(stderr, "undefined Scheme procedure: %s\n", procedure_name);
        return PSI_STATUS_ERROR;
    }

    args = sexp_list1(vm->ctx, argument);
    value = sexp_apply(vm->ctx, procedure, args);
    if (sexp_exceptionp(value)) {
        sexp_print_exception(vm->ctx, value, sexp_current_error_port(vm->ctx));
        return PSI_STATUS_ERROR;
    }

    *value_out = value;
    return PSI_STATUS_OK;
}

static int psi_vm_call_procedure2(
    struct psi_vm *vm,
    const char *procedure_name,
    sexp argument1,
    sexp argument2,
    sexp *value_out
) {
    sexp symbol;
    sexp procedure;
    sexp args;
    sexp value;

    if (vm == NULL || procedure_name == NULL || value_out == NULL) {
        return PSI_STATUS_ERROR;
    }

    symbol = sexp_intern(vm->ctx, procedure_name, -1);
    procedure = sexp_env_ref(vm->ctx, vm->env, symbol, SEXP_FALSE);
    if (procedure == SEXP_FALSE) {
        fprintf(stderr, "undefined Scheme procedure: %s\n", procedure_name);
        return PSI_STATUS_ERROR;
    }

    args = sexp_list2(vm->ctx, argument1, argument2);
    value = sexp_apply(vm->ctx, procedure, args);
    if (sexp_exceptionp(value)) {
        sexp_print_exception(vm->ctx, value, sexp_current_error_port(vm->ctx));
        return PSI_STATUS_ERROR;
    }

    *value_out = value;
    return PSI_STATUS_OK;
}

static int psi_vm_call_procedure0(struct psi_vm *vm, const char *procedure_name, sexp *value_out) {
    sexp symbol;
    sexp procedure;
    sexp value;

    if (vm == NULL || procedure_name == NULL || value_out == NULL) {
        return PSI_STATUS_ERROR;
    }

    symbol = sexp_intern(vm->ctx, procedure_name, -1);
    procedure = sexp_env_ref(vm->ctx, vm->env, symbol, SEXP_FALSE);
    if (procedure == SEXP_FALSE) {
        fprintf(stderr, "undefined Scheme procedure: %s\n", procedure_name);
        return PSI_STATUS_ERROR;
    }

    value = sexp_apply(vm->ctx, procedure, SEXP_NULL);
    if (sexp_exceptionp(value)) {
        sexp_print_exception(vm->ctx, value, sexp_current_error_port(vm->ctx));
        return PSI_STATUS_ERROR;
    }

    *value_out = value;
    return PSI_STATUS_OK;
}

static int psi_vm_parse_action_list(
    struct psi_vm *vm,
    sexp value,
    char **action_name,
    char **action_text,
    long *action_number
) {
    sexp payload_value;

    if (action_name == NULL || action_text == NULL || action_number == NULL) {
        return PSI_STATUS_ERROR;
    }

    *action_name = NULL;
    *action_text = NULL;
    *action_number = 0l;

    if (value == SEXP_FALSE) {
        return PSI_STATUS_OK;
    }
    if (!sexp_pairp(value) || !sexp_stringp(sexp_car(value))) {
        fprintf(stderr, "invalid Scheme command result\n");
        return PSI_STATUS_ERROR;
    }

    if (psi_vm_extract_string(vm->ctx, sexp_car(value), action_name) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    if (strcmp(*action_name, "print") == 0) {
        if (!sexp_pairp(sexp_cdr(value)) || !sexp_stringp(sexp_cadr(value))) {
            fprintf(stderr, "invalid Scheme print action\n");
            free(*action_name);
            *action_name = NULL;
            return PSI_STATUS_ERROR;
        }
        payload_value = sexp_cadr(value);
        if (psi_vm_extract_string(vm->ctx, payload_value, action_text) != PSI_STATUS_OK) {
            free(*action_name);
            *action_name = NULL;
            return PSI_STATUS_ERROR;
        }
    } else if (strcmp(*action_name, "compact") == 0) {
        if (!sexp_pairp(sexp_cdr(value)) || !sexp_fixnump(sexp_cadr(value))) {
            fprintf(stderr, "invalid Scheme compact action\n");
            free(*action_name);
            *action_name = NULL;
            return PSI_STATUS_ERROR;
        }
        payload_value = sexp_cadr(value);
        *action_number = (long)sexp_unbox_fixnum(payload_value);
    }

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
    vm->host.session = NULL;
    vm->host.vm = vm;

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
    psi_current_host = &vm->host;

    sexp_define_foreign(vm->ctx, vm->env, "psi-version", 0, psi_foreign_version);
    sexp_define_foreign(vm->ctx, vm->env, "psi-log", 1, psi_foreign_log);
    sexp_define_foreign(vm->ctx, vm->env, "psi-session-message-count", 0, psi_foreign_session_message_count);
    sexp_define_foreign(vm->ctx, vm->env, "psi-read-file", 1, psi_foreign_read_file);
    sexp_define_foreign(vm->ctx, vm->env, "psi-tool-call", 2, psi_foreign_tool_call);
    sexp_define_foreign(vm->ctx, vm->env, "psi-current-date", 0, psi_foreign_current_date);
    sexp_define_foreign(vm->ctx, vm->env, "psi-current-working-directory", 0, psi_foreign_current_working_directory);
    sexp_define_foreign(vm->ctx, vm->env, "psi-parent-directory", 1, psi_foreign_parent_directory);
    sexp_define_foreign(vm->ctx, vm->env, "psi-file-exists?", 1, psi_foreign_file_exists);
    sexp_define_foreign(vm->ctx, vm->env, "psi-runtime-info", 0, psi_foreign_runtime_info);
    sexp_define_foreign(vm->ctx, vm->env, "psi-session-messages", 0, psi_foreign_session_messages);
    sexp_define_foreign(vm->ctx, vm->env, "psi-process-run", 1, psi_foreign_process_run);
    sexp_define_foreign(vm->ctx, vm->env, "psi-file-write", 2, psi_foreign_file_write);
    sexp_define_foreign(vm->ctx, vm->env, "psi-session-append!", 3, psi_foreign_session_append_bang);
    sexp_define_foreign(vm->ctx, vm->env, "psi-session-clear!", 0, psi_foreign_session_clear_bang);

    return psi_vm_load_bootstrap(vm);
}

void psi_vm_destroy(struct psi_vm *vm) {
    if (vm == NULL || vm->ctx == NULL) {
        return;
    }

    sexp_destroy_context(vm->ctx);
    vm->ctx = NULL;
    vm->env = NULL;
    vm->host.session = NULL;
    vm->host.vm = NULL;
    psi_current_host = NULL;
}

void psi_vm_bind_session(struct psi_vm *vm, struct psi_session *session) {
    if (vm == NULL) {
        return;
    }

    vm->host.session = session;
    psi_current_host = &vm->host;
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
    sexp value;

    if (vm == NULL || procedure_name == NULL || output_text == NULL) {
        return PSI_STATUS_ERROR;
    }

    *output_text = NULL;
    if (psi_vm_call_procedure1(
            vm,
            procedure_name,
            sexp_c_string(vm->ctx, argument ? argument : "", -1),
            &value
        ) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    return psi_vm_extract_string(vm->ctx, value, output_text);
}

int psi_vm_call_procedure0_to_string(struct psi_vm *vm, const char *procedure_name, char **output_text) {
    sexp value;

    if (vm == NULL || procedure_name == NULL || output_text == NULL) {
        return PSI_STATUS_ERROR;
    }

    *output_text = NULL;
    if (psi_vm_call_procedure0(vm, procedure_name, &value) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    return psi_vm_extract_string(vm->ctx, value, output_text);
}

int psi_vm_tool_specs_json(struct psi_vm *vm, char **output_json) {
    return psi_vm_active_tool_specs_json(vm, "", output_json);
}

int psi_vm_active_tool_specs_json(struct psi_vm *vm, const char *user_text, char **output_json) {
    sexp value;
    cJSON *json_value;
    cJSON *anthropic_tools;
    cJSON *tool_entry;
    cJSON *filtered_entry;
    cJSON *field;

    if (vm == NULL || output_json == NULL) {
        return PSI_STATUS_ERROR;
    }

    *output_json = NULL;
    if (psi_vm_call_procedure1(
            vm,
            "psi-select-tool-specs",
            sexp_c_string(vm->ctx, user_text != NULL ? user_text : "", -1),
            &value
        ) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    json_value = psi_vm_sexp_to_cjson(vm->ctx, value);
    if (json_value == NULL) {
        return PSI_STATUS_ERROR;
    }

    if (!cJSON_IsArray(json_value)) {
        cJSON_Delete(json_value);
        return PSI_STATUS_ERROR;
    }

    anthropic_tools = cJSON_CreateArray();
    if (anthropic_tools == NULL) {
        cJSON_Delete(json_value);
        return PSI_STATUS_ERROR;
    }

    cJSON_ArrayForEach(tool_entry, json_value) {
        filtered_entry = cJSON_CreateObject();
        if (filtered_entry == NULL) {
            cJSON_Delete(anthropic_tools);
            cJSON_Delete(json_value);
            return PSI_STATUS_ERROR;
        }

        field = cJSON_GetObjectItemCaseSensitive(tool_entry, "name");
        if (field != NULL) {
            cJSON_AddItemToObject(filtered_entry, "name", cJSON_Duplicate(field, 1));
        }
        field = cJSON_GetObjectItemCaseSensitive(tool_entry, "description");
        if (field != NULL) {
            cJSON_AddItemToObject(filtered_entry, "description", cJSON_Duplicate(field, 1));
        }
        field = cJSON_GetObjectItemCaseSensitive(tool_entry, "input_schema");
        if (field != NULL) {
            cJSON_AddItemToObject(filtered_entry, "input_schema", cJSON_Duplicate(field, 1));
        }
        cJSON_AddItemToArray(anthropic_tools, filtered_entry);
    }

    *output_json = cJSON_PrintUnformatted(anthropic_tools);
    cJSON_Delete(anthropic_tools);
    cJSON_Delete(json_value);
    return *output_json != NULL ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

int psi_vm_render_event_json(
    struct psi_vm *vm,
    const char *event_name,
    const char *payload_json,
    char **output_text
) {
    cJSON *payload_root;
    sexp payload_value;
    sexp rendered_value;

    if (vm == NULL || event_name == NULL || output_text == NULL) {
        return PSI_STATUS_ERROR;
    }

    *output_text = NULL;
    if (payload_json == NULL || payload_json[0] == '\0') {
        payload_value = SEXP_NULL;
    } else {
        payload_root = cJSON_Parse(payload_json);
        if (payload_root == NULL) {
            return PSI_STATUS_ERROR;
        }
        payload_value = psi_vm_cjson_to_sexp(vm->ctx, payload_root);
        cJSON_Delete(payload_root);
    }

    if (psi_vm_call_procedure2(
            vm,
            "psi-handle-event",
            sexp_intern(vm->ctx, event_name, -1),
            payload_value,
            &rendered_value
        ) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    if (rendered_value == SEXP_FALSE || rendered_value == SEXP_NULL) {
        *output_text = psi_strdup("");
        return *output_text != NULL ? PSI_STATUS_OK : PSI_STATUS_ERROR;
    }

    return psi_vm_extract_string(vm->ctx, rendered_value, output_text);
}

int psi_vm_parse_command(
    struct psi_vm *vm,
    const char *line,
    char **action_name,
    char **action_text,
    long *action_number
) {
    sexp value;

    if (vm == NULL || line == NULL) {
        return PSI_STATUS_ERROR;
    }
    value = SEXP_FALSE;
    if (psi_vm_call_procedure1(vm, "psi-handle-command-list", sexp_c_string(vm->ctx, line, -1), &value) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }
    return psi_vm_parse_action_list(vm, value, action_name, action_text, action_number);
}

int psi_vm_dispatch_tool_json(
    struct psi_vm *vm,
    const char *tool_name,
    const char *input_json,
    char **output_json
) {
    cJSON *input_root;
    sexp name_sexp;
    sexp input_sexp;
    sexp result_sexp;
    cJSON *result_json;

    if (vm == NULL || tool_name == NULL || output_json == NULL) {
        return PSI_STATUS_ERROR;
    }

    *output_json = NULL;
    input_root = (input_json != NULL && input_json[0] != '\0')
        ? cJSON_Parse(input_json)
        : cJSON_CreateObject();
    if (input_root == NULL) {
        return PSI_STATUS_ERROR;
    }

    name_sexp = sexp_c_string(vm->ctx, tool_name, -1);
    input_sexp = psi_vm_cjson_to_sexp(vm->ctx, input_root);
    cJSON_Delete(input_root);

    if (psi_vm_call_procedure2(
            vm,
            "psi-tool-dispatch-alist",
            name_sexp,
            input_sexp,
            &result_sexp
        ) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    result_json = psi_vm_sexp_to_cjson(vm->ctx, result_sexp);
    if (result_json == NULL) {
        return PSI_STATUS_ERROR;
    }
    *output_json = cJSON_PrintUnformatted(result_json);
    cJSON_Delete(result_json);
    return *output_json != NULL ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

int psi_vm_session_compact(
    struct psi_vm *vm,
    long keep_recent,
    const char *summary_text
) {
    sexp result;

    if (vm == NULL || summary_text == NULL) {
        return PSI_STATUS_ERROR;
    }

    if (psi_vm_call_procedure2(
            vm,
            "psi-session-do-compact",
            sexp_make_fixnum((sexp_sint_t)keep_recent),
            sexp_c_string(vm->ctx, summary_text, -1),
            &result
        ) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }
    return (result == SEXP_FALSE) ? PSI_STATUS_ERROR : PSI_STATUS_OK;
}

int psi_vm_build_compaction_request(
    struct psi_vm *vm,
    long keep_recent,
    char **system_prompt,
    char **user_prompt
) {
    sexp value;

    if (vm == NULL || system_prompt == NULL || user_prompt == NULL) {
        return PSI_STATUS_ERROR;
    }

    *system_prompt = NULL;
    *user_prompt = NULL;
    value = SEXP_FALSE;
    if (psi_vm_call_procedure1(
            vm,
            "psi-build-compaction-request",
            sexp_make_fixnum((sexp_sint_t)keep_recent),
            &value
        ) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    if (!sexp_pairp(value) || !sexp_pairp(sexp_cdr(value)) ||
        !sexp_stringp(sexp_car(value)) || !sexp_stringp(sexp_cadr(value))) {
        fprintf(stderr, "invalid Scheme compaction request\n");
        return PSI_STATUS_ERROR;
    }

    if (psi_vm_extract_string(vm->ctx, sexp_car(value), system_prompt) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }
    if (psi_vm_extract_string(vm->ctx, sexp_cadr(value), user_prompt) != PSI_STATUS_OK) {
        free(*system_prompt);
        *system_prompt = NULL;
        return PSI_STATUS_ERROR;
    }
    return PSI_STATUS_OK;
}
