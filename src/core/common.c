#include <stdlib.h>
#include <string.h>
#include "psi/common.h"

char *psi_strdup(const char *text) {
    return psi_strdup_n(text, text ? strlen(text) : 0u);
}

char *psi_strdup_n(const char *text, size_t length) {
    char *copy;

    if (text == NULL) {
        copy = (char *)malloc(1u);
        if (copy != NULL) {
            copy[0] = '\0';
        }
        return copy;
    }

    copy = (char *)malloc(length + 1u);
    if (copy == NULL) {
        return NULL;
    }

    if (length > 0u) {
        memcpy(copy, text, length);
    }
    copy[length] = '\0';
    return copy;
}
