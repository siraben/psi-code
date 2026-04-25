/* HTTP POST on top of 9front webfs(4), APE-POSIX flavour.
 *
 * Replaces src/core/anthropic.c (libcurl). webfs handles TLS + the
 * HTTP state machine; we just pipe bytes through the /mnt/web/N files.
 *
 * Abort: checked between chunks. webfs has no curl-style xferinfo
 * callback, but closing the body fd cancels the transfer.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "psi/abort.h"
#include "psi/anthropic.h"
#include "psi/common.h"

static int
write_all(int fd, const char *buf, size_t n)
{
    size_t off = 0;
    while (off < n) {
        long w = write(fd, buf + off, n - off);
        if (w <= 0) return -1;
        off += (size_t)w;
    }
    return 0;
}

static int
writestr_path(const char *path, const char *s, size_t n)
{
    int fd = open(path, O_WRONLY);
    if (fd < 0) return -1;
    if (write_all(fd, s, n) < 0) { close(fd); return -1; }
    close(fd);
    return 0;
}

static int
ctl_setf(const char *connroot, const char *fmt, ...)
{
    char path[128], line[1024];
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    if (n <= 0 || (size_t)n >= sizeof line - 1) return -1;
    if (line[n - 1] != '\n') { line[n++] = '\n'; line[n] = 0; }
    snprintf(path, sizeof path, "%s/ctl", connroot);
    return writestr_path(path, line, (size_t)n);
}

static int
webfs_clone(int *clonefd_out, char *numbuf, size_t numsz)
{
    int fd;
    long n;
    fd = open("/mnt/web/clone", O_RDWR);
    if (fd < 0) return -1;
    n = read(fd, numbuf, numsz - 1);
    if (n <= 0) { close(fd); return -1; }
    numbuf[n] = 0;
    while (n > 0 && (numbuf[n-1] == '\n' || numbuf[n-1] == ' '))
        numbuf[--n] = 0;
    *clonefd_out = fd;
    return 0;
}

static int
webfs_prepare(
    const char *url,
    const char *const *headers, size_t header_count,
    const char *body, size_t body_len,
    char *connroot, size_t connroot_sz, int *clonefd_out)
{
    char numbuf[32], path[128];
    size_t i;

    if (webfs_clone(clonefd_out, numbuf, sizeof numbuf) < 0) return -1;
    snprintf(connroot, connroot_sz, "/mnt/web/%s", numbuf);

    if (ctl_setf(connroot, "url %s", url) < 0) goto fail;
    if (ctl_setf(connroot, "contenttype application/json") < 0) goto fail;
    if (ctl_setf(connroot, "request POST") < 0) goto fail;
    for (i = 0; i < header_count; i++) {
        if (ctl_setf(connroot, "headers %s", headers[i]) < 0) goto fail;
    }
    if (body != NULL && body_len > 0) {
        snprintf(path, sizeof path, "%s/postbody", connroot);
        if (writestr_path(path, body, body_len) < 0) goto fail;
    }
    return 0;
fail:
    close(*clonefd_out);
    *clonefd_out = -1;
    return -1;
}

/* 9front webfs(4) signals HTTP status out-of-band: opening
 * /mnt/web/N/body succeeds on 2xx (status 200 assumed for our
 * purposes), and fails with the HTTP status line embedded in the
 * errno string on 4xx/5xx. This differs from Plan-9-from-Bell-Labs
 * webfs which had a /status file; 9front does not.
 *
 * If open succeeded, return 200. If it failed, the caller reads the
 * HTTP status out of the last error description via errstr() — see
 * webfs_parse_errno_status below. */

static long
webfs_parse_errno_status(void)
{
    /* strerror(errno) on 9front APE surfaces the Plan 9 errstr, which
     * for a webfs body-open failure looks like "500 Internal Server
     * Error" or similar. Parse the leading integer. */
    const char *s = strerror(errno);
    char *end;
    long v;
    if (s == NULL) return 0;
    v = strtol(s, &end, 10);
    return (end > s) ? v : 0;
}

int
psi_http_post(
    const char *url,
    const char *const *header_lines, size_t header_count,
    const char *body, size_t body_len,
    const struct psi_abort_signal *abort_signal,
    long *status_code, char **response_body)
{
    char connroot[64], path[128];
    int clonefd, fd;
    char *buf = NULL;
    size_t cap = 0, len = 0;

    if (status_code != NULL) *status_code = 0;
    if (response_body != NULL) *response_body = NULL;

    if (webfs_prepare(url, header_lines, header_count, body, body_len,
                      connroot, sizeof connroot, &clonefd) < 0)
        return PSI_STATUS_ERROR;

    snprintf(path, sizeof path, "%s/body", connroot);
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        /* Body open failure — extract HTTP status from errno string. */
        if (status_code != NULL) *status_code = webfs_parse_errno_status();
        close(clonefd);
        return PSI_STATUS_ERROR;
    }
    /* Body open succeeded — webfs only gets here on 2xx. */
    if (status_code != NULL) *status_code = 200;
    for (;;) {
        long n;
        if (psi_abort_signal_is_triggered(abort_signal)) {
            free(buf);
            close(fd); close(clonefd);
            return PSI_STATUS_ERROR;
        }
        if (len + 8192 + 1 > cap) {
            size_t ncap = cap == 0 ? 16384 : cap * 2;
            char *nb = (char *)realloc(buf, ncap);
            if (nb == NULL) { free(buf); close(fd); close(clonefd); return PSI_STATUS_ERROR; }
            buf = nb; cap = ncap;
        }
        n = read(fd, buf + len, cap - len - 1);
        if (n <= 0) break;
        len += (size_t)n;
    }
    close(fd);
    if (buf != NULL) buf[len] = 0;
    close(clonefd);
    if (response_body != NULL) {
        *response_body = buf != NULL ? buf : psi_strdup("");
    } else {
        free(buf);
    }
    return PSI_STATUS_OK;
}

int
psi_http_post_stream(
    const char *url,
    const char *const *header_lines, size_t header_count,
    const char *body, size_t body_len,
    psi_http_chunk_cb on_chunk, void *userdata,
    const struct psi_abort_signal *abort_signal,
    long *status_code)
{
    char connroot[64], path[128], buf[8192];
    int clonefd, fd;

    if (status_code != NULL) *status_code = 0;
    if (webfs_prepare(url, header_lines, header_count, body, body_len,
                      connroot, sizeof connroot, &clonefd) < 0)
        return PSI_STATUS_ERROR;

    snprintf(path, sizeof path, "%s/body", connroot);
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        if (status_code != NULL) *status_code = webfs_parse_errno_status();
        close(clonefd);
        return PSI_STATUS_ERROR;
    }
    if (status_code != NULL) *status_code = 200;
    for (;;) {
        long n;
        if (psi_abort_signal_is_triggered(abort_signal)) {
            close(fd); close(clonefd);
            return PSI_STATUS_ERROR;
        }
        n = read(fd, buf, sizeof buf);
        if (n <= 0) break;
        if (on_chunk != NULL) on_chunk(userdata, buf, (size_t)n);
    }
    close(fd);
    close(clonefd);
    return PSI_STATUS_OK;
}
