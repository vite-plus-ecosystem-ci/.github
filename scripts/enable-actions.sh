#!/usr/bin/env bash
# Enable GitHub Actions on ecosystem-ci forks.
#
#   enable-actions.sh <name> [<name>...]   enable Actions on specific forks
#   enable-actions.sh --all                enable Actions on every repo in ecosystem.json
#
# Sets the repo-level Actions toggle, then activates any workflows still parked
# in the fork-disabled state (scheduled/cron workflows are not auto-activated on
# forks). Idempotent: safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${ECOSYSTEM_MANIFEST:-$SCRIPT_DIR/../ecosystem.json}"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh is required" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }
[ $# -ge 1 ] || { grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 1; }

ORG="$(jq -r '.org' "$MANIFEST")"
if [ "$1" = "--all" ]; then
  targets="$(jq -r '.repos[].name' "$MANIFEST")"
else
  targets="$*"
fi

for name in $targets; do
  gh api -X PUT "repos/$ORG/$name/actions/permissions" \
    -F enabled=true -f allowed_actions=all >/dev/null

  ids="$(gh api "repos/$ORG/$name/actions/workflows" \
    --jq '.workflows[] | select(.state=="disabled_fork") | .id' 2>/dev/null || true)"
  activated=0
  for id in $ids; do
    if gh api -X PUT "repos/$ORG/$name/actions/workflows/$id/enable" >/dev/null 2>&1; then
      activated=$((activated + 1))
    fi
  done

  left="$(gh api "repos/$ORG/$name/actions/workflows" \
    --jq '[.workflows[] | select(.state!="active")] | length' 2>/dev/null || echo '?')"
  echo "OK  $name  (activated $activated fork-disabled workflow(s); non-active remaining: $left)"
done
