# Claude sandbox

This project's devcontainer is configured to run Claude Code with
`--dangerously-skip-permissions` (see `justfile`'s `claude` recipe). To make
that safe, the container is set up as a sandbox: Claude can use the project
toolchain, push/pull through PATs it owns, and persist its own settings —
but it cannot reach back to the host's identity or shared resources.

This file documents what's locked down, what's deliberately left exposed,
and how to verify the sandbox is intact.

Background reading on the threat model — VS Code's IPC sockets, the git
credential bridge, and `VSCODE_IPC_HOOK_CLI` as a host code-exec channel:
[Coding agents in secured VS Code dev containers](https://www.danieldemmel.me/blog/coding-agents-in-secured-vscode-dev-containers).

## What's locked down

- **No host SSH keys.** `SSH_AUTH_SOCK` is unset in `remoteEnv`, so any
  SSH-agent forwarded by the host is invisible inside the container. No
  private keys are mounted into `/root/.ssh` either — only `known_hosts`.
- **No host bridges via VS Code IPC sockets.** VS Code drops several unix
  sockets in `/tmp` and `/run/user/<uid>/`, each a potential bridge from
  the container back to the host:
    - `vscode-git-*.sock` (referenced by `VSCODE_GIT_IPC_HANDLE`) — the
      git credential bridge that can surface host PATs.
    - `vscode-ipc-*.sock` (referenced by `VSCODE_IPC_HOOK_CLI`) — runs
      the `code` CLI on the host, opening files or executing commands.
    - `vscode-ssh-auth-*.sock` — VS Code's own SSH agent forward, reachable
      even when `SSH_AUTH_SOCK` is blanked because the path is discoverable.
    - `vscode-remote-containers-ipc-*.sock` — the Dev Containers extension's
      host-container RPC channel.

  VS Code re-injects the env vars on attach regardless of settings, AND
  re-creates the sockets up to ~60s after attach — so blanking the env
  vars in `remoteEnv` and one-shot socket removal in `postStart.sh` are
  both insufficient on their own. A compromised Claude does not need the
  env vars: it can `ls /tmp/vscode-*.sock` (or `/run/user/<uid>/`) and
  connect directly. The load-bearing defence is the continuous sweeper at
  `.devcontainer/socket-sweeper.sh`, which `inotifywait`'s both directories
  and removes any matching socket as it appears. `just claude` starts the
  sweeper and Claude as siblings of a bash wrapper, with two enforcement
  layers so a rogue Claude cannot escape the sweeper:
    1. `wait -n` in the wrapper: if either child exits, the wrapper kills
       the survivor. Handles the case where Claude kills only the sweeper.
    2. `setpriv --pdeathsig SIGKILL` on both children: the kernel kills
       each child the moment the wrapper dies. Handles the case where
       Claude kills the wrapper itself (which would otherwise reparent
       Claude to PID 1 and let it survive). The residual bypass is Claude
       calling `prctl(PR_SET_PDEATHSIG, 0)` to disable its own death
       signal — possible but requires a raw syscall, not just `kill`.

  `postStart.sh` still sweeps once at attach (covers the gap before
  `just claude` is invoked); `.claude/hooks/sandbox-check.sh` verifies the
  sockets are absent on every prompt submit (belt-and-braces if every
  layer above is somehow defeated).
- **No host URL-opener.** `BROWSER` is blanked so anything that calls
  `$BROWSER` in-container stays in-container instead of triggering a
  helper on the host.
- **No VS Code git credential injection.** Four Dev Containers settings
  pinned in `devcontainer.json` reduce what VS Code sets up in the first
  place — useful belt-and-braces on top of the socket deletion:
    - `git.terminalAuthentication: false` — VS Code's Git extension is
      told not to inject `GIT_ASKPASS` / `VSCODE_GIT_IPC_HANDLE` into the
      integrated terminal. In practice the Dev Containers extension can
      still re-inject `VSCODE_GIT_IPC_HANDLE` on attach, which is why
      the socket-deletion defence exists; `GIT_ASKPASS` is checked
      directly because it is a script path, not a socket.
    - `dev.containers.gitCredentialHelperConfigLocation: "none"` — the
      Dev Containers extension does not write a `credential.helper` line
      into `/etc/gitconfig`, so nothing in-container references the
      `/tmp/vscode-remote-containers-*.js` bridge.
    - `dev.containers.copyGitConfig: false` — the host's `~/.gitconfig`
      is not copied into the container, so any `url.ssh://...insteadOf`
      rewrites or per-host helpers stay on the host.
    - `dev.containers.dockerCredentialHelper: false` — VS Code does not
      inject the host's docker credential helper, so any in-container
      docker tooling cannot reach back to a host registry login.

  `postStart.sh` also clears any stray system-scope `credential.helper`
  and removes the `/tmp/vscode-remote-containers-*.js` shim if VS Code
  drops it on attach.
- **Per-host helpers point at the in-container CLI.** The host gitconfig
  often references `/usr/local/bin/gh`; here `gh` is at `/usr/bin/gh`. We
  rewrite the helper to `command -v gh` / `command -v glab` so it doesn't
  fall through to a stale entry.
- **All git remotes forced to HTTPS.** `url.<https>.insteadOf` rewrites
  `git@github.com:` and `git@gitlab.diamond.ac.uk:` so push/pull always
  uses the gh/glab credential helper rather than SSH.
- **Auth is per-repo.** `gh-auth-${repo}` and `glab-auth-${repo}` are
  named volumes, not bind mounts — each project gets its own scoped PAT
  via `just gh-auth` / `just glab-auth`. Authenticate once per repo and
  the token survives container rebuilds.

## What's deliberately exposed (and why)

- **`/root/.claude` is bind-mounted from the host's `~/.claude`.** Claude's
  settings, memory, hooks, and skills are shared between the host and the
  container — that's the whole point. Anything Claude writes to its own
  config persists to the host home directory. Treat `~/.claude` on the
  host as part of the sandbox boundary, not outside it.
- **`/workspaces` is the parent of the project, not the project itself.**
  The `workspaceMount` source is `${localWorkspaceFolder}/..`, so all
  sibling repos in the same parent directory are visible inside the
  container. This is intentional — it lets `pip install -e ../peer-repo`
  work and lets Claude read across related projects when asked. If you
  keep unrelated work in the same parent dir, Claude can see it.
- **`--net=host` shares the host's network namespace.** The container's
  hostname will match the host's, and any service bound to `localhost` on
  the host is reachable from inside. This is needed for X11, EPICS CA,
  and to avoid devcontainer port-forwarding hassles. It also means the
  container can talk to anything the host can talk to on its LAN.
- **`/cache` is a shared named volume across all devcontainers** built
  from this template — uv cache, pre-commit cache, and the project venv
  live there. Faster rebuilds; the trade-off is that a poisoned cache
  affects every project sharing the volume.

## Verifying the sandbox

From inside the container:

```bash
# Should be empty / unset
echo "SSH_AUTH_SOCK='${SSH_AUTH_SOCK:-<unset>}'"
echo "BROWSER='${BROWSER:-<unset>}'"
ssh-add -l                                         # "Could not open a connection..."
ls /root/.ssh                                      # only known_hosts

# VSCODE_GIT_IPC_HANDLE / VSCODE_IPC_HOOK_CLI may be set (VS Code re-injects
# on attach), but the sockets they point at must be gone — both /tmp and
# /run/user/<uid>/ are covered by the sweeper.
ls /tmp/vscode-*.sock 2>/dev/null                  # should match nothing
ls /run/user/*/vscode-*.sock 2>/dev/null           # should match nothing
[ -n "${VSCODE_GIT_IPC_HANDLE:-}" ] && ls "$VSCODE_GIT_IPC_HANDLE" 2>/dev/null  # no such file
[ -n "${VSCODE_IPC_HOOK_CLI:-}" ] && ls "$VSCODE_IPC_HOOK_CLI" 2>/dev/null      # no such file
pgrep -f socket-sweeper.sh                         # sweeper PID — must be live while `just claude` is running

# Should NOT return a host PAT
printf 'protocol=https\nhost=github.com\n\n' | git credential fill

# Should show only gh/glab helpers (no /tmp/vscode-remote-containers-*.js)
git config --global --list | grep -i credential
```

If `git credential fill` returns a `password=gho_...` for github.com when
you have not run `just gh-auth`, the sandbox is leaking — open an issue
against the python-copier-template.

## Authenticating

```bash
just gh-auth     # paste a github.com PAT (repo + workflow scope is enough)
just glab-auth   # gitlab.com  (pass a hostname arg for self-hosted instances)
```

## Starting Claude

```bash
just claude      # runs `claude --dangerously-skip-permissions` with SSH_AUTH_SOCK blanked
```
