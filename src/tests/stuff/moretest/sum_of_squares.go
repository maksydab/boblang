package main

import "fmt"

func main() {
	fmt.Println("sum_of_squares")
	n := 500000
	s := 0
	for n > 0 {
		s = s + n*n
		n--
	}
	fmt.Println(s)
}
