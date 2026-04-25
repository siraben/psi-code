/* Minimal editline shim for 9front APE (no libedit). */
#ifndef PSI9FRONT_EDITLINE_READLINE_H
#define PSI9FRONT_EDITLINE_READLINE_H

#ifdef __cplusplus
extern "C" {
#endif

char *readline(const char *prompt);
void add_history(const char *line);

#ifdef __cplusplus
}
#endif

#endif
