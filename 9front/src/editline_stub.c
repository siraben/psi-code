/* fgets-based readline fallback. No history, no line-editing —
 * plenty for scripted --agent runs and good enough for a basic REPL
 * inside rio. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
    return buf;
}

void
add_history(const char *line)
{
    (void)line;
}
