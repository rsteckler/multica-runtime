#!/usr/bin/env bash
# Multica daemon entrypoint. Wires up auth (Multica + GitHub) and execs the
# daemon in foreground mode so the container's PID 1 is the daemon itself.
set -euo pipefail

: "${MULTICA_TOKEN:?MULTICA_TOKEN is required (Multica personal access token)}"
: "${MULTICA_SERVER_URL:?MULTICA_SERVER_URL is required (e.g. ws://host:8080/ws)}"

# Multica login: writes token + watched workspaces into ~/.multica/config.json
# (which is on a PVC, so this is idempotent across restarts). Failures here
# don't block startup — the daemon's own reconnect loop will retry against
# the backend once it starts.
if ! multica login --token "$MULTICA_TOKEN"; then
    echo "warning: 'multica login' failed at startup; daemon will retry on its own" >&2
fi

# GitHub auth: the daemon clones repos over HTTPS to populate its repo
# cache (~/multica_workspaces/.repos), and a headless container has no
# credentials by default — clones of private repos fail with
# "terminal prompts disabled". When GH_TOKEN is provided, rewrite
# github.com HTTPS URLs to embed the token. Written on every start so the
# value tracks the current secret even if it rotates.
if [[ -n "${GH_TOKEN:-}" ]]; then
    git config --global \
        "url.https://x-access-token:${GH_TOKEN}@github.com/.insteadOf" \
        "https://github.com/"
    # Mirror to GITHUB_TOKEN so any tool checking that name also works
    # (gh CLI honours either, but some scripts check GITHUB_TOKEN).
    export GITHUB_TOKEN="${GITHUB_TOKEN:-$GH_TOKEN}"
fi

exec multica daemon start --foreground "$@"
