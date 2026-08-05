#include <stdio.h>
int main() {
    printf("sorting\n[");
    int arr[150];
    for (int i = 0; i < 150; i++) arr[i] = 150 - i;
    for (int i = 0; i < 150; i++)
        for (int j = i + 1; j < 150; j++)
            if (arr[j] < arr[i]) { int t = arr[i]; arr[i] = arr[j]; arr[j] = t; }
    for (int i = 0; i < 150; i++) {
        if (i > 0) printf(", ");
        printf("%d", arr[i]);
    }
    printf("]\n");
    return 0;
}
