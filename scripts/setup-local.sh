#!/usr/bin/env bash
# Clone ecosystem-ci forks locally on their tracked branch, with origin + source remotes.
#
#   setup-local.sh <name> [<name>...]   clone/refresh specific repos
#   setup-local.sh --all                clone/refresh every repo in ecosystem.json
#
# Each fork lands in $DEST/<name> (default ~/git/github.com/vite-plus-ecosystem-ci),
# checked out on its tracked branch, with remotes:
#   origin -> git@github.com:<org>/<name>.git   (the fork)
#   source -> git@github.com:<upstream>.git      (the original)
# Override the destination with ECOSYSTEM_DEST.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${ECOSYSTEM_MANIFEST:-$SCRIPT_DIR/../ecosystem.json}"
DEST="${ECOSYSTEM_DEST:-$HOME/git/github.com/vite-plus-ecosystem-ci}"

command -v jq  >/dev/null || { echo "jq is required"  >&2; exit 1; }
command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }
[ $# -ge 1 ] || { grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 1; }

ORG="$(jq -r '.org' "$MANIFEST")"
if [ "$1" = "--all" ]; then
  targets="$(jq -r '.repos[].name' "$MANIFEST")"
else
  targets="$*"
fi

mkdir -p "$DEST"
for name in $targets; do
  entry="$(jq -c --arg n "$name" '.repos[] | select(.name==$n)' "$MANIFEST")"
  if [ -z "$entry" ]; then echo "!! $name: not in manifest, skipping" >&2; continue; fi
  branch="$(jq -r '.branch'    <<<"$entry")"
  upstream="$(jq -r '.upstream' <<<"$entry")"
  target="$DEST/$name"

  if [ -d "$target/.git" ]; then
    git -C "$target" fetch --quiet origin
  else
    git clone --quiet "git@github.com:$ORG/$name.git" "$target"
  fi
  git -C "$target" checkout --quiet "$branch"

  if git -C "$target" remote get-url source >/dev/null 2>&1; then
    git -C "$target" remote set-url source "git@github.com:$upstream.git"
  else
    git -C "$target" remote add source "git@github.com:$upstream.git"
  fi

  echo "OK  $name -> $(git -C "$target" rev-parse --abbrev-ref HEAD)  (source: $upstream)"
done
