package cli

import (
	"bytes"
	_ "embed"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"

	"forgejo.srv.hnatekmar.dev/hnatekmar/kiseki/internal/repo"
)

// The canonical sidecar example lives next door as YAML rather than pasted into
// Go source: it stays a real .yaml file for editors and linters, and `just lint`
// plus the golden test diff the output against examples/extraSVC.yaml.
//
//go:embed example.yaml
var exampleYAML string

func runExample(args []string, out, errw io.Writer) int {
	fs := newFlagSet("example", "[--output FILE]", errw)
	path := fs.String("output", "", "write the example to FILE instead of stdout")
	fs.StringVar(path, "o", "", "shorthand for --output")
	if code, ok := parseFlags(fs, args, errw); !ok {
		return code
	}

	if *path == "" {
		fmt.Fprint(out, exampleYAML)
		return 0
	}

	if dir := filepath.Dir(*path); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			fmt.Fprintf(errw, "kiseki: %v\n", err)
			return 1
		}
	}
	if err := os.WriteFile(*path, []byte(exampleYAML), 0o644); err != nil {
		fmt.Fprintf(errw, "kiseki: %v\n", err)
		return 1
	}

	// Render the file against the real chart: a sample that does not template is
	// worse than no sample. Helm is optional here, and saying so beats skipping
	// the check silently.
	if _, err := exec.LookPath("helm"); err != nil {
		fmt.Fprintln(errw, "kiseki: helm not found on PATH, skipping the render check")
	} else if code := renderExample(*path, errw); code != 0 {
		return code
	}

	fmt.Fprintf(out, "Wrote %s\n", *path)
	fmt.Fprintf(out, "Use it with: kiseki create <name> -f %s\n", *path)
	return 0
}

// renderExample templates the written file against the chart. Helm's own output
// is held back on success and printed on failure, where it explains more than a
// summary line can.
func renderExample(path string, errw io.Writer) int {
	chart, err := repo.ChartDir()
	if err != nil {
		fmt.Fprintf(errw, "kiseki: %v\n", err)
		return 1
	}

	cmd := exec.Command("helm", "template", "kiseki-example", chart,
		"--set", "ssh.authorizedKey=example", "-f", path)
	var helmOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &helmOut, errw

	if err := cmd.Run(); err != nil {
		fmt.Fprintf(errw, "kiseki: generated file does not render: %s\n", path)
		if helmOut.Len() > 0 {
			fmt.Fprint(errw, helmOut.String())
		}
		return 1
	}
	return 0
}
