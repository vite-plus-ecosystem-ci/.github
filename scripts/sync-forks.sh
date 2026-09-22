#!/usr/bin/env bash
# Safely fast-forward ecosystem-ci fork bases to their tracked upstream branches.
#
#   sync-forks.sh <name> [<name>...]   sync specific repos
#   sync-forks.sh --all                sync every repo in ecosystem.json
#   sync-forks.sh --check --all        report drift without pushing
#
# Exit 0 means every selected fork is current or was safely fast-forwarded.
# Exit 1 means an operational error occurred. Exit 2 means manual work is needed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${ECOSYSTEM_MANIFEST:-$SCRIPT_DIR/../ecosystem.json}"
DEST="${ECOSYSTEM_DEST:-$HOME/git/github.com/vite-plus-ecosystem-ci}"

usage() {
  grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'
}

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }

check_only=false
all=false
names=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check)
      check_only=true
      ;;
    --all)
      all=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      names+=("$1")
      ;;
  esac
  shift
done

if $all && [ ${#names[@]} -gt 0 ]; then
  echo "--all cannot be combined with repository names" >&2
  exit 1
fi
if ! $all && [ ${#names[@]} -eq 0 ]; then
  usage >&2
  exit 1
fi

ORG="$(jq -r '.org' "$MANIFEST")"
if $all; then
  targets="$(jq -r '.repos[].name' "$MANIFEST")"
else
  targets="${names[*]}"
fi

current=0
synced=0
stale=0
manual=0
errors=0

for name in $targets; do
  entry="$(jq -c --arg n "$name" '.repos[] | select(.name==$n)' "$MANIFEST")"
  if [ -z "$entry" ]; then
    echo "ERROR  $name: not in manifest" >&2
    errors=$((errors + 1))
    continue
  fi

  branch="$(jq -r '.branch' <<<"$entry")"
  upstream="$(jq -r '.upstream' <<<"$entry")"
  target="$DEST/$name"
  source_url="git@github.com:$upstream.git"

  if [ ! -d "$target/.git" ]; then
    echo "ERROR  $name: checkout not found at $target; run scripts/setup-local.sh $name" >&2
    errors=$((errors + 1))
    continue
  fi

  if git -C "$target" remote get-url source >/dev/null 2>&1; then
    if ! git -C "$target" remote set-url source "$source_url"; then
      echo "ERROR  $name: cannot configure source remote" >&2
      errors=$((errors + 1))
      continue
    fi
  else
    if ! git -C "$target" remote add source "$source_url"; then
      echo "ERROR  $name: cannot add source remote" >&2
      errors=$((errors + 1))
      continue
    fi
  fi

  if ! git -C "$target" fetch --quiet origin "+refs/heads/$branch:refs/remotes/origin/$branch"; then
    echo "ERROR  $name: cannot fetch origin/$branch" >&2
    errors=$((errors + 1))
    continue
  fi
  if ! git -C "$target" fetch --quiet source "+refs/heads/$branch:refs/remotes/source/$branch"; then
    echo "ERROR  $name: cannot fetch source/$branch ($upstream)" >&2
    errors=$((errors + 1))
    continue
  fi

  if ! counts="$(git -C "$target" rev-list --left-right --count "origin/$branch...source/$branch")"; then
    echo "ERROR  $name: cannot compare origin/$branch with source/$branch" >&2
    errors=$((errors + 1))
    continue
  fi
  read -r fork_only upstream_only <<<"$counts"

  if [ "$fork_only" -ne 0 ]; then
    echo "MANUAL $name/$branch: $fork_only fork-only commit(s), $upstream_only upstream commit(s); not changed"
    manual=$((manual + 1))
    continue
  fi

  if [ "$upstream_only" -eq 0 ]; then
    echo "CURRENT $name/$branch"
    current=$((current + 1))
    continue
  fi

  if $check_only; then
    echo "STALE   $name/$branch: can fast-forward by $upstream_only commit(s)"
    stale=$((stale + 1))
    continue
  fi

  if ! git -C "$target" push --no-verify origin "source/$branch:refs/heads/$branch" >/dev/null; then
    echo "ERROR  $name/$branch: fast-forward push failed" >&2
    errors=$((errors + 1))
    continue
  fi

  echo "SYNCED  $name/$branch: advanced by $upstream_only commit(s)"
  echo "REOPEN  $name: close and reopen any current smoke-test PR that existed before this sync"
  synced=$((synced + 1))

  current_branch="$(git -C "$target" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ "$current_branch" = "$branch" ]; then
    if ! git -C "$target" diff --quiet || ! git -C "$target" diff --cached --quiet; then
      echo "MANUAL $name/$branch: local branch has changes and was not advanced"
      manual=$((manual + 1))
    elif ! git -C "$target" merge --quiet --ff-only "source/$branch"; then
      echo "MANUAL $name/$branch: local branch did not fast-forward; remote fork is already current"
      manual=$((manual + 1))
    fi
  fi

  if command -v gh >/dev/null; then
    open_prs="$(gh pr list --repo "$ORG/$name" --base "$branch" --state open --limit 100 \
      --json number,headRefName,url \
      --jq '.[] | select(.headRefName | test("^(update-vite-plus-prerelease-test-|test/vite-plus-prerelease-)")) | "PR      #\(.number) \(.headRefName) \(.url)"' \
      2>/dev/null || true)"
    if [ -n "$open_prs" ]; then
      printf '%s\n' "$open_prs"
    fi
  fi
done

echo "SUMMARY current=$current synced=$synced stale=$stale manual=$manual errors=$errors"

if [ "$errors" -ne 0 ]; then
  exit 1
fi
if [ "$manual" -ne 0 ] || [ "$stale" -ne 0 ]; then
  exit 2
fi
