/* Minimal <err.h> shim for 9front APE — just the bits argtable3's
 * embedded getopt_long needs. */
#ifndef PSI9FRONT_ERR_H
#define PSI9FRONT_ERR_H

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

static void
warnx(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static void
errx(int eval, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(eval);
}

#endif
