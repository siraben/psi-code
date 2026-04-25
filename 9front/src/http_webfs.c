/* HTTP POST on top of 9front webfs(4) — self-contained.
 *
 * Exports:
 *   int psi_http_post(url, headers[], nheaders,
 *                     body, body_len, *status, **resp_body)
 *   int psi_http_post_stream(url, headers[], nheaders,
 *                     body, body_len, cb, userdata, *status)
 *
 * Return 0 on success, -1 on failure.
 */

#include <u.h>
#include <libc.h>

static int
writestr(const char *path, const char *s, long n)
{
	int fd, w;
	fd = open(path, OWRITE);
	if(fd < 0) return -1;
	w = write(fd, s, n);
	close(fd);
	return (w == n) ? 0 : -1;
}

static int
ctl_set(const char *connroot, const char *line)
{
	char path[128], buf[1024];
	long n;
	snprint(path, sizeof path, "%s/ctl", connroot);
	n = strlen(line);
	if(n == 0 || line[n-1] != '\n'){
		if(n + 1 >= (long)sizeof buf) return -1;
		memcpy(buf, line, n); buf[n++] = '\n'; buf[n] = 0;
		return writestr(path, buf, n);
	}
	return writestr(path, line, n);
}

static int
webfs_clone(char *numout, int numsz, int *clonefd_out)
{
	int fd, n;
	fd = open("/mnt/web/clone", ORDWR);
	if(fd < 0) return -1;
	n = read(fd, numout, numsz - 1);
	if(n <= 0){ close(fd); return -1; }
	numout[n] = 0;
	while(n > 0 && (numout[n-1] == '\n' || numout[n-1] == ' '))
		numout[--n] = 0;
	*clonefd_out = fd;
	return 0;
}

static int
webfs_prepare(
	const char *url,
	const char *const *headers, int header_count,
	const char *body, long body_len,
	char *connroot, int connroot_sz, int *clonefd_out)
{
	char numbuf[32], path[128], line[1024];
	long n;
	int i;

	if(webfs_clone(numbuf, sizeof numbuf, clonefd_out) < 0) return -1;
	snprint(connroot, connroot_sz, "/mnt/web/%s", numbuf);

	snprint(line, sizeof line, "url %s", url);
	if(ctl_set(connroot, line) < 0) goto fail;
	if(ctl_set(connroot, "contenttype application/json") < 0) goto fail;
	if(ctl_set(connroot, "request POST") < 0) goto fail;
	for(i = 0; i < header_count; i++){
		n = snprint(line, sizeof line, "headers %s", headers[i]);
		if(n <= 0 || n >= (long)sizeof line) goto fail;
		if(ctl_set(connroot, line) < 0) goto fail;
	}
	if(body != nil && body_len > 0){
		snprint(path, sizeof path, "%s/postbody", connroot);
		if(writestr(path, body, body_len) < 0) goto fail;
	}
	return 0;
fail:
	close(*clonefd_out);
	*clonefd_out = -1;
	return -1;
}

static long
webfs_status(const char *connroot)
{
	char path[128], buf[256];
	int fd, n;
	snprint(path, sizeof path, "%s/status", connroot);
	fd = open(path, OREAD);
	if(fd < 0) return 0;
	n = read(fd, buf, sizeof buf - 1);
	close(fd);
	if(n <= 0) return 0;
	buf[n] = 0;
	return strtol(buf, nil, 10);
}

int
psi_http_post(
	const char *url,
	const char *const *headers, int nheaders,
	const char *body, int body_len,
	long *status_out, char **resp_out)
{
	char connroot[64], path[128];
	int clonefd, fd, n;
	char *buf = nil;
	long cap = 0, len = 0;

	if(status_out) *status_out = 0;
	if(resp_out)   *resp_out   = nil;

	if(webfs_prepare(url, headers, nheaders, body, body_len,
		connroot, sizeof connroot, &clonefd) < 0)
		return -1;

	snprint(path, sizeof path, "%s/body", connroot);
	fd = open(path, OREAD);
	if(fd < 0){ close(clonefd); return -1; }
	for(;;){
		if(len + 8192 + 1 > cap){
			cap = cap == 0 ? 16384 : cap * 2;
			buf = realloc(buf, cap);
			if(buf == nil){ close(fd); close(clonefd); return -1; }
		}
		n = read(fd, buf + len, cap - len - 1);
		if(n <= 0) break;
		len += n;
	}
	close(fd);
	if(buf) buf[len] = 0;
	if(status_out) *status_out = webfs_status(connroot);
	close(clonefd);
	if(resp_out) *resp_out = buf;
	else free(buf);
	return 0;
}

int
psi_http_post_stream(
	const char *url,
	const char *const *headers, int nheaders,
	const char *body, int body_len,
	void (*cb)(void *, const char *, long), void *userdata,
	long *status_out)
{
	char connroot[64], path[128], buf[8192];
	int clonefd, fd, n;

	if(status_out) *status_out = 0;
	if(webfs_prepare(url, headers, nheaders, body, body_len,
		connroot, sizeof connroot, &clonefd) < 0)
		return -1;
	snprint(path, sizeof path, "%s/body", connroot);
	fd = open(path, OREAD);
	if(fd < 0){ close(clonefd); return -1; }
	for(;;){
		n = read(fd, buf, sizeof buf);
		if(n <= 0) break;
		if(cb) cb(userdata, buf, n);
	}
	close(fd);
	if(status_out) *status_out = webfs_status(connroot);
	close(clonefd);
	return 0;
}
