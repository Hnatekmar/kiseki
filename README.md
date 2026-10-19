<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/kiseki-logo-dark.svg">
  <img src="assets/kiseki-logo-light.svg" alt="Kiseki" width="420">
</picture>

</div>

[![Helm](https://img.shields.io/badge/Helm-chart-0F1689?logo=helm&logoColor=white)](charts/kiseki)
[![Fedora](https://img.shields.io/badge/Fedora-42-51A2DA?logo=fedora&logoColor=white)](https://fedoraproject.org)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-kind-326CE5?logo=kubernetes&logoColor=white)](https://kind.sigs.k8s.io)

> Disposable Linux development environments on Kubernetes

**Kiseki** creates temporary development pods on your Kubernetes cluster. Each pod runs Fedora 42 with SSH access and your dotfiles. When you finish work, you delete the environment completely.

---

## What Kiseki Does

Kiseki gives you a clean Linux development environment that:
- Lives in your Kubernetes cluster, not on your machine
- Includes SSH access, zsh, and your dotfiles
- Can have extra services like databases and Docker
- Deletes completely when you finish

## Quick Start

Install prerequisites, then create your first environment in 2 minutes.

### Prerequisites

You need these tools:
- `kind` (local Kubernetes)
- `kubectl` (cluster control)
- `helm` (package manager)
- `just` (task runner)
- `socat` (network tool)
- SSH client

### Step 1: Install Kiseki

```bash
./scripts/install.sh
```

This creates a symlink in `~/.local/bin`. Edits to this checkout work immediately.

### Step 2: Create an environment

```bash
kiseki create my-dev-env --cpu 4 --memory 8Gi
```

The prompt asks for CPU and memory if you omit the flags.

### Step 3: Connect to your environment

```bash
ssh kiseki-my-dev-env
```

You are now in a Fedora 42 pod as root with your dotfiles loaded.

### Step 4: Clean up when done

```bash
kiseki destroy my-dev-env
```

This removes the pod, storage, and SSH configuration.

---

## Common Use Cases

### Web development with database
```bash
kiseki create web-app \
  --container pg=postgres:17,port=5432,env=POSTGRES_PASSWORD=dev \
  --address web.dev-k8s.srv.hnatekmar.dev \
  --port 3000
```

### Docker builds
```bash
kiseki create build-env --docker
```

### GPU development
```bash
kiseki create gpu-env --gpu 1
```

### Persistent home directory
```bash
kiseki create work --persistence --persistence-size 20Gi
```

---

## What You Get Inside

Each environment includes:
- **Fedora 42** base system
- **zsh** shell with your dotfiles from `/workdir`
- **SSH server** for remote access
- **Package manager** (`dnf`) for installing software
- **Root access** to install what you need

The `/workdir` folder always starts fresh. Your home directory (`/root`) is temporary unless you request persistence.

---

## Adding Services

Sidecars run in the same pod network. Connect to them on localhost:

```bash
# Redis and PostgreSQL
kiseki create api \
  --container redis=redis:7-alpine,port=6379 \
  --container pg=postgres:17,port=5432,env=POSTGRES_PASSWORD=dev

# Inside the pod, connect to:
# Redis: localhost:6379
# PostgreSQL: localhost:5432
```

For complex setups, generate a values file:
```bash
kiseki example > my-env.yaml
kiseki create api -f my-env.yaml
```

---

## Scripting and Automation

Use JSON output for automation:

```bash
# Create and get SSH alias
kiseki create ci-1 --cpu 2 --memory 4Gi --no-check --json | jq -r .ssh_alias

# List all environments
kiseki list --json | jq -r '.[] | "\(.name) \(.phase)"'
```

---

## How SSH Access Works

Kiseki adds SSH aliases to `~/.ssh/config.d/kiseki`. Each alias runs a proxy command that:
1. Starts a `kubectl port-forward` to your pod
2. Bridges the connection with `socat`

Host key checking is disabled because pod keys regenerate on restart.

---

## Development and Testing

```bash
just lint      # Check chart rendering
just test      # Full smoke test on kind cluster
just test-gpu  # GPU test with nvkind
```

`just test` creates a fresh kind cluster, tests the complete workflow, then cleans up.

---

## Documentation

- [Configuration Reference](docs/configuration.md) — all chart values and options
- [Architecture Decisions](docs/adr) — technical design decisions
- [AGENTS.md](AGENTS.md) — development guidelines and troubleshooting