#ifndef PSI_COMMON_H
#define PSI_COMMON_H

#include <stddef.h>

#define PSI_VERSION "0.1.0"

#ifndef PSI_LUA_BOOT_FILE
#define PSI_LUA_BOOT_FILE ""
#endif

#define PSI_UNUSED(x) ((void)(x))
#define PSI_ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))

enum psi_status {
    PSI_STATUS_OK = 0,
    PSI_STATUS_ERROR = 1
};

char *psi_strdup(const char *text);
char *psi_strdup_n(const char *text, size_t length);

#endif
