package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// threeEnvs lays out the state directory `list` reads and a kubectl that answers
// for the first two environments and fails for the third.
func threeEnvs(t *testing.T) string {
	t.Helper()

	root := t.TempDir()
	stateRoot := filepath.Join(root, "state", "kiseki")
	for _, env := range []struct{ name, ctx, port, url string }{
		{"alpha", "kind-kiseki-test-cluster", "2200", ""},
		{"beta", "dev-k8s", "2201", "https://beta.dev-k8s.srv.example.com"},
		{"gamma", "missing-ctx", "2202", ""},
	} {
		dir := filepath.Join(stateRoot, env.name)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		write(t, filepath.Join(dir, "port"), env.port)
		write(t, filepath.Join(dir, "context"), env.ctx)
		if env.url != "" {
			write(t, filepath.Join(dir, "url"), env.url)
		}
	}
	// A stray directory is not an environment and must not appear as a row.
	if err := os.MkdirAll(filepath.Join(stateRoot, ".stray"), 0o755); err != nil {
		t.Fatalf("mkdir stray: %v", err)
	}
	t.Setenv("XDG_STATE_HOME", filepath.Join(root, "state"))

	scripts := t.TempDir()
	script := `#!/bin/sh
ns=""
for a in "$@"; do case "$prev" in -n) ns="$a";; esac; prev="$a"; done
case "$ns" in
kiseki-alpha) echo '{"items":[{"metadata":{"name":"pod-1"},"status":{"phase":"Running"}}]}' ;;
kiseki-beta)  echo '{"items":[{"metadata":{"name":"pod-1"},"status":{"phase":"Pending"}}]}' ;;
*)            echo 'error: context does not exist' >&2; exit 1 ;;
esac
`
	if err := os.WriteFile(filepath.Join(scripts, "kubectl"), []byte(script), 0o755); err != nil {
		t.Fatalf("write fake kubectl: %v", err)
	}
	t.Setenv("PATH", scripts+string(os.PathListSeparator)+os.Getenv("PATH"))

	return root
}

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content+"\n"), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// The table is the shape users see. It is asserted whole, because column drift
// is invisible in a passing build and obvious in a terminal.
func TestListTable(t *testing.T) {
	threeEnvs(t)

	want := strings.Join([]string{
		"NAME                 CONTEXT                   PORT     NAMESPACE            PHASE        URL",
		strings.Repeat("-", 100),
		"alpha                kind-kiseki-test-cluster  2200     kiseki-alpha         Running      ",
		"beta                 dev-k8s                   2201     kiseki-beta          Pending      https://beta.dev-k8s.srv.example.com",
		"gamma                missing-ctx               2202     kiseki-gamma         unreachable  ",
		"",
	}, "\n")

	var out, errw bytes.Buffer
	if code := runList(nil, &out, &errw); code != 0 {
		t.Fatalf("list exited %d: %s", code, errw.String())
	}
	if out.String() != want {
		t.Fatalf("table mismatch\n got:\n%s\nwant:\n%s", out.String(), want)
	}
}

// --json is the automation contract. Field order and the fact that port is a
// number are part of it.
func TestListJSON(t *testing.T) {
	threeEnvs(t)

	want := `[{"name":"alpha","context":"kind-kiseki-test-cluster","port":2200,"namespace":"kiseki-alpha","phase":"Running","url":""},` +
		`{"name":"beta","context":"dev-k8s","port":2201,"namespace":"kiseki-beta","phase":"Pending","url":"https://beta.dev-k8s.srv.example.com"},` +
		`{"name":"gamma","context":"missing-ctx","port":2202,"namespace":"kiseki-gamma","phase":"unreachable","url":""}]` + "\n"

	var out, errw bytes.Buffer
	if code := runList([]string{"--json"}, &out, &errw); code != 0 {
		t.Fatalf("list --json exited %d: %s", code, errw.String())
	}
	if out.String() != want {
		t.Fatalf("json mismatch\n got: %s\nwant: %s", out.String(), want)
	}
}

func TestListEmpty(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", filepath.Join(t.TempDir(), "nothing"))

	var out, errw bytes.Buffer
	if code := runList(nil, &out, &errw); code != 0 {
		t.Fatalf("list exited %d: %s", code, errw.String())
	}
	if out.String() != "No environments found.\n" {
		t.Fatalf("got %q", out.String())
	}

	out.Reset()
	if code := runList([]string{"--json"}, &out, &errw); code != 0 {
		t.Fatalf("list --json exited %d: %s", code, errw.String())
	}
	if out.String() != "[]\n" {
		t.Fatalf("got %q", out.String())
	}
}

func TestListRejectsArguments(t *testing.T) {
	var out, errw bytes.Buffer
	if code := runList([]string{"--nope"}, &out, &errw); code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}
	if !strings.Contains(errw.String(), "Unknown flag: --nope") {
		t.Fatalf("stderr = %q", errw.String())
	}

	errw.Reset()
	if code := runList([]string{"extra"}, &out, &errw); code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}
	if !strings.Contains(errw.String(), "Unexpected argument: extra") {
		t.Fatalf("stderr = %q", errw.String())
	}
}

// A state directory whose port file is not a number is corrupt state, not an
// environment with a zero port.
func TestListRejectsCorruptPort(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "state", "kiseki", "broken")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	write(t, filepath.Join(dir, "port"), "not-a-port")
	write(t, filepath.Join(dir, "context"), "ctx")
	t.Setenv("XDG_STATE_HOME", filepath.Join(root, "state"))

	var out, errw bytes.Buffer
	if code := runList(nil, &out, &errw); code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}
	if !strings.Contains(errw.String(), "not a port number") {
		t.Fatalf("stderr = %q", errw.String())
	}
}
