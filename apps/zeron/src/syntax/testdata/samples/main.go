package main

import (
	"fmt"
	"strings"
)

// Shape is an interface.
type Shape interface{ Area() float64 }

type Rect struct {
	W, H float64 `json:"w"`
}

func (r *Rect) Area() float64 { return r.W * r.H }

func main() {
	s := []Shape{&Rect{W: 2, H: 3.5}}
	ch := make(chan int, 1)
	go func() { ch <- len(s) }()
	fmt.Println(strings.ToUpper("hi"), <-ch, nil, true, 'x', 0x1F)
}
