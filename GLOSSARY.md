# Glossary

The project's shared vocabulary. Issues, documents, and skills use these terms.

- **Environment**: one named development environment on a Kubernetes cluster. It owns one namespace, one Helm release, one SSH alias, and one port-forward.
- **Spawn script**: the bash entry point that creates, lists, and destroys environments. It also provides the SSH proxy helper.
- **Proxy helper**: the part of the spawn script that keeps the port-forward alive and bridges an SSH connection to the pod.
