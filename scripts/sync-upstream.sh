#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
upstream_url='https://github.com/deepseek-ai/chat-demo.git'

git_run() {
  printf '\n执行 Git 命令：git'
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
    printf '\n同步已停止（退出码 %s），请查看上方提示。\n' "$status" >&2
    if git_path_exists MERGE_HEAD; then
      printf '正在中止尚未完成的合并……\n' >&2
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
  printf '未找到 Git，请先安装 Git 后重试。\n' >&2
  exit 1
fi

actual_root="$(git_text rev-parse --show-toplevel)"
if [[ "$(cd -- "$actual_root" && pwd -P)" != "$repo_root" ]]; then
  printf '脚本所在目录与 Git 仓库根目录不匹配。\n' >&2
  exit 1
fi

for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
  if git_path_exists "$marker"; then
    printf '检测到 Git 操作尚未完成（%s），请先完成或中止该操作。\n' "$marker" >&2
    exit 1
  fi
done

branch="$(git_text branch --show-current)"
if [[ "$branch" != dev ]]; then
  printf "请先切换到 dev 分支再运行脚本（当前分支：'%s'）。\n" "$branch" >&2
  exit 1
fi

status="$(git_text status --porcelain)"
if [[ -n "$status" ]]; then
  printf '工作区存在未提交改动，请先提交或 stash 后再同步：\n%s\n' "$status" >&2
  exit 1
fi

if ! git -C "$repo_root" remote get-url origin >/dev/null 2>&1; then
  printf '缺少 origin 远端，请先将 origin 配置为指向你自己的 fork。\n' >&2
  exit 1
fi

origin_url="$(git_text remote get-url origin)"
if is_official_repo "$origin_url"; then
  printf 'origin 指向官方仓库，请将 origin 改为你自己的 fork；本脚本不会向 upstream 推送。\n' >&2
  exit 1
fi

if git -C "$repo_root" remote get-url upstream >/dev/null 2>&1; then
  configured_upstream="$(git_text remote get-url upstream)"
  if ! is_official_repo "$configured_upstream"; then
    printf 'upstream 远端没有指向 DeepSeek 官方仓库，请检查远端配置。\n' >&2
    exit 1
  fi
else
  printf '正在添加官方 upstream 远端：%s\n' "$upstream_url"
  git_run remote add upstream "$upstream_url"
fi

printf 'Fork 远端（origin）：已配置\n'
printf '官方远端（upstream）：已配置\n'

for ref in refs/heads/main refs/heads/dev; do
  if ! has_ref "$ref"; then
    printf '缺少必需的本地分支：%s\n' "${ref#refs/heads/}" >&2
    exit 1
  fi
done

printf '\n正在从 origin 和 upstream 获取更新……\n'
git_run fetch --prune origin
git_run fetch --prune upstream

if ! has_ref refs/remotes/upstream/main; then
  printf '未找到官方 upstream/main 分支。\n' >&2
  exit 1
fi

if ! is_ancestor main upstream/main; then
  printf '本地 main 含有 upstream/main 中没有的提交。未执行合并或推送，请手动检查 main。\n' >&2
  exit 1
fi

if has_ref refs/remotes/origin/main && ! is_ancestor origin/main upstream/main; then
  printf 'origin/main 并非落后于 upstream/main。未执行合并或推送，请手动检查 fork 的 main 分支。\n' >&2
  exit 1
fi

if has_ref refs/remotes/origin/dev; then
  if ! is_ancestor origin/dev dev && ! is_ancestor dev origin/dev; then
    printf '本地 dev 与 origin/dev 已分叉。未执行合并或推送，请先手动协调两个 dev 分支。\n' >&2
    exit 1
  fi
fi

printf '\n即将执行以下操作：\n  1. 将本地 main 快进到 upstream/main。\n  2. 如有需要，将 origin/dev 快进合并到本地 dev。\n  3. 将 main 合并到 dev。\n  4. 将 main 和 dev 推送到 origin（你的 fork）。\n'
read -r -p '是否继续？输入 y 或“是”确认 [y/N] ' answer
case "$answer" in
  y|Y|yes|YES|Yes|是|继续) ;;
  *)
    printf '已取消，未执行合并或推送。\n'
    exit 0
    ;;
esac

printf '\n正在更新 main……\n'
git_run switch main
git_run merge --ff-only upstream/main

printf '\n正在更新 dev……\n'
git_run switch dev
if has_ref refs/remotes/origin/dev; then
  git_run merge --ff-only origin/dev
fi
git_run merge --no-edit main

printf '\n正在将更新后的分支推送到 origin……\n'
git_run push origin main
git_run push origin dev

printf '\n同步完成，当前位于 dev 分支。\n'
