package main

import "fmt"

func main() {
	fmt.Println("collatz")
	total := 0
	for k := 1; k <= 50000; k++ {
		n := k
		steps := 0
		for n > 1 {
			if n%2 == 0 {
				n = n / 2
			} else {
				n = 3*n + 1
			}
			steps++
		}
		total += steps
	}
	fmt.Println(total)
}
