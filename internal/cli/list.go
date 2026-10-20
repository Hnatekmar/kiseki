package cli

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"strings"
	"sync"

	"forgejo.srv.hnatekmar.dev/hnatekmar/kiseki/internal/kube"
	"forgejo.srv.hnatekmar.dev/hnatekmar/kiseki/internal/state"
)

// phase is the cluster question each row asks. It is a variable so tests can
// answer it without a cluster; production always uses kube.Phase.
var phase = kube.Phase

// envJSON is the --json shape of one row. The field order matches the Bash
// emitter byte for byte, and it is the only place the shape is written down.
type envJSON struct {
	Name      string `json:"name"`
	Context   string `json:"context"`
	Port      int    `json:"port"`
	Namespace string `json:"namespace"`
	Phase     string `json:"phase"`
	URL       string `json:"url"`
}

type listOptions struct {
	json bool
}

func (o *listOptions) register(fs *flag.FlagSet) {
	fs.BoolVar(&o.json, "json", false, "print one JSON array on stdout")
}

func runList(args []string, out, errw io.Writer) int {
	var opts listOptions
	fs := newFlagSet("list", "[--json]", errw)
	opts.register(fs)
	if code, ok := parseFlags(fs, args, errw); !ok {
		return code
	}

	envs, err := state.LoadAll()
	if err != nil {
		fmt.Fprintf(errw, "kiseki: %v\n", err)
		return 1
	}

	if len(envs) == 0 {
		if opts.json {
			fmt.Fprintln(out, "[]")
		} else {
			fmt.Fprintln(out, "No environments found.")
		}
		return 0
	}

	// One row per environment. Rows are filled concurrently because each one asks
	// a cluster with its own deadline: ten environments behind a dead VPN should
	// cost one deadline, not ten. Writing to a fixed index keeps the output in
	// name order.
	rows := make([]envJSON, len(envs))
	failures := make([]error, len(envs))

	var wg sync.WaitGroup
	for i, env := range envs {
		wg.Add(1)
		go func(i int, env state.Env) {
			defer wg.Done()
			word, err := phase(env.Context, env.Namespace(), env.Kubeconfig)
			rows[i] = envJSON{
				Name:      env.Name,
				Context:   env.Context,
				Port:      env.Port,
				Namespace: env.Namespace(),
				Phase:     word,
				URL:       env.URL,
			}
			failures[i] = err
		}(i, env)
	}
	wg.Wait()

	// The table and the JSON document are the only things on stdout; the reason a
	// row says "unreachable" goes to stderr, where it cannot corrupt either.
	for i, err := range failures {
		if err == nil {
			continue
		}
		// Name the environment once: clientcmd already includes the context in
		// its own message, and repeating it reads like two errors.
		if strings.Contains(err.Error(), envs[i].Context) {
			fmt.Fprintf(errw, "kiseki: %v\n", err)
		} else {
			fmt.Fprintf(errw, "kiseki: %s: %v\n", envs[i].Context, err)
		}
	}

	if opts.json {
		return printJSON(out, errw, rows)
	}

	fmt.Fprintf(out, "%-20s %-25s %-8s %-20s %-12s %s\n", "NAME", "CONTEXT", "PORT", "NAMESPACE", "PHASE", "URL")
	fmt.Fprintln(out, strings.Repeat("-", 100))
	for _, row := range rows {
		fmt.Fprintf(out, "%-20s %-25s %-8d %-20s %-12s %s\n", row.Name, row.Context, row.Port, row.Namespace, row.Phase, row.URL)
	}
	return 0
}

func printJSON(out, errw io.Writer, rows []envJSON) int {
	enc := json.NewEncoder(out)
	// A URL with & in it must not come out as \u0026: the Bash emitter did not
	// escape it, and neither should this one.
	enc.SetEscapeHTML(false)
	if err := enc.Encode(rows); err != nil {
		fmt.Fprintf(errw, "kiseki: %v\n", err)
		return 1
	}
	return 0
}
