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

# GitHub auth. The daemon clones private repos into ~/multica_workspaces/.repos,
# and a headless container has no creds by default. We use `gh auth setup-git`
# to install gh as a git credential helper — this avoids URL-encoding traps
# (tokens with #, &, ? etc.) that the previous `url.<...>.insteadOf` approach
# was vulnerable to.
#
# The PVC may carry stale credential config from a prior token. Clear all
# github.com-related rewrites/helpers before re-applying so the value
# tracks the current secret on every start.
git config --global --unset-all 'credential.https://github.com.helper' 2>/dev/null || true
# Remove any url.*.insteadOf rules that point at github.com — including the
# old token-embedding pattern. Iterate because section names contain the
# (potentially URL-encoded) token literally.
while IFS= read -r section; do
    [[ -z "$section" ]] && continue
    git config --global --remove-section "$section" 2>/dev/null || true
done < <(git config --global --get-regexp '^url\..*github\.com.*\.insteadOf$' 2>/dev/null \
            | sed -E 's/^(url\..*github\.com.*)\.insteadOf .*/\1/' \
            | sort -u)

if [[ -n "${GH_TOKEN:-}" ]]; then
    # Sanity check: a valid PAT against api.github.com returns 200. Log a
    # clear warning if not — saves a lot of "why are clones failing" later.
    if ! curl -fsS -H "Authorization: token ${GH_TOKEN}" \
              -o /dev/null -w "%{http_code}" \
              https://api.github.com/user 2>/dev/null | grep -q '^200$'; then
        echo "warning: GH_TOKEN does not authenticate against api.github.com — private repo clones will fail" >&2
    fi

    # gh CLI uses GH_TOKEN automatically. `gh auth setup-git` installs gh
    # as the git credential helper for github.com, which sidesteps URL-
    # encoding issues entirely and is the GitHub-recommended approach.
    gh auth setup-git --hostname github.com 2>/dev/null || \
        echo "warning: 'gh auth setup-git' failed; private repo clones may fail" >&2

    # Mirror so scripts that check GITHUB_TOKEN also work.
    export GITHUB_TOKEN="${GITHUB_TOKEN:-$GH_TOKEN}"
fi

# Commit signing. When MULTICA_SIGNING_KEY (private SSH key, in OpenSSH
# format) and MULTICA_GIT_EMAIL are provided, configure git to sign every
# commit. GitHub renders these as "Verified" provided:
#   1. The matching public key is registered on the user's GitHub account
#      as a *Signing key* (NOT an authentication key — separate section
#      at github.com/settings/ssh/new).
#   2. MULTICA_GIT_EMAIL matches a verified email on that account.
#
# The key is rewritten on every container start so rotations propagate
# without manual intervention. ~/.ssh is on the PVC, but we overwrite it
# anyway — the secret is the source of truth.
if [[ -n "${MULTICA_SIGNING_KEY:-}" && -n "${MULTICA_GIT_EMAIL:-}" ]]; then
    install -d -m 700 "${HOME}/.ssh"
    printf '%s\n' "${MULTICA_SIGNING_KEY}" > "${HOME}/.ssh/multica_signing"
    chmod 600 "${HOME}/.ssh/multica_signing"
    # ssh-keygen -Y sign refuses keys without a trailing newline on some
    # OpenSSH versions; printf already added one above. Generate the .pub
    # so git can find it for SSH signature verification when needed.
    ssh-keygen -y -f "${HOME}/.ssh/multica_signing" > "${HOME}/.ssh/multica_signing.pub" 2>/dev/null \
        || echo "warning: failed to derive public key from MULTICA_SIGNING_KEY" >&2

    git config --global user.email "${MULTICA_GIT_EMAIL}"
    git config --global user.name "${MULTICA_GIT_NAME:-Multica Daemon}"
    git config --global gpg.format ssh
    git config --global user.signingkey "${HOME}/.ssh/multica_signing"
    git config --global commit.gpgsign true
    git config --global tag.gpgsign true
fi

exec multica daemon start --foreground "$@"
