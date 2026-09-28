#!/usr/bin/env bash
# 最终方案：xfail-safe 封禁 = nftables set + Python 守护
# 不依赖 ipset / fail2ban；只用系统自带 nft + python3
set -uo pipefail

echo "=== 1. 清掉之前不生效的 recent 规则 ==="
python3 - <<'PY'
p = '/etc/ufw/before.rules'
s = open(p, encoding='utf-8').read()
start = s.find('# BEGIN TS-BAN-GUARD')
if start != -1:
    end = s.find('# END TS-BAN-GUARD') + len('# END TS-BAN-GUARD\n')
    s = s[:start] + s[end:]
    open(p, 'w', encoding='utf-8').write(s)
    print("  before.rules 中的 recent 块已移除")
else:
    print("  (无残留)")
PY
# 清理可能残留的 nft 表
nft delete table inet ts_guard 2>/dev/null && echo "  旧 ts_guard 表已清理" || true

echo
echo "=== 2. 创建 nftables 封禁表（独立表，不受 ufw reload 影响）==="
nft -f - <<'NFT'
table inet ts_guard {
  set banned {
    type ipv4_addr
    flags timeout
    comment "ssh brute-force ban list"
  }
  chain input {
    type filter hook input priority -150; policy accept;
    ip saddr @banned counter drop
  }
}
NFT
echo "  表 inet ts_guard 已创建"
echo "--- 验证 ---"
nft list table inet ts_guard | sed 's/^/  /'

echo
echo "=== 3. 安装 Python 守护脚本 ==="
cat > /usr/local/sbin/ts-guard.py <<'PYGUARD'
#!/usr/bin/env python3
"""SSH 暴力破解封禁守护（fail2ban 等效，零外部依赖）

原理：
  1. 解析 /var/log/auth.log 最近 N 秒的失败登录
  2. 同一 IP 失败次数 >= 阈值则加入 nftables 集合 inet ts_guard/banned
  3. 集合条目带 timeout，到期内核自动移除，无需额外清理

设计约束：
  - 只封 IPv4；私网与回环永不封禁
  - 已有封禁条目不重复添加
  - 任何异常都静默退出，绝不阻塞系统
"""
import ipaddress
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta

AUTH_LOG = "/var/log/auth.log"
FIND_WINDOW = 600          # 统计窗口（秒）
MAX_RETRY = 5              # 阈值
BAN_SECONDS = 3600         # 封禁时长（内核自动到期）
NFT_TABLE = "inet ts_guard"
NFT_SET = "banned"

FAIL_RE = re.compile(
    r"(Failed password|Invalid user|authentication failure|"
    r"Connection closed by authenticating user|PAM \d+ more authentication failures)"
)
IP_RE = re.compile(r"from (\d{1,3}(?:\.\d{1,3}){3})")
TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})")
TAIL_LINES = 6000


def is_private(ip: str) -> bool:
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return True
    return a.is_private or a.is_loopback or a.is_link_local or a.is_multicast


def read_failures():
    """返回 {ip: 失败次数}，只统计时间窗内的记录。"""
    cutoff = (datetime.now() - timedelta(seconds=FIND_WINDOW)).strftime("%Y-%m-%dT%H:%M:%S")
    counts = {}
    try:
        with open(AUTH_LOG, "r", encoding="utf-8", errors="ignore") as fh:
            lines = fh.readlines()[-TAIL_LINES:]
    except OSError:
        return counts

    current_ts = ""
    for line in lines:
        m = TS_RE.match(line)
        if m:
            current_ts = m.group(1)
        if not FAIL_RE.search(line):
            continue
        if current_ts and current_ts < cutoff:
            continue
        ip_m = IP_RE.search(line)
        if ip_m:
            counts[ip_m.group(1)] = counts.get(ip_m.group(1), 0) + 1
    return counts


def current_banned():
    """读取当前已封禁 IP 集合。"""
    out = subprocess.run(
        ["nft", "-j", "list", "set"] + NFT_TABLE.split() + [NFT_SET],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        return set()
    return set(re.findall(r'"(\d{1,3}(?:\.\d{1,3}){3})"', out.stdout))


def main() -> int:
    counts = read_failures()
    if not counts:
        return 0

    already = current_banned()
    banned_now = []
    for ip, n in counts.items():
        if n < MAX_RETRY or is_private(ip) or ip in already:
            continue
        r = subprocess.run(
            ["nft", "add", "element"] + NFT_TABLE.split()
            + [NFT_SET, "{", ip, "timeout", f"{BAN_SECONDS}s", "}"],
            capture_output=True, text=True,
        )
        if r.returncode == 0:
            banned_now.append(ip)

    if banned_now:
        stamp = datetime.now().isoformat(timespec="seconds")
        with open("/var/log/ts-guard.log", "a", encoding="utf-8") as fh:
            for ip in banned_now:
                fh.write(f"{stamp} BANNED {ip} for {BAN_SECONDS}s "
                         f"(failures={counts[ip]})\n")
        subprocess.run(["logger", "-t", "ts-guard",
                        f"BANNED {len(banned_now)} ip(s): {','.join(banned_now)}"],
                       check=False)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)   # 永不报错，避免 systemd 反复重启
PYGUARD
chmod 700 /usr/local/sbin/ts-guard.py
python3 -c "import ast,sys; ast.parse(open('/usr/local/sbin/ts-guard.py').read())" && echo "  Python 语法 OK"

echo
echo "=== 4. 更新 systemd 单元指向 Python 脚本 ==="
cat > /etc/systemd/system/ts-guard.service <<'EOF'
[Unit]
Description=TS Guard - ban SSH brute-force sources (nftables based)
After=network.target nftables.service
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ts-guard.py
Nice=10
IOSchedulingClass=idle
EOF
systemctl daemon-reload
systemctl restart ts-guard.timer
echo "  timer: $(systemctl is-active ts-guard.timer)"
systemctl start ts-guard.service && echo "  手动运行一次: OK"

echo
echo "=== 5. 备份旧脚本 ==="
mv /usr/local/sbin/ts-guard.sh /usr/local/sbin/ts-guard.sh.bak 2>/dev/null && echo "  旧 xt_recent 版已备份为 .bak"

echo
echo "=== 6. 开机自恢复（重建 nft 表）==="
cat > /usr/local/sbin/ts-firewall-restore.sh <<'RESTORE'
#!/usr/bin/env bash
# 开机重建 nftables 封禁表（独立表，不干扰 ufw）
set -uo pipefail
nft list table inet ts_guard >/dev/null 2>&1 && exit 0
nft -f - <<'NFT'
table inet ts_guard {
  set banned {
    type ipv4_addr
    flags timeout
    comment "ssh brute-force ban list"
  }
  chain input {
    type filter hook input priority -150; policy accept;
    ip saddr @banned counter drop
  }
}
NFT
RESTORE
chmod 700 /usr/local/sbin/ts-firewall-restore.sh
systemctl daemon-reload
systemctl enable ts-firewall-restore.service >/dev/null 2>&1
echo "  ts-firewall-restore: $(systemctl is-enabled ts-firewall-restore.service 2>/dev/null)"
systemctl start ts-firewall-restore.service 2>&1 | head -2

echo
echo "=== 7. 端到端功能验证 ==="
echo "--- 注入测试 IP ---"
nft add element inet ts_guard banned { 198.51.100.77 timeout 60s } 2>&1 && echo "  注入成功"
echo "--- 集合内容 ---"
nft list set inet ts_guard banned 2>&1 | sed 's/^/  /'
echo "--- 规则命中计数器（应有 drop 规则）---"
nft list table inet ts_guard 2>&1 | grep -E "counter|drop" | sed 's/^/  /'
echo "--- 清理测试 IP ---"
nft delete element inet ts_guard banned { 198.51.100.77 } 2>&1 && echo "  已清理"
echo
echo "GUARD_FINAL_DONE"
