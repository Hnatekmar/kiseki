// Package cli is the kiseki command surface.
package cli

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"

	"forgejo.srv.hnatekmar.dev/hnatekmar/kiseki/internal/repo"
)

const helpText = `kiseki: Kubernetes dev environment manager

Usage: kiseki <command> [options]

Commands:
  create [<name>] [options]   Create a new dev environment
  list [--json]               List all active environments
  destroy <name> [-f]         Destroy an environment
  example [--output FILE]     Print the sidecar values example, or write it
  proxy <alias>               Proxy SSH traffic (internal)
  help                        Show this help message

Create options:
  --cpu N             CPU cores (default: prompt then 4)
  --memory SIZE       Memory (default: prompt then 8Gi)
  --gpu N             Request N NVIDIA GPUs (default: 0)
  --ssh-key PATH      SSH public key path
  --context CTX       Kubernetes context
  --address HOST      Publish an Ingress for HOST; requires --port
  --port PORT         Container port the app listens on; requires --address
  --container SPEC    Sidecar in the pod, repeatable:
                      name=IMAGE[:TAG][,port=N][,env=KEY=VALUE]
  --docker            Add a docker:dind sidecar and set DOCKER_HOST
  --persistence       Persist /root on a PVC (default 10Gi)
  --persistence-size SIZE
                      PVC size, implies --persistence (e.g. 20Gi)
  --storage-class CLASS
                      StorageClass for the PVC, implies --persistence
  --set KEY=VALUE     Helm value override, repeatable (e.g. image.tag=43)
  -f, --values FILE   Helm values file, repeatable
  --json              Print one JSON object on stdout, progress on stderr
  --no-check          Skip SSH connectivity check

Destroy options:
  -f                  Force destroy without confirmation

Examples:
  kiseki create my-env --cpu 2 --memory 4Gi
  kiseki create web --address app.dev-k8s.srv.example.com --port 3000
  kiseki create api --container redis=redis:7-alpine,port=6379 --container pg=postgres:17,env=POSTGRES_PASSWORD=secret
  kiseki example > extraSVC.yaml      # sidecars with volumes and an init container
  kiseki create api -f extraSVC.yaml
  kiseki create build --docker --persistence --set storage.size=20Gi
  kiseki list --json
  kiseki destroy my-env -f
`

// Run dispatches one command line and returns the process exit code.
func Run(args []string, out, errw io.Writer, in io.Reader) int {
	cmd := "help"
	if len(args) > 0 {
		cmd = args[0]
		args = args[1:]
	}

	switch cmd {
	case "example":
		return runExample(args, out, errw)
	case "list":
		return runList(args, out, errw)
	case "help", "-h", "--help":
		fmt.Fprint(out, helpText)
		return 0
	case "create", "destroy", "proxy":
		// Ported one at a time. Until a subcommand lands here, the legacy script
		// still owns it, so the binary is usable throughout the migration.
		return delegate(cmd, args, out, errw, in)
	default:
		fmt.Fprintf(errw, "kiseki: Unknown command: %s\n", cmd)
		fmt.Fprint(out, helpText)
		return 1
	}
}

func delegate(sub string, args []string, out, errw io.Writer, in io.Reader) int {
	script, err := repo.LegacyScript()
	if err != nil {
		fmt.Fprintf(errw, "kiseki: %s is not ported yet, and the legacy script is missing: %v\n", sub, err)
		return 1
	}

	cmd := exec.Command(script, append([]string{sub}, args...)...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = in, out, errw
	cmd.Env = os.Environ()

	if err := cmd.Run(); err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return exit.ExitCode()
		}
		fmt.Fprintf(errw, "kiseki: %v\n", err)
		return 1
	}
	return 0
}
