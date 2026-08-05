#include <stdio.h>
int main() {
    printf("collatz\n");
    long long total = 0;
    for (int k = 1; k <= 50000; k++) {
        long long n = k, steps = 0;
        while (n > 1) {
            if (n % 2 == 0) n /= 2;
            else n = 3 * n + 1;
            steps++;
        }
        total += steps;
    }
    printf("%lld\n", total);
    return 0;
}
