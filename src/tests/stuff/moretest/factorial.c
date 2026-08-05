#include <stdio.h>
int main() {
    printf("factorial\n");
    long long n = 20, r = 1;
    while (n > 0) { r = r * n; n = n - 1; }
    printf("%lld\n", r);
    return 0;
}
