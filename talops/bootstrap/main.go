package main

import (
	"os"

	"github.com/jdwlabs/infrastructure/bootstrap"
)

func main() {
	if err := cmd.Execute(); err != nil {
		os.Exit(1)
	}
}
