package repo

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeChart(t *testing.T, root string) {
	t.Helper()
	dir := filepath.Join(root, "charts", "kiseki")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir chart: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "Chart.yaml"), []byte("name: kiseki\n"), 0o644); err != nil {
		t.Fatalf("write Chart.yaml: %v", err)
	}
}

func writeModule(t *testing.T, root, module string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, "go.mod"), []byte("module "+module+"\n\ngo 1.26\n"), 0o644); err != nil {
		t.Fatalf("write go.mod: %v", err)
	}
}

func TestRootFindsTheCheckoutFromTheWorkingDirectory(t *testing.T) {
	root := t.TempDir()
	writeChart(t, root)
	writeModule(t, root, "forgejo.srv.hnatekmar.dev/hnatekmar/kiseki")

	sub := filepath.Join(root, "internal", "cli")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	t.Chdir(sub)

	got, err := Root()
	if err != nil {
		t.Fatalf("Root: %v", err)
	}
	if got != root {
		t.Fatalf("Root = %q, want %q", got, root)
	}
}

// A chart on its own is not a checkout: any directory could hold one, and
// delegate would then run whatever scripts/kiseki.sh sat inside it.
func TestRootIgnoresAChartWithoutACheckoutMarker(t *testing.T) {
	root := t.TempDir()
	writeChart(t, root)
	t.Chdir(root)

	if _, err := Root(); err == nil {
		t.Fatal("Root accepted a chart with no checkout marker")
	}
}

func TestRootIgnoresAForeignModuleThatVendorsAChart(t *testing.T) {
	root := t.TempDir()
	writeChart(t, root)
	writeModule(t, root, "example.com/somebody/else")
	t.Chdir(root)

	if _, err := Root(); err == nil {
		t.Fatal("Root accepted an unrelated module that happens to contain charts/kiseki")
	}
}

func TestLegacyScriptNeedsACheckout(t *testing.T) {
	root := t.TempDir()
	writeChart(t, root)
	if err := os.MkdirAll(filepath.Join(root, "scripts"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	script := filepath.Join(root, "scripts", "kiseki.sh")
	if err := os.WriteFile(script, []byte("#!/usr/bin/env bash\ntrue\n"), 0o755); err != nil {
		t.Fatalf("write script: %v", err)
	}
	t.Chdir(root)

	_, err := LegacyScript()
	if err == nil {
		t.Fatal("LegacyScript ran a script from a directory that is not a checkout")
	}
	if !strings.Contains(err.Error(), "kiseki checkout") && !strings.Contains(err.Error(), "cannot find") {
		t.Fatalf("error = %q, want a checkout complaint", err)
	}
}

// A pasted or $(cat ...) value carries a newline; an untrimmed path can never
// match a directory.
func TestChartDirTrimsKISEKI_CHART(t *testing.T) {
	root := t.TempDir()
	writeChart(t, root)
	chart := filepath.Join(root, "charts", "kiseki")

	t.Setenv("KISEKI_CHART", "  "+chart+"\n")
	got, err := ChartDir()
	if err != nil {
		t.Fatalf("ChartDir: %v", err)
	}
	if got != chart {
		t.Fatalf("ChartDir = %q, want %q", got, chart)
	}
}

func TestChartDirRejectsAChartlessOverride(t *testing.T) {
	t.Setenv("KISEKI_CHART", t.TempDir())
	if _, err := ChartDir(); err == nil {
		t.Fatal("ChartDir accepted a directory with no Chart.yaml")
	}
}
