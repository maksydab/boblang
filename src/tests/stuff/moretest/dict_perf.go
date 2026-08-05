package main

import "fmt"

func main() {
    fmt.Println("dict_perf")
    d := make(map[int]int)
    s := 0
    for i := 0; i < 10000; i++ {
        d[i] = i * 2
    }
    for i := 0; i < 10000; i++ {
        s += d[i]
    }
    fmt.Println(s)
}
