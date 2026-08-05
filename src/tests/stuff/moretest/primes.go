package main

import "fmt"

func main() {
	fmt.Println("primes")
	limit := 10000000
	sieve := make([]bool, limit)
	for i := 0; i < limit; i++ {
		sieve[i] = true
	}
	sieve[0] = false
	sieve[1] = false
	for i := 2; i*i < limit; i++ {
		if sieve[i] {
			for j := i * i; j < limit; j += i {
				sieve[j] = false
			}
		}
	}
	total := 0
	for i := 2; i < limit; i++ {
		if sieve[i] {
			total += i
		}
	}
	fmt.Println(total)
}
