#!/bin/bash
# Inner script for `just claude`: run inside a private mount namespace
# (created by `unshare -m` from the justfile recipe). Mounts tmpfs over
# the locations VS Code uses for host-bridge sockets and any credential
# dirs the user may bind in for their own use, then exec's claude with
# PR_SET_PDEATHSIG so it dies if its parent (the wrapping shell) does.
# Requires CAP_SYS_ADMIN — granted via --cap-add=SYS_ADMIN in
# devcontainer.json's runArgs. See README-CLAUDE.md for the full model.
set -euo pipefail

# VS Code drops IPC sockets (vscode-ipc-*.sock, vscode-git-*.sock,
# vscode-ssh-auth-*.sock, vscode-remote-containers-ipc-*.sock) and the
# vscode-remote-containers-*.js credential shim in /tmp, plus more in
# /run/user/<uid>/. Replacing these directories with tmpfs in Claude's
# namespace makes them invisible — the host's processes outside this
# namespace continue to use them normally.
mount -t tmpfs tmpfs /tmp
if [ -d /run/user ]; then
    mount -t tmpfs tmpfs /run/user
fi

# Mask credential directories the user may bind in from the host for
# their own use from non-Claude terminals (e.g. ~/.ssh for git push over
# SSH). Claude sees an empty tmpfs; the user's regular shell, which
# runs outside this namespace, sees the originals.
for d in /root/.ssh /root/.gnupg /root/.aws /root/.azure /root/.gcloud /root/.docker; do
    if [ -d "$d" ]; then
        mount -t tmpfs tmpfs "$d"
    fi
done
# .netrc is a single file, not a dir — mask via bind to /dev/null.
if [ -e /root/.netrc ]; then
    mount --bind /dev/null /root/.netrc
fi

# IS_SANDBOX=1 is the canary `.claude/hooks/sandbox-check.sh` keys off to
# verify this script ran. SSH_AUTH_SOCK= is belt-and-braces; the path it
# would point at is no longer reachable in the new /tmp anyway.
exec setpriv --pdeathsig SIGKILL env SSH_AUTH_SOCK= IS_SANDBOX=1 \
    claude --dangerously-skip-permissions
