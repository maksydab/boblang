#include <stdio.h>
int main() {
    printf("gcd\n");
    long long a = 123456789012, b = 987654321098, t;
    while (b != 0) { t = b; b = a % b; a = t; }
    printf("%lld\n", a);
    return 0;
}
