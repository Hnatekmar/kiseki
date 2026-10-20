// Package state reads the per-environment state directory the CLI keeps under
// $XDG_STATE_HOME/kiseki.
package state

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Env is one created environment, as recorded on disk at create time.
type Env struct {
	Name       string
	Dir        string
	Context    string
	Port       int
	URL        string
	Kubeconfig string // file the context came from, empty when it was the default
}

// Root is $XDG_STATE_HOME/kiseki, ~/.local/state/kiseki by default.
func Root() string {
	if v := os.Getenv("XDG_STATE_HOME"); v != "" {
		return filepath.Join(v, "kiseki")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".local", "state", "kiseki")
}

// Namespace is where the chart was installed, and the release name.
func (e Env) Namespace() string { return "kiseki-" + e.Name }

// SSHAlias is the Host block written into ~/.ssh/config.d/kiseki.
func (e Env) SSHAlias() string { return "kiseki-" + e.Name }

// Load reads one environment. A state directory without a port file is not an
// environment and reports ErrNotEnvironment.
func Load(name string) (Env, error) {
	return load(filepath.Join(Root(), name))
}

// LoadAll reads every environment, sorted by name so `list` output is stable.
// A missing state root is not an error: it means nothing has been created yet.
func LoadAll() ([]Env, error) {
	entries, err := os.ReadDir(Root())
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	envs := make([]Env, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		env, err := load(filepath.Join(Root(), entry.Name()))
		if err != nil {
			if IsNotEnvironment(err) {
				continue
			}
			return nil, err
		}
		envs = append(envs, env)
	}
	return envs, nil
}

func load(dir string) (Env, error) {
	portText, err := readFile(filepath.Join(dir, "port"))
	if err != nil {
		if os.IsNotExist(err) {
			return Env{}, fmt.Errorf("%s: %w", dir, ErrNotEnvironment)
		}
		return Env{}, err
	}
	port, err := strconv.Atoi(strings.TrimSpace(portText))
	if err != nil {
		return Env{}, fmt.Errorf("%s/port: not a port number", dir)
	}

	ctx, err := readFile(filepath.Join(dir, "context"))
	if err != nil && !os.IsNotExist(err) {
		return Env{}, err
	}

	env := Env{
		Name:    filepath.Base(dir),
		Dir:     dir,
		Context: strings.TrimSpace(ctx),
		Port:    port,
	}

	if url, err := readFile(filepath.Join(dir, "url")); err == nil {
		env.URL = strings.TrimSpace(url)
	} else if !os.IsNotExist(err) {
		return Env{}, err
	}

	if kubeconfig, err := readFile(filepath.Join(dir, "kubeconfig")); err == nil {
		env.Kubeconfig = strings.TrimSpace(kubeconfig)
	} else if !os.IsNotExist(err) {
		return Env{}, err
	}

	return env, nil
}

// ErrNotEnvironment marks a directory that exists under the state root but was
// never completed by `create`.
var ErrNotEnvironment = fmt.Errorf("not an environment")

// IsNotEnvironment reports whether err came from a directory that is not an
// environment.
func IsNotEnvironment(err error) bool {
	return err != nil && strings.HasSuffix(err.Error(), ErrNotEnvironment.Error())
}

// readFile reads a whole state file. State files are one short value each, and
// a single trailing newline is stripped by the callers that care.
func readFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(data), nil
}
