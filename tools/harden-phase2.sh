#!/usr/bin/env bash
# 阶段二：服务器重置 + 安全加固
# 设计原则：先放行 SSH 再启防火墙；全程可回退；Docker 端口单独处理（绕过 UFW 的问题）
set -uo pipefail

LOG=/root/ts-hardening-$(date +%Y%m%d-%H%M%S).log
exec > >(tee -a "$LOG") 2>&1
echo "日志: $LOG"
echo

echo "=== A. 停用 LobeChat（保留镜像与数据，可一键恢复）==="
docker update --restart=no lobe-chat 2>/dev/null && echo "  restart 策略已改为 no"
docker stop lobe-chat 2>/dev/null && echo "  lobe-chat 已停止" || echo "  (未在运行)"
echo "  镜像与 /root/lobehub-db 数据保留，恢复命令：docker start lobe-chat"
echo

echo "=== B. 安装 fail2ban ==="
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq fail2ban >/dev/null 2>&1 && echo "  fail2ban 安装完成" || echo "  !! fail2ban 安装失败（可能无外网 apt 源）"

cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
# 封禁 1 小时，1 小时内重犯则翻倍至最长 1 周
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w
bantime = 1h
findtime = 10m
maxretry = 4
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
backend = systemd
mode = aggressive
maxretry = 4
EOF
echo "  jail.local 已写入（sshd: 10 分钟内 4 次失败即封禁）"
if command -v fail2ban-client >/dev/null 2>&1; then
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban
  sleep 3
  fail2ban-client status sshd 2>&1 | sed 's/^/  /' || echo "  !! fail2ban 启动异常"
else
  echo "  !! fail2ban-client 不存在，跳过"
fi
echo

echo "=== C. UFW 防火墙 ==="
apt-get install -y -qq ufw >/dev/null 2>&1
# C1. 关键：先放行 SSH，避免自锁
ufw --force reset >/dev/null 2>&1
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp comment 'SSH' >/dev/null
ufw allow 80/tcp comment 'HTTP' >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null
echo "  规则: 允许 22/80/443，其余入站默认拒绝"
ufw --force enable >/dev/null
echo "  ufw status: $(ufw status | head -1)"

# C2. Docker 发布的端口会绕过 UFW，必须在 DOCKER-USER 链上拦截
grep -q 'DOCKER-USER' /etc/ufw/after.rules 2>/dev/null || cat >> /etc/ufw/after.rules <<'EOF'

# BEGIN TS-DOCKER-GUARD
# Docker 直接操作 iptables，会绕过 ufw 的 INPUT 规则；这里在 DOCKER-USER 链上补一道闸。
*filter
:ufw-user-forward - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -j DROP
COMMIT
# END TS-DOCKER-GUARD
EOF
echo "  DOCKER-USER 兜底规则已写入 /etc/ufw/after.rules"
ufw reload >/dev/null 2>&1 && echo "  ufw 已重载"
echo

echo "=== D. 关闭无用服务（省内存 + 减攻击面）==="
for s in ModemManager fwupd multipathd; do
  if systemctl list-unit-files | grep -q "^${s}\.service"; then
    systemctl stop "$s" >/dev/null 2>&1
    systemctl disable "$s" >/dev/null 2>&1
    systemctl mask "$s" >/dev/null 2>&1
    echo "  已停用+屏蔽: $s"
  fi
done
echo

echo "=== E. 内核与网络加固 (/etc/sysctl.d/99-ts-hardening.conf) ==="
cat > /etc/sysctl.d/99-ts-hardening.conf <<'EOF'
# ---- 网络安全 ----
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_syn_backlog = 2048
net.core.somaxconn = 1024
# ---- 内核信息泄露防护 ----
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.sysrq = 0
kernel.core_uses_pid = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
# ---- 保留 Docker 所需转发 ----
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null 2>&1 && echo "  sysctl 已生效"
echo

echo "=== F. 自动安全更新 ==="
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq unattended-upgrades >/dev/null 2>&1
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52ts-unattended <<'EOF'
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
systemctl enable unattended-upgrades >/dev/null 2>&1
systemctl restart unattended-upgrades >/dev/null 2>&1
echo "  自动安全更新已启用（不自动重启，避免中断服务）"
echo

echo "=== G. 清理与瘦身（重置动作）==="
before=$(df -h / | awk 'NR==2{print $4}')
apt-get clean >/dev/null 2>&1
apt-get autoremove -y -qq >/dev/null 2>&1
journalctl --vacuum-size=200M >/dev/null 2>&1
find /var/log -type f -name '*.gz' -delete 2>/dev/null
find /var/log -type f -name '*.[0-9]' -delete 2>/dev/null
: > /var/log/btmp 2>/dev/null
rm -rf /tmp/* /var/tmp/* 2>/dev/null
docker container prune -f >/dev/null 2>&1
after=$(df -h / | awk 'NR==2{print $4}')
echo "  根分区可用空间: $before -> $after"
echo

echo "=== H. 加固后状态 ==="
echo "--- 监听端口 ---"
ss -tulnp | awk 'NR>1{print "  "$1" "$5" "$7}' | sort -u
echo "--- ufw ---"
ufw status verbose | sed 's/^/  /'
echo "--- fail2ban ---"
systemctl is-active fail2ban | sed 's/^/  active: /'
echo "--- 内存 ---"
free -m | sed 's/^/  /'
echo "--- DOCKER-USER 链 ---"
iptables -S DOCKER-USER 2>/dev/null | sed 's/^/  /'
echo
echo "PHASE2_DONE"
