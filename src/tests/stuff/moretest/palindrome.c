#include <stdio.h>
#include <string.h>
int main() {
    printf("palindrome\n");
    const char *s = "amanaplanacanalpanama";
    int i = 0, j = strlen(s) - 1, is_pal = 1;
    while (i < j) { if (s[i] != s[j]) { is_pal = 0; break; } i++; j--; }
    printf("%s\n", is_pal ? "True" : "False");
    return 0;
}
