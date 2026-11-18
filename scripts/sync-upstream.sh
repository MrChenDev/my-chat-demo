#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
upstream_url='https://github.com/deepseek-ai/chat-demo.git'

git_run() {
  printf '\n> git'
  printf ' %q' "$@"
  printf '\n'
  git -C "$repo_root" "$@"
}

git_text() {
  git -C "$repo_root" "$@"
}

is_official_repo() {
  case "$1" in
    https://github.com/deepseek-ai/chat-demo|https://github.com/deepseek-ai/chat-demo/|https://github.com/deepseek-ai/chat-demo.git|https://github.com/deepseek-ai/chat-demo.git/|git@github.com:deepseek-ai/chat-demo|git@github.com:deepseek-ai/chat-demo.git|ssh://git@github.com/deepseek-ai/chat-demo|ssh://git@github.com/deepseek-ai/chat-demo.git)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

has_ref() {
  git -C "$repo_root" show-ref --verify --quiet "$1"
}

git_path_exists() {
  local path
  path="$(git_text rev-parse --git-path "$1")" || return 1
  if [[ "$path" != /* ]]; then
    path="$repo_root/$path"
  fi
  [[ -e "$path" ]]
}

is_ancestor() {
  git -C "$repo_root" merge-base --is-ancestor "$1" "$2" >/dev/null 2>&1
}

on_exit() {
  local status=$?
  trap - EXIT
  if (( status != 0 )); then
    printf '\nSync stopped (exit %s). Review the message above.\n' "$status" >&2
    if git_path_exists MERGE_HEAD; then
      printf 'Aborting the incomplete merge...\n' >&2
      git -C "$repo_root" merge --abort || true
    fi
    local current_branch
    current_branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || true)"
    if [[ "$current_branch" == main ]] && ! git_path_exists MERGE_HEAD; then
      git -C "$repo_root" switch dev || true
    fi
  fi
  exit "$status"
}
trap on_exit EXIT

if ! command -v git >/dev/null 2>&1; then
  printf 'Git was not found. Install Git and try again.\n' >&2
  exit 1
fi

actual_root="$(git_text rev-parse --show-toplevel)"
if [[ "$(cd -- "$actual_root" && pwd -P)" != "$repo_root" ]]; then
  printf 'The script directory does not match the Git repository root.\n' >&2
  exit 1
fi

for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
  if git_path_exists "$marker"; then
    printf 'A Git operation is already in progress (%s). Finish or abort it first.\n' "$marker" >&2
    exit 1
  fi
done

branch="$(git_text branch --show-current)"
if [[ "$branch" != dev ]]; then
  printf "Switch to the dev branch before running this script (current branch: '%s').\n" "$branch" >&2
  exit 1
fi

status="$(git_text status --porcelain)"
if [[ -n "$status" ]]; then
  printf 'The working tree is not clean. Commit or stash changes before syncing:\n%s\n' "$status" >&2
  exit 1
fi

if ! git -C "$repo_root" remote get-url origin >/dev/null 2>&1; then
  printf 'The origin remote is missing. Configure origin to point to your fork first.\n' >&2
  exit 1
fi

origin_url="$(git_text remote get-url origin)"
if is_official_repo "$origin_url"; then
  printf 'origin points to the official repository. Configure origin to your fork; this script never pushes to upstream.\n' >&2
  exit 1
fi

if git -C "$repo_root" remote get-url upstream >/dev/null 2>&1; then
  configured_upstream="$(git_text remote get-url upstream)"
  if ! is_official_repo "$configured_upstream"; then
    printf 'The upstream remote does not point to the official repository: %s\n' "$configured_upstream" >&2
    exit 1
  fi
else
  printf 'Adding official upstream remote: %s\n' "$upstream_url"
  git_run remote add upstream "$upstream_url"
fi

printf 'Fork (origin): %s\n' "$origin_url"
printf 'Official (upstream): %s\n' "$(git_text remote get-url upstream)"

for ref in refs/heads/main refs/heads/dev; do
  if ! has_ref "$ref"; then
    printf 'Required local branch is missing: %s\n' "${ref#refs/heads/}" >&2
    exit 1
  fi
done

printf '\nFetching updates from origin and upstream...\n'
git_run fetch --prune origin
git_run fetch --prune upstream

if ! has_ref refs/remotes/upstream/main; then
  printf 'The official upstream/main branch was not found.\n' >&2
  exit 1
fi

if ! is_ancestor main upstream/main; then
  printf 'Local main has commits not present in upstream/main. Inspect main manually; nothing was merged or pushed.\n' >&2
  exit 1
fi

if has_ref refs/remotes/origin/main && ! is_ancestor origin/main upstream/main; then
  printf 'origin/main is not behind upstream/main. Inspect the fork main branch manually; nothing was merged or pushed.\n' >&2
  exit 1
fi

if has_ref refs/remotes/origin/dev; then
  if ! is_ancestor origin/dev dev && ! is_ancestor dev origin/dev; then
    printf 'Local dev and origin/dev have diverged. Reconcile them manually; nothing was merged or pushed.\n' >&2
    exit 1
  fi
fi

printf '\nThis will:\n  1. Fast-forward local main to upstream/main.\n  2. Fast-forward dev from origin/dev when needed.\n  3. Merge main into dev.\n  4. Push main and dev to origin (your fork).\n'
read -r -p 'Continue? [y/N] ' answer
case "$answer" in
  y|Y|yes|YES|Yes) ;;
  *)
    printf 'Cancelled. No merges or pushes were made.\n'
    exit 0
    ;;
esac

printf '\nUpdating main...\n'
git_run switch main
git_run merge --ff-only upstream/main

printf '\nUpdating dev...\n'
git_run switch dev
if has_ref refs/remotes/origin/dev; then
  git_run merge --ff-only origin/dev
fi
git_run merge --no-edit main

printf '\nPushing updated branches to origin...\n'
git_run push origin main
git_run push origin dev

printf '\nSync completed. You are on dev.\n'
