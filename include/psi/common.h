#ifndef PSI_COMMON_H
#define PSI_COMMON_H

#include <stddef.h>

#define PSI_VERSION "0.1.0"

#ifndef PSI_SCHEME_BOOT_FILE
#define PSI_SCHEME_BOOT_FILE "scheme/boot.scm"
#endif

#define PSI_UNUSED(x) ((void)(x))

enum psi_status {
    PSI_STATUS_OK = 0,
    PSI_STATUS_ERROR = 1
};

char *psi_strdup(const char *text);
char *psi_strdup_n(const char *text, size_t length);

#endif
