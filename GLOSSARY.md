# Glossary

The project's shared vocabulary. Issues, documents, and skills use these terms.

- **Environment**: one named development environment on a Kubernetes cluster. It owns one namespace (`kiseki-<name>`), one Helm release, one SSH alias (`kiseki-<name>`), and one port-forward.
- **Home volume**: the optional PVC mounted at `/root` when `--persistence` is set. It is the only part of an environment that survives a pod restart.
- **Workdir**: `/workdir`, recreated on every start. Provisioning clones dots there and runs its bootstrap; it is deliberately not persistent.
- **Spawn script**: the bash entry point that creates, lists, and destroys environments. It also provides the SSH proxy helper.
- **Proxy helper**: the part of the spawn script that keeps the port-forward alive and bridges an SSH connection to the pod.
- **Address**: the hostname an environment is published at, passed as `--address`. It becomes the Ingress host and the TLS common name.
- **Web port**: the container port behind an address, passed as `--port`. The app must listen on `0.0.0.0`.
- **Sidecar**: an extra container in the dev pod, sharing its network namespace. The dev container reaches it on `127.0.0.1:<port>`.
- **dind sidecar**: the privileged `docker:dind` container that provides a docker daemon to the dev container through `DOCKER_HOST`.
