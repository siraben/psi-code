/* HTTP primitives for 9front: implements psi_http_post_stream and
 * psi_http_post on top of 9front's webfs(4) — /mnt/web/clone +
 * url/headers/contenttype/postbody/body files.
 *
 * psi's C API (include/psi/anthropic.h) is identical across platforms:
 *
 *     int psi_http_post_stream(url, headers[], headerN, body, bodyN,
 *                              on_chunk, userdata, abort_signal, *status);
 *     int psi_http_post(url, headers[], headerN, body, bodyN,
 *                       abort_signal, *status, **response_body);
 *
 * webfs conveniently streams response bodies as they arrive, so SSE
 * works with one design.
 *
 * Error model: return PSI_STATUS_OK on success, PSI_STATUS_ERROR
 * otherwise. *status is the HTTP response code on success (200/400/etc).
 */

#include <u.h>
#include <libc.h>
#include <bio.h>

#include "psi/abort.h"
#include "psi/anthropic.h"
#include "psi/common.h"

/* /mnt/web/clone: open+read → connection number N (decimal string),
 * the working directory /mnt/web/N thereafter carries:
 *    ctl           — commands (unused here; header/postbody files are
 *                    preferred).
 *    url           — write the URL here.
 *    contenttype   — write the MIME type for the request body.
 *    postbody      — write the request body bytes here.
 *    headers       — write one or more "Name: value\n" lines.
 *    body          — read the response body here (may block/stream).
 *    status        — read the HTTP status line when done.
 *    parsed/*      — optional; each response header as a separate file.
 */

#define WEBCLONE    "/mnt/web/clone"
#define WEBSNUM_MAX 32

static int
write_all(int fd, const char *buf, int n)
{
	int w, off = 0;
	while(off < n){
		w = write(fd, buf + off, n - off);
		if(w <= 0) return -1;
		off += w;
	}
	return 0;
}

/* Open /mnt/web/clone and read the connection number into *numout. */
static int
webfs_clone(char *numout, int numsz)
{
	int fd, n;
	fd = open(WEBCLONE, ORDWR);
	if(fd < 0) return -1;
	n = read(fd, numout, numsz - 1);
	if(n <= 0){
		close(fd);
		return -1;
	}
	numout[n] = '\0';
	/* strip trailing newline/space */
	while(n > 0 && (numout[n-1] == '\n' || numout[n-1] == ' '))
		numout[--n] = '\0';
	return fd;  /* keep fd open for the lifetime of the connection */
}

/* Write all of `val` to $connroot/file. */
static int
webfs_set(const char *connroot, const char *file, const char *val, int vlen)
{
	char path[128];
	int fd, r;
	snprint(path, sizeof path, "%s/%s", connroot, file);
	fd = open(path, OWRITE);
	if(fd < 0) return -1;
	r = write_all(fd, val, vlen);
	close(fd);
	return r;
}

/* Set one header line. Each header gets its own write to the
 * "header" file (not "headers"); webfs accumulates. */
static int
webfs_header(const char *connroot, const char *line)
{
	return webfs_set(connroot, "headers", line, strlen(line));
}

/* Read the response status code from $connroot/status. Format:
 *   "200 OK" or "400 Bad Request". First integer is the code. */
static long
webfs_status(const char *connroot)
{
	char path[128], buf[128];
	int fd, n;
	long code = 0;
	snprint(path, sizeof path, "%s/status", connroot);
	fd = open(path, OREAD);
	if(fd < 0) return 0;
	n = read(fd, buf, sizeof buf - 1);
	close(fd);
	if(n <= 0) return 0;
	buf[n] = '\0';
	code = strtol(buf, nil, 10);
	return code;
}

/* Build a connection: clone, set url, headers, contenttype, postbody.
 * Returns connroot in out (caller: size >= 48). Returns 0 on success. */
static int
webfs_prepare(
	const char *url,
	const char *const *headers, size_t header_count,
	const char *body, size_t body_len,
	char *connroot_out, int connroot_sz,
	int *clonefd_out)
{
	char numbuf[WEBSNUM_MAX];
	int clonefd;
	size_t i;

	clonefd = webfs_clone(numbuf, sizeof numbuf);
	if(clonefd < 0) return -1;
	snprint(connroot_out, connroot_sz, "/mnt/web/%s", numbuf);

	if(webfs_set(connroot_out, "url", url, strlen(url)) < 0)
		goto fail;

	/* Anthropic wants JSON; default the content-type. The caller may
	 * override via a header line. */
	if(body != NULL && body_len > 0){
		if(webfs_set(connroot_out, "contenttype",
			"application/json", 16) < 0) goto fail;
	}

	for(i = 0; i < header_count; i++){
		/* Each header line must end with '\n'. */
		char linebuf[512];
		size_t n = strlen(headers[i]);
		if(n + 1 >= sizeof linebuf) goto fail;
		memcpy(linebuf, headers[i], n);
		if(n > 0 && linebuf[n-1] != '\n') linebuf[n++] = '\n';
		linebuf[n] = '\0';
		if(webfs_header(connroot_out, linebuf) < 0) goto fail;
	}

	if(body != NULL && body_len > 0){
		if(webfs_set(connroot_out, "postbody", body, body_len) < 0)
			goto fail;
	}

	*clonefd_out = clonefd;
	return 0;
fail:
	close(clonefd);
	return -1;
}

/* Read $connroot/body until EOF, invoking the user callback per chunk.
 * The abort_signal is polled between reads. */
static int
webfs_stream_body(
	const char *connroot,
	psi_http_chunk_cb cb, void *userdata,
	const struct psi_abort_signal *abort_signal)
{
	char path[128];
	int fd, n;
	char buf[8192];
	snprint(path, sizeof path, "%s/body", connroot);
	fd = open(path, OREAD);
	if(fd < 0) return -1;
	for(;;){
		if(abort_signal && psi_abort_signal_is_triggered(abort_signal))
			break;
		n = read(fd, buf, sizeof buf);
		if(n <= 0) break;
		if(cb) cb(userdata, buf, (size_t)n);
	}
	close(fd);
	return 0;
}

/* Read the whole body into a freshly allocated NUL-terminated string. */
static char *
webfs_read_body(const char *connroot, size_t *outlen)
{
	char path[128];
	int fd, n;
	char *buf = nil;
	size_t cap = 0, len = 0;
	snprint(path, sizeof path, "%s/body", connroot);
	fd = open(path, OREAD);
	if(fd < 0) return nil;
	for(;;){
		if(len + 8192 + 1 > cap){
			cap = (cap == 0) ? 16384 : cap * 2;
			buf = realloc(buf, cap);
			if(buf == nil){ close(fd); return nil; }
		}
		n = read(fd, buf + len, cap - len - 1);
		if(n <= 0) break;
		len += n;
	}
	close(fd);
	if(buf) buf[len] = '\0';
	if(outlen) *outlen = len;
	return buf;
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
	char connroot[48];
	int clonefd, r;

	if(status_code) *status_code = 0;

	if(webfs_prepare(url, header_lines, header_count,
		body, body_len, connroot, sizeof connroot, &clonefd) < 0)
		return PSI_STATUS_ERROR;

	r = webfs_stream_body(connroot, on_chunk, userdata, abort_signal);
	if(status_code) *status_code = webfs_status(connroot);
	close(clonefd);
	return r < 0 ? PSI_STATUS_ERROR : PSI_STATUS_OK;
}

int
psi_http_post(
	const char *url,
	const char *const *header_lines, size_t header_count,
	const char *body, size_t body_len,
	const struct psi_abort_signal *abort_signal,
	long *status_code,
	char **response_body)
{
	char connroot[48];
	int clonefd;
	char *buf;

	USED(abort_signal);
	if(status_code) *status_code = 0;
	if(response_body) *response_body = nil;

	if(webfs_prepare(url, header_lines, header_count,
		body, body_len, connroot, sizeof connroot, &clonefd) < 0)
		return PSI_STATUS_ERROR;

	buf = webfs_read_body(connroot, nil);
	if(status_code) *status_code = webfs_status(connroot);
	close(clonefd);

	if(buf == nil) return PSI_STATUS_ERROR;
	if(response_body) *response_body = buf; else free(buf);
	return PSI_STATUS_OK;
}
