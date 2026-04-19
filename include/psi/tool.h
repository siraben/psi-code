#ifndef PSI_TOOL_H
#define PSI_TOOL_H

#include "psi/common.h"

struct psi_host_context;

int psi_tool_call_json(
    struct psi_host_context *host,
    const char *tool_name,
    const char *input_json,
    char **output_json
);

#endif
