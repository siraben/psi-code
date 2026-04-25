/* Minimal AmigaDOS hello world. Uses ANSI C stdio that vbcc's
 * minstart libc maps to dos.library Write() under the hood. */

#include <stdio.h>

int main(void)
{
    printf("hello from psi on m68k AmigaOS!\n");
    return 0;
}
