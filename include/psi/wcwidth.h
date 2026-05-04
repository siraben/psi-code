#ifndef PSI_WCWIDTH_H
#define PSI_WCWIDTH_H

/*
 * psi_wcwidth: number of terminal cells a Unicode codepoint occupies.
 *
 *   -1   non-printable / control
 *    0   combining mark / zero-width / format control
 *    1   ordinary single-width character
 *    2   East Asian Wide / Fullwidth / common emoji
 *
 * Backed by Markus Kuhn's public-domain mk_wcwidth implementation
 * (see src/core/wcwidth.c). Pure C89, no allocation, no globals, no
 * locale dependency. Suitable for any target the rest of psi runs on.
 */
int psi_wcwidth(int cp);

#endif /* PSI_WCWIDTH_H */
