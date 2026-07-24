/* SagePTE artifact
 * Minimal example workload: touches a fixed 16 MB region three times. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#define BASE ((void *)0x100000000UL)
#define SIZE (16UL * 1024 * 1024)
#define PASSES 3

int main(void) {
    unsigned char *p = mmap(BASE, SIZE, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (p == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    unsigned long sum = 0;
    for (int pass = 0; pass < PASSES; pass++)
        for (unsigned long off = 0; off < SIZE; off += 4096)
            sum += ++p[off];
    printf("done sum=%lu\n", sum);
    return 0;
}
