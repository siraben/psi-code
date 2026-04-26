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

/* Allocate a webfs connection slot via /mnt/web/clone and fill connroot
 * with "/mnt/web/N". The clone fd must stay open for the duration of
 * the request — closing it tears down the slot. */
static int
webfs_clone(int *clonefd_out, char *connroot, size_t connroot_sz)
{
    char numbuf[32];
    long n;
    int fd = open("/mnt/web/clone", O_RDWR);
    if (fd < 0) return -1;
    n = read(fd, numbuf, sizeof numbuf - 1);
    if (n <= 0) { close(fd); return -1; }
    numbuf[n] = 0;
    while (n > 0 && (numbuf[n-1] == '\n' || numbuf[n-1] == ' '))
        numbuf[--n] = 0;
    snprintf(connroot, connroot_sz, "/mnt/web/%s", numbuf);
    *clonefd_out = fd;
    return 0;
}

/* Configure ctl + postbody for a POST request. On failure the caller
 * still owns clonefd and must close it. */
static int
webfs_configure_post(
    const char *connroot,
    const char *url,
    const char *const *headers, size_t header_count,
    const char *body, size_t body_len)
{
    char path[128];
    size_t i;

    if (ctl_setf(connroot, "url %s", url) < 0) return -1;
    if (ctl_setf(connroot, "contenttype application/json") < 0) return -1;
    if (ctl_setf(connroot, "request POST") < 0) return -1;
    for (i = 0; i < header_count; i++) {
        if (ctl_setf(connroot, "headers %s", headers[i]) < 0) return -1;
    }
    if (body != NULL && body_len > 0) {
        snprintf(path, sizeof path, "%s/postbody", connroot);
        if (writestr_path(path, body, body_len) < 0) return -1;
    }
    return 0;
}

/* 9front webfs(4) signals HTTP status out-of-band: opening
 * /mnt/web/N/body succeeds on 2xx, and fails with the HTTP status line
 * embedded in the errno string on 4xx/5xx. This differs from
 * Plan-9-from-Bell-Labs webfs which had a /status file; 9front does
 * not. strerror(errno) on 9front APE surfaces the Plan 9 errstr, which
 * for a body-open failure looks like "500 Internal Server Error". */
static long
webfs_parse_errno_status(void)
{
    const char *s = strerror(errno);
    char *end;
    long v;
    if (s == NULL) return 0;
    v = strtol(s, &end, 10);
    return (end > s) ? v : 0;
}

/* Open the body fd. On success returns 0 and *body_fd is the body fd;
 * *status_code is set to 200. On failure returns -1; *status_code is
 * set to the parsed HTTP status (or 0 if unparseable). The clone fd is
 * left open for the caller in both cases. */
static int
webfs_open_body(const char *connroot, int *body_fd, long *status_code)
{
    char path[128];
    int fd;
    snprintf(path, sizeof path, "%s/body", connroot);
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        if (status_code != NULL) *status_code = webfs_parse_errno_status();
        return -1;
    }
    if (status_code != NULL) *status_code = 200;
    *body_fd = fd;
    return 0;
}

/* Run the POST and open body. Returns 0 on success with bodyfd_out/
 * clonefd_out owned by caller. On failure returns PSI_STATUS_ERROR
 * and *status_code may be set to a parsed HTTP status. */
static int
webfs_post_open(
    const char *url,
    const char *const *headers, size_t header_count,
    const char *body, size_t body_len,
    long *status_code,
    char *connroot, size_t connroot_sz,
    int *clonefd_out, int *bodyfd_out)
{
    if (webfs_clone(clonefd_out, connroot, connroot_sz) < 0)
        return PSI_STATUS_ERROR;
    if (webfs_configure_post(connroot, url, headers, header_count,
                             body, body_len) < 0) {
        close(*clonefd_out);
        return PSI_STATUS_ERROR;
    }
    if (webfs_open_body(connroot, bodyfd_out, status_code) < 0) {
        close(*clonefd_out);
        return PSI_STATUS_ERROR;
    }
    return PSI_STATUS_OK;
}

int
psi_http_post(
    const char *url,
    const char *const *header_lines, size_t header_count,
    const char *body, size_t body_len,
    const struct psi_abort_signal *abort_signal,
    long *status_code, char **response_body)
{
    char connroot[64];
    int clonefd, fd, rc;
    char *buf = NULL;
    size_t cap = 0, len = 0;

    if (status_code != NULL) *status_code = 0;
    if (response_body != NULL) *response_body = NULL;

    rc = webfs_post_open(url, header_lines, header_count, body, body_len,
                         status_code, connroot, sizeof connroot,
                         &clonefd, &fd);
    if (rc != PSI_STATUS_OK) return rc;

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
    close(clonefd);
    if (buf != NULL) buf[len] = 0;
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
    char connroot[64], buf[8192];
    int clonefd, fd, rc;

    if (status_code != NULL) *status_code = 0;

    rc = webfs_post_open(url, header_lines, header_count, body, body_len,
                         status_code, connroot, sizeof connroot,
                         &clonefd, &fd);
    if (rc != PSI_STATUS_OK) return rc;

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
