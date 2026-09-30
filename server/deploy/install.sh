#!/usr/bin/env bash
# HAP 商店元数据服务 —— 服务器侧安装脚本
set -uo pipefail

python3 -c 'from cryptography.hazmat.primitives.ciphers.aead import AESGCM' || {
  echo '请先安装 python3-cryptography（签名身份库需要 AES-GCM）' >&2
  exit 1
}
python3 -c 'from PIL import Image' || {
  if [ -n "${HAPSTORE_PIL_WHEEL:-}" ] && [ -f "$HAPSTORE_PIL_WHEEL" ]; then
    python3 -m pip install --break-system-packages --no-index "$HAPSTORE_PIL_WHEEL" || exit 1
  else
    apt-get update && apt-get install -y python3-pil || exit 1
  fi
}

echo "=== 1. systemd 服务 ==="
cat > /etc/systemd/system/hapstore-api.service <<'EOF'
[Unit]
Description=HAP Store metadata API
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/hapstore
Environment=HAPSTORE_DB=/var/lib/hapstore/hapstore.db
Environment=HAPSTORE_HOST=127.0.0.1
Environment=HAPSTORE_PORT=8787
Environment=HAPSTORE_SYNC_INTERVAL=1800
# 采集新鲜度的**真正开关**。后台循环按 SYNC_INTERVAL 唤醒，但每次只采
# apps_needing_sync() 挑出来的应用，而它的默认阈值是 6 小时 —— 只改 SYNC_INTERVAL
# 会出现「每 30 分钟醒一次、却只采超过 6 小时没采的」，刚发布的版本最坏要等 6 小时
# 才在客户端可见。这里配成 10 分钟，让它明显小于唤醒间隔，每轮都有活干。
# 配额：每个应用 2 次 GitHub API 调用（HAP 走 CDN 不计），未认证上限 60 次/小时；
# 30 分钟一轮 × 每轮几个应用，远低于上限。
Environment=HAPSTORE_SYNC_MAX_AGE=600
# Python cryptography 用于签名身份库的 AES-256-GCM 加密。
# 本机系统代理可能只代理 HTTP 或握手超时；商店的身份核验与
# GitHub 可信元数据请求直接出站，避免继承 /etc/environment 的代理。
UnsetEnvironment=HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
ExecStart=/usr/bin/python3 /opt/hapstore/run.py
Restart=always
RestartSec=5
# 加固：最小权限
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/hapstore
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hapstore-api >/dev/null 2>&1
systemctl restart hapstore-api
sleep 3
echo "  状态: $(systemctl is-active hapstore-api)"
echo "  开机自启: $(systemctl is-enabled hapstore-api 2>/dev/null)"

echo
echo "=== 2. nginx 反代 /api/ → 127.0.0.1:8787 ==="
python3 - <<'PY'
import re
p = '/etc/nginx/sites-enabled/default'
s = open(p, encoding='utf-8').read()

# 找到并替换现有的 /api/ 段落
new_block = """    # ---- 元数据 API 反代 ----
    location /api/ {
        proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 3s;
        proxy_read_timeout 30s;
    }
"""

start = s.find('    location /api/ {')
if start != -1:
    end = s.find('\n    }\n', start)
    # 定位到该 location 块的结尾
    depth = 0
    i = start
    while i < len(s):
        if s[i] == '{':
            depth += 1
        elif s[i] == '}':
            depth -= 1
            if depth == 0:
                end = i + 1
                break
        i += 1
    s = s[:start] + new_block.rstrip() + s[end:]
    print("  已替换现有 /api/ 段落")
else:
    # 插到「其余路径 404」之前
    anchor = '    # 其余路径 404'
    idx = s.find(anchor)
    if idx == -1:
        idx = s.rfind('}')
    s = s[:idx] + new_block + '\n' + s[idx:]
    print("  已插入新 /api/ 段落")

open(p, 'w', encoding='utf-8').write(s)
PY

if nginx -t 2>&1 | grep -q successful; then
  systemctl reload nginx
  echo "  nginx 已重载"
else
  echo "  !! nginx 配置错误"
  nginx -t 2>&1 | sed 's/^/    /'
  exit 1
fi

echo
echo "=== 3. 验证 ==="
echo "  本机 API:  $(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1:8787/api/v1/healthz)"
echo "  经 nginx:  $(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1/api/v1/healthz)"
echo "  内容:"
curl -s -m 5 http://127.0.0.1/api/v1/healthz | sed 's/^/    /'
echo
echo "  内存占用:"
ps -o rss= -C python3 2>/dev/null | awk '{printf "    python3 RSS = %.1f MB\n", $1/1024}'
echo
echo "INSTALL_DONE"
