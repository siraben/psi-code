#ifndef PSI_PROMPT_H
#define PSI_PROMPT_H

#include "psi/common.h"

char *psi_prompt_current_date(void);
char *psi_prompt_current_working_directory(void);
char *psi_prompt_parent_directory(const char *path);
int psi_prompt_file_exists(const char *path);

#endif
