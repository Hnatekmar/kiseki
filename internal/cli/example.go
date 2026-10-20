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

	dir := filepath.Dir(*path)
	if dir == "" {
		dir = "."
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		fmt.Fprintf(errw, "kiseki: %v\n", err)
		return 1
	}

	// Write next to the target and publish only after the render check: a values
	// file helm rejects must not replace whatever the user already had there.
	tmp, err := os.CreateTemp(dir, ".kiseki-example-*.yaml")
	if err != nil {
		fmt.Fprintf(errw, "kiseki: %v\n", err)
		return 1
	}
	defer os.Remove(tmp.Name()) // no-op once the rename succeeds

	if _, err := tmp.WriteString(exampleYAML); err != nil {
		tmp.Close()
		fmt.Fprintf(errw, "kiseki: %v\n", err)
		return 1
	}
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		fmt.Fprintf(errw, "kiseki: %v\n", err)
		return 1
	}
	if err := tmp.Close(); err != nil {
		fmt.Fprintf(errw, "kiseki: %v\n", err)
		return 1
	}

	// Render the file against the real chart: a sample that does not template is
	// worse than no sample. Helm is optional here, and saying so beats skipping
	// the check silently.
	if _, err := exec.LookPath("helm"); err != nil {
		fmt.Fprintln(errw, "kiseki: helm not found on PATH, skipping the render check")
	} else if code := renderExample(tmp.Name(), errw); code != 0 {
		return code
	}

	if err := os.Rename(tmp.Name(), *path); err != nil {
		fmt.Fprintf(errw, "kiseki: %v\n", err)
		return 1
	}

	fmt.Fprintf(out, "Wrote %s\n", *path)
	fmt.Fprintf(out, "Use it with: kiseki create <name> -f %s\n", *path)
	return 0
}

// renderExample templates the written file against the chart. Both streams are
// captured so a failure reads in the order helm produced it, and nothing is
// printed when the file is good.
func renderExample(path string, errw io.Writer) int {
	chart, err := repo.ChartDir()
	if err != nil {
		fmt.Fprintf(errw, "kiseki: %v\n", err)
		return 1
	}

	cmd := exec.Command("helm", "template", "kiseki-example", chart,
		"--set", "ssh.authorizedKey=example", "-f", path)
	var helmOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &helmOut, &helmOut

	if err := cmd.Run(); err != nil {
		fmt.Fprintf(errw, "kiseki: generated file does not render: %s\n", path)
		if helmOut.Len() > 0 {
			fmt.Fprint(errw, helmOut.String())
		}
		return 1
	}
	return 0
}
