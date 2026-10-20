// Command kiseki spawns and destroys Kubernetes dev environments.
package main

import (
	"os"

	"forgejo.srv.hnatekmar.dev/hnatekmar/kiseki/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Stdout, os.Stderr, os.Stdin))
}
