#!/usr/bin/env bash
# 阶段三：SSH 加固 —— 关闭密码登录，仅保留密钥
# 安全前提：调用方已确认密钥登录可用，且已备份原配置
set -uo pipefail

echo "=== 0. 前置检查 ==="
AK=/root/.ssh/authorized_keys
if [ ! -s "$AK" ]; then
  echo "  !! authorized_keys 为空，中止（否则会自锁）"
  exit 1
fi
echo "  authorized_keys 条目数: $(grep -c . "$AK")"
chmod 700 /root/.ssh
chmod 600 "$AK"
echo "  权限已修正: .ssh=700 authorized_keys=600"

echo
echo "=== 1. 再次备份 sshd 配置 ==="
BK=/root/ts-pre-hardening/$(date +%Y%m%d-%H%M%S)-sshd
mkdir -p "$BK"
cp -a /etc/ssh/sshd_config "$BK/"
[ -d /etc/ssh/sshd_config.d ] && cp -a /etc/ssh/sshd_config.d "$BK/"
echo "  备份到 $BK"

echo
echo "=== 2. 写入加固配置（drop-in，便于回退）==="
cat > /etc/ssh/sshd_config.d/99-ts-hardening.conf <<'EOF'
# ---- TS SSH 加固 ----
# 仅允许密钥认证，彻底关闭密码登录（防爆破）
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
# root 仅允许密钥登录
PermitRootLogin prohibit-password
# 精简攻击面
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
MaxAuthTries 4
MaxSessions 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
# 仅允许 root（本机无其他运维账号）
AllowUsers root
EOF
echo "  已写入 /etc/ssh/sshd_config.d/99-ts-hardening.conf"

echo
echo "=== 3. 语法校验（不重启）==="
if sshd -t 2>&1; then
  echo "  sshd 配置语法 OK"
else
  echo "  !! 语法错误，回退配置"
  rm -f /etc/ssh/sshd_config.d/99-ts-hardening.conf
  exit 1
fi

echo
echo "=== 4. 应用前预览生效值 ==="
sshd -T 2>/dev/null | grep -Ei '^(passwordauthentication|permitrootlogin|pubkeyauthentication|kbdinteractiveauthentication|maxauthtries|x11forwarding|allowusers|permitemptypasswords)' | sed 's/^/  /'

echo
echo "=== 5. 应用配置（reload，不断开现有连接）==="
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
sleep 2
echo "  ssh 服务: $(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd)"
echo "  生效值确认:"
sshd -T 2>/dev/null | grep -Ei '^(passwordauthentication|permitrootlogin|pubkeyauthentication)' | sed 's/^/    /'

echo
echo "SSH_HARDENED_DONE"
