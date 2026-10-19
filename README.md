# Kiseki (奇跡)

> Against all odds, they work

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/kiseki-logo-dark.svg">
    <img src="assets/kiseki-logo-light.svg" alt="Kiseki" width="420">
  </picture>
</p>

Kubernetes dev environments. Each environment is one Fedora 42 pod, reached over `kubectl port-forward` and an SSH alias. Managed with a Helm chart and a Bash spawn script. A pod can carry sidecar containers (redis, postgres, …), a docker daemon for image builds, and one Ingress for web work.

## Prerequisites

kind, kubectl, helm, just, socat, and an ssh client. The smoke test uses the public key at `~/.ssh/id_ed25519.pub`. For your own environments the script auto-detects keys under `~/.ssh` or takes `--ssh-key`. The GPU test also needs `nvkind`, an NVIDIA driver, and the NVIDIA container toolkit.

## Install as a command

Put `kiseki` on PATH with a symlink to this checkout, so edits take effect
immediately:

```bash
./scripts/install.sh                       # ~/.local/bin/kiseki
./scripts/install.sh --prefix /usr/local   # system-wide (needs write access)
./scripts/install.sh --uninstall
```

`just install` does the same. The installer refuses to overwrite a regular file
and will not uninstall a symlink that points somewhere other than this checkout.

## Quick Start

Run the full smoke test. It recreates the kind cluster `kiseki-test-cluster` (deletes it first), spawns an environment, checks SSH, then tears everything down. Recreating the cluster deletes any other environments on it:

```bash
just test
```

Create an environment. CPU and memory prompt on a TTY. Flags override. Omit `--context` to use the current kubectl context.

```bash
scripts/kiseki.sh create my-env --cpu 4 --memory 8Gi --ssh-key ~/.ssh/id_ed25519.pub
```

Connect, list, and destroy:

```bash
ssh kiseki-my-env
scripts/kiseki.sh list
scripts/kiseki.sh destroy my-env
scripts/kiseki.sh destroy my-env -f   # no confirmation
```

## What You Get

A single `fedora:42` pod with one container running `openssh-server` and `zsh`. You log in as `root` inside the pod. No GPU by default. Startup installs packages via dnf and starts sshd.

The home directory is ephemeral unless you pass `--persistence`. `/workdir` is always ephemeral: provisioning clones [dots](https://github.com/Hnatekmar/dots) there and runs its bootstrap on every start, so tools land in `/root` and the checkout itself does not need to survive.

## Persistent home

`--persistence` claims a PVC and mounts it at `/root`, so dotfiles, toolchains, caches, and shell history survive a pod restart:

```bash
scripts/kiseki.sh create work --persistence --persistence-size 20Gi
```

The default is 10Gi on the chart's `storage.storageClass` (`truenas-nvmeof`). Pass `--storage-class` to use another class. Only the home directory is persistent; the container image, `/workdir`, and the dind sidecar's image store are not.

The Deployment uses the `Recreate` strategy, so a restart detaches the `ReadWriteOnce` volume before the new pod starts:

```bash
kubectl rollout restart deployment/kiseki-work -n kiseki-work
```

The SSH helper waits for the replacement pod and replaces a port-forward that still points at the old one, so the next `ssh kiseki-work` reconnects without manual cleanup.

## Web access

Publish one container port through an Ingress:

```bash
scripts/kiseki.sh create web --address web.dev-k8s.srv.hnatekmar.dev --port 3000
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
scripts/kiseki.sh create api \
  --container redis=redis:7-alpine,port=6379 \
  --container pg=postgres:17,port=5432,env=POSTGRES_PASSWORD=dev
```

`--container` takes `name=IMAGE[:TAG][,port=N][,env=KEY=VALUE]`, repeatable. The
dev container reaches each one on `127.0.0.1:<port>`, and the provisioning script
waits for every declared port before starting sshd, so an app cannot race redis
or postgres at startup.

Anything richer — volumes, init containers, commands, resource limits, probes —
goes in a values file. Generate the file instead of remembering the shape:

```bash
scripts/kiseki.sh example                          # print to stdout
scripts/kiseki.sh example --output extraSVC.yaml   # write and render-check it
scripts/kiseki.sh create api -f extraSVC.yaml --address api.dev-k8s.srv.hnatekmar.dev --port 8080
```

[`examples/extraSVC.yaml`](examples/extraSVC.yaml) is that file, committed and
kept in sync by `just lint`. It adds redis and postgres sidecars, an `emptyDir`
for postgres data, a seeding init container, and a shared volume mounted into the
dev container at `/seed`.

The values keys are:

| Key | Effect |
|-----|--------|
| `extraContainers` | sidecars, full container specs; declared ports are waited on |
| `extraVolumes` | pod-level volumes the sidecars can mount |
| `extraVolumeMounts` | mounts added to the dev container |
| `extraInitContainers` | run to completion before anything else starts |

Sidecar state is ephemeral unless its volume points at a claim. `--persistence`
creates one claim (`data`) for the home directory; a sidecar that needs durable
state can mount that claim under its own path, or use a PVC created alongside
the release.

## Docker builds

```bash
scripts/kiseki.sh create build --docker
```

Adds a `docker:dind` sidecar and points `DOCKER_HOST` at it, so `docker build`
and `docker run` work from the first shell. The daemon is privileged, so the CLI
labels the namespace it creates with
`pod-security.kubernetes.io/enforce=privileged`. Clusters that forbid privileged
containers cannot use this flag.

## GPU

Request GPUs with `--gpu`:

```bash
scripts/kiseki.sh create gpu-env --gpu 1
```

The cluster must have an `nvidia` RuntimeClass and the NVIDIA device plugin. The GPU Operator provides both. For a local kind test, use `just test-gpu`. It uses `nvkind` and installs the device plugin.

Use a recent `nvkind` build. `go install github.com/NVIDIA/nvkind/cmd/nvkind@main` works with containerd 2.x. Follow the nvkind setup steps for the NVIDIA container toolkit.

## How SSH Works

The script writes one block per environment into `~/.ssh/config.d/kiseki` and adds an `Include` directive to `~/.ssh/config` on first use. Every alias uses `ProxyCommand` to run `scripts/kiseki.sh proxy <alias>`, which starts a `kubectl port-forward` (port 2200-2299) and bridges it with `socat`. The script disables host-key checking. It uses `StrictHostKeyChecking no` and `UserKnownHostsFile /dev/null`. Pod keys regenerate on every start. The Kubernetes API channel is the trust boundary.

VS Code Remote-SSH and JetBrains Gateway work with the alias `kiseki-<name>`.

## Scripting

`create` and `list` take `--json`. Progress goes to stderr, so stdout is one
JSON document:

```bash
scripts/kiseki.sh create ci-1 --cpu 2 --memory 4Gi --no-check --json | jq -r .ssh_alias
scripts/kiseki.sh list --json | jq -r '.[] | "\(.name) \(.phase)"'
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
| `storage.enabled`                      | `false` |
| `storage.size`                         | `10Gi` |
| `storage.storageClass`                 | `truenas-nvmeof` |
| `ingress.enabled`                      | `false` |
| `ingress.host` / `ingress.port`        | `""` / `3000` |
| `ingress.className`                    | `nginx` |
| `ingress.clusterIssuer`                | `letsencrypt-cloudflare` |
| `ingress.tls`                          | `true` |
| `extraContainers`                      | `[]` |
| `extraVolumes`                         | `[]` |
| `extraVolumeMounts`                    | `[]` |
| `extraInitContainers`                  | `[]` |
| `ports`                                | `[]` |
| `docker.enabled`                       | `false` |
| `docker.image.repository` / `.tag`     | `docker` / `28-dind` |
| `docker.storage.sizeLimit`             | `20Gi` |

`gpu.runtimeClassName` must name an existing RuntimeClass on the cluster.
`docker.enabled` needs a namespace at the privileged Pod Security level.

## Contributing

See [AGENTS.md](AGENTS.md).
