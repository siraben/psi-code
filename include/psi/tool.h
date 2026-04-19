#ifndef PSI_TOOL_H
#define PSI_TOOL_H

#include "psi/common.h"

int psi_tool_call_json(const char *tool_name, const char *input_json, char **output_json);

#endif
