#!/bin/bash
# 上游同步：拉取原仓库更新 → cherry-pick → 统一品牌 → 重算 SHA256SUMS → 测试 → 推送 → 可选部署到本机
# 用法: bash scripts/sync-upstream.sh [--deploy] [--no-push] [--deploy-only]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
UPSTREAM="https://github.com/YOURSJEYO/claude-switcher"
MARKER="$HOME/.claude-switcher/upstream-last-sha"
DEFAULT_BASE="179a38bfdb61c834e4e6d044c82308ecf9bf29a6"
LOCK="/tmp/claude-switcher-sync.lock"
PUSH=1; DEPLOY=0; MODE=""
for a in "$@"; do
  case "$a" in
    --no-push) PUSH=0 ;;
    --deploy) DEPLOY=1 ;;
    --deploy-only) MODE="deploy-only" ;;
  esac
done

log() { echo "SYNC: $*"; }
fail() { echo "SYNC: FAIL: $*"; exit 1; }

deploy_local() {
  local changed="$1"
  local appdir="$HOME/Applications/Claude切换器.app"
  local core="$HOME/.local/bin/claude-switch.sh"
  local touched_admin=""
  echo "$changed" | grep -qE '^(daemons/|installer/)' && touched_admin="yes"
  if echo "$changed" | grep -q '^core/claude-switch.sh'; then
    cp "$core" "$core.bak.$(date +%s)" 2>/dev/null || true
    cp core/claude-switch.sh "$core.new"
    grep -E '^(PROXY_MODE|PROXY_GROUP|COUNTRY_TARGET|TZ_TARGET|LOCALE_TARGET)="' "$core" > /tmp/cs-conf.txt 2>/dev/null || true
    while IFS= read -r line; do
      key="${line%%=*}"
      [ -n "$key" ] && sed -i '' "s|^${key}=.*|${line}|" "$core.new"
    done < /tmp/cs-conf.txt
    mv "$core.new" "$core"; chmod +x "$core"
    "$core" check >/tmp/cs-check.log 2>&1 || log "注意：更新后 check 未通过（$(cat /tmp/cs-check.log)）"
    log "已更新本机核心脚本（保留地区/代理配置）"
  fi
  if echo "$changed" | grep -q '^core/stun-probe.py'; then
    cp core/stun-probe.py "$HOME/.claude-switcher/stun-probe.py"
    log "已更新 STUN 探针"
  fi
  if echo "$changed" | grep -q '^app/'; then
    if [ -d "$appdir" ]; then
      if swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" app/main.swift -o /tmp/cs-app-new -framework SwiftUI -framework AppKit >/tmp/deploy-build.log 2>&1; then
        pkill -x ClaudeSwitcher 2>/dev/null || true; sleep 1
        cp /tmp/cs-app-new "$appdir/Contents/MacOS/ClaudeSwitcher"
        codesign --force --deep -s - "$appdir" >/dev/null 2>&1 || true
        open "$appdir"
        rm -f /tmp/cs-app-new
        log "已更新本机 App 并重新启动（不影响 Claude）"
      else
        log "App 编译失败，跳过 App 更新"
      fi
    else
      log "未找到 ~/Applications/Claude切换器.app，跳过 App 更新"
    fi
  fi
  [ -n "$touched_admin" ] && log "守护进程/安装器有变动，自动部署需管理员：请手动重跑 installer/安装.command"
  return 0
}

if [ "${MODE:-}" = "deploy-only" ]; then
  deploy_local "core/claude-switch.sh core/stun-probe.py app/main.swift"
  exit 0
fi

mkdir "$LOCK" 2>/dev/null || { log "已有同步在跑，退出"; exit 0; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

[ -z "$(git status --porcelain)" ] || fail "工作区不干净，先处理未提交改动"
[ "$(git branch --show-current)" = "main" ] || fail "当前不在 main 分支"

git fetch -q "$UPSTREAM" main:refs/remotes/upstream/main || fail "拉取上游失败（网络？）"
UP_SHA=$(git rev-parse upstream/main)
BASE=$(cat "$MARKER" 2>/dev/null || echo "$DEFAULT_BASE")
git cat-file -e "$BASE^{commit}" 2>/dev/null || fail "基线 $BASE 不在本地对象库"
[ "$BASE" = "$UP_SHA" ] && { log "无更新（已是最新 ${UP_SHA}）"; exit 0; }

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
    log "冲突仅 SHA256SUMS，已用本仓库版本继续"
  else
    git cherry-pick --abort 2>/dev/null
    git checkout -q main
    git branch -D "$BRANCH" >/dev/null 2>&1
    fail "存在人工冲突，已放弃本次同步: $CONF"
  fi
done

FILES=$(git grep -l 'YOURSJEYO' -- . ':!scripts/sync-upstream.sh' 2>/dev/null || true)
[ -n "$FILES" ] && echo "$FILES" | while read -r f; do sed -i '' 's|YOURSJEYO/claude-switcher|fubo-ops/claude-switcher|g' "$f"; done
FILES2=$(git grep -l 'yoursjeyo\.github\.io' -- . ':!scripts/sync-upstream.sh' 2>/dev/null || true)
[ -n "$FILES2" ] && echo "$FILES2" | while read -r f; do sed -i '' 's|yoursjeyo\.github\.io/claude-switcher|fubo-ops.github.io/claude-switcher|g' "$f"; done
[ -n "$FILES" ] && log "已重新统一仓库地址"

bash scripts/gen-sums.sh >/dev/null || fail "生成 SHA256SUMS 失败"
shasum -a 256 -c SHA256SUMS >/dev/null || fail "SHA256SUMS 校验失败"

log "运行回归测试..."
python3 -m unittest discover -s tests -v >/tmp/sync-tests.log 2>&1 || { tail -20 /tmp/sync-tests.log; fail "单元测试失败"; }
log "编译 App 并自检..."
BUILD="/tmp/claude-switcher-sync-build-$$"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" app/main.swift -o "$BUILD" -framework SwiftUI -framework AppKit >/tmp/sync-build.log 2>&1 || { tail -10 /tmp/sync-build.log; rm -f "$BUILD"; fail "编译失败"; }
"$BUILD" --selftest >/tmp/sync-selftest.log 2>&1 || { tail -10 /tmp/sync-selftest.log; rm -f "$BUILD"; fail "App 自检失败"; }
grep -q 'SELFTEST: PASS' /tmp/sync-selftest.log || { rm -f "$BUILD"; fail "App 自检未通过"; }
rm -f "$BUILD"
find . -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
log "测试通过（单测 + 编译 + selftest）"

if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -q -m "chore(sync): 上游同步后统一品牌与 SHA256SUMS"
fi

git checkout -q main
git merge --ff-only "$BRANCH" >/dev/null 2>&1 || fail "main 快进合并失败"
git branch -d "$BRANCH" >/dev/null 2>&1 || true

CHANGED=$(git diff --name-only "$BASE".."$UP_SHA" 2>/dev/null)
if [ "$DEPLOY" -eq 1 ]; then
  deploy_local "$CHANGED"
fi

if [ "$PUSH" -eq 1 ]; then
  git push -q origin main || fail "推送到 origin 失败"
  log "已推送 origin/main（$(git rev-parse --short HEAD)）"
else
  log "已本地合并（--no-push，未推送）"
fi
echo "$UP_SHA" > "$MARKER"
log "同步完成：基线更新到 $(git rev-parse --short upstream/main)"
