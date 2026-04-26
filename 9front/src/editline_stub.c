/* Plan 9 readline replacement. libedit isn't available under APE, and
 * on a rio/vt terminal we don't need it: rio already provides
 * line-at-a-time editing (mouse select + snarf/paste via B2 menu,
 * arrow keys for character motion, B3 menu for history of past
 * terminal commands from scrollback). That makes the Plan-9-idiomatic
 * readline a thin fgets wrapper.
 *
 * History:
 *   libedit's C-p recall is a terminal-mode feature rio doesn't do.
 *   As a consolation, every non-empty line is appended to
 *   $home/lib/psi-history so `cat $home/lib/psi-history | grep foo`
 *   still works. Path is overridable via $PSI_HISTORY_FILE.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void
append_history(const char *line)
{
    const char *path;
    FILE *f;
    if (line == NULL || line[0] == '\0') return;
    path = getenv("PSI_HISTORY_FILE");
    if (path == NULL || path[0] == '\0') {
        static char fallback[512];
        const char *home = getenv("home");
        if (home == NULL || home[0] == '\0') home = getenv("HOME");
        if (home == NULL || home[0] == '\0') return;
        snprintf(fallback, sizeof fallback, "%s/lib/psi-history", home);
        path = fallback;
    }
    f = fopen(path, "a");
    if (f == NULL) return;
    fputs(line, f);
    fputc('\n', f);
    fclose(f);
}

char *
readline(const char *prompt)
{
    char *buf;
    size_t cap = 0, len = 0;
    int c;

    if (prompt != NULL) {
        fputs(prompt, stdout);
        fflush(stdout);
    }
    buf = NULL;
    for (;;) {
        c = getchar();
        if (c == EOF) {
            if (len == 0) { free(buf); return NULL; }
            break;
        }
        if (c == '\n') break;
        if (len + 2 > cap) {
            size_t ncap = cap == 0 ? 128 : cap * 2;
            char *nb = (char *)realloc(buf, ncap);
            if (nb == NULL) { free(buf); return NULL; }
            buf = nb; cap = ncap;
        }
        buf[len++] = (char)c;
    }
    if (buf == NULL) buf = (char *)malloc(1);
    if (buf != NULL) buf[len] = '\0';
    append_history(buf);
    return buf;
}

void
add_history(const char *line)
{
    /* Our readline() already appends every returned line to the
     * history file; explicit calls are a no-op. */
    (void)line;
}
