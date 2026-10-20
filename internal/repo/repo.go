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
			if isChart(filepath.Join(dir, chartRel)) {
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
	if v := os.Getenv("KISEKI_CHART"); v != "" {
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
// yet. It disappears with the last of them.
func LegacyScript() (string, error) {
	root, err := Root()
	if err != nil {
		return "", err
	}
	path := filepath.Join(root, "scripts", "kiseki.sh")
	if st, err := os.Stat(path); err != nil || st.IsDir() {
		return "", fmt.Errorf("%s not found", path)
	}
	return path, nil
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
