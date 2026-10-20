#!/usr/bin/env bash
# Write a kind cluster config for a docker daemon that is not on localhost.
#
# The normal kind kubeconfig points at 127.0.0.1:<port>, which is only correct
# when the daemon runs in the same network namespace as kubectl. In a dind
# runner the daemon is a sibling: its published ports live on the bridge the job
# container is attached to, so that bridge's address is both what the kubeconfig
# must name and what the daemon must bind. host.docker.internal is not usable
# here — it resolves to the daemon's *default* bridge, which is a different
# interface from the per-job network.
#
# Usage: kind-config.sh OUTPUT
set -euo pipefail

out="${1:?usage: kind-config.sh OUTPUT}"

# Default gateway of this container = the dind daemon's bridge address. Read
# from /proc/net/route so this works in a bare image without iproute2.
gw_hex="$(awk '$2 == "00000000" { print $3; exit }' /proc/net/route)"
if [[ -z "${gw_hex}" ]]; then
  echo "kind-config: no default gateway; is this container on a docker bridge?" >&2
  exit 1
fi
# 00000000 is what an onlink/default-less route reports; treating it as an
# address would publish the API server on 0.0.0.0.
if [[ ${#gw_hex} -ne 8 || "$gw_hex" == "00000000" ]]; then
  echo "kind-config: no usable default gateway ('$gw_hex') in /proc/net/route" >&2
  exit 1
fi
# The field is the address little-endian in hex.
gw="$(printf '%d.%d.%d.%d' "0x${gw_hex:6:2}" "0x${gw_hex:4:2}" "0x${gw_hex:2:2}" "0x${gw_hex:0:2}")"

port="${KIND_APISERVER_PORT:-16443}"
[[ "$port" =~ ^[0-9]{1,5}$ ]] || {
  echo "kind-config: KIND_APISERVER_PORT must be a port number, got '$port'" >&2
  exit 1
}
port=$((10#$port))
((port >= 1 && port <= 65535)) || {
  echo "kind-config: KIND_APISERVER_PORT out of range: $port" >&2
  exit 1
}

cat >"$out" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  apiServerAddress: "${gw}"
  # A fixed port is required, not cosmetic: with port 0 kind probes for a free
  # one by listening on the api server address itself, which lives on the daemon
  # host and not in this container, so that probe fails with "cannot assign
  # requested address". With an explicit port kind skips the probe and the
  # daemon publishes on the bridge.
  apiServerPort: ${port}
kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      certSANs:
        - "${gw}"
EOF

echo "kind-config: api server address ${gw} -> $out"
