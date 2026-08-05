#include <stdio.h>
int main() {
    printf("sum_of_squares\n");
    long long n = 500000, s = 0;
    while (n > 0) { s = s + n * n; n = n - 1; }
    printf("%lld\n", s);
    return 0;
}
