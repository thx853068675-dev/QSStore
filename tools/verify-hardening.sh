#!/usr/bin/env bash
# 加固后最终复验（只读）
echo "════════ 1. 身份与访问 ════════"
echo "  sshd 生效值:"
sshd -T 2>/dev/null | grep -Ei '^(passwordauthentication|permitrootlogin|pubkeyauthentication|kbdinteractiveauthentication|maxauthtries|x11forwarding|allowusers)' | sed 's/^/    /'
echo "  authorized_keys: $(grep -c . /root/.ssh/authorized_keys 2>/dev/null) 条"
echo "  root 密码状态: $(passwd -S root 2>/dev/null | awk '{print $2}')  (P=已设密码 L=锁定)"
echo "  可登录账号(有 shell 且 uid>=1000): $(awk -F: '$3>=1000 && $3<65534 && $7 !~ /nologin|false/ {print $1}' /etc/passwd | tr '\n' ' ')"

echo
echo "════════ 2. 防火墙 ════════"
echo "  ufw: $(ufw status | head -1)"
ufw status | tail -n +4 | sed 's/^/    /'
echo "  INPUT policy: $(iptables -L INPUT -n | head -1 | grep -oE 'policy [A-Z]+')"
echo "  DOCKER-USER 兜底: $(iptables -S DOCKER-USER 2>/dev/null | grep -c DROP) 条 DROP"

echo
echo "════════ 3. 暴力破解防护 ════════"
echo "  nft 封禁表:"
nft list set inet ts_guard banned 2>/dev/null | grep -E "type|elements" | sed 's/^/    /'
echo "  drop 规则:"
nft list table inet ts_guard 2>/dev/null | grep -E "counter.*drop" | sed 's/^/    /'
echo "  guard timer: $(systemctl is-active ts-guard.timer) / $(systemctl is-enabled ts-guard.timer 2>/dev/null)"
echo "  开机恢复服务: $(systemctl is-enabled ts-firewall-restore.service 2>/dev/null)"
echo "  封禁日志: $(wc -l < /var/log/ts-guard.log 2>/dev/null || echo 0) 行"
echo "  最近封禁记录:"
tail -3 /var/log/ts-guard.log 2>/dev/null | sed 's/^/    /' || echo "    (暂无)"

echo
echo "════════ 4. 内核加固 ════════"
for k in net.ipv4.tcp_syncookies net.ipv4.conf.all.rp_filter kernel.dmesg_restrict kernel.kptr_restrict kernel.sysrq fs.protected_hardlinks net.ipv4.conf.all.accept_redirects net.ipv4.conf.all.accept_source_route net.ipv4.ip_forward; do
  printf "    %-42s = %s\n" "$k" "$(sysctl -n $k 2>/dev/null)"
done

echo
echo "════════ 5. 服务与端口 ════════"
echo "  监听端口:"
ss -tulnp 2>/dev/null | awk 'NR>1{print "    "$1" "$5}' | sort -u
echo "  已屏蔽的无用服务:"
for s in ModemManager fwupd multipathd; do
  printf "    %-16s %s\n" "$s" "$(systemctl is-enabled $s 2>/dev/null || echo unknown)"
done
echo "  Docker 容器:"
docker ps -a --format '    {{.Names}} | {{.Status}}' 2>/dev/null

echo
echo "════════ 6. 资源 ════════"
free -m | awk 'NR==2{printf "  内存: used=%sMB total=%sMB avail=%sMB\n",$3,$2,$7}'
df -h / | awk 'NR==2{printf "  磁盘: used=%s total=%s avail=%s (%s)\n",$3,$2,$4,$5}'
echo "  负载: $(cat /proc/loadavg | cut -d' ' -f1-3)"

echo
echo "════════ 7. 出站连通性 ════════"
for u in http://www.baidu.com https://api.github.com/rate_limit http://mirrors.cloud.aliyuncs.com; do
  printf "    %-42s " "$u"
  curl -s --connect-timeout 4 -m 6 -o /dev/null -w "%{http_code}\n" "$u" 2>&1 || echo TIMEOUT
done

echo
echo "════════ 8. 备份与回退 ════════"
ls -1 /root/ts-pre-hardening/ 2>/dev/null | sed 's/^/    /'
echo "  回退命令: cp /root/ts-pre-hardening/<时间>-sshd/sshd_config /etc/ssh/ && rm -f /etc/ssh/sshd_config.d/99-ts-hardening.conf && systemctl reload ssh"

echo
echo "════════ 9. 定时任务审计（防后门）════════"
echo "  root crontab: $(crontab -l 2>/dev/null | grep -vc '^#' || echo 0) 条"
echo "  /etc/cron.d: $(ls /etc/cron.d/ 2>/dev/null | tr '\n' ' ')"
echo "  systemd timers: $(systemctl list-timers --no-pager --no-legend 2>/dev/null | wc -l) 个"
systemctl list-timers --no-pager --no-legend 2>/dev/null | awk '{print "    "$NF" -> "$1" "$2" "$3}' | head -8
echo "  监听 0.0.0.0 的可疑进程:"
ss -tulnp 2>/dev/null | grep "0.0.0.0\|:::" | grep -vE "sshd|nginx|systemd-resolve|docker-proxy|chronyd|privoxy" | sed 's/^/    /' || echo "    (无)"

echo
echo "VERIFY_DONE"
