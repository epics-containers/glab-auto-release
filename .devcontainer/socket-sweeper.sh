#!/bin/bash
# Continuous removal of VS Code host-bridge sockets and shims, run as a
# sibling of the Claude process under `just claude`. VS Code's server
# re-creates these up to ~60s after attach, so the one-shot rm in
# postStart.sh is not enough on its own. See README-CLAUDE.md.
#
# This script is started by the `claude` recipe in justfile. If it dies,
# the wrapper kills Claude. If Claude dies, the wrapper kills this.
set -euo pipefail

# Initial sweep — catches sockets that already exist before inotifywait
# registers its watch. Covers both /tmp and /run/user/<uid>/, the two
# locations where VS Code drops these.
sweep_once() {
    rm -f /tmp/vscode-*.sock /tmp/vscode-remote-containers-*.js 2>/dev/null || true
    for d in /run/user/*/; do
        [ -d "$d" ] && rm -f "$d"vscode-*.sock 2>/dev/null || true
    done
}

sweep_once

# Build watch list from directories that actually exist; inotifywait
# fails the whole process if any path is missing. Trailing slashes are
# important so `--format '%w%f'` produces a clean full path.
watches=( /tmp/ )
for d in /run/user/*/; do
    [ -d "$d" ] && watches+=( "$d" )
done

# Watch for new files and rm anything matching our patterns. CREATE fires
# when a socket is bound; MOVED_TO covers the rare case of a file being
# moved in from another mount.
inotifywait -m -q -e create,moved_to --format '%w%f' "${watches[@]}" | \
while read -r path; do
    case "$path" in
        */vscode-*.sock|*/vscode-remote-containers-*.js)
            rm -f "$path" 2>/dev/null || true
            ;;
    esac
done
