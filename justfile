# Start Claude Code in sandbox mode (no SSH agent, skip permission prompts).
# Runs the socket sweeper (.devcontainer/socket-sweeper.sh) as Claude's
# sibling under this recipe — if either child exits the other is killed,
# so a compromised Claude cannot disable the sweeper and keep operating.
# See README-CLAUDE.md for the full sandbox model.
# VSCODE_GIT_IPC_HANDLE / GIT_ASKPASS are no longer cleared here — the
# devcontainer pins git.terminalAuthentication=false so VS Code never sets
# them. SSH_AUTH_SOCK still gets blanked because there is no VS Code setting
# to disable host SSH agent forwarding.
claude:
    #!/bin/bash
    set -uo pipefail
    # setpriv --pdeathsig SIGKILL: kernel kills the child the moment this
    # bash wrapper exits, so a compromised Claude that kills the wrapper
    # to escape the sweeper dies before it can use any socket. Closes the
    # window between wrapper death and bash's `wait -n` cleanup. The
    # residual bypass is Claude calling prctl(PR_SET_PDEATHSIG, 0) itself
    # — accepted; raises the bar from one shell command to a syscall.
    setpriv --pdeathsig SIGKILL .devcontainer/socket-sweeper.sh &
    sweeper=$!
    SSH_AUTH_SOCK= IS_SANDBOX=1 setpriv --pdeathsig SIGKILL claude --dangerously-skip-permissions &
    claude=$!
    trap 'kill $sweeper $claude 2>/dev/null; wait 2>/dev/null' EXIT INT TERM
    wait -n $sweeper $claude || true
    if ! kill -0 $sweeper 2>/dev/null && kill -0 $claude 2>/dev/null; then
        echo "FATAL: socket sweeper exited — terminating Claude" >&2
    fi


# Authenticate gh CLI with a GitHub PAT (token not stored in shell history)
gh-auth:
    #!/bin/bash
    read -sp "GitHub PAT: " t && echo
    echo "$t" | gh auth login --with-token
    unset t
    gh auth setup-git
    gh auth status


# Authenticate glab CLI with a GitLab PAT (token not stored in shell history).
# --git-protocol https prevents glab's SSH insteadOf rewrite.
glab-auth hostname="gitlab.com":
    #!/bin/bash
    read -sp "GitLab PAT for {{ hostname }}: " t && echo
    echo "$t" | glab auth login --stdin --hostname {{ hostname }} --git-protocol https
    unset t
    glab auth status
