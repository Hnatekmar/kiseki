# Ingress for web access, sidecars in the dev pod

Status: accepted

Web work needs a channel that SSH does not provide: a server on a container port
that a browser can reach. `kiseki create --address HOST --port PORT` creates a
Service port and an Ingress with a cert-manager certificate, instead of a
`kubectl port-forward` on the workstation. A port-forward ties the URL to one
machine, needs a process per environment, and dies with the terminal. An Ingress
gives a stable name (`<name>.dev-k8s.srv.hnatekmar.dev`) that works from any host
on the lab network, and the certificate is issued automatically. The cost: the
cluster must have an ingress controller, the named ClusterIssuer, and a DNS
record for the host. Those exist on the dev cluster; the README states the
requirement for other clusters. We rejected a NodePort or LoadBalancer Service
for the same reason as in ADR-0001: it needs an add-on on kind and exposes a
port without a name.

Sidecars (redis, postgres, a second server) are containers in the same pod, not
separate Deployments. The pod shares one network namespace, so the dev container
reaches them at `127.0.0.1:<port>` with no Service, no DNS name, and no network
policy. We rejected a Deployment plus Service per sidecar: it multiplies objects
per environment, and a dev database is not meant to outlive the pod. The cost:
sidecars share the pod's lifecycle and cannot be restarted independently, and
their state is ephemeral unless the environment has a persistent volume.

The dind sidecar needs `privileged: true`. Clusters that enforce the baseline Pod
Security standard reject that pod at creation time, and the rollout only reports
a timeout. `kiseki create --docker` therefore labels the namespace it creates
with `pod-security.kubernetes.io/enforce=privileged`. That widening is scoped to
one disposable namespace and the CLI prints it. We rejected asking the user to
label the namespace by hand: the failure appears as a pod that never starts, and
the flag would be a promise the tool does not keep.

Volumes, init containers, and port ordering complete the sidecar contract. A
sidecar with no volume cannot hold state, and an app that connects to redis during
startup races a container that starts in parallel; both failures look like a
broken environment rather than a missing piece of configuration. Declared sidecar
ports are therefore waited on before sshd starts, and `extraVolumes`,
`extraVolumeMounts`, and `extraInitContainers` are pass-through pod fields with
reserved-name checks rather than a second configuration language.
