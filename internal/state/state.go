// Package state reads the per-environment state directory the CLI keeps under
// $XDG_STATE_HOME/kiseki.
package state

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// ErrNotEnvironment marks a directory under the state root that `create` never
// finished writing. It is a sentinel rather than a formatted string so callers
// can use errors.Is and stay correct once the message is wrapped.
var ErrNotEnvironment = errors.New("not an environment")

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

// Load reads one environment.
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
			if errors.Is(err, ErrNotEnvironment) {
				continue
			}
			return nil, err
		}
		envs = append(envs, env)
	}
	return envs, nil
}

// load reads one state directory. `create` writes `port` and `context` in one
// block, and both are required: a directory holding one but not the other is an
// interrupted create, not an environment. Such a row would advertise an empty
// context, and `--context ""` silently means "whatever the current context is",
// i.e. the wrong cluster.
func load(dir string) (Env, error) {
	port, err := readPort(dir)
	if err != nil {
		return Env{}, err
	}
	contextName, err := readContext(dir)
	if err != nil {
		return Env{}, err
	}

	url, err := readStateFile(filepath.Join(dir, "url"), false)
	if err != nil {
		return Env{}, err
	}
	kubeconfig, err := readStateFile(filepath.Join(dir, "kubeconfig"), false)
	if err != nil {
		return Env{}, err
	}

	return Env{
		Name:       filepath.Base(dir),
		Dir:        dir,
		Context:    contextName,
		Port:       port,
		URL:        url,
		Kubeconfig: kubeconfig,
	}, nil
}

func readPort(dir string) (int, error) {
	text, err := readStateFile(filepath.Join(dir, "port"), true)
	if err != nil {
		return 0, err
	}
	port, err := strconv.Atoi(text)
	if err != nil {
		return 0, fmt.Errorf("%s/port: %w", dir, err)
	}
	return port, nil
}

func readContext(dir string) (string, error) {
	text, err := readStateFile(filepath.Join(dir, "context"), true)
	if err != nil {
		return "", err
	}
	if text == "" {
		return "", fmt.Errorf("%s: empty context file: %w", dir, ErrNotEnvironment)
	}
	return text, nil
}

// readStateFile reads one short state file. When required, an absent file is
// ErrNotEnvironment; when optional, it is empty. Any other failure is wrapped so
// the caller keeps *os.PathError identity.
func readStateFile(path string, required bool) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			if required {
				return "", fmt.Errorf("%s: %w", path, ErrNotEnvironment)
			}
			return "", nil
		}
		return "", fmt.Errorf("%s: %w", path, err)
	}
	return strings.TrimSpace(string(data)), nil
}
