print("collatz")
total = 0
k = 1
while k <= 50000:
    n = k
    steps = 0
    while n > 1:
        if n % 2 == 0:
            n = n // 2
        else:
            n = 3 * n + 1
        steps = steps + 1
    total = total + steps
    k = k + 1
print(total)
