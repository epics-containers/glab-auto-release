#!/bin/bash
# UserPromptSubmit hook: verify the Claude sandbox is intact before
# executing any prompt. Exit code 2 blocks the prompt and shows the
# message to the user. See README-CLAUDE.md for the full sandbox model.

fail() { echo "BLOCKED: $1" >&2; exit 2; }

# Are we in the devcontainer at all?
[ -n "${IN_DEVCONTAINER:-}" ] || \
    fail "not in the devcontainer (IN_DEVCONTAINER unset). Reopen the project in the devcontainer."

# IS_SANDBOX=1 is set by the inner `just claude` script after it sets up
# the private mount namespace. If it's missing, Claude was launched
# without the namespace and /tmp/vscode-*.sock host bridges are reachable.
[ -n "${IS_SANDBOX:-}" ] || \
    fail "IS_SANDBOX unset — Claude was not launched via \"just claude\", so the mount-namespace sandbox is not active."

# Host SSH agent must not be reachable. remoteEnv blanks SSH_AUTH_SOCK and
# `just claude` re-blanks it; if it is set, neither layer applied.
[ -z "${SSH_AUTH_SOCK:-}" ] || \
    fail "SSH_AUTH_SOCK is set ($SSH_AUTH_SOCK) — host SSH agent is reachable. run \"just claude\" or rebuild the devcontainer."

# VS Code git credential bridge must be unreachable. The env vars may
# still be inherited, but the private mount namespace should hide the
# IPC socket and askpass script under /tmp. If the files exist, /tmp
# is not isolated.
[ ! -e "${VSCODE_GIT_IPC_HANDLE:-}" ] || \
    fail "VSCODE_GIT_IPC_HANDLE socket ($VSCODE_GIT_IPC_HANDLE) is reachable — VS Code credential bridge leaked into the namespace. Relaunch via \"just claude\" or rebuild the devcontainer."
[ ! -e "${GIT_ASKPASS:-}" ] || \
    fail "GIT_ASKPASS script ($GIT_ASKPASS) is reachable — VS Code askpass leaked into the namespace. Relaunch via \"just claude\" or rebuild the devcontainer."

# The /tmp credential helper script VS Code drops in must have been removed.
if compgen -G '/tmp/vscode-remote-containers-*.js' >/dev/null; then
    fail "/tmp/vscode-remote-containers-*.js bridge present — re-run .devcontainer/postStart.sh."
fi

# system-scope credential.helper is where VS Code injects; if anything
# is set there git will use it before our per-host helpers.
if git config --system --get credential.helper >/dev/null 2>&1; then
    fail "system credential.helper is still set — re-run .devcontainer/postStart.sh."
fi

exit 0
