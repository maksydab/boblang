#include <stdio.h>
#include <stdlib.h>
int main() {
    printf("primes\n");
    long limit = 10000000L;
    char *sieve = malloc(limit);
    for (long i = 0; i < limit; i++) sieve[i] = 1;
    sieve[0] = sieve[1] = 0;
    for (long i = 2; i * i < limit; i++) {
        if (sieve[i]) {
            for (long j = i * i; j < limit; j += i) sieve[j] = 0;
        }
    }
    long total = 0;
    for (long i = 2; i < limit; i++)
        if (sieve[i]) total += i;
    printf("%ld\n", total);
    free(sieve);
    return 0;
}
