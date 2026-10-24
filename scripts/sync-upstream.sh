#!/bin/bash
# 上游同步：拉取原仓库更新 → cherry-pick → 修复品牌/校验 → 测试 → 推送到本仓库
# 用法: bash scripts/sync-upstream.sh [--no-push]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
UPSTREAM="https://github.com/fubo-ops/claude-switcher"
MARKER="$HOME/.claude-switcher/upstream-last-sha"
DEFAULT_BASE="179a38bfdb61c834e4e6d044c82308ecf9bf29a6"
LOCK="/tmp/claude-switcher-sync.lock"
PUSH=1
[ "${1:-}" = "--no-push" ] && PUSH=0

log() { echo "SYNC: $*"; }
fail() { echo "SYNC: FAIL: $*"; exit 1; }

mkdir "$LOCK" 2>/dev/null || { log "已有同步在跑，退出"; exit 0; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

[ -z "$(git status --porcelain)" ] || fail "工作区不干净，先处理未提交改动"
[ "$(git branch --show-current)" = "main" ] || fail "当前不在 main 分支"

git fetch -q "$UPSTREAM" main:refs/remotes/upstream/main || fail "拉取上游失败（网络？）"
UP_SHA=$(git rev-parse upstream/main)
BASE=$(cat "$MARKER" 2>/dev/null || echo "$DEFAULT_BASE")
git cat-file -e "$BASE^{commit}" 2>/dev/null || fail "基线 $BASE 不在本地对象库（请先 fetch 全部历史）"
[ "$BASE" = "$UP_SHA" ] && { log "无更新（已是最新 $UP_SHA）"; exit 0; }

COMMITS=$(git rev-list --reverse "$BASE..upstream/main")
[ -z "$COMMITS" ] && { log "无更新"; exit 0; }
log "发现上游更新: $(echo "$COMMITS" | wc -l | tr -d ' ') 个提交"
echo "$COMMITS" | while read -r c; do log "  - $(git log -1 --format='%h %s' "$c")"; done

BRANCH="sync/upstream-$(date +%Y%m%d-%H%M%S)"
git checkout -q -b "$BRANCH" main

for c in $COMMITS; do
  if git cherry-pick -x "$c" >/tmp/cp.log 2>&1; then
    log "已应用 $(git log -1 --format='%h %s' "$c")"
    continue
  fi
  CONF=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
  if [ "$CONF" = "SHA256SUMS " ]; then
    git checkout --ours SHA256SUMS 2>/dev/null || true
    git add SHA256SUMS
    git -c core.editor=true cherry-pick --continue >/dev/null 2>&1 || fail "解决 SHA256SUMS 冲突失败"
    log "冲突仅 SHA256SUMS，已用本仓库版本并通过 cherry-pick 继续"
  else
    git cherry-pick --abort 2>/dev/null
    git checkout -q main
    git branch -D "$BRANCH" >/dev/null 2>&1
    fail "存在人工冲突，已放弃本次同步: $CONF"
  fi
done

# 品牌统一：不允许上游账号/域名回流
if git grep -l 'YOURSJEYO' >/dev/null 2>&1; then
  git grep -l 'YOURSJEYO' | while read -r f; do
    sed -i '' 's|fubo-ops/claude-switcher|fubo-ops/claude-switcher|g; s|yoursjeyo\.github\.io/claude-switcher|fubo-ops.github.io/claude-switcher|g' "$f"
  done
  log "已重新统一仓库地址"
fi
git grep -l 'yoursjeyo\.github\.io' >/dev/null 2>&1 && {
  git grep -l 'yoursjeyo\.github\.io' | while read -r f; do
    sed -i '' 's|yoursjeyo\.github\.io/claude-switcher|fubo-ops.github.io/claude-switcher|g' "$f"
  done
}

# 校验清单必须与当前文件一致
bash scripts/gen-sums.sh >/dev/null || fail "生成 SHA256SUMS 失败"
shasum -a 256 -c SHA256SUMS >/dev/null || fail "SHA256SUMS 校验失败"

# 测试：回归单测 + 编译 + App 自检
log "运行回归测试..."
python3 -m unittest discover -s tests -v >/tmp/sync-tests.log 2>&1 || { tail -20 /tmp/sync-tests.log; fail "单元测试失败"; }
log "编译 App 并自检..."
BUILD="/tmp/claude-switcher-sync-build-$$"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" app/main.swift -o "$BUILD" -framework SwiftUI -framework AppKit >/tmp/sync-build.log 2>&1 || { tail -10 /tmp/sync-build.log; rm -f "$BUILD"; fail "编译失败"; }
"$BUILD" --selftest >/tmp/sync-selftest.log 2>&1 || { tail -10 /tmp/sync-selftest.log; rm -f "$BUILD"; fail "App 自检失败"; }
grep -q 'SELFTEST: PASS' /tmp/sync-selftest.log || { rm -f "$BUILD"; fail "App 自检未通过"; }
rm -f "$BUILD"
log "测试通过（单测 + 编译 + selftest）"

if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -q -m "chore(sync): 上游同步后统一品牌与 SHA256SUMS"
fi

git checkout -q main
git merge --ff-only "$BRANCH" >/dev/null 2>&1 || fail "main 快进合并失败"
git branch -d "$BRANCH" >/dev/null 2>&1 || true

if [ "$PUSH" -eq 1 ]; then
  git push -q origin main || fail "推送到 origin 失败"
  log "已推送 origin/main（$(git rev-parse --short HEAD)）"
else
  log "已本地合并（--no-push，未推送）"
fi

echo "$UP_SHA" > "$MARKER"
log "同步完成：基线更新到 $(git rev-parse --short upstream/main)"
