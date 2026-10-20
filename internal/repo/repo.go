// Package repo locates the checkout the binary belongs to.
//
// The Bash CLI resolved the chart relative to its own path, which worked
// because install.sh symlinked the script into the checkout. A binary in
// ~/.local/bin has no such relationship, so resolution walks up from the real
// executable first, then from the working directory, and KISEKI_CHART wins over
// both.
package repo

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const chartRel = "charts/kiseki"

// Root is the checkout directory that holds the chart.
func Root() (string, error) {
	var starts []string
	if dir := exeDir(); dir != "" {
		starts = append(starts, dir)
	}
	if wd, err := os.Getwd(); err == nil {
		starts = append(starts, wd)
	}

	for _, start := range starts {
		for dir := start; ; {
			if isCheckout(dir) {
				return dir, nil
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}
	return "", fmt.Errorf("cannot find %s above the executable or the working directory (set KISEKI_CHART)", chartRel)
}

// ChartDir is the Helm chart the CLI installs.
func ChartDir() (string, error) {
	// Trimmed: a value written with $(cat file) or pasted from a terminal
	// carries a newline, and an untrimmed path can never match a directory.
	if v := strings.TrimSpace(os.Getenv("KISEKI_CHART")); v != "" {
		abs, err := filepath.Abs(v)
		if err != nil {
			return "", err
		}
		if !isChart(abs) {
			return "", fmt.Errorf("KISEKI_CHART=%s is not a chart directory", v)
		}
		return abs, nil
	}
	root, err := Root()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, chartRel), nil
}

// LegacyScript is the Bash CLI, used by subcommands the port has not reached
// yet. It disappears with the last of them. It does not imply IsExecutable:
// delegate falls back to `bash path` when the mode bits are missing.
func LegacyScript() (string, error) {
	root, err := checkout()
	if err != nil {
		return "", err
	}
	path := filepath.Join(root, "scripts", "kiseki.sh")
	st, err := os.Stat(path)
	if err != nil || !st.Mode().IsRegular() {
		return "", fmt.Errorf("%s not found", path)
	}
	return path, nil
}

// checkout is the source tree. KISEKI_CHART names the chart inside it, so the
// override has to move the script lookup too: an installed binary pointed at one
// checkout must not delegate to another.
func checkout() (string, error) {
	if v := strings.TrimSpace(os.Getenv("KISEKI_CHART")); v != "" {
		abs, err := filepath.Abs(v)
		if err != nil {
			return "", err
		}
		return filepath.Dir(filepath.Dir(abs)), nil
	}
	return Root()
}

// IsExecutable reports whether path can be run directly. A checkout that lost
// its mode bits still works through `bash path`, which is what delegate does.
func IsExecutable(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.Mode().IsRegular() && st.Mode().Perm()&0o111 != 0
}

// isCheckout reports whether dir is a kiseki checkout: the chart, plus proof
// that the directory is this source tree and not any directory that happens to
// contain a chart. A bare go.mod is not proof — an unrelated Go module with a
// copied chart would satisfy it — so the module path has to match.
func isCheckout(dir string) bool {
	if !isChart(filepath.Join(dir, chartRel)) {
		return false
	}
	if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
		return true
	}
	return moduleIsKiseki(filepath.Join(dir, "go.mod"))
}

func moduleIsKiseki(gomod string) bool {
	data, err := os.ReadFile(gomod)
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "module ") {
			continue
		}
		path := strings.TrimSpace(strings.TrimPrefix(line, "module "))
		return strings.HasSuffix(path, "/kiseki")
	}
	return false
}

func isChart(dir string) bool {
	st, err := os.Stat(filepath.Join(dir, "Chart.yaml"))
	return err == nil && !st.IsDir()
}

func exeDir() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	// A symlink into ~/.local/bin resolves back to the checkout, which is where
	// the chart lives.
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	return filepath.Dir(exe)
}
