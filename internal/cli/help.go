package cli

import (
	"flag"
	"fmt"
	"io"
)

// cliCommand is one row of the CLI surface. Each command's flags are declared by
// a single register function that both the parser and this help text use, so
// `kiseki help` cannot document a flag the command rejects, or miss one it
// accepts.
type cliCommand struct {
	name    string
	summary string
	usage   string
	flags   func(*flag.FlagSet)
}

var cliCommands = []cliCommand{
	{name: "create", summary: "Create a new dev environment", usage: "[<name>] [flags]", flags: (&createOptions{}).register},
	{name: "list", summary: "List all active environments", usage: "[--json]", flags: (&listOptions{}).register},
	{name: "destroy", summary: "Destroy an environment", usage: "<name> [-f]", flags: (&destroyOptions{}).register},
	{name: "example", summary: "Print the sidecar values example, or write it", usage: "[--output FILE]", flags: (&exampleOptions{}).register},
	{name: "proxy", summary: "Proxy SSH traffic (internal)", usage: "<alias>"},
	{name: "version", summary: "Print the version"},
	{name: "help", summary: "Show this help message"},
}

const examplesText = `
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

// printHelp writes the command list, then flag's own rendering of every flag the
// CLI defines. Nothing here enumerates a flag: adding one to a register function
// is what puts it in the help.
func printHelp(out io.Writer) {
	fmt.Fprint(out, "kiseki: Kubernetes dev environment manager\n\nUsage: kiseki <command> [options]\n\nCommands:\n")
	for _, cmd := range cliCommands {
		name := cmd.name
		if cmd.usage != "" {
			name += " " + cmd.usage
		}
		fmt.Fprintf(out, "  %-30s %s\n", name, cmd.summary)
	}

	fmt.Fprint(out, "\nFlags (both --name and -name are accepted):\n")
	for _, cmd := range cliCommands {
		if cmd.flags == nil {
			continue
		}
		fs := flag.NewFlagSet(cmd.name, flag.ContinueOnError)
		fs.SetOutput(out)
		cmd.flags(fs)
		fmt.Fprintf(out, "\n  kiseki %s %s\n", cmd.name, cmd.usage)
		fs.PrintDefaults()
	}

	fmt.Fprint(out, examplesText)
}
