/* Minimal AmigaOS echo. Built specifically so vamos has a real
 * AmigaOS-format binary to dispatch when psi tests its spawn path
 * via os.execute / SystemTagList. */

#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    int i;
    for (i = 1; i < argc; i++) {
        fputs(argv[i], stdout);
        if (i + 1 < argc) fputc(' ', stdout);
    }
    fputc('\n', stdout);
    return 0;
}
