#!/usr/bin/env bash
# 修正：封禁规则插到 ufw-before-input 的早期位置（环回之后、conntrack 之前）
set -uo pipefail

echo "=== 1. 插入封禁规则 ==="
python3 - <<'PY'
p = '/etc/ufw/before.rules'
s = open(p, encoding='utf-8').read()

# 移除旧块（若有）
start = s.find('# BEGIN TS-BAN-GUARD')
if start != -1:
    end = s.find('# END TS-BAN-GUARD') + len('# END TS-BAN-GUARD\n')
    s = s[:start] + s[end:]
    print("  旧块已移除")

block = (
    "# BEGIN TS-BAN-GUARD\n"
    "# 暴力破解封禁（xt_recent 驱动，由 /usr/local/sbin/ts-guard.sh 维护）\n"
    "# 位置在 conntrack 之前：被封 IP 的已建立连接也会被切断\n"
    "-A ufw-before-input -m recent --name ts_banned --rcheck --seconds 3600 --hitcount 5 -j DROP\n"
    "# END TS-BAN-GUARD\n"
)

anchor = "-A ufw-before-output -o lo -j ACCEPT\n"
idx = s.find(anchor)
if idx == -1:
    raise SystemExit("  !! 找不到锚点")
idx += len(anchor)
s = s[:idx] + "\n" + block + s[idx:]
open(p, 'w', encoding='utf-8').write(s)
print("  已插入到环回规则之后")
PY

echo
echo "=== 2. 重载 UFW ==="
ufw reload 2>&1 | head -3
sleep 1

echo
echo "=== 3. 验证规则已进内核 ==="
echo "--- ufw-before-input 前 6 条 ---"
nft list table ip filter 2>/dev/null | grep -A 8 "chain ufw-before-input" | head -10 | sed 's/^/  /'
echo "--- recent 表 ---"
ls /proc/net/xt_recent/ 2>&1 | sed 's/^/  /'

echo
echo "=== 4. 端到端功能验证（真实制造失败登录）==="
if [ -e /proc/net/xt_recent/ts_banned ]; then
  echo "  初始状态: $(grep -c '^' /proc/net/xt_recent/ts_banned) 条"
  echo "  规则命中计数（重启前）: $(nft list table ip filter 2>/dev/null | grep -A 8 'chain ufw-before-input' | grep -i 'recent' | head -1)"
else
  echo "  !! recent 表仍未创建，规则可能未加载"
fi

echo
echo "FIX4_DONE"
