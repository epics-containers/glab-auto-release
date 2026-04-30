#!/bin/bash
# UserPromptSubmit hook: verify the Claude sandbox is intact before
# executing any prompt. Exit code 2 blocks the prompt and shows the
# message to the user. See README-CLAUDE.md for the full sandbox model.

fail() { echo "BLOCKED: $1" >&2; exit 2; }

# Are we in the devcontainer at all?
[ -n "${IN_DEVCONTAINER:-}" ] || \
    fail "not in the devcontainer (IN_DEVCONTAINER unset). Reopen the project in the devcontainer."

# Host SSH agent must not be reachable. remoteEnv blanks SSH_AUTH_SOCK and
# `just claude` re-blanks it; if it is set, neither layer applied.
[ -z "${SSH_AUTH_SOCK:-}" ] || \
    fail "SSH_AUTH_SOCK is set ($SSH_AUTH_SOCK) — host SSH agent is reachable. run \"just claude\" or rebuild the devcontainer."

# GIT_ASKPASS is a script path, not a socket — check the env var directly.
[ -z "${GIT_ASKPASS:-}" ] || \
    fail "GIT_ASKPASS is set — VS Code askpass is injected. Rebuild the devcontainer (git.terminalAuthentication should be false)."

# VS Code drops a Node-based credential bridge as a script in /tmp. Not a
# socket — checked separately.
if compgen -G '/tmp/vscode-remote-containers-*.js' >/dev/null; then
    fail "/tmp/vscode-remote-containers-*.js bridge present — re-run .devcontainer/postStart.sh."
fi

# All other VS Code host bridges are unix sockets, and they appear in
# two locations:
#   /tmp/vscode-git-*.sock                  (VSCODE_GIT_IPC_HANDLE — git creds)
#   /tmp/vscode-ipc-*.sock                  (VSCODE_IPC_HOOK_CLI — `code` CLI)
#   /tmp/vscode-ssh-auth-*.sock             (host SSH agent forward)
#   /tmp/vscode-remote-containers-ipc-*.sock (Dev Containers extension RPC)
#   /run/user/<uid>/vscode-*.sock           (same bridges, different path)
# VS Code re-injects the env vars on attach AND re-creates the sockets up
# to ~60s after attach — see README-CLAUDE.md. The real defence is the
# continuous sweeper at .devcontainer/socket-sweeper.sh, started by
# `just claude` as Claude's sibling. This check is belt-and-braces: if
# the sweeper dies the sockets accumulate and we block here.
if compgen -G '/tmp/vscode-*.sock' >/dev/null; then
    fail "/tmp/vscode-*.sock present — socket sweeper not running. Restart with \"just claude\"."
fi
if compgen -G '/run/user/*/vscode-*.sock' >/dev/null; then
    fail "/run/user/*/vscode-*.sock present — socket sweeper not running. Restart with \"just claude\"."
fi

# system-scope credential.helper is where VS Code injects; if anything
# is set there git will use it before our per-host helpers.
if git config --system --get credential.helper >/dev/null 2>&1; then
    fail "system credential.helper is still set — re-run .devcontainer/postStart.sh."
fi

exit 0
