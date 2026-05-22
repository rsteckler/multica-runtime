# multica-runtime

Container image that runs the [Multica](https://github.com/multica-ai/multica)
agent daemon as a Kubernetes workload. Bakes in the stable agent toolchain
(Claude Code, gh, Railway, Modal, PostHog) plus a standard dev environment
so agents can run real builds and deploys without a network detour for
every dependency.

The image is consumed by the homelab Helm chart at
`helmcharts/charts/productivity/multica/templates/daemon-deployment.yaml`.

## What's inside

| Tool | Source | Purpose |
| --- | --- | --- |
| `multica` | GitHub release (pinned via `MULTICA_VERSION` build-arg) | Multica CLI + daemon |
| `claude` | `npm i -g @anthropic-ai/claude-code` | Claude Code agent |
| `gh` | `cli.github.com` apt repo | GitHub CLI |
| `railway` | `npm i -g @railway/cli` | Railway deploys |
| `render` | GitHub release (pinned via `RENDER_CLI_VERSION` build-arg) | Render deploys |
| `modal` | `pip install modal` (in `/opt/modal-venv`) | Modal deploys |
| `posthog-cli` | `npm i -g posthog-cli` | PostHog admin |
| `node` 22 LTS | NodeSource apt repo | Node toolchain |
| `python3` + `uv` | apt + Astral installer | Python toolchain |
| `go` 1.26 | go.dev tarball | Go toolchain |
| `git`, `make`, `build-essential`, `ripgrep`, `fd`, `fzf`, `jq`, `tmux`, `vim`, ... | apt | Standard dev tools |
| `psql`, `redis-cli` | apt | DB clients for in-cluster debugging |

Long-tail CLIs the user hasn't asked for (fly, vercel, supabase, ...) can be
installed at runtime into `$HOME/.local/bin`. That directory is on a PVC
in the helm chart, so installs persist across pod restarts — install once,
all future sessions see it.

## Environment

| Variable | Required | Purpose |
| --- | --- | --- |
| `MULTICA_TOKEN` | yes | Multica personal access token (`mul_...`) |
| `MULTICA_SERVER_URL` | yes | WebSocket URL of the backend, e.g. `ws://homestack-multica-backend:8080/ws` |
| `ANTHROPIC_API_KEY` | recommended | Used by Claude Code for non-interactive auth |
| `RENDER_API_KEY` | optional | Used by `render` CLI for non-interactive auth |
| `MULTICA_AGENT_RUNTIME_NAME` | optional | Display name in Multica's runtime list (default `Local Agent`) |
| `MULTICA_DAEMON_DEVICE_NAME` | optional | Display name for this device |
| `MULTICA_WORKSPACES_ROOT` | optional | Task workspace root (default `~/multica_workspaces`) |
| `MULTICA_DAEMON_MAX_CONCURRENT_TASKS` | optional | Max parallel tasks (default 20) |

See `multica daemon --help` and `CLI_AND_DAEMON.md` in the multica repo for
the full env-var surface (poll intervals, GC TTLs, agent paths, etc.).

## Build locally

```bash
docker build -t multica-runtime:dev --build-arg MULTICA_VERSION=0.2.29 .
docker run --rm -it \
    -e MULTICA_TOKEN=mul_xxx \
    -e MULTICA_SERVER_URL=ws://host.docker.internal:8080/ws \
    -e ANTHROPIC_API_KEY=sk-ant-... \
    multica-runtime:dev
```

## Release

Push a `vX.Y.Z` tag — the GitHub Action builds and pushes
`ghcr.io/<owner>/multica-runtime:vX.Y.Z` + `:latest`. The `MULTICA_VERSION`
build-arg is automatically derived from the tag, so `v0.2.29` builds against
the matching Multica server release.

```bash
git tag v0.2.29
git push origin v0.2.29
```

Then bump the `daemon.image.tag` field in the helm chart's `values.yaml`.
