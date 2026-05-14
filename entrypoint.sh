#!/usr/bin/env bash
# Multica daemon entrypoint. Logs in with the provided token (idempotent —
# the daemon stores config under ~/.multica which is on a PVC) and then
# execs the daemon in foreground mode so the container's PID 1 is the
# daemon itself. Kubernetes can then signal it directly and the readiness/
# liveness probes against the health port work as expected.
set -euo pipefail

: "${MULTICA_TOKEN:?MULTICA_TOKEN is required (Multica personal access token)}"
: "${MULTICA_SERVER_URL:?MULTICA_SERVER_URL is required (e.g. ws://host:8080/ws)}"

# `multica login --token` writes the token into ~/.multica/config.json and
# auto-discovers / watches workspaces. Safe to re-run on every container
# start. We swallow failure here because a transient backend hiccup at boot
# shouldn't prevent the daemon from coming up — the daemon's own reconnect
# loop will retry against the backend once it starts.
if ! multica login --token "$MULTICA_TOKEN"; then
    echo "warning: 'multica login' failed at startup; daemon will retry on its own" >&2
fi

exec multica daemon start --foreground "$@"
