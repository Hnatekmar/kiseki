// Package kube shells out to kubectl.
//
// The CLI keeps kubectl and helm as child processes rather than adopting
// client-go: five call sites do not justify the dependency tree or the version
// skew, and the contract stays the one users already have on their PATH.
package kube

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// Pod is the part of a pod the CLI reports on.
type Pod struct {
	Name  string
	Phase string
}

// podList is the subset of `kubectl get pods -o json` the CLI needs. Field
// selection beats a jsonpath template here: the Bash version encoded a record
// format into the query and parsed it back with IFS splitting.
type podList struct {
	Items []struct {
		Metadata struct {
			Name string `json:"name"`
		} `json:"metadata"`
		Status struct {
			Phase string `json:"phase"`
		} `json:"status"`
	} `json:"items"`
}

// GetPods lists the pods matching selector in ns. kubeconfig, when set, pins the
// call to the file the environment was created with: a context name alone is
// ambiguous, and a ProxyCommand runs in a shell that inherited nothing.
func GetPods(ctx, ns, selector, kubeconfig string) ([]Pod, error) {
	out, err := kubectl(kubeconfig, "--context", ctx, "get", "pods", "-n", ns, "-l", selector, "-o", "json")
	if err != nil {
		return nil, err
	}

	var list podList
	if err := json.Unmarshal(out, &list); err != nil {
		return nil, fmt.Errorf("cannot parse kubectl output: %w", err)
	}

	pods := make([]Pod, 0, len(list.Items))
	for _, item := range list.Items {
		pods = append(pods, Pod{Name: item.Metadata.Name, Phase: item.Status.Phase})
	}
	return pods, nil
}

// Phase is the single word `kiseki list` prints: the first pod's phase, "no
// pods" when the namespace holds none, or "unreachable" when the context cannot
// be queried.
func Phase(ctx, ns, kubeconfig string) string {
	pods, err := GetPods(ctx, ns, "app.kubernetes.io/instance="+ns, kubeconfig)
	if err != nil {
		return "unreachable"
	}
	if len(pods) == 0 {
		return "no pods"
	}
	return pods[0].Phase
}

// kubectl runs one kubectl command and returns stdout. The first line of stderr
// is what a caller reports: kubectl's later lines are hints that bury the cause.
func kubectl(kubeconfig string, args ...string) ([]byte, error) {
	cmd := exec.Command("kubectl", args...)
	if kubeconfig != "" {
		// Append rather than replace: kubectl also reads the rest of the
		// environment, and KUBECONFIG is a list on many machines.
		cmd.Env = append(os.Environ(), "KUBECONFIG="+kubeconfig)
	}

	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		// kubectl prefixes hints with 'E' or 'W'; the cause is the first line.
		if idx := strings.IndexByte(msg, '\n'); idx >= 0 {
			msg = msg[:idx]
		}
		if msg == "" {
			return nil, err
		}
		return nil, fmt.Errorf("%s", msg)
	}
	return out, nil
}
