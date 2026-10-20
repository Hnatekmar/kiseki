package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// stubPhase answers the cluster question from a table, so `list` runs with no
// cluster, no kubeconfig and no kubectl.
func stubPhase(t *testing.T, answers map[string]string) {
	t.Helper()
	original := phase
	t.Cleanup(func() { phase = original })
	phase = func(contextName, _, _ string) (string, error) {
		if word, ok := answers[contextName]; ok {
			return word, nil
		}
		return "unreachable", fmt.Errorf("context %q: dial tcp: connection refused", contextName)
	}
}

// threeEnvs lays out the state directory `list` reads: two reachable
// environments, one whose context is gone, a stray directory, and one that an
// interrupted create left without a context file.
func threeEnvs(t *testing.T) {
	t.Helper()

	stateRoot := filepath.Join(t.TempDir(), "state", "kiseki")
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

	// Not a directory create ever finished.
	if err := os.MkdirAll(filepath.Join(stateRoot, ".stray"), 0o755); err != nil {
		t.Fatalf("mkdir stray: %v", err)
	}
	half := filepath.Join(stateRoot, "half")
	if err := os.MkdirAll(half, 0o755); err != nil {
		t.Fatalf("mkdir half: %v", err)
	}
	write(t, filepath.Join(half, "port"), "2203")

	t.Setenv("XDG_STATE_HOME", filepath.Dir(stateRoot))
	stubPhase(t, map[string]string{
		"kind-kiseki-test-cluster": "Running",
		"dev-k8s":                  "Pending",
	})
}

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content+"\n"), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// The table is the shape users see. It is asserted whole, because column drift
// is invisible in a passing build and obvious in a terminal. `half` is absent on
// purpose: a port without a context is an interrupted create, not an environment.
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
	stubPhase(t, nil)

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
	if !strings.Contains(errw.String(), "nope") {
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

// Help is not a failure.
func TestListHelp(t *testing.T) {
	var out, errw bytes.Buffer
	if code := runList([]string{"-h"}, &out, &errw); code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}
}

// A port file that is not a number is corrupt state, not an environment with a
// zero port.
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
	if !strings.Contains(errw.String(), "port") {
		t.Fatalf("stderr = %q", errw.String())
	}
}

// "unreachable" is a display word, not a diagnosis: the cause goes to stderr so
// a Forbidden or a bad kubeconfig is distinguishable from a dead cluster, while
// stdout stays exactly the table or the JSON document.
func TestListExplainsUnreachable(t *testing.T) {
	threeEnvs(t)

	var out, errw bytes.Buffer
	if code := runList(nil, &out, &errw); code != 0 {
		t.Fatalf("list exited %d: %s", code, errw.String())
	}
	if !strings.Contains(errw.String(), "connection refused") {
		t.Fatalf("stderr = %q, want the cause", errw.String())
	}
	if !strings.Contains(errw.String(), "missing-ctx") {
		t.Fatalf("stderr = %q, want the context named", errw.String())
	}
	if strings.Contains(out.String(), "connection refused") {
		t.Fatal("the cause leaked onto stdout")
	}

	out.Reset()
	errw.Reset()
	if code := runList([]string{"--json"}, &out, &errw); code != 0 {
		t.Fatalf("list --json exited %d: %s", code, errw.String())
	}
	if !json.Valid(out.Bytes()) {
		t.Fatalf("stdout is not valid JSON: %s", out.String())
	}
}
