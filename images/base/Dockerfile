# Base image for kiseki environments.
#
# The stock fedora image has no sshd, so up.sh installs openssh-server, zsh, git
# and rsync from Fedora mirrors on every pod start, and dots' bootstrap.sh then
# runs its own `dnf install` for curl, tar, findutils, python3, gcc, make and
# socat. Both are network fetches in the critical path of provisioning: a slow
# or unreachable mirror leaves the environment stuck before anyone can log in.
# Baking the packages in removes those fetches entirely; up.sh and bootstrap.sh
# keep their install branches as a fallback for the stock image.
#
# Build: `just base-image` (or `docker buildx build -t <ref> images/base`).
#
# The ARG must be declared before FROM for --build-arg to bind to it; without the
# declaration Docker warns UndefinedArgInFrom and the build silently relies on the
# inline default. 46 is still "Container Image Prerelease" on Docker Hub, so 45.
ARG FEDORA_VERSION=45
FROM fedora:${FEDORA_VERSION}

# openssh-server/zsh/git/rsync: what up.sh would otherwise install.
# docker-cli: only used with --docker, but it is small and removes a fetch from
#   that path too.
# curl/tar/findutils/python3/gcc/make/socat: dots' bootstrap prerequisites.
# diffutils/patch/procps-ng/hostname/iproute/which/lsof: what a development
#   shell is expected to have. `just lint` in kiseki needs `diff`.
# install_weak_deps=0 keeps the image from pulling recommendation packages.
RUN dnf5 install -y --setopt=install_weak_deps=0 \
        openssh-server zsh git rsync docker-cli \
        curl tar findutils python3 gcc make socat \
        procps-ng hostname iproute which lsof diffutils patch \
 && dnf5 clean packages \
 && rm -rf /var/cache/dnf /var/cache/libdnf5 /var/cache/dnf5

# sshd's runtime dir and its privilege-separation chroot. up.sh recreates both,
# but a container started without up.sh should still be able to run sshd.
RUN mkdir -p /run/sshd /usr/share/empty.sshd

# chsh validates -s against /etc/shells by literal string, and PATH resolves zsh
# to /usr/sbin/zsh (/usr/sbin is a symlink to bin), which the zsh package does
# not list. Without this every bootstrap prints "not listed in /etc/shells"
# while claiming success.
RUN zsh_path="$(command -v zsh)" \
 && grep -qx "$zsh_path" /etc/shells || echo "$zsh_path" >> /etc/shells

# Presence marker: up.sh skips its package install when this exists, and prints
# it on start so a stuck environment records which image it booted.
RUN printf 'fedora %s\n' "$(rpm -E %fedora)" > /etc/kiseki-image

LABEL org.opencontainers.image.title="kiseki base" \
      org.opencontainers.image.description="Fedora with the kiseki provisioning prerequisites preinstalled" \
      org.opencontainers.image.source="https://forgejo.srv.hnatekmar.dev/hnatekmar/kiseki"
