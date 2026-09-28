#!/usr/bin/env bash
# 工具真实可用性探测（上一版探测脚本有 bug，全部误报 OK）
echo "== 工具真实可用性 =="
for b in ipset iptables iptables-legacy nft ufw fail2ban-client logger python3; do
  p=$(command -v "$b" 2>/dev/null)
  printf "  %-18s %s\n" "$b" "${p:-(缺失)}"
done
echo
echo "== iptables 后端 =="
iptables --version 2>&1 | head -1
echo "  alternatives: $(readlink -f /usr/sbin/iptables 2>/dev/null)"
echo
echo "== nft 可用性（nftables 是 Ubuntu 24.04 默认后端）=="
nft --version 2>&1 | head -1
echo
echo "== xt_recent 内核模块（可用于无 ipset 的动态封禁）=="
modprobe xt_recent 2>/dev/null
lsmod | grep -E "^xt_recent" | awk '{print "  loaded: "$1}' || echo "  (未加载)"
iptables -m recent --help >/dev/null 2>&1 && echo "  xt_recent: 可用" || echo "  xt_recent: 不可用"
echo
echo "== ufw-before.rules 尾部 =="
tail -12 /etc/ufw/before.rules
echo
echo "== ufw 配置文件是否含我们的块 =="
grep -n "TS-BAN-GUARD" /etc/ufw/before.rules 2>/dev/null || echo "  (未找到)"
echo "PROBE2_DONE"
