# The CLI is a Go binary; everything else stays Bash

Status: accepted

`scripts/kiseki.sh` and `scripts/kiseki.d/*.sh` are 1,345 lines of Bash that
parse flags, validate Kubernetes quantities, keep a state directory, edit
`~/.ssh/config`, allocate ports, generate YAML and JSON, and poll the cluster.
Those are not shell tasks. The parts that grew hardest are the parts a typed
language does natively: `environment_state()` builds a `kubectl -o jsonpath`
query separated by `\x1f` because `IFS` collapses consecutive tab fields, then
takes it apart with `${rest%%,*}` chains; `append_sidecar()` writes a values
file with `printf` and a hand-written `yaml_str` escaper, while `--json` output
goes through a second, hand-written `json_str` escaper that has to agree with
it. The CLI moves to Go, in one binary.

Everything that runs inside the cluster or around it stays Bash. `up.sh` ships
in the chart and runs on stock `fedora:42`; a Go provisioning step would mean
publishing an image the project does not have, for 107 lines of `chown`, `dnf`
and `ssh-keygen`. `create-cluster.sh`, `test-gpu.sh` and `scripts/ci/*.sh` are
glue around `kind`, `docker` and `apt`, and are what CI invokes directly —
compiling them would add a build step to the lane that currently just runs them.
`install.sh` stops being a symlink into the checkout and becomes a build step.

Two host dependencies disappear with the port. `proxy.sh` bridges the forward
with `socat`; Go's `net.Dial` and `io.Copy` do the same without it.
`port_in_use()` shells out to `ss`, which is why `ci.yml` installs `iproute2`;
a bind attempt is both cheaper and free of that dependency.

The binary reads the cluster through `client-go`, not `kubectl -o json`. The
first draft shelled out to kubectl to keep the dependency tree small; review
overturned it on three concrete failures. A typed client takes a context, so a
context whose API server accepts the connection and never answers can no longer
hang `list` on one row. A JSON decode failure stops being indistinguishable from
a dead cluster. And pinning the kubeconfig becomes a field on the loading rules
instead of an environment variable spliced into a child process, where it
duplicated whatever `KUBECONFIG` the caller already had. `helm` stays a child
process — it is a release tool, not an API client — and so do the kubectl calls
inside the Bash `create`/`destroy` paths, which keep working until they are
ported. Dependencies are `client-go` with `api` and `apimachinery`, plus
`yaml.v3` once `create` starts emitting chart values. No `cobra`: the surface is
five subcommands, so `flag` with one `FlagSet` per subcommand is enough, and
`--json` becomes a struct tag instead of a second escaper.

The chart is not embedded. `CHART_DIR` is currently resolved relative to the
script, and `install.sh` deliberately symlinks into the checkout so edits are
live. A binary cannot do that, so resolution becomes: `$KISEKI_CHART`, then the
checkout found by walking up from the executable, then from the working
directory, then a clear error. Embedding would make the binary self-contained
and break the `helm template` iteration loop that chart work depends on; the
resolution order keeps both usable.

Consequences:

- Three contracts are frozen and must not drift during the port:
  `examples/extraSVC.yaml` is byte-diffed in `just lint`, the `--json` object
  shapes are public, and roughly ten Justfile assertions match exact error
  strings.
- The pod-state parser is the risky part of the port. Before deleting the Bash,
  capture real `kubectl get pods -o json` fixtures for the states it calls out —
  terminating-pod overlap, an unschedulable `PodScheduled` message, an init
  container retrying after a non-zero exit, a crash loop, and the ready case —
  and make them tests. The jsonpath version cannot be tested this way, so the
  fixtures are the port's first payoff.
- The `syntax` recipe becomes `go vet` and `go build`, and the mgmt CI lane
  installs Go through `scripts/ci/install-tools.sh --go`, pinned by version and
  sha256 like the rest of the toolchain rather than through an unpinned action.
  The CLI validation assertions in `just lint` move into table tests over the
  pure validators, which is what lets that lane stop installing `kubectl`, `helm`
  and `ssh` just to make its own assertions meaningful.
- `proxy` runs as an SSH `ProxyCommand` on every connection, so its startup
  cost is user-visible. A Go binary starts in single-digit milliseconds, faster
  than sourcing six files and starting three subshells.
- Migration is a strangler: the binary takes one subcommand at a time, and
  `create`, `destroy` and `proxy` exec the legacy script until they are ported.
  `install.sh` keeps pointing at the Bash until `create` lands, so `just test`
  and CI stay green throughout.
