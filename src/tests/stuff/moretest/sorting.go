package main

import "fmt"

func main() {
	fmt.Println("sorting")
	arr := make([]int, 150)
	for i := 0; i < 150; i++ {
		arr[i] = 150 - i
	}
	for i := 0; i < 150; i++ {
		for j := i + 1; j < 150; j++ {
			if arr[j] < arr[i] {
				t := arr[i]
				arr[i] = arr[j]
				arr[j] = t
			}
		}
	}
	fmt.Print("[")
	for i, v := range arr {
		if i > 0 {
			fmt.Print(", ")
		}
		fmt.Print(v)
	}
	fmt.Println("]")
}
