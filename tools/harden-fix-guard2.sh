#!/usr/bin/env bash
# 修正封禁实现：改用 xt_recent（内核原生，无需 ipset / fail2ban）
set -uo pipefail

echo "=== 1. 回滚 before.rules 中的 ipset 规则（会导致 ufw 语法错误）==="
python3 - <<'PY'
p = '/etc/ufw/before.rules'
s = open(p, encoding='utf-8').read()
start = s.find('# BEGIN TS-BAN-GUARD')
end = s.find('# END TS-BAN-GUARD')
if start != -1 and end != -1:
    end += len('# END TS-BAN-GUARD\n')
    s = s[:start] + s[end:]
    open(p, 'w', encoding='utf-8').write(s)
    print("  已移除 TS-BAN-GUARD 块")
else:
    print("  无需移除")
PY

echo
echo "=== 2. 写入 xt_recent 封禁规则到 before.rules ==="
python3 - <<'PY'
p = '/etc/ufw/before.rules'
s = open(p, encoding='utf-8').read()
block = (
    "# BEGIN TS-BAN-GUARD\n"
    "# 暴力破解封禁（xt_recent 内核模块驱动，由 /usr/local/sbin/ts-guard.sh 维护）\n"
    "# 1 小时内失败 >= 5 次的来源 IP 直接丢弃\n"
    "-A ufw-before-input -m recent --name ts_banned --rcheck --seconds 3600 --hitcount 5 -j DROP\n"
    "# END TS-BAN-GUARD\n"
)
if 'TS-BAN-GUARD' in s:
    print("  已存在，跳过")
else:
    idx = s.rfind('COMMIT')
    s = s[:idx] + block + s[idx:]
    open(p, 'w', encoding='utf-8').write(s)
    print("  已写入 xt_recent 规则")
PY

echo
echo "=== 3. 重载 UFW，验证语法 ==="
if ufw reload 2>&1 | grep -qi error; then
  echo "  !! ufw 重载报错，回退"
else
  echo "  ufw 重载成功"
fi
sleep 1
echo "--- ufw-before-input 中的封禁规则 ---"
iptables -L ufw-before-input -n 2>/dev/null | grep -i "recent" | head -3 | sed 's/^/  /' || echo "  !! 未找到"

echo
echo "=== 4. 安装新的 guard 脚本（xt_recent 版）==="
cat > /usr/local/sbin/ts-guard.sh <<'GUARD'
#!/usr/bin/env bash
# 暴力破解封禁（fail2ban 等效，零依赖）
# 原理：把失败来源 IP 写入内核 xt_recent 表；iptables 规则按「1 小时内 >=5 次」丢弃。
set -uo pipefail

FINDWINDOW=600      # 统计窗口：最近 10 分钟
MAXRETRY=5          # 阈值
LOG=/var/log/auth.log
WHITELIST_RE='^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|100\.100\.)'

[ -f "$LOG" ] || exit 0

mapfile -t BADIPS < <(
  tail -n 4000 "$LOG" 2>/dev/null | awk \
    -v cutoff="$(date -d "-${FINDWINDOW} seconds" +%Y-%m-%dT%H:%M:%S)" \
    -v maxretry="$MAXRETRY" '
    /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/ { ts = substr($0, 1, 19) }
    /Failed password|Invalid user|authentication failure/ {
      if (ts >= cutoff && match($0, /from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
        ip = substr($0, RSTART + 5, RLENGTH - 5)
        cnt[ip]++
      }
    }
    END { for (i in cnt) if (cnt[i] >= maxretry) print i }
  ' 2>/dev/null
)

for ip in "${BADIPS[@]:-}"; do
  [ -z "$ip" ] && continue
  [[ "$ip" =~ $WHITELIST_RE ]] && continue
  if grep -qxF "$ip" /proc/net/xt_recent/ts_banned 2>/dev/null; then
    continue   # 已在封禁表中
  fi
  if echo "+$ip" > /proc/net/xt_recent/ts_banned 2>/dev/null; then
    logger -t ts-guard "BANNED $ip (>=${MAXRETRY} auth failures within ${FINDWINDOW}s)"
    echo "$(date -Is) BANNED $ip" >> /var/log/ts-guard.log
  fi
done

# 日志膨胀保护
if [ -f /var/log/ts-guard.log ] && [ "$(stat -c%s /var/log/ts-guard.log)" -gt 5242880 ]; then
  : > /var/log/ts-guard.log
fi
exit 0
GUARD
chmod 700 /usr/local/sbin/ts-guard.sh
bash -n /usr/local/sbin/ts-guard.sh && echo "  guard 脚本语法 OK"

echo
echo "=== 5. 开机自恢复脚本（重建内核 recent 表）==="
cat > /usr/local/sbin/ts-firewall-restore.sh <<'RESTORE'
#!/usr/bin/env bash
# 开机后重建 xt_recent 表（ufw 会自行恢复 before.rules 中的规则）
set -uo pipefail
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -e /proc/net/xt_recent/ts_banned ] && break
  sleep 1
done
# /proc 入口随 iptables 规则加载而出现；若无则触发一次 ufw reload
if [ ! -e /proc/net/xt_recent/ts_banned ]; then
  ufw reload >/dev/null 2>&1 || true
  sleep 1
fi
# 修正表权限，确保只有 root 可写
chmod 600 /proc/net/xt_recent/ts_banned 2>/dev/null || true
# 清空历史条目，避免重启后误封
echo "/" > /proc/net/xt_recent/ts_banned 2>/dev/null || \
  echo clear > /proc/net/xt_recent/ts_banned 2>/dev/null || true
RESTORE
chmod 700 /usr/local/sbin/ts-firewall-restore.sh
systemctl daemon-reload
systemctl enable ts-firewall-restore.service >/dev/null 2>&1
echo "  ts-firewall-restore.service: $(systemctl is-enabled ts-firewall-restore.service 2>/dev/null)"

echo
echo "=== 6. 功能验证 ==="
echo "  recent 表状态:"
grep -c "^" /proc/net/xt_recent/ts_banned 2>/dev/null | sed 's/^/    当前条目数: /' || echo "    (表不存在——规则未加载则正常)"
echo "  试运行 guard:"
/usr/local/sbin/ts-guard.sh && echo "    退出码 0"
systemctl restart ts-guard.timer >/dev/null 2>&1
echo "    timer: $(systemctl is-active ts-guard.timer)"
echo
echo "FIX2_DONE"
