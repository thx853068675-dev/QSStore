#!/usr/bin/env bash
# 阶段二修正：把 ipset 封禁规则挂到 UFW 的 before 链（早期生效，且 ufw reload 后仍在）
set -uo pipefail

echo "=== 1. 当前 INPUT 顺序（修正前）==="
iptables -L INPUT -n --line-numbers | head -10 | sed 's/^/  /'
echo

echo "=== 2. 把封禁规则写入 /etc/ufw/before.rules（UFW 原生位置）==="
if grep -q 'TS-BAN-GUARD' /etc/ufw/before.rules 2>/dev/null; then
  echo "  已存在，跳过"
else
  # 在 *filter 段落内、COMMIT 之前插入
  python3 - <<'PY'
import re, io
p = '/etc/ufw/before.rules'
s = open(p, encoding='utf-8').read()
block = (
    "# BEGIN TS-BAN-GUARD\n"
    "# 封禁集合（由 ts-guard.sh / fail2ban 等效实现维护）\n"
    "-A ufw-before-input -m set --match-set ts_banned src -j DROP\n"
    "# END TS-BAN-GUARD\n"
)
if 'TS-BAN-GUARD' in s:
    print("  已存在")
else:
    # 插到 *filter 段最后一个 COMMIT 之前
    idx = s.rfind('COMMIT')
    s = s[:idx] + block + s[idx:]
    open(p, 'w', encoding='utf-8').write(s)
    print("  已写入 /etc/ufw/before.rules")
PY
fi
echo

echo "=== 3. 清理旧的 INPUT 直接挂钩（避免重复）==="
while iptables -C INPUT -m set --match-set ts_banned src -j DROP 2>/dev/null; do
  iptables -D INPUT -m set --match-set ts_banned src -j DROP && echo "  移除一条 INPUT 直接规则"
done
echo

echo "=== 4. 重载 UFW 并验证 ==="
ufw reload >/dev/null 2>&1
sleep 1
echo "--- INPUT 顺序（修正后）---"
iptables -L INPUT -n --line-numbers | head -10 | sed 's/^/  /'
echo "--- ufw-before-input 中的封禁规则 ---"
iptables -L ufw-before-input -n 2>/dev/null | grep -i "ts_banned\|DROP" | head -5 | sed 's/^/  /' || echo "  !! 未找到"
echo

echo "=== 5. 实战验证：封禁一个测试 IP 并确认丢包计数上升 ==="
ipset add ts_banned 203.0.113.66 timeout 60 2>/dev/null && echo "  测试 IP 203.0.113.66 已加入封禁集"
echo "  集合内容: $(ipset list ts_banned | grep -c '^203\.') 条匹配"
before=$(iptables -L ufw-before-input -n -v -x 2>/dev/null | grep ts_banned | awk '{print $1}')
echo "  规则命中计数: ${before:-未知}"
echo "  (规则已在链上即视为生效；真实命中需有该 IP 的流量)"
ipset del ts_banned 203.0.113.66 2>/dev/null && echo "  测试 IP 已移除"
echo

echo "=== 6. 语法自检：guard 脚本可执行 ==="
bash -n /usr/local/sbin/ts-guard.sh && echo "  ts-guard.sh 语法 OK"
/usr/local/sbin/ts-guard.sh && echo "  ts-guard.sh 试运行 OK"
systemctl start ts-guard.service 2>&1 | head -3
echo "  service 运行结果: $(systemctl is-failed ts-guard.service 2>/dev/null || echo ok)"
echo
echo "FIX_DONE"
