package cli

import (
	"bytes"
	"os/exec"
	"strings"
	"testing"
)

// delegate must hand the subcommand to the legacy script as its first argument.
// It once passed the script path in that position instead, and the symptom was
// the script reporting "Unknown command: /path/to/scripts/kiseki.sh" — a failure
// that no test covered until this one.
func TestDelegatePassesSubcommandToTheScript(t *testing.T) {
	// create checks for its tools before parsing flags, so the assertion below
	// only means anything when they are installed (the mgmt CI lane has them).
	for _, tool := range []string{"kubectl", "helm", "ssh"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s is not installed; the legacy script would fail before parsing", tool)
		}
	}

	var out, errw bytes.Buffer
	code := Run([]string{"create", "probe", "--bogus-flag"}, &out, &errw, strings.NewReader(""))

	if code != 1 {
		t.Fatalf("exit code = %d, want 1 (stderr: %s)", code, errw.String())
	}
	// The message has to come from the Bash flag parser, which proves the argv
	// was [script, create, probe, --bogus-flag].
	if !strings.Contains(errw.String(), "Unknown flag: --bogus-flag") {
		t.Fatalf("stderr = %q, want the legacy script's own flag error", errw.String())
	}
	if strings.Contains(errw.String(), "Unknown command") {
		t.Fatalf("the script saw a command it does not know, so argv is wrong: %q", errw.String())
	}
}

// An unknown top-level command is the binary's own error, not the script's.
func TestRunRejectsUnknownCommand(t *testing.T) {
	var out, errw bytes.Buffer
	if code := Run([]string{"no-such-command"}, &out, &errw, strings.NewReader("")); code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}
	if !strings.Contains(errw.String(), "Unknown command: no-such-command") {
		t.Fatalf("stderr = %q", errw.String())
	}
	if !strings.Contains(out.String(), "Usage: kiseki") {
		t.Fatal("help text was not printed after the error")
	}
}

func TestRunHelp(t *testing.T) {
	for _, arg := range []string{"help", "-h", "--help"} {
		var out, errw bytes.Buffer
		if code := Run([]string{arg}, &out, &errw, strings.NewReader("")); code != 0 {
			t.Fatalf("%s: exit code = %d, want 0", arg, code)
		}
		if !strings.Contains(out.String(), "Usage: kiseki") {
			t.Fatalf("%s: help text missing", arg)
		}
	}
}

// A release artifact must be able to say what it is.
func TestVersionCommand(t *testing.T) {
	originalVersion, originalCommit, originalDate := Version, Commit, Date
	t.Cleanup(func() { Version, Commit, Date = originalVersion, originalCommit, originalDate })
	Version, Commit, Date = "v1.2.3", "abc1234", "2026-10-20"

	var out, errw bytes.Buffer
	if code := Run([]string{"version"}, &out, &errw, strings.NewReader("")); code != 0 {
		t.Fatalf("version exited %d: %s", code, errw.String())
	}
	want := "kiseki v1.2.3 (commit abc1234, built 2026-10-20)\n"
	if out.String() != want {
		t.Fatalf("got %q, want %q", out.String(), want)
	}
}
