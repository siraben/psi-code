#include <stdio.h>
#include <stdlib.h>
#include "psi/host_ops.h"
#include "psi/session.h"
#include "psi/tool.h"

static const long PSI_HOST_READ_FILE_MAX_BYTES = 262144l;

static int psi_host_read_file(struct psi_host_call *call) {
    FILE *file;
    long size;
    size_t read_size;
    char *buffer;

    if (call->input_text == NULL) {
        return PSI_STATUS_ERROR;
    }

    file = fopen(call->input_text, "rb");
    if (file == NULL) {
        return PSI_STATUS_ERROR;
    }

    if (fseek(file, 0l, SEEK_END) != 0) {
        fclose(file);
        return PSI_STATUS_ERROR;
    }

    size = ftell(file);
    if (size < 0l || size > PSI_HOST_READ_FILE_MAX_BYTES) {
        fclose(file);
        return PSI_STATUS_ERROR;
    }

    if (fseek(file, 0l, SEEK_SET) != 0) {
        fclose(file);
        return PSI_STATUS_ERROR;
    }

    buffer = (char *)malloc((size_t)size + 1u);
    if (buffer == NULL) {
        fclose(file);
        return PSI_STATUS_ERROR;
    }

    read_size = fread(buffer, 1u, (size_t)size, file);
    fclose(file);
    if (read_size != (size_t)size) {
        free(buffer);
        return PSI_STATUS_ERROR;
    }

    buffer[size] = '\0';
    call->output_text = buffer;
    return PSI_STATUS_OK;
}

int psi_host_call(struct psi_host_context *context, struct psi_host_call *call) {
    if (call == NULL) {
        return PSI_STATUS_ERROR;
    }

    call->output_text = NULL;
    call->output_number = 0l;

    switch (call->kind) {
        case PSI_HOST_OP_VERSION:
            call->output_text = psi_strdup(PSI_VERSION);
            return call->output_text != NULL ? PSI_STATUS_OK : PSI_STATUS_ERROR;
        case PSI_HOST_OP_LOG:
            fprintf(stderr, "[psi] %s\n", call->input_text ? call->input_text : "");
            return PSI_STATUS_OK;
        case PSI_HOST_OP_SESSION_MESSAGE_COUNT:
            call->output_number = context != NULL && context->session != NULL ? (long)context->session->count : 0l;
            return PSI_STATUS_OK;
        case PSI_HOST_OP_READ_FILE:
            return psi_host_read_file(call);
        case PSI_HOST_OP_TOOL_CALL:
            return psi_tool_call_json(call->name, call->input_text, &call->output_text);
        default:
            return PSI_STATUS_ERROR;
    }
}
