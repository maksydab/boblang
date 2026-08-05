package main

import "fmt"

func main() {
	fmt.Println("gcd")
	a := 123456789012
	b := 987654321098
	for b != 0 {
		t := b
		b = a % b
		a = t
	}
	fmt.Println(a)
}
