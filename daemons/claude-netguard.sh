#!/bin/bash
# Claude 切换器 - 网络自动恢复守护（用户态 LaunchAgent）
# 隧道异常中断且“最近还在正常使用”时自动重连；三档策略：scutil start → 拉起客户端 → 重启客户端。
# 恢复后若断网前 Claude 在运行，则通过 check 后自动重新打开（避免保镖杀进程后一直空着）。
# 失败每 20s 重试，最长 5 分钟；用户主动关闭代理超过 5 分钟后不再介入。
set -u
export LC_ALL=en_US.UTF-8
H="__HOME__"
MODE="__PROXY_MODE__"
SERVICE="__PROXY_SERVICE__"
APP=""
case "$MODE" in
  shadowrocket) APP="Shadowrocket" ;;
  clash-verge) APP="Clash Verge" ;;
  sing-box) APP="sing-box" ;;
  clashx) APP="ClashX" ;;
  surge) APP="Surge" ;;
esac
BASE="$H/.claude-switcher"
STATE="$BASE/netguard.state"
COOLDOWN="$BASE/netguard.cooldown"
LOG="$H/Library/Logs/claude-netguard.log"
SW="$H/.local/bin/claude-switch.sh"
CLAUDE_STATE="$BASE/netguard.claude"
mkdir -p "$BASE"
now=$(date +%s)

tun_up() { ifconfig 2>/dev/null | grep -q 'inet 198\.18\.'; }

proxy_up() {
  case "$MODE" in
    shadowrocket)
      nc=$(scutil --nc list 2>/dev/null)
      if echo "$nc" | grep -q 'com.liguangming.Shadowrocket'; then
        echo "$nc" | grep 'com.liguangming.Shadowrocket' | grep -q '(Connected)'
      else
        tun_up
      fi ;;
    clash-verge) pgrep -f verge-mihomo >/dev/null 2>&1 && tun_up ;;
    sing-box) pgrep -f sing-box >/dev/null 2>&1 && tun_up ;;
    clashx) { pgrep -x ClashX >/dev/null 2>&1 || pgrep -f clash >/dev/null 2>&1; } && tun_up ;;
    surge) pgrep -f Surge >/dev/null 2>&1 && tun_up ;;
    *) tun_up ;;
  esac
}

if tun_up && proxy_up; then
  echo "$now ok" > "$STATE"
  if pgrep -f '/Applications/Claude.app/Contents/MacOS/Claude' >/dev/null 2>&1; then
    echo running > "$CLAUDE_STATE"
  else
    echo stopped > "$CLAUDE_STATE"
  fi
  exit 0
fi

last=$(awk '{print $1}' "$STATE" 2>/dev/null)
last=${last:-$now}
down=$((now - last))
# 只在“最近 5 分钟内还好用”且已断 >=15s 时介入，避免跟用户主动关代理打架
grep -q ' ok$' "$STATE" 2>/dev/null || exit 0
[ "$down" -lt 300 ] || exit 0
[ "$down" -ge 15 ] || exit 0
cd_ts=$(cat "$COOLDOWN" 2>/dev/null || echo 0)
[ $((now - cd_ts)) -lt 20 ] && exit 0
echo "$now" > "$COOLDOWN"

echo "$(date '+%F %T') 隧道中断 ${down}s，尝试自动恢复 (mode=$MODE service=$SERVICE)" >> "$LOG"

# 隧道恢复后，如果断网前 Claude 正在运行，则通过安检后自动重新打开
restore_claude() {
  [ "$(cat "$CLAUDE_STATE" 2>/dev/null)" = "running" ] || return 0
  pgrep -f '/Applications/Claude.app/Contents/MacOS/Claude' >/dev/null 2>&1 && return 0
  if "$SW" check >/dev/null 2>&1; then
    if open -a "Claude" >/dev/null 2>&1; then
      echo "$(date '+%F %T') 隧道恢复后自动重新打开 Claude（账号 $(cat "$BASE/current" 2>/dev/null)）" >> "$LOG"
      echo stopped > "$CLAUDE_STATE"
    fi
  else
    echo "$(date '+%F %T') 隧道已恢复但环境检查未过，未自动打开 Claude" >> "$LOG"
  fi
}

try_ok() {  # $1=策略名 $2=最多等待秒数
  local i
  for i in $(seq 1 "$2"); do
    sleep 1
    if tun_up; then
      echo "$(date '+%F %T') 恢复成功($1, ${i}s)" >> "$LOG"
      echo "$(date +%s) ok" > "$STATE"
      restore_claude
      exit 0
    fi
  done
}

# 策略 1：直接请求 VPN 服务重连
if [ -n "$SERVICE" ]; then
  scutil --nc start "$SERVICE" >/dev/null 2>&1
  try_ok "scutil start" 6
fi

# 策略 2：拉起代理客户端（OnDemand 可能被唤醒）
if [ -n "$APP" ]; then
  open -a "$APP" >/dev/null 2>&1
  try_ok "open app" 8
fi

# 策略 3：重启代理客户端（解决扩展崩溃循环导致 OnDemand 卡死）
if [ -n "$APP" ]; then
  osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1
  sleep 3
  open -a "$APP" >/dev/null 2>&1
  sleep 3
  [ -n "$SERVICE" ] && scutil --nc start "$SERVICE" >/dev/null 2>&1
  try_ok "restart app" 10
fi

echo "$(date '+%F %T') 自动恢复失败，20s 后重试" >> "$LOG"
