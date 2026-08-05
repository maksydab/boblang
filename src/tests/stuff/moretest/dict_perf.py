print("dict_perf")
d = {}
s = 0
for i in range(10000):
    d[i] = i * 2
for i in range(10000):
    s += d[i]
print(s)
