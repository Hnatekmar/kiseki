package kube

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func pod(name string, phase corev1.PodPhase, instance string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: "kiseki-x",
			Labels:    map[string]string{"app.kubernetes.io/instance": instance},
		},
		Status: corev1.PodStatus{Phase: phase},
	}
}

func TestListPodsFiltersBySelector(t *testing.T) {
	cs := fake.NewClientset(
		pod("mine", corev1.PodRunning, "kiseki-x"),
		pod("other", corev1.PodRunning, "kiseki-y"),
	)

	pods, err := listPods(context.Background(), cs, "kiseki-x", "app.kubernetes.io/instance=kiseki-x")
	if err != nil {
		t.Fatalf("listPods: %v", err)
	}
	if len(pods) != 1 || pods[0].Name != "mine" {
		t.Fatalf("pods = %+v, want only the pod for kiseki-x", pods)
	}
}

func TestPhaseWord(t *testing.T) {
	cases := []struct {
		name string
		pods []Pod
		err  error
		want string
	}{
		{"first pod's phase", []Pod{{Name: "a", Phase: "Pending"}}, nil, "Pending"},
		{"no pods", nil, nil, "no pods"},
		{"unreachable", nil, errors.New("dial tcp: connection refused"), "unreachable"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := phaseWord(tc.pods, tc.err); got != tc.want {
				t.Fatalf("phaseWord = %q, want %q", got, tc.want)
			}
		})
	}
}

// An API server that accepts the connection and never answers used to hang
// `kiseki list` until kubectl gave up, so every environment after it stayed
// unprinted. The deadline is the fix; this test is the proof.
func TestPhaseTimesOutOnAHangingServer(t *testing.T) {
	if testing.Short() {
		t.Skip("waits out the timeout")
	}

	blocked := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-blocked:
		}
	}))
	defer srv.Close()
	defer close(blocked)

	kubeconfig := writeKubeconfig(t, srv.URL)

	start := time.Now()
	got, err := Phase("hang", "kiseki-x", kubeconfig)
	elapsed := time.Since(start)

	if got != "unreachable" {
		t.Fatalf("Phase = %q, want unreachable", got)
	}
	if err == nil {
		t.Fatal("Phase returned no error for a server that never answers")
	}
	if elapsed > Timeout+5*time.Second {
		t.Fatalf("Phase took %s, want it bounded by the %s deadline", elapsed, Timeout)
	}
}

// writeKubeconfig writes a one-context kubeconfig pointing at server.
func writeKubeconfig(t *testing.T, server string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "kubeconfig")
	body := `apiVersion: v1
kind: Config
clusters:
- name: hang
  cluster:
    server: ` + server + `
contexts:
- name: hang
  context:
    cluster: hang
    user: hang
current-context: hang
users:
- name: hang
  user: {}
`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write kubeconfig: %v", err)
	}
	return path
}
