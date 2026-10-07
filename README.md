# Dev Environments

Kubernetes dev environments. Each environment is one Fedora 42 pod, reached over `kubectl port-forward` and an SSH alias. Managed with a Helm chart and a Bash spawn script.

## Prerequisites

kind, kubectl, helm, just, socat, and an ssh client. The smoke test uses the public key at `~/.ssh/id_ed25519.pub`; for your own environments the script auto-detects keys under `~/.ssh` or takes `--ssh-key`.

## Quick Start

Run the full smoke test. It recreates the kind cluster `dev-envs-test-cluster` (deletes it first), spawns an environment, checks SSH, then tears everything down. Recreating the cluster removes any other environments on it:

```bash
just test
```

Create an environment (CPU and memory prompt on a TTY; flags override; omit `--context` to use the current kubectl context):

```bash
scripts/dev-env.sh create my-env --cpu 4 --memory 8Gi --ssh-key ~/.ssh/id_ed25519.pub
```

Connect, list, and destroy:

```bash
ssh k8s-dev-my-env
scripts/dev-env.sh list
scripts/dev-env.sh destroy my-env
scripts/dev-env.sh destroy my-env -f   # no confirmation
```

## What You Get

A single `fedora:42` pod with one container running `openssh-server` and `zsh`. You log in as `root` inside the pod. Storage is ephemeral (no PVC). No GPU. Startup installs packages via dnf and starts sshd.

## How SSH Works

The script writes one block per environment into `~/.ssh/config.d/k8s-dev-envs` and adds an `Include` directive to `~/.ssh/config` on first use. Every alias uses `ProxyCommand` to run `scripts/dev-env.sh proxy <alias>`, which starts a `kubectl port-forward` (port 2200-2299) and bridges it with `socat`. Host-key checking is disabled (`StrictHostKeyChecking no`, `UserKnownHostsFile /dev/null`) because pod keys regenerate on every start. The Kubernetes API channel is the trust boundary.

VS Code Remote-SSH and JetBrains Gateway work with the alias `k8s-dev-<name>`.

## Justfile

One recipe only:

```
just test    # kind cluster -> create env -> ssh check -> destroy
```

## Chart Values

| Key                                    | Default   |
|----------------------------------------|-----------|
| `image.repository` / `image.tag`       | `fedora:42` |
| `resources.requests.{cpu,memory}`      | `1` / `1Gi` |
| `resources.limits.{cpu,memory}`        | `4` / `8Gi` |
| `ssh.authorizedKey`                    | `""` (use `--set-file`) |

## Project Structure

```
.
├── charts/dev-env/             # Helm chart
├── scripts/
│   ├── dev-env.sh              # Spawn/destroy/list script
│   └── create-cluster.sh       # Create kind cluster for tests
├── docs/
├── Justfile
├── GLOSSARY.md
├── README.md
└── AGENTS.md
```

## Limitations

- v1 targets kind only.
- Ephemeral storage: all data is lost on pod restart.
- No GPU support.
- SSH access only via port-forward.

## Contributing

See [AGENTS.md](AGENTS.md).