#!/usr/bin/env bash
# 启用 ufw 并做端到端封禁验证
set -uo pipefail

echo "=== 1. 正式启用 ufw ==="
ufw --force enable 2>&1 | head -3
grep -E "^ENABLED" /etc/ufw/ufw.conf | sed 's/^/  /'
echo "  status: $(ufw status | head -1)"

echo
echo "=== 2. 确认封禁规则已进内核 ==="
if [ -e /proc/net/xt_recent/ts_banned ]; then
  echo "  /proc/net/xt_recent/ts_banned 已存在"
  grep -c '^' /proc/net/xt_recent/ts_banned | sed 's/^/  当前条目: /'
else
  echo "  !! recent 表不存在"
  echo "  排查：规则是否在 ufw-before-input 链上"
  nft list table ip filter 2>/dev/null | grep -B2 -A2 "recent" | head -10 | sed 's/^/    /'
fi

echo
echo "=== 3. 手工注入一个测试 IP，确认规则命中计数上升 ==="
if [ -e /proc/net/xt_recent/ts_banned ]; then
  # 注意：单条 +IP 不足以触发（需 hitcount>=5），这里验证写入通道
  echo "+198.51.100.77" > /proc/net/xt_recent/ts_banned 2>/dev/null
  echo "  写入测试 IP 后条目数: $(grep -c '^' /proc/net/xt_recent/ts_banned)"
  # 取规则计数器
  hits=$(nft -a list table ip filter 2>/dev/null | grep -A1 "recent" | grep -oE 'packets [0-9]+' | head -1)
  echo "  规则命中: ${hits:-未知}"
  echo "/" > /proc/net/xt_recent/ts_banned
  echo "  已清空测试数据"
fi

echo
echo "=== 4. 最终状态汇总 ==="
echo "--- 监听端口 ---"
ss -tulnp 2>/dev/null | awk 'NR>1{print "  "$1" "$5}' | sort -u
echo "--- ufw ---"
ufw status | head -8 | sed 's/^/  /'
echo "--- guard ---"
echo "  timer: $(systemctl is-active ts-guard.timer)"
echo "  脚本: $(test -x /usr/local/sbin/ts-guard.sh && echo OK || echo MISSING)"
echo "  日志: $(test -f /var/log/ts-guard.log && wc -l < /var/log/ts-guard.log || echo 0) 行"
echo
echo "GUARD_ENABLED_DONE"
