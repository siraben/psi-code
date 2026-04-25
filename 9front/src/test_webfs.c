/* Smoke test: POST a JSON to Anthropic via 9front webfs(4). */

#include <u.h>
#include <libc.h>

static int
writestr(const char *path, const char *s)
{
	int fd, n, w;
	fd = open(path, OWRITE);
	if(fd < 0){ fprint(2, "open %s: %r\n", path); return -1; }
	n = strlen(s);
	w = write(fd, s, n);
	close(fd);
	if(w != n){ fprint(2, "short write %s (%d/%d)\n", path, w, n); return -1; }
	return 0;
}

void
main(void)
{
	int clonefd, bodyfd, n;
	char num[32], ctl[64], pb[64], bp[64], statusp[64], buf[4096];
	char *apikey, *body;

	apikey = getenv("ANTHROPIC_API_KEY");
	if(apikey == nil || *apikey == '\0') sysfatal("ANTHROPIC_API_KEY not set");

	clonefd = open("/mnt/web/clone", ORDWR);
	if(clonefd < 0) sysfatal("open clone: %r");
	n = read(clonefd, num, sizeof num - 1);
	if(n <= 0) sysfatal("read clone: %r");
	num[n] = 0;
	while(n > 0 && (num[n-1]=='\n' || num[n-1]==' ')) num[--n] = 0;
	fprint(2, "conn: /mnt/web/%s\n", num);

	snprint(ctl,    sizeof ctl,    "/mnt/web/%s/ctl",      num);
	snprint(pb,     sizeof pb,     "/mnt/web/%s/postbody", num);
	snprint(bp,     sizeof bp,     "/mnt/web/%s/body",     num);
	snprint(statusp,sizeof statusp,"/mnt/web/%s/status",   num);

	/* Configure the request via ctl. */
	if(writestr(ctl, "url https://api.anthropic.com/v1/messages\n") < 0)
		sysfatal("url");
	if(writestr(ctl, "contenttype application/json\n") < 0)
		sysfatal("ctype");
	if(writestr(ctl, "request POST\n") < 0)
		sysfatal("req");
	/* Custom headers via ctl "headers" */
	if(writestr(ctl, "headers anthropic-version: 2023-06-01\n") < 0)
		sysfatal("hdr1");
	snprint(buf, sizeof buf, "headers x-api-key: %s\n", apikey);
	if(writestr(ctl, buf) < 0) sysfatal("hdr2");

	/* Body */
	body =
		"{\"model\":\"claude-haiku-4-5\","
		"\"max_tokens\":32,"
		"\"messages\":[{\"role\":\"user\",\"content\":"
		"\"Reply exactly one word: NINEFRONT\"}]}";
	if(writestr(pb, body) < 0) sysfatal("postbody");

	/* Read body — opening it triggers the POST. */
	bodyfd = open(bp, OREAD);
	if(bodyfd < 0) sysfatal("open body: %r");
	for(;;){
		n = read(bodyfd, buf, sizeof buf - 1);
		if(n <= 0) break;
		write(1, buf, n);
	}
	close(bodyfd);
	print("\n");

	/* status */
	{
		int sfd = open(statusp, OREAD);
		if(sfd >= 0){
			n = read(sfd, buf, sizeof buf - 1);
			if(n > 0){ buf[n]=0; fprint(2, "status: %s", buf); }
			close(sfd);
		}
	}
	close(clonefd);
	exits(nil);
}
