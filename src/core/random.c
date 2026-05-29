#include "psi/random.h"

#include "psi/common.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#ifdef _MSC_VER
#pragma comment(lib, "bcrypt.lib")
#endif
#else
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#endif

int psi_random_bytes(unsigned char *buffer, size_t len) {
#ifdef _WIN32
    if (len == 0u)
        return PSI_STATUS_OK;
    if (BCryptGenRandom(NULL, buffer, (ULONG)len, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0)
        return PSI_STATUS_ERROR;
    return PSI_STATUS_OK;
#else
    int fd;
    size_t off;

    if (len == 0u)
        return PSI_STATUS_OK;
    fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0)
        return PSI_STATUS_ERROR;
    off = 0u;
    while (off < len) {
        ssize_t n;
        n = read(fd, buffer + off, len - off);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            close(fd);
            return PSI_STATUS_ERROR;
        }
        if (n == 0) {
            close(fd);
            return PSI_STATUS_ERROR;
        }
        off += (size_t)n;
    }
    if (close(fd) != 0)
        return PSI_STATUS_ERROR;
    return PSI_STATUS_OK;
#endif
}
