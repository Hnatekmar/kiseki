package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"

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

func runList(args []string, out, errw io.Writer) int {
	fs := newFlagSet("list", "[--json]", errw)
	jsonMode := fs.Bool("json", false, "print one JSON array on stdout")
	if code, ok := parseFlags(fs, args, errw); !ok {
		return code
	}

	envs, err := state.LoadAll()
	if err != nil {
		fmt.Fprintf(errw, "kiseki: %v\n", err)
		return 1
	}

	if len(envs) == 0 {
		if *jsonMode {
			fmt.Fprintln(out, "[]")
		} else {
			fmt.Fprintln(out, "No environments found.")
		}
		return 0
	}

	// One row per environment, each carrying the phase read from the cluster it
	// was created on. A context that cannot be reached is a row, not an error:
	// the rest of the list is still worth printing.
	rows := make([]envJSON, 0, len(envs))
	for _, env := range envs {
		rows = append(rows, envJSON{
			Name:      env.Name,
			Context:   env.Context,
			Port:      env.Port,
			Namespace: env.Namespace(),
			Phase:     phase(env.Context, env.Namespace(), env.Kubeconfig),
			URL:       env.URL,
		})
	}

	if *jsonMode {
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
