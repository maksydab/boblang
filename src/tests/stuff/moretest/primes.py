print("primes")
limit = 10000000
sieve = [1] * limit
sieve[0] = 0
sieve[1] = 0
i = 2
while i * i < limit:
    if sieve[i] == 1:
        j = i * i
        while j < limit:
            sieve[j] = 0
            j = j + i
    i = i + 1
total = 0
i = 2
while i < limit:
    if sieve[i] == 1:
        total = total + i
    i = i + 1
print(total)
