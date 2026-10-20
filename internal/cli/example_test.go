package cli

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"forgejo.srv.hnatekmar.dev/hnatekmar/kiseki/internal/repo"
)

// The committed example is a published artifact: users pass it to
// `kiseki create -f`. It must equal what the generator prints, or the docs and
// the generator drift apart.
func TestExampleMatchesCommittedFile(t *testing.T) {
	root, err := repo.Root()
	if err != nil {
		t.Fatalf("repo root: %v", err)
	}
	want, err := os.ReadFile(filepath.Join(root, "examples", "extraSVC.yaml"))
	if err != nil {
		t.Fatalf("read committed example: %v", err)
	}

	var out, errw bytes.Buffer
	if code := runExample(nil, &out, &errw); code != 0 {
		t.Fatalf("example exited %d: %s", code, errw.String())
	}

	if got := out.String(); got != string(want) {
		t.Fatalf("generated example differs from examples/extraSVC.yaml (%s):\n%s",
			firstLineDiff(got, string(want)), strings.Join(divergingLines(got, string(want)), "\n"))
	}
}

func TestExampleWritesFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "nested", "extraSVC.yaml")

	var out, errw bytes.Buffer
	if code := runExample([]string{"--output", path}, &out, &errw); code != 0 {
		t.Fatalf("example --output exited %d: %s", code, errw.String())
	}

	written, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read written file: %v", err)
	}
	if string(written) != exampleYAML {
		t.Fatal("written file differs from the generator's own output")
	}
	if !strings.Contains(out.String(), "Wrote "+path) {
		t.Fatalf("missing confirmation, got: %q", out.String())
	}
}

func TestExampleRejectsUnknownArgument(t *testing.T) {
	var out, errw bytes.Buffer
	if code := runExample([]string{"--nope"}, &out, &errw); code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}
	if !strings.Contains(errw.String(), "Unknown argument: --nope") {
		t.Fatalf("stderr = %q", errw.String())
	}
}

// firstLineDiff names the line where two texts first differ, so a golden-file
// failure points at the edit instead of dumping both files.
func firstLineDiff(a, b string) string {
	al, bl := strings.Split(a, "\n"), strings.Split(b, "\n")
	for i := 0; i < len(al) && i < len(bl); i++ {
		if al[i] != bl[i] {
			return fmt.Sprintf("line %d", i+1)
		}
	}
	return "end of file"
}

func divergingLines(a, b string) []string {
	al, bl := strings.Split(a, "\n"), strings.Split(b, "\n")
	var out []string
	for i := 0; i < len(al) || i < len(bl); i++ {
		var x, y string
		if i < len(al) {
			x = al[i]
		}
		if i < len(bl) {
			y = bl[i]
		}
		if x != y {
			out = append(out, fmt.Sprintf("line %d\n  got: %q\n want: %q", i+1, x, y))
			if len(out) == 4 {
				out = append(out, "...")
				break
			}
		}
	}
	return out
}
