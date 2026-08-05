i = 0
while i < 2000:
    j = 0
    print(i)
    while j < 5000:
        l = [j, j + 1, j + 2, j + 3, j + 4]
        l2 = [j * 2, j * 3, j * 4]
        d = {"a": j, "b": l, "c": l2}
        s = str(j)
        j = j + 1
    i = i + 1