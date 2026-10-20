// Package kube reads cluster state through client-go.
//
// Reads go through the typed client rather than `kubectl -o json`. Three reasons,
// in order of weight: the client takes a context, so an API server that accepts
// a connection and never answers cannot hang `kiseki list`; it removes kubectl
// and its JSON formatting from the read path, so a parse failure is no longer
// indistinguishable from a dead cluster; and pinning the kubeconfig file becomes
// a field on the loading rules instead of an environment variable spliced into a
// child process.
//
// Helm stays a child process. It is a release tool, not an API client, and the
// Bash `create`/`destroy` paths still drive both helm and kubectl.
package kube

import (
	"context"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

// Timeout bounds one cluster question. It is deliberately short: `list` asks
// once per environment, and a context behind a dead VPN should read as
// unreachable in seconds rather than holding up the rows after it.
const Timeout = 5 * time.Second

// Pod is the part of a pod the CLI reports on.
type Pod struct {
	Name  string
	Phase string
}

// GetPods lists the pods matching selector in ns.
func GetPods(ctx context.Context, contextName, ns, selector, kubeconfig string) ([]Pod, error) {
	cs, err := client(contextName, kubeconfig)
	if err != nil {
		return nil, err
	}
	return listPods(ctx, cs, ns, selector)
}

// Phase is the word `kiseki list` prints for one environment, plus the reason
// when the word is "unreachable". Returning the error matters: an RBAC Forbidden
// on a healthy cluster and an expired credential both read as "unreachable", and
// without the cause the operator chases the wrong problem.
func Phase(contextName, ns, kubeconfig string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), Timeout)
	defer cancel()

	pods, err := GetPods(ctx, contextName, ns, "app.kubernetes.io/instance="+ns, kubeconfig)
	return phaseWord(pods, err), err
}

// listPods takes a client, not a kubeconfig, so tests can pass client-go's fake
// and run without a cluster.
func listPods(ctx context.Context, cs kubernetes.Interface, ns, selector string) ([]Pod, error) {
	list, err := cs.CoreV1().Pods(ns).List(ctx, metav1.ListOptions{LabelSelector: selector})
	if err != nil {
		return nil, err
	}

	pods := make([]Pod, 0, len(list.Items))
	for _, item := range list.Items {
		pods = append(pods, Pod{Name: item.Name, Phase: string(item.Status.Phase)})
	}
	return pods, nil
}

// phaseWord is the status column: the first pod's phase, "no pods" when the
// namespace holds none, or "unreachable" for any failure.
func phaseWord(pods []Pod, err error) string {
	switch {
	case err != nil:
		return "unreachable"
	case len(pods) == 0:
		return "no pods"
	default:
		return pods[0].Phase
	}
}

// client is pinned to the kubeconfig the environment was created with: a context
// name alone is ambiguous, because it can live in any file named by KUBECONFIG.
func client(contextName, kubeconfig string) (kubernetes.Interface, error) {
	rules := clientcmd.NewDefaultClientConfigLoadingRules()
	if kubeconfig != "" {
		rules.ExplicitPath = kubeconfig
	}

	// Errors are returned unwrapped: clientcmd already names the context, and the
	// caller adds it when printing ("kiseki: <context>: ...") without repeating it.
	cfg, err := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		rules,
		&clientcmd.ConfigOverrides{CurrentContext: contextName},
	).ClientConfig()
	if err != nil {
		return nil, err
	}

	return kubernetes.NewForConfig(cfg)
}
