# Configuration Reference

`kiseki` passes flags to the Helm chart in `charts/kiseki`. Everything a flag sets
can also be set with `--set` or a values file, which is where the options that
have no flag live.

## Chart Values

| Key | Default | Notes |
|-----|---------|-------|
| `image.repository` / `image.tag` | `fedora` / `42` | |
| `resources.requests.{cpu,memory}` | `1` / `1Gi` | |
| `resources.limits.{cpu,memory}` | `4` / `8Gi` | |
| `gpu.enabled` | `false` | |
| `gpu.count` | `1` | |
| `gpu.runtimeClassName` | `nvidia` | Must name an existing RuntimeClass |
| `ssh.authorizedKey` | `""` | Use `--set-file` |
| `fullnameOverride` | `""` | Optional resource-name override; defaults to the release name |
| `storage.enabled` | `false` | |
| `storage.size` | `10Gi` | |
| `storage.storageClass` | `truenas-nvmeof` | |
| `ingress.enabled` | `false` | |
| `ingress.host` / `ingress.port` | `""` / `3000` | |
| `ingress.className` | `nginx` | |
| `ingress.clusterIssuer` | `letsencrypt-cloudflare` | |
| `ingress.tls` | `true` | |
| `ingress.annotations` | `{}` | |
| `ports` | `[]` | Extra container ports, documentation only |
| `extraContainers` | `[]` | Sidecars |
| `extraVolumes` | `[]` | Pod-level volumes |
| `extraVolumeMounts` | `[]` | Mounts added to the dev container |
| `extraInitContainers` | `[]` | Run to completion before anything else |
| `docker.enabled` | `false` | Needs a namespace at the privileged Pod Security level |
| `docker.image.repository` / `.tag` | `docker` / `28-dind` | |
| `docker.storage.sizeLimit` | `20Gi` | |

## Sidecar Keys

| Key | Effect |
|-----|--------|
| `extraContainers` | Sidecars as full container specs; declared ports are waited on |
| `extraVolumes` | Pod-level volumes the sidecars can mount |
| `extraVolumeMounts` | Mounts added to the dev container |
| `extraInitContainers` | Run to completion before anything else starts |

A volume is only visible to the dev container when it also appears in
`extraVolumeMounts`; sidecars mount it through their own `volumeMounts`.

Sidecar state is ephemeral unless its volume points at a claim. `--persistence`
creates one PVC named after the release, mounted as the volume `data` at
`/root`; a sidecar that needs durable state can mount that claim under its own
path, or use a PVC created alongside the release.

## Storage

`storage.enabled` mounts the claim at `/root`, not `/data`. Everything under
`/root` survives a restart: dotfiles, toolchains, caches, shell history, and the
dots bootstrap. `/workdir` stays ephemeral because provisioning pulls the dots
checkout again on every start.

The Deployment uses the `Recreate` strategy so a restart detaches the
`ReadWriteOnce` volume before the new pod starts. To restart an environment:

```bash
kubectl rollout restart deployment/kiseki-<name> -n kiseki-<name>
```

## Ingress

`ingress.enabled` requires `ingress.host`. The chart renders one Service port and
one Ingress rule, with a cert-manager certificate when `ingress.tls` is true, so
the cluster needs:

- an ingress controller (the default assumes `ingressClassName: nginx`),
- the ClusterIssuer named by `ingress.clusterIssuer`,
- a DNS record for `ingress.host` pointing at the controller.

The app inside the container must bind `0.0.0.0`. `ingress.port` is the container
port, and the CLI rejects `22`.

## Chart Install Without the CLI

```bash
helm install kiseki-work charts/kiseki \
  --namespace kiseki-work --create-namespace \
  --set-file ssh.authorizedKey="$HOME/.ssh/id_ed25519.pub"
```

Resource names equal the release name. A hand-installed chart that enables
`docker` must label its namespace first:

```bash
kubectl label namespace kiseki-work pod-security.kubernetes.io/enforce=privileged
```
