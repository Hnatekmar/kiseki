package kube

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// fakeKubectl puts a kubectl on PATH that prints stdout, then stderr, then exits
// with code. The CLI shells out to kubectl by design, so the fake is the seam.
func fakeKubectl(t *testing.T, stdout, stderr string, code int) {
	t.Helper()
	dir := t.TempDir()
	script := "#!/bin/sh\ncat <<'OUT'\n" + stdout + "\nOUT\ncat >&2 <<'ERR'\n" + stderr + "\nERR\nexit " + strconv.Itoa(code) + "\n"
	path := filepath.Join(dir, "kubectl")
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake kubectl: %v", err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

const runningPod = `{"items":[{"metadata":{"name":"kiseki-x-abc"},"status":{"phase":"Running"}}]}`
const noPods = `{"items":[]}`

func TestPhaseRunning(t *testing.T) {
	fakeKubectl(t, runningPod, "", 0)
	if got := Phase("kind-test", "kiseki-x", ""); got != "Running" {
		t.Fatalf("Phase = %q, want Running", got)
	}
}

func TestPhaseNoPods(t *testing.T) {
	fakeKubectl(t, noPods, "", 0)
	if got := Phase("kind-test", "kiseki-x", ""); got != "no pods" {
		t.Fatalf("Phase = %q, want %q", got, "no pods")
	}
}

// A context that does not exist must read as unreachable, not as an empty
// environment: the two mean opposite things to whoever is looking at the list.
func TestPhaseUnreachable(t *testing.T) {
	fakeKubectl(t, "", `error: context "gone" does not exist`, 1)
	if got := Phase("gone", "kiseki-x", ""); got != "unreachable" {
		t.Fatalf("Phase = %q, want unreachable", got)
	}
}

func TestGetPodsNames(t *testing.T) {
	fakeKubectl(t, runningPod, "", 0)
	pods, err := GetPods("kind-test", "kiseki-x", "app.kubernetes.io/instance=kiseki-x", "")
	if err != nil {
		t.Fatalf("GetPods: %v", err)
	}
	if len(pods) != 1 || pods[0].Name != "kiseki-x-abc" {
		t.Fatalf("pods = %+v", pods)
	}
}

// The kubeconfig file must reach the child process: a context can live in any
// file on KUBECONFIG, and `list` runs with whatever the caller exported.
func TestGetPodsForwardsKubeconfig(t *testing.T) {
	dir := t.TempDir()
	script := `#!/bin/sh
if [ "$KUBECONFIG" = "` + dir + `/kubeconfig" ]; then
  echo '{"items":[{"metadata":{"name":"p"},"status":{"phase":"Forwarded"}}]}'
  exit 0
fi
echo "wrong KUBECONFIG: $KUBECONFIG" >&2
exit 3
`
	path := filepath.Join(dir, "kubectl")
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake kubectl: %v", err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	if got := Phase("ctx", "ns", filepath.Join(dir, "kubeconfig")); got != "Forwarded" {
		t.Fatalf("Phase = %q, want Forwarded (kubeconfig was not forwarded)", got)
	}
}

// kubectl's first stderr line is the cause; the rest are hints.
func TestGetPodsReportsFirstErrorLine(t *testing.T) {
	fakeKubectl(t, "", "error: the server is unreachable\nhint: check your VPN", 1)
	_, err := GetPods("ctx", "ns", "sel", "")
	if err == nil {
		t.Fatal("expected an error")
	}
	if got := err.Error(); got != "error: the server is unreachable" {
		t.Fatalf("error = %q", got)
	}
}
