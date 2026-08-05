package main

import "fmt"

func main() {
	fmt.Println("factorial")
	n := 20
	r := 1
	for n > 0 {
		r = r * n
		n--
	}
	fmt.Println(r)
}
