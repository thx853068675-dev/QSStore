#!/usr/bin/env bash
# 修正：把封禁规则插到 ufw-before-input 链的【最前面】
# 原因：ufw 自动生成的 `-A ufw-before-input -j ufw-user-input` 会先 ACCEPT 22 端口，
#       规则若排在它后面将永远不生效。
set -uo pipefail

echo "=== 1. 定位 ufw-user-input 跳转行位置 ==="
grep -n "ufw-before-input.*ufw-user-input" /etc/ufw/before.rules | sed 's/^/  /'

echo
echo "=== 2. 重写 TS-BAN-GUARD 块到链首 ==="
python3 - <<'PY'
p = '/etc/ufw/before.rules'
s = open(p, encoding='utf-8').read()

# 先移除旧块
start = s.find('# BEGIN TS-BAN-GUARD')
if start != -1:
    end = s.find('# END TS-BAN-GUARD')
    end += len('# END TS-BAN-GUARD\n')
    s = s[:start] + s[end:]
    print("  旧块已移除")

block = (
    "# BEGIN TS-BAN-GUARD\n"
    "# 暴力破解封禁（xt_recent 驱动，由 /usr/local/sbin/ts-guard.sh 维护）\n"
    "# 必须放在 ufw-user-input 跳转之前，否则 22 端口会先被 ACCEPT\n"
    "-A ufw-before-input -m recent --name ts_banned --rcheck --seconds 3600 --hitcount 5 -j DROP\n"
    "# END TS-BAN-GUARD\n"
)

anchor = "-A ufw-before-input -j ufw-user-input"
idx = s.find(anchor)
if idx == -1:
    raise SystemExit("  !! 找不到锚点，未修改")
s = s[:idx] + block + s[idx:]
open(p, 'w', encoding='utf-8').write(s)
print("  新块已插入到 `-A ufw-before-input -j ufw-user-input` 之前")
PY

echo
echo "=== 3. 重载并验证 ==="
ufw reload >/dev/null 2>&1 && echo "  ufw reload OK"
sleep 1
echo "--- ufw-before-input 顺序（封禁规则应在第一条）---"
nft list table ip filter 2>/dev/null | grep -A 6 "chain ufw-before-input" | head -8 | sed 's/^/  /'
echo
echo "--- /proc recent 表是否出现 ---"
ls /proc/net/xt_recent/ 2>&1 | sed 's/^/  /'

echo
echo "=== 4. 端到端验证：制造失败登录并确认 IP 被记录 ==="
echo "  当前表内容: $(grep -c '^' /proc/net/xt_recent/ts_banned 2>/dev/null || echo '表暂不存在')"

echo
echo "=== 5. 清空历史条目（避免误封）==="
echo "/" > /proc/net/xt_recent/ts_banned 2>/dev/null && echo "  已清空" || echo "  (表不存在)"

echo
echo "=== 6. 最终状态 ==="
echo "  guard timer: $(systemctl is-active ts-guard.timer)"
echo "  firewall-restore: $(systemctl is-enabled ts-firewall-restore.service 2>/dev/null)"
bash -n /usr/local/sbin/ts-guard.sh && echo "  guard 脚本语法 OK"
echo
echo "FIX3_DONE"
