# AI Agent Guidelines

This document provides guidelines for AI agents working on this repository.

## Project Overview

This repository provides Kubernetes-based development environments using a Helm chart and a Bash spawn script. The project is named Kiseki (formerly `dev-envs`). Tests run on a local kind cluster.

## Technology Stack

- **Orchestration**: Kubernetes / kind
- **Packaging**: Helm
- **Provisioning**: Bash
- **Task Runner**: Just
- **Base Image**: fedora:42

## Conventions

### Commit Messages
- Use conventional commits (feat, fix, refactor, chore, etc.)
- Keep subject line under 72 characters.
- Do not use emoji prefixes.

### File Structure
- Chart lives in `charts/kiseki/`
- Scripts live in `scripts/`
- Root-level docs for user-facing information (README.md, AGENTS.md)
- Keep documentation concise and actionable

## Guidelines for AI Agents

### Chart Changes
- Run `helm lint` on every chart change.
- Run `helm template` to inspect rendered manifests.
- Verify the chart works on a kind cluster.
- Resource names must equal the release name.

### Script Changes
- Use bash shebang: `#!/usr/bin/env bash`
- Include error handling (`set -euo pipefail`) where appropriate.
- Comment non-obvious logic.

### Provisioning Script
- The provisioning script (`charts/kiseki/static/up.sh`) runs at container start.
- It must stay idempotent: re-runnable without errors.
- Do not use `chsh` on `fedora:42` (it is not available).
- User state belongs in `/root`. `/workdir` is recreated on every start and must stay disposable.

### Secret Volumes
- Secret volume mounts are read-only inside the container.

## Testing

### Smoke Test

```bash
just test
```

This recipe recreates the kind cluster, creates an environment non-interactively, runs an SSH smoke check, then destroys the environment. Prerequisites are listed in README.md.

CI (`.forgejo/workflows/ci.yml`) runs `just lint` on the `mgmt` runner and `just test`
on the `dind` runner. The dind lane needs one thing from the caller: `KIND_CONFIG`
pointing at a kind config, because that docker daemon is not on localhost and the
default kubeconfig would name an unreachable 127.0.0.1. `scripts/ci/kind-config.sh`
generates that file from the container's own default gateway. Keep the recipe as the
only list of checks — the workflow must not grow a parallel copy of them.

### GPU Smoke Test

```bash
just test-gpu
```

This recipe uses `nvkind` to create a GPU-enabled kind cluster, installs the NVIDIA device plugin, creates an environment with one GPU, runs `nvidia-smi` over SSH, then destroys the environment. It needs an NVIDIA driver, the NVIDIA container toolkit, and `nvkind`.

## Troubleshooting

### Pod Not Ready
The image pull and dnf install take time. Check status with:

```bash
kubectl --context <ctx> get pods -n <namespace>
kubectl --context <ctx> logs -l app.kubernetes.io/instance=<release> -n <namespace>
```

### SSH Debugging

```bash
ssh -v kiseki-<name>
```

The port-forward log is at `~/.local/state/kiseki/<name>/forward.log`.

### Terminating Namespace After Destroy

The namespace may linger in Terminating state. Force cleanup if needed:

```bash
kubectl delete namespace dev-<name> --force --grace-period=0
```

### Pod Never Starts With a PodSecurity Error

A privileged container (the `--docker` dind sidecar) is rejected on clusters that
enforce the baseline Pod Security standard. The ReplicaSet records
`violates PodSecurity "baseline:latest"`, while the rollout only shows a timeout.
`kiseki create --docker` labels the namespace it creates; a hand-installed
chart needs the label first:

```bash
kubectl label namespace dev-<name> pod-security.kubernetes.io/enforce=privileged
```

### Host-Key Warnings

Host-key warnings on the local forward are expected in v1 because pod keys regenerate on every start. The `StrictHostKeyChecking no` setting handles this.

## Security

- Never commit SSH private keys or kubeconfigs.
- Host-key checking is disabled on the local forward deliberately. The Kubernetes API channel is the trust boundary.
- Keep the fedora image updated for security patches.

## Resources

- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [kind Documentation](https://kind.sigs.k8s.io/)
- [Helm Documentation](https://helm.sh/docs/)
- [Just Command Runner](https://github.com/casey/just)

## Agent skills

### Issue tracker

Issues live as GitHub issues in this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

Triage uses the five canonical labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` at the repo root, ADRs in `docs/adr/`. See `docs/agents/domain.md`.