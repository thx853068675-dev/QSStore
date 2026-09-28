#!/usr/bin/env bash
# 只读探测：可用工具与 ipset 支持
echo "== 可用工具 =="
for b in ipset iptables-save iptables-restore ufw fail2ban-client logger systemd-cat; do
  printf "  %-20s " "$b"
  command -v "$b" >/dev/null 2>&1 && echo "OK" || echo "-"
done
echo
echo "== ipset 内核支持 =="
modprobe ip_set 2>/dev/null
modprobe xt_set 2>/dev/null
modprobe ip_set_hash_ip 2>/dev/null
lsmod | grep -E "^ip_set|^xt_set" | awk '{print "  "$1}' || true
if iptables -m set --help >/dev/null 2>&1; then echo "  xt_set: 可用"; else echo "  xt_set: 不可用"; fi
echo
echo "== apt 残留 =="
echo "  deb 缓存: $(ls /var/cache/apt/archives/*.deb 2>/dev/null | wc -l) 个"
echo "  包索引:   $(ls /var/lib/apt/lists/*Packages* 2>/dev/null | wc -l) 个"
echo
echo "== ufw/fail2ban 残留 =="
ls /etc/ufw 2>/dev/null | head -5 || echo "  (无 /etc/ufw)"
ls /etc/fail2ban 2>/dev/null | head -5 || echo "  (无 /etc/fail2ban)"
echo
echo "== 资源现状 =="
df -h / | tail -1 | awk '{print "  disk: "$3" used / "$2" total, "$4" avail"}'
free -m | awk 'NR==2{print "  mem:  "$3"MB used / "$2"MB total, "$7"MB avail"}'
echo
echo "== docker 状态 =="
docker ps -a --format '  {{.Names}} | {{.Status}} | restart={{.Label "x"}}' 2>/dev/null
docker inspect lobe-chat --format '  restart-policy={{.HostConfig.RestartPolicy.Name}} running={{.State.Running}}' 2>/dev/null
echo "PROBE_DONE"
