# Dev Environments

Kubernetes dev environments. Each environment is one Fedora 42 pod, reached over `kubectl port-forward` and an SSH alias. Managed with a Helm chart and a Bash spawn script. A pod can carry sidecar containers (redis, postgres, …), a docker daemon for image builds, and one Ingress for web work.

## Prerequisites

kind, kubectl, helm, just, socat, and an ssh client. The smoke test uses the public key at `~/.ssh/id_ed25519.pub`. For your own environments the script auto-detects keys under `~/.ssh` or takes `--ssh-key`. The GPU test also needs `nvkind`, an NVIDIA driver, and the NVIDIA container toolkit.

## Install as a command

Put `dev-env` on PATH with a symlink to this checkout, so edits take effect
immediately:

```bash
./scripts/install.sh                       # ~/.local/bin/dev-env
./scripts/install.sh --prefix /usr/local   # system-wide (needs write access)
./scripts/install.sh --uninstall
```

`just install` does the same. The installer refuses to overwrite a regular file
and will not uninstall a symlink that points somewhere other than this checkout.

## Quick Start

Run the full smoke test. It recreates the kind cluster `dev-envs-test-cluster` (deletes it first), spawns an environment, checks SSH, then tears everything down. Recreating the cluster deletes any other environments on it:

```bash
just test
```

Create an environment. CPU and memory prompt on a TTY. Flags override. Omit `--context` to use the current kubectl context.

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

A single `fedora:42` pod with one container running `openssh-server` and `zsh`. You log in as `root` inside the pod. Storage is ephemeral (no PVC). No GPU by default. Startup installs packages via dnf and starts sshd.

## Web access

Publish one container port through an Ingress:

```bash
scripts/dev-env.sh create web --address web.dev-k8s.srv.hnatekmar.dev --port 3000
```

`--address` is the hostname, `--port` is the port the app listens on inside the
container. The chart adds a Service port and an Ingress with a cert-manager
certificate. The app must bind `0.0.0.0`, not `127.0.0.1`. The URL is printed at
the end and kept for `list`.

The cluster needs an ingress controller, the named ClusterIssuer
(`ingress.clusterIssuer`, default `letsencrypt-cloudflare`), and a DNS record
for the host. Without them the Ingress stays unserved and the environment still
works over SSH.

## Sidecars

Run extra containers in the pod, sharing its network namespace:

```bash
scripts/dev-env.sh create api \
  --container redis=redis:7-alpine,port=6379 \
  --container pg=postgres:17,port=5432,env=POSTGRES_PASSWORD=dev
```

`--container` takes `name=IMAGE[:TAG][,port=N][,env=KEY=VALUE]`, repeatable. The
dev container reaches each one on `127.0.0.1:<port>`. For anything richer
(commands, volumes, resources), pass a values file with `extraContainers:` in
the chart's format:

```bash
scripts/dev-env.sh create api -f sidecars.yaml
```

Sidecar state is ephemeral unless the environment has persistence.

## Docker builds

```bash
scripts/dev-env.sh create build --docker
```

Adds a `docker:dind` sidecar and points `DOCKER_HOST` at it, so `docker build`
and `docker run` work from the first shell. The daemon is privileged, so the CLI
labels the namespace it creates with
`pod-security.kubernetes.io/enforce=privileged`. Clusters that forbid privileged
containers cannot use this flag.

## GPU

Request GPUs with `--gpu`:

```bash
scripts/dev-env.sh create gpu-env --gpu 1
```

The cluster must have an `nvidia` RuntimeClass and the NVIDIA device plugin. The GPU Operator provides both. For a local kind test, use `just test-gpu`. It uses `nvkind` and installs the device plugin.

Use a recent `nvkind` build. `go install github.com/NVIDIA/nvkind/cmd/nvkind@main` works with containerd 2.x. Follow the nvkind setup steps for the NVIDIA container toolkit.

## How SSH Works

The script writes one block per environment into `~/.ssh/config.d/k8s-dev-envs` and adds an `Include` directive to `~/.ssh/config` on first use. Every alias uses `ProxyCommand` to run `scripts/dev-env.sh proxy <alias>`, which starts a `kubectl port-forward` (port 2200-2299) and bridges it with `socat`. The script disables host-key checking. It uses `StrictHostKeyChecking no` and `UserKnownHostsFile /dev/null`. Pod keys regenerate on every start. The Kubernetes API channel is the trust boundary.

VS Code Remote-SSH and JetBrains Gateway work with the alias `k8s-dev-<name>`.

## Scripting

`create` and `list` take `--json`. Progress goes to stderr, so stdout is one
JSON document:

```bash
scripts/dev-env.sh create ci-1 --cpu 2 --memory 4Gi --no-check --json | jq -r .ssh_alias
scripts/dev-env.sh list --json | jq -r '.[] | "\(.name) \(.phase)"'
```

Every prompt is skipped when flags provide the value, so an agent can create and
inspect environments without a TTY.

## Justfile

```
just lint      # render checks for CPU, GPU, ingress, sidecars, docker, empty resources
just test      # kind cluster -> create env -> ssh check -> destroy
just test-gpu  # nvkind cluster -> GPU env -> nvidia-smi check -> destroy
```

## Chart Values

| Key                                    | Default   |
|----------------------------------------|-----------|
| `image.repository` / `image.tag`       | `fedora:42` |
| `resources.requests.{cpu,memory}`      | `1` / `1Gi` |
| `resources.limits.{cpu,memory}`        | `4` / `8Gi` |
| `gpu.enabled`                          | `false` |
| `gpu.count`                            | `1` |
| `gpu.runtimeClassName`                 | `nvidia` |
| `ssh.authorizedKey`                    | `""` (use `--set-file`) |
| `ingress.enabled`                      | `false` |
| `ingress.host` / `ingress.port`        | `""` / `3000` |
| `ingress.className`                    | `nginx` |
| `ingress.clusterIssuer`                | `letsencrypt-cloudflare` |
| `ingress.tls`                          | `true` |
| `extraContainers`                      | `[]` |
| `ports`                                | `[]` |
| `docker.enabled`                       | `false` |
| `docker.image.repository` / `.tag`     | `docker` / `28-dind` |
| `docker.storage.sizeLimit`             | `20Gi` |

`gpu.runtimeClassName` must name an existing RuntimeClass on the cluster.
`docker.enabled` needs a namespace at the privileged Pod Security level.

## Project Structure

```
.
├── charts/dev-env/             # Helm chart
├── scripts/
│   ├── dev-env.sh              # Spawn/destroy/list script
│   ├── dev-env.d/              # Subcommand implementations
│   ├── install.sh              # Symlink the CLI into a bin directory
│   ├── create-cluster.sh       # Create kind cluster for tests
│   └── test-gpu.sh             # GPU smoke test
├── docs/
├── Justfile
├── GLOSSARY.md
├── README.md
└── AGENTS.md
```

## Limitations

- Tested on kind and on the lab dev cluster.
- Ephemeral storage: all data is lost on pod restart.
- GPU support requires an `nvidia` RuntimeClass and the NVIDIA device plugin. The GPU Operator provides both. `nvkind` provides the RuntimeClass for local kind tests.
- SSH access is always via port-forward; web access is optional through an Ingress.
- One Ingress host per environment.

## Contributing

See [AGENTS.md](AGENTS.md).
