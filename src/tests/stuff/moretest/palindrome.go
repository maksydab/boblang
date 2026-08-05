package main

import "fmt"

func main() {
	fmt.Println("palindrome")
	s := "amanaplanacanalpanama"
	i := 0
	j := len(s) - 1
	isPal := true
	for i < j {
		if s[i] != s[j] {
			isPal = false
			break
		}
		i++
		j--
	}
	fmt.Println(isPal)
}
