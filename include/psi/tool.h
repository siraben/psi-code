#ifndef PSI_TOOL_H
#define PSI_TOOL_H

#include "psi/common.h"

struct psi_tool_definition {
    const char *name;
    const char *description;
    const char *prompt_snippet;
    const char *prompt_guidelines[5];
};

const struct psi_tool_definition *psi_tool_definitions(size_t *count);
int psi_tool_call_json(const char *tool_name, const char *input_json, char **output_json);
int psi_tool_schemas_json(char **output_json);

#endif
