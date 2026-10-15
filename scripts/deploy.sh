#!/usr/bin/env bash
#
# Deploy a revision of this repository into the local daemon venv and restart
# the launchd-managed Maestral daemon.
#
# Usage: scripts/deploy.sh [GIT_REF]      (default: HEAD)
#
# Overridable with environment variables:
#   MAESTRAL_REPO         git checkout to deploy from
#   MAESTRAL_FORK_VENV    virtualenv that the daemon runs from
#   MAESTRAL_AGENT_LABEL  launchd agent label of the daemon

set -euo pipefail

MAESTRAL_REPO="${MAESTRAL_REPO:-/Users/kywk/kywk/project/maestral}"
MAESTRAL_FORK_VENV="${MAESTRAL_FORK_VENV:-/Users/kywk/.local/share/maestral-fork/venv}"
MAESTRAL_AGENT_LABEL="${MAESTRAL_AGENT_LABEL:-com.samschott.maestral-daemon.maestral}"

REF="${1:-HEAD}"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "Deploying '$REF' from $MAESTRAL_REPO ..."

# Export the requested revision without any .git metadata.
git -C "$MAESTRAL_REPO" archive "$REF" | tar -x -C "$STAGING"

# Install into the daemon venv. --no-deps is load-bearing: it keeps the
# existing dependency set (in particular the pinned Dropbox SDK) untouched.
# --force-reinstall makes sure that reinstalling the same version still
# picks up the new code.
"$MAESTRAL_FORK_VENV/bin/pip" install --quiet --force-reinstall --no-deps "$STAGING"

# Restart the daemon. Stop the current process first, then let launchd start
# a fresh instance so the agent keeps managing the daemon.
"$MAESTRAL_FORK_VENV/bin/maestral" stop || true

if ! launchctl kickstart -k "gui/$(id -u)/$MAESTRAL_AGENT_LABEL"; then
    echo "launchctl kickstart failed, falling back to a manual start" >&2
    "$MAESTRAL_FORK_VENV/bin/maestral" start
fi

sleep 5
"$MAESTRAL_FORK_VENV/bin/maestral" status

echo "Deployed '$REF' to $MAESTRAL_FORK_VENV"
