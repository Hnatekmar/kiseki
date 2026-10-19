<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/kiseki-logo-dark.svg">
  <img src="assets/kiseki-logo-light.svg" alt="Kiseki" width="420">
</picture>

</div>

[![Helm](https://img.shields.io/badge/Helm-chart-0F1689?logo=helm&logoColor=white)](charts/kiseki)
[![Fedora](https://img.shields.io/badge/Fedora-42-51A2DA?logo=fedora&logoColor=white)](https://fedoraproject.org)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-kind-326CE5?logo=kubernetes&logoColor=white)](https://kind.sigs.k8s.io)

> Against all odds, they work

**kiseki** gives you a disposable Linux dev box on Kubernetes. One command creates a Fedora 42 pod with `zsh`, `openssh-server`, and your dotfiles. You connect with `ssh kiseki-<name>` and drop it when you are done.

Each environment is a Helm release, so sidecars, a docker daemon, a persistent home, GPUs, and one Ingress for web work are flags — not manifests you maintain by hand.

---

## Documentation

- [Configuration Reference](docs/configuration.md) — chart values, sidecar keys, defaults
- [Architecture Decisions](docs/adr) — SSH proxying, ingress and sidecars, home persistence
- [AGENTS.md](AGENTS.md) — repo conventions, troubleshooting

---

## Why kiseki?

- **Nothing installed locally** — the toolchain lives in the pod; your machine needs `kubectl` and an SSH client.
- **Disposable by design** — `destroy` removes the namespace, the claim, and the SSH alias.
- **Real isolation** — a pod in your cluster, not a container next to your dotfiles.
- **Batteries included** — redis and postgres sidecars, dind image builds, GPUs, ingress.
- **Scriptable** — `create` and `list` emit JSON, and flags skip every prompt.
- **Editor friendly** — works with VS Code Remote-SSH and JetBrains Gateway.

---

## Quick Start

Requires `kind`, `kubectl`, `helm`, `just`, `socat`, and an SSH client.

### 1. Install

```bash
./scripts/install.sh                       # symlink into ~/.local/bin
./scripts/install.sh --prefix /usr/local   # system-wide
./scripts/install.sh --uninstall
```

The symlink points at this checkout, so edits take effect immediately. `just install` does the same. The installer refuses to overwrite a regular file or remove a symlink that points elsewhere.

### 2. Create an environment

```bash
kiseki create my-env --cpu 4 --memory 8Gi
```

CPU and memory prompt on a TTY; flags override the prompts. Without `--context`, the current kubectl context is used.

### 3. Connect

```bash
ssh kiseki-my-env
```

### 4. Destroy

```bash
kiseki list
kiseki destroy my-env      # -f skips confirmation
```

---

## What You Get

A single `fedora:42` pod running `openssh-server` and `zsh`. You log in as `root`. Startup installs packages with `dnf` and starts `sshd`.

`/root` is ephemeral until you ask for persistence. `/workdir` is always ephemeral: provisioning clones [dots](https://github.com/Hnatekmar/dots) there and runs its bootstrap on every start, so the checkout itself never has to survive.

---

## Persistent Home

```bash
kiseki create work --persistence --persistence-size 20Gi
```

Claims a PVC and mounts it at `/root`, so dotfiles, toolchains, caches, and shell history survive a pod restart. The default is 10Gi on the chart's `storage.storageClass` (`truenas-nvmeof`); `--storage-class` picks another. The image, `/workdir`, and the dind image store stay ephemeral.

The Deployment uses the `Recreate` strategy, so a restart detaches the `ReadWriteOnce` volume before the new pod starts:

```bash
kubectl rollout restart deployment/kiseki-work -n kiseki-work
```

The SSH helper waits for the replacement pod and re-points a stale port-forward, so the next `ssh kiseki-work` reconnects without cleanup.

---

## Web Access

```bash
kiseki create web --address web.dev-k8s.srv.hnatekmar.dev --port 3000
```

The chart adds a Service port and an Ingress with a cert-manager certificate. Your app must bind `0.0.0.0`, not `127.0.0.1`. The URL is printed at the end and kept for `list`.

This needs an ingress controller, the named ClusterIssuer (`ingress.clusterIssuer`, default `letsencrypt-cloudflare`), and a DNS record. Without them the Ingress stays unserved and the environment still works over SSH.

---

## Sidecars

Extra containers share the pod's network namespace:

```bash
kiseki create api \
  --container redis=redis:7-alpine,port=6379 \
  --container pg=postgres:17,port=5432,env=POSTGRES_PASSWORD=dev
```

`--container` takes `name=IMAGE[:TAG][,port=N][,env=KEY=VALUE]` and repeats. The dev container reaches each one on `127.0.0.1:<port>`, and provisioning waits for every declared port before starting `sshd`, so nothing races at startup.

Anything richer — volumes, init containers, commands, limits, probes — goes in a values file. Generate it instead of remembering the shape:

```bash
kiseki example                      # print to stdout
kiseki example --output extraSVC.yaml
kiseki create api -f extraSVC.yaml --address api.dev-k8s.srv.hnatekmar.dev --port 8080
```

[`examples/extraSVC.yaml`](examples/extraSVC.yaml) is that file, committed and kept in sync by `just lint`.

---

## Docker Builds

```bash
kiseki create build --docker
```

Adds a `docker:dind` sidecar and points `DOCKER_HOST` at it, so `docker build` and `docker run` work from the first shell. The daemon is privileged, so the CLI labels the namespace it creates with `pod-security.kubernetes.io/enforce=privileged`. Clusters that forbid privileged containers cannot use this flag.

---

## GPU

```bash
kiseki create gpu-env --gpu 1
```

The cluster needs an `nvidia` RuntimeClass and the NVIDIA device plugin; the GPU Operator provides both. For a local kind test, `just test-gpu` uses `nvkind` and installs the device plugin.

---

## How SSH Works

Each environment gets an alias in `~/.ssh/config.d/kiseki`, included from `~/.ssh/config` on first use. The alias runs `ProxyCommand kiseki proxy <alias>`, which starts a `kubectl port-forward` (port 2200-2299) and bridges it with `socat`.

Host-key checking is disabled (`StrictHostKeyChecking no`, `UserKnownHostsFile /dev/null`) because pod keys regenerate on every start. The Kubernetes API channel is the trust boundary.

---

## Scripting

`create` and `list` take `--json`. Progress goes to stderr, so stdout is one JSON document:

```bash
kiseki create ci-1 --cpu 2 --memory 4Gi --no-check --json | jq -r .ssh_alias
kiseki list --json | jq -r '.[] | "\(.name) \(.phase)"'
```

---

## Development

```bash
just lint      # render checks for CPU, GPU, ingress, sidecars, docker, empty resources
just test      # kind cluster -> create env -> ssh check -> destroy
just test-gpu  # nvkind cluster -> GPU env -> nvidia-smi check -> destroy
```

`just test` recreates the kind cluster `kiseki-test-cluster` (deleting it first), so any other environments on it go away too.
