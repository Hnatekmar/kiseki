// Command kiseki spawns and destroys Kubernetes dev environments.
package main

import (
	"os"

	"forgejo.srv.hnatekmar.dev/hnatekmar/kiseki/internal/cli"
)

// Set by -ldflags at release time; "dev" marks a plain `go build`.
var (
	version = "dev"
	commit  = "none"
	date    = "unknown"
)

func main() {
	cli.Version, cli.Commit, cli.Date = version, commit, date
	os.Exit(cli.Run(os.Args[1:], os.Stdout, os.Stderr, os.Stdin))
}
