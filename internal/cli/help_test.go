package cli

import (
	"bytes"
	"flag"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"

	"forgejo.srv.hnatekmar.dev/hnatekmar/kiseki/internal/repo"
)

// Every flag a command accepts must appear in the help. The help is generated
// from the same register function the parser uses, so this is really a guard on
// printHelp: dropping a command from the list would otherwise silently hide its
// flags.
func TestHelpListsEveryFlag(t *testing.T) {
	var out, errw bytes.Buffer
	if code := Run([]string{"help"}, &out, &errw, strings.NewReader("")); code != 0 {
		t.Fatalf("help exited %d: %s", code, errw.String())
	}
	help := out.String()

	for _, cmd := range cliCommands {
		if cmd.flags == nil {
			continue
		}
		fs := flag.NewFlagSet(cmd.name, flag.ContinueOnError)
		cmd.flags(fs)
		fs.VisitAll(func(f *flag.Flag) {
			// flag.PrintDefaults writes "  -name ..." on its own line.
			line := regexp.MustCompile(`(?m)^\s+-{1,2}` + regexp.QuoteMeta(f.Name) + `\b`)
			if !line.MatchString(help) {
				t.Errorf("%s: flag %q is accepted but missing from the help", cmd.name, f.Name)
			}
		})
	}
}

// The Bash parsers still own create and destroy, so their flags are documented
// from a Go definition that nothing parses yet. This keeps the documentation
// from advertising a flag the script would reject.
func TestLegacyFlagsMatchBash(t *testing.T) {
	root, err := repo.Root()
	if err != nil {
		t.Fatalf("repo root: %v", err)
	}

	cases := []struct {
		command string
		flags   func(*flag.FlagSet)
		script  string
	}{
		{"create", (&createOptions{}).register, "scripts/kiseki.d/create.sh"},
		{"destroy", (&destroyOptions{}).register, "scripts/kiseki.d/manage.sh"},
	}

	for _, tc := range cases {
		t.Run(tc.command, func(t *testing.T) {
			fs := flag.NewFlagSet(tc.command, flag.ContinueOnError)
			tc.flags(fs)

			source, err := os.ReadFile(filepath.Join(root, tc.script))
			if err != nil {
				t.Fatalf("read %s: %v", tc.script, err)
			}
			accepted := bashFlags(string(source))
			if len(accepted) == 0 {
				t.Fatalf("found no flags in %s; the parser changed shape", tc.script)
			}

			fs.VisitAll(func(f *flag.Flag) {
				if !accepted[f.Name] {
					t.Errorf("help documents --%s, which %s does not accept (it accepts %v)",
						f.Name, tc.script, sortedNames(accepted))
				}
			})
		})
	}
}

// caseLabel matches a shell case arm made only of flags, such as
// `--cpu)`, `-f | --values)` or `-*)`.
var caseLabel = regexp.MustCompile(`(?m)^\s*((?:--?[a-z][a-z-]*\s*\|\s*)*--?[a-z][a-z-]*)\)`)

// bashFlags collects the flag names a shell parser accepts from its case arms.
func bashFlags(source string) map[string]bool {
	names := map[string]bool{}
	for _, match := range caseLabel.FindAllStringSubmatch(source, -1) {
		for _, token := range strings.Split(match[1], "|") {
			name := strings.TrimLeft(strings.TrimSpace(token), "-")
			if name != "" {
				names[name] = true
			}
		}
	}
	return names
}

func sortedNames(set map[string]bool) []string {
	names := make([]string, 0, len(set))
	for name := range set {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}
