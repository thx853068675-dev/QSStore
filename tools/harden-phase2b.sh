#!/usr/bin/env bash
# 阶段二（零依赖版）：服务器重置 + 安全加固
# 背景：该机出站 80/443 的应用层数据被阿里云侧丢弃，无法 apt 安装，
#       因此 fail2ban 用 ipset+iptables 自行实现（内核模块已确认可用）。
set -uo pipefail

LOG=/root/ts-hardening-$(date +%Y%m%d-%H%M%S).log
exec > >(tee -a "$LOG") 2>&1
echo "日志: $LOG"
echo

echo "=== A. LobeChat 停用确认 ==="
docker update --restart=no lobe-chat >/dev/null 2>&1
docker stop lobe-chat >/dev/null 2>&1
docker inspect lobe-chat --format '  状态: running={{.State.Running}} restart={{.HostConfig.RestartPolicy.Name}}' 2>/dev/null
echo "  镜像与 /root/lobehub-db 保留，恢复：docker start lobe-chat"
echo

echo "=== B. fail2ban 等效实现（ipset + iptables）==="
# B1. 封禁 IP 集合，条目自带 TTL 到期自动解封
ipset destroy ts_banned 2>/dev/null
ipset create ts_banned hash:ip timeout 3600 -exist
echo "  ipset ts_banned 已创建（默认封禁 1 小时，自动过期）"

# B2. iptables 挂钩（幂等）
iptables -N TS-GUARD 2>/dev/null
iptables -C INPUT -m set --match-set ts_banned src -j DROP 2>/dev/null || \
  iptables -I INPUT 1 -m set --match-set ts_banned src -j DROP
iptables -C INPUT -m set --match-set ts_banned src -m comment --comment "ts-guard" -j LOG 2>/dev/null || true
echo "  INPUT 封禁规则已挂载"

# B3. 扫描与封禁脚本
cat > /usr/local/sbin/ts-guard.sh <<'GUARD'
#!/usr/bin/env bash
# 扫描 sshd 失败登录，用 ipset 封禁来源 IP（fail2ban 等效，零依赖）
set -uo pipefail
SET=ts_banned
BANTIME=3600        # 首次封禁 1 小时
FINDWINDOW=600      # 只统计最近 10 分钟
MAXRETRY=5          # 阈值：同一 IP 失败 5 次
WHITELIST_RE='^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|100\.100\.)'

# 集合不存在则重建
ipset list -n "$SET" >/dev/null 2>&1 || ipset create "$SET" hash:ip timeout "$BANTIME" -exist

LOG=/var/log/auth.log
[ -f "$LOG" ] || exit 0

# 只取尾部若干行，用字符串比较判断时间窗（避免逐行 fork date，性能关键）
mapfile -t CANDIDATES < <(
  tail -n 4000 "$LOG" 2>/dev/null | awk -v cutoff="$(date -d "-${FINDWINDOW} seconds" +%Y-%m-%dT%H:%M:%S)" \
      -v maxretry="$MAXRETRY" '
    /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/ { ts = substr($0, 1, 19) }
    /Failed password|Invalid user|authentication failure/ {
      if (ts >= cutoff) {
        if (match($0, /from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
          ip = substr($0, RSTART + 5, RLENGTH - 5)
          cnt[ip]++
        }
      }
    }
    END { for (i in cnt) if (cnt[i] >= maxretry) print i }
  ' 2>/dev/null
)

for ip in "${CANDIDATES[@]:-}"; do
  [ -z "$ip" ] && continue
  [[ "$ip" =~ $WHITELIST_RE ]] && continue
  if ipset test "$SET" "$ip" 2>/dev/null; then continue; fi
  ipset add "$SET" "$ip" timeout "$BANTIME" 2>/dev/null && \
    logger -t ts-guard "BANNED $ip for ${BANTIME}s (>=${MAXRETRY} auth failures in ${FINDWINDOW}s)"
done

# 日志膨胀保护
[ -f /var/log/ts-guard.log ] && [ "$(stat -c%s /var/log/ts-guard.log)" -gt 5242880 ] && : > /var/log/ts-guard.log
exit 0
GUARD
chmod 700 /usr/local/sbin/ts-guard.sh
echo "  /usr/local/sbin/ts-guard.sh 已安装"

# B4. systemd 定时器（每分钟扫描）
cat > /etc/systemd/system/ts-guard.service <<'EOF'
[Unit]
Description=TS Guard - ban brute-force SSH sources (fail2ban equivalent)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ts-guard.sh
EOF

cat > /etc/systemd/system/ts-guard.timer <<'EOF'
[Unit]
Description=Run TS Guard every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
Unit=ts-guard.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ts-guard.timer >/dev/null 2>&1
echo "  ts-guard.timer: $(systemctl is-active ts-guard.timer)"
echo

echo "=== C. UFW 防火墙 ==="
if command -v ufw >/dev/null 2>&1; then
  ufw --force reset >/dev/null 2>&1
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp comment 'SSH' >/dev/null
  ufw allow 80/tcp comment 'HTTP' >/dev/null
  ufw allow 443/tcp comment 'HTTPS' >/dev/null
  ufw --force enable >/dev/null
  echo "  规则: 允许 22/80/443，其余入站默认拒绝"
  echo "  status: $(ufw status | head -1)"

  # Docker 绕过 UFW 的兜底
  if ! grep -q 'TS-DOCKER-GUARD' /etc/ufw/after.rules 2>/dev/null; then
    cat >> /etc/ufw/after.rules <<'EOF'

# BEGIN TS-DOCKER-GUARD
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
    echo "  DOCKER-USER 兜底规则已写入"
  fi
  ufw reload >/dev/null 2>&1
else
  echo "  !! ufw 不可用，改用纯 iptables"
  iptables -P INPUT DROP
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A INPUT -p tcp --dport 22 -j ACCEPT
  iptables -A INPUT -p tcp --dport 80 -j ACCEPT
  iptables -A INPUT -p tcp --dport 443 -j ACCEPT
fi
echo

echo "=== D. 关闭无用服务 ==="
for s in ModemManager fwupd multipathd; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${s}\.service"; then
    systemctl stop "$s" >/dev/null 2>&1
    systemctl disable "$s" >/dev/null 2>&1
    systemctl mask "$s" >/dev/null 2>&1
    echo "  已停用+屏蔽: $s"
  fi
done
echo

echo "=== E. 内核与网络加固 ==="
cat > /etc/sysctl.d/99-ts-hardening.conf <<'EOF'
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
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.sysrq = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null 2>&1 && echo "  sysctl 已生效"

# 规则开机自动恢复（ufw 会自行恢复；ipset/自定义链需自己恢复）
cat > /usr/local/sbin/ts-firewall-restore.sh <<'RESTORE'
#!/usr/bin/env bash
# 开机恢复 ipset 与 TS-GUARD 挂钩
set -uo pipefail
ipset create ts_banned hash:ip timeout 3600 -exist
iptables -N TS-GUARD 2>/dev/null
iptables -C INPUT -m set --match-set ts_banned src -j DROP 2>/dev/null || \
  iptables -I INPUT 1 -m set --match-set ts_banned src -j DROP
RESTORE
chmod 700 /usr/local/sbin/ts-firewall-restore.sh

cat > /etc/systemd/system/ts-firewall-restore.service <<'EOF'
[Unit]
Description=Restore TS firewall guard rules (ipset + iptables)
After=network.target ufw.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ts-firewall-restore.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ts-firewall-restore.service >/dev/null 2>&1
echo "  规则开机自恢复已配置"
echo

echo "=== F. 自动安全更新状态 ==="
cat /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null | sed 's/^/  /'
if ! grep -q 'AutocleanInterval' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  echo "  已补全 AutocleanInterval"
fi
echo "  (注：出站被封时 apt 无法更新，恢复出站后自动生效)"
echo

echo "=== G. 清理与瘦身 ==="
before=$(df -h / | awk 'NR==2{print $4}')
apt-get clean >/dev/null 2>&1
journalctl --vacuum-size=200M >/dev/null 2>&1
find /var/log -type f -name '*.gz' -delete 2>/dev/null
find /var/log -type f -name '*.[0-9]' -delete 2>/dev/null
: > /var/log/btmp 2>/dev/null
rm -rf /tmp/* /var/tmp/* 2>/dev/null
docker container prune -f >/dev/null 2>&1
after=$(df -h / | awk 'NR==2{print $4}')
echo "  根分区可用: $before -> $after"
echo

echo "=== H. 加固后状态 ==="
echo "--- 监听端口 ---"
ss -tulnp 2>/dev/null | awk 'NR>1{print "  "$1" "$5}' | sort -u
echo "--- ufw ---"
ufw status verbose 2>/dev/null | sed 's/^/  /' || echo "  (无 ufw)"
echo "--- ts-guard ---"
echo "  timer: $(systemctl is-active ts-guard.timer 2>/dev/null)  封禁集: $(ipset list ts_banned 2>/dev/null | grep -c '^[0-9]' ) 条"
echo "--- 内存 ---"
free -m | awk 'NR==2{print "  used="$3"MB total="$2"MB avail="$7"MB"}'
echo "--- INPUT 链前 8 条 ---"
iptables -L INPUT -n --line-numbers 2>/dev/null | head -12 | sed 's/^/  /'
echo
echo "PHASE2B_DONE"
