#!/usr/bin/env bash
# bump-version.sh — Update the multica daemon image and helm chart to a
# specific upstream multica release. Deterministic and idempotent: running
# twice with the same args produces the same final state.
#
# What it changes:
#   - Dockerfile         ARG MULTICA_VERSION    -> <multica_version>
#   - values.yaml        image.backend.tag      -> v<multica_version>
#                        image.frontend.tag     -> v<multica_version>
#                        daemon.image.tag       -> <runtime_tag>
#   - Chart.yaml         appVersion             -> "v<multica_version>"
#
# Chart `version` is intentionally NOT bumped — Chart.yaml's own comment says
# only bump it on template changes, and this script only touches values.
#
# Usage:
#   scripts/bump-version.sh <multica_version> [runtime_tag]
#
# Examples:
#   scripts/bump-version.sh 0.3.1            # auto-bumps daemon image tag patch
#   scripts/bump-version.sh v0.3.1 v0.2.0    # explicit daemon image tag
#
# Env:
#   MULTICA_HELM_DIR   Path to the helm chart directory.
#                      Default: ~/code/helmcharts/charts/productivity/multica

set -euo pipefail

err() { echo "error: $*" >&2; exit 1; }

usage() {
    awk '/^# /{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"
}

[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 1; }

multica_raw="$1"
multica_ver="${multica_raw#v}"
[[ "$multica_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || err "invalid multica version '$multica_raw' — expected semver like 0.3.1 or v0.3.1"
multica_tag="v${multica_ver}"

runtime_dir="$(cd "$(dirname "$0")/.." && pwd)"
helm_dir="${MULTICA_HELM_DIR:-$HOME/code/helmcharts/charts/productivity/multica}"

dockerfile="$runtime_dir/Dockerfile"
values_yaml="$helm_dir/values.yaml"
chart_yaml="$helm_dir/Chart.yaml"

[[ -f "$dockerfile" ]]  || err "missing $dockerfile"
[[ -f "$values_yaml" ]] || err "missing $values_yaml — set MULTICA_HELM_DIR if helm chart lives elsewhere"
[[ -f "$chart_yaml" ]]  || err "missing $chart_yaml"

# Runtime image tag: explicit arg wins; otherwise patch-bump the tag currently
# in values.yaml under daemon.image.
current_runtime_tag="$(awk '
    /repository: ghcr.io\/rsteckler\/multica-runtime/ { getline; print; exit }
' "$values_yaml" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
[[ -n "$current_runtime_tag" ]] || err "couldn't read current daemon.image.tag from $values_yaml"

if [[ -n "${2:-}" ]]; then
    runtime_tag="$2"
    [[ "$runtime_tag" != v* ]] && runtime_tag="v$runtime_tag"
    [[ "$runtime_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || err "invalid runtime tag '$2' — expected semver like v0.1.6"
else
    IFS=. read -r maj min pat <<<"${current_runtime_tag#v}"
    runtime_tag="v${maj}.${min}.$((pat + 1))"
fi

# Snapshot current state for the summary.
current_multica="$(grep -oE '^ARG MULTICA_VERSION=[^ ]+' "$dockerfile" | cut -d= -f2 || true)"
current_appver="$(grep -oE '^appVersion: ".*"' "$chart_yaml" | cut -d'"' -f2 || true)"

printf 'Updating to multica %s (daemon image %s)\n\n' "$multica_tag" "$runtime_tag"
printf '  Dockerfile MULTICA_VERSION     %-10s -> %s\n' "$current_multica" "$multica_ver"
printf '  values.yaml backend.tag        %-10s -> %s\n' "$current_appver" "$multica_tag"
printf '  values.yaml frontend.tag       %-10s -> %s\n' "$current_appver" "$multica_tag"
printf '  values.yaml daemon.image.tag   %-10s -> %s\n' "$current_runtime_tag" "$runtime_tag"
printf '  Chart.yaml appVersion          %-10s -> %s\n\n' "$current_appver" "$multica_tag"

# --- Dockerfile -------------------------------------------------------------
sed -i \
    -e "s|^ARG MULTICA_VERSION=.*|ARG MULTICA_VERSION=${multica_ver}|" \
    "$dockerfile"

# --- values.yaml ------------------------------------------------------------
# Each replacement is scoped to the `tag:` line *immediately after* the
# matching `repository:` line, so postgres/redis tags are never touched.
# Any inline comment on the tag line is intentionally dropped — it's
# usually stale by the time you bump.
sed -i \
    -e "\|repository: ghcr.io/multica-ai/multica-backend|{n;s|tag: .*|tag: ${multica_tag}|;}" \
    -e "\|repository: ghcr.io/multica-ai/multica-web|{n;s|tag: .*|tag: ${multica_tag}|;}" \
    -e "\|repository: ghcr.io/rsteckler/multica-runtime|{n;s|tag: .*|tag: ${runtime_tag}|;}" \
    "$values_yaml"

# --- Chart.yaml -------------------------------------------------------------
sed -i \
    -e "s|^appVersion:.*|appVersion: \"${multica_tag}\"|" \
    "$chart_yaml"

cat <<EOF
Done. Next steps:

  1. Build + push the new daemon image (CI tags + pushes on git tag):
       cd $runtime_dir
       git add -A && git commit -m 'chore: bump baked multica to $multica_ver'
       git tag $runtime_tag && git push origin main $runtime_tag

  2. Roll out via the chart:
       cd $helm_dir
       git add -A && git commit -m 'chore(multica): upgrade to $multica_tag (daemon $runtime_tag)'
       git push
EOF
