# Persist the home directory, not the workdir

Status: accepted

`--persistence` mounts the claim at `/root`. The previous chart mounted it at
`/data`, a path nothing wrote to: the flag claimed a volume and then no part of
the environment used it. The state that matters for a dev environment is what
the dots bootstrap creates — dotfiles, language toolchains, package caches,
shell history — and all of it lives under `$HOME`.

The workdir is the wrong target. `/workdir` holds only the dots checkout that
`up.sh` recreates on every start; persisting it would preserve a git clone that
is cheaper to re-clone than to keep in sync, while the toolchain it installed
would still disappear. Mounting both would need two claims and leave the user
guessing which paths survive.

Consequences:

- The claim is `ReadWriteOnce`, so the Deployment keeps `strategy: Recreate`. A
  rolling update would hold two pods against the same volume.
- The default size is 10Gi, not 1Gi: a toolchain, a package cache, and a few
  cloned repositories do not fit comfortably in 1Gi.
- The first pod on an empty claim starts with an empty `/root`; `up.sh` runs the
  bootstrap on every start, so the directory converges without a seeding step.
- The image's `/root` content is hidden by the mount. The image does not rely on
  it: authorized keys come from `/etc/kiseki-ssh` and are copied in at start.
- Refreshing a dead pod keeps the claim, so `kiseki destroy` is the only
  operation that deletes the data. Operators should expect that asymmetry.
