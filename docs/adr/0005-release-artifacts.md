# Releases are goreleaser tarballs that carry the chart

Status: accepted

Tags already existed (`ci.yml` triggers on `v*`) but nothing built a binary. The
CLI moves to Go, so the artifact becomes a compiled program rather than a
checkout to symlink, and the per-platform builds, archives, checksums and release
notes are exactly the work goreleaser exists to do. `goreleaser release --clean`
runs on the `mgmt` runner from `.forgejo/workflows/release.yml`; the tool is
installed by `scripts/ci/install-tools.sh --goreleaser`, pinned by version and
sha256 like helm, kubectl, just and Go.

The tarball is not a lone binary. `kiseki example --output` renders its sample
against the real chart and `create` will install it, so an artifact that unpacked
to a single file would fail at the first command that needs a chart. Each archive
contains the binary, `charts/kiseki/**`, the README and `examples/extraSVC.yaml`,
and `kiseki example --output` was verified against an unpacked archive, not just
against a checkout.

That layout is why `repo.Root()` now trusts two sources differently. A directory
found by walking up from the executable belongs to whoever installed it, so a
chart sitting next to the binary is enough; a directory found by walking up from
the working directory is not trusted that way and still has to carry a checkout
marker (`.git`, or a `go.mod` whose module path is kiseki). Embedding the chart in
the binary remains rejected for the reason in ADR 0004: chart work is a `helm
template` loop and should not require a rebuild.

Versions are stamped into the binary with `-X main.version`/`main.commit`/
`main.date`, printed by `kiseki version`. A plain `go build` says `dev`, so a
version quoted in a bug report distinguishes a release from a working tree.

Consequences:

- Pushing a `v*` tag publishes a release. Nothing else does: the workflow has no
  other trigger, so a broken config cannot publish from a branch.
- The token is Forgejo's repository-scoped `github.token`, which needs
  `contents: write`. If the instance restricts it, the workflow's env switches to
  a `RELEASE_TOKEN` secret; that is a one-line change, documented in the workflow.
- A release artifact cannot create environments yet. `create`, `destroy` and
  `proxy` still exec `scripts/kiseki.sh`, which an installed tarball does not
  contain, so those commands report exactly that instead of pretending. `version`,
  `help`, `list` and `example` are complete in a released binary; the rest becomes
  available as the port lands, and the release workflow needs no change when it
  does.
- The chart inside an archive is a copy. Fixing a chart bug still requires a new
  tag, which is the price of shipping a usable artifact rather than a binary that
  cannot render its own example.
- `dist/` is a build output and stays out of git; `just release-snapshot` builds
  and archives locally without publishing, and `just release-check` validates the
  config.
