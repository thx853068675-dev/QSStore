#!/usr/bin/env bash
# 阶段一：备份现状 + 安装管理公钥（不改动 sshd 配置，保证可回退）
set -euo pipefail

PUBKEY="${1:?usage: harden-phase1.sh <pubkey-file>}"
BK=/root/ts-pre-hardening
STAMP=$(date +%Y%m%d-%H%M%S)

mkdir -p "$BK/$STAMP"

echo "=== 1. 备份关键配置 ==="
for f in /etc/ssh/sshd_config /etc/nginx/sites-enabled/default /etc/privoxy/config \
         /etc/shadowsocks.json /etc/apt/sources.list; do
  [ -e "$f" ] && cp -a "$f" "$BK/$STAMP/$(echo "$f" | tr '/' '_')" && echo "  saved $f"
done
[ -d /etc/ssh/sshd_config.d ] && cp -a /etc/ssh/sshd_config.d "$BK/$STAMP/sshd_config.d" && echo "  saved sshd_config.d/"
systemctl list-unit-files --state=enabled --no-legend > "$BK/$STAMP/enabled-units.txt" 2>/dev/null || true
ss -tulnp > "$BK/$STAMP/listening.txt" 2>/dev/null || true
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' > "$BK/$STAMP/docker.txt" 2>/dev/null || true
echo "  备份目录: $BK/$STAMP"

echo
echo "=== 2. 安装管理公钥 ==="
install -d -m 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
KEY=$(cat "$PUBKEY")
if grep -qF "$KEY" /root/.ssh/authorized_keys 2>/dev/null; then
  echo "  公钥已存在"
else
  echo "$KEY" >> /root/.ssh/authorized_keys
  echo "  公钥已添加"
fi
echo "  authorized_keys 行数: $(wc -l < /root/.ssh/authorized_keys)"

echo
echo "=== 3. 校验 sshd 配置语法 ==="
sshd -t && echo "  sshd 配置语法 OK"
echo "PHASE1_DONE"
