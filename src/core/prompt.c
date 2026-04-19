#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#ifdef _WIN32
#include <direct.h>
#define psi_getcwd _getcwd
#else
#include <unistd.h>
#define psi_getcwd getcwd
#endif
#include "psi/prompt.h"
#include "psi/common.h"

char *psi_prompt_current_working_directory(void) {
    size_t size;
    char *buffer;

    size = 256u;
    for (;;) {
        buffer = (char *)malloc(size);
        if (buffer == NULL) {
            return NULL;
        }

        if (psi_getcwd(buffer, (int)size) != NULL) {
            return buffer;
        }

        free(buffer);
        if (size >= 8192u) {
            break;
        }
        size *= 2u;
    }

    return psi_strdup(".");
}

char *psi_prompt_current_date(void) {
    char buffer[32];
    time_t now_value;
    struct tm *local_time;

    now_value = time(NULL);
    local_time = localtime(&now_value);
    if (local_time == NULL) {
        return NULL;
    }

    sprintf(
        buffer,
        "%04d-%02d-%02d",
        local_time->tm_year + 1900,
        local_time->tm_mon + 1,
        local_time->tm_mday
    );
    return psi_strdup(buffer);
}

char *psi_prompt_parent_directory(const char *path) {
    char *copy;
    char *slash;

    copy = psi_strdup(path);
    if (copy == NULL) {
        return NULL;
    }

    slash = strrchr(copy, '/');
    if (slash == NULL) {
        free(copy);
        return psi_strdup(".");
    }

    if (slash == copy) {
        slash[1] = '\0';
    } else {
        *slash = '\0';
    }

    return copy;
}

int psi_prompt_file_exists(const char *path) {
    struct stat stat_buffer;

    if (path == NULL || path[0] == '\0') {
        return 0;
    }
    return stat(path, &stat_buffer) == 0 ? 1 : 0;
}
