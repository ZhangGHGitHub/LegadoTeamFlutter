#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: helper <prog> [args...]\n"); return 2; }
    if (setresgid(10055, 10055, 10055) != 0) { perror("setresgid"); return 1; }
    if (setresuid(10055, 10055, 10055) != 0) { perror("setresuid"); return 1; }
    execv(argv[1], &argv[1]);
    perror("execv");
    return 1;
}
