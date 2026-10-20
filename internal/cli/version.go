package cli

import (
	"fmt"
	"io"
)

// Stamped at build time: goreleaser passes -X main.version/-X main.commit/
// -X main.date, and main copies them here. A plain `go build` leaves "dev", so a
// version seen in a bug report says whether it came from a release.
var (
	Version = "dev"
	Commit  = "none"
	Date    = "unknown"
)

// runVersion answers the first question asked of a downloaded artifact.
func runVersion(out io.Writer) int {
	fmt.Fprintf(out, "kiseki %s (commit %s, built %s)\n", Version, Commit, Date)
	return 0
}
