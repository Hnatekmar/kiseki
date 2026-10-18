# SSH access to dev pods via a self-healing ProxyCommand

Status: accepted

Developers reach a dev environment with plain `ssh kiseki-<name>`, so VS Code Remote-SSH and JetBrains Gateway work with no custom plugin. The `Host` block points `ProxyCommand` at `scripts/kiseki.sh proxy %h`, which keeps a detached `kubectl port-forward` alive and bridges the connection with `socat`; because the config carries no `Port`, the helper can reallocate a dead port silently. We rejected a static `HostName`/`Port` block (fails after a host reboot), a LoadBalancer/NodePort Service (needs an add-on on kind, and the port is exposed), and `stdssh` over `kubectl exec` (new, low-popularity project, and it needs a binary inside the pod). The cost: `socat` is a host dependency, and the helper needs `flock` to avoid double-starting a forward.
