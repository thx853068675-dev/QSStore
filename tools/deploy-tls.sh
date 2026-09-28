#!/usr/bin/env bash
# Copyright QuietStart contributors. SPDX-License-Identifier: MIT
#
# 为元数据 API 启用 HTTPS（自签 IP 证书）+ 打印客户端 pinning 指纹。
#
# 背景：元数据决定「从哪个镜像下载、用什么哈希校验」。明文 HTTP 下中间人可
# 同时替换镜像与哈希，完整性校验失去意义。IP 直连拿不到公共 CA 证书，因此
# 用**自签证书 + 客户端指纹 pinning**：App 内置该证书的 SHA-256 指纹，只信任
# 这一张，任何被替换的证书都会被拒绝。
#
# 在**服务器**上以 root 执行：
#   bash deploy-tls.sh
#
# 执行后：
#   1) 会打印一行  PIN=<sha256>
#   2) 用该值重新构建 App：
#        ./tools/build-app.sh release \
#          --base https://store.example.com \
#          --pin  <sha256>
#   （或直接给 build-app.sh 传 HAPSTORE_API_BASE / HAPSTORE_API_PIN 环境变量）
#
# 可重复执行：证书已存在时不会重新生成（避免指纹变化导致已装 App 失联）。

set -uo pipefail

IP="${TS_IP:-store.example.com}"
SSL_DIR="/etc/nginx/ssl"
CERT="$SSL_DIR/hapstore.crt"
KEY="$SSL_DIR/hapstore.key"
BK="/root/ts-pre-hardening/$(date +%Y%m%d-%H%M%S)-tls"
mkdir -p "$BK" "$SSL_DIR"

echo "=== 备份现有 nginx 站点 ==="
if [ -f /etc/nginx/sites-enabled/default ]; then
  cp -a /etc/nginx/sites-enabled/default "$BK/default"
  echo "  已备份到 $BK/default"
fi

echo
echo "=== 生成自签证书（若不存在）==="
if [ -f "$CERT" ] && [ -f "$KEY" ]; then
  echo "  证书已存在，沿用：$CERT"
else
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY" -out "$CERT" -days 3650 \
    -subj "/C=CN/O=HapStore/CN=$IP" \
    -addext "subjectAltName=IP:$IP" \
    >/dev/null 2>&1
  chmod 600 "$KEY"
  echo "  已生成：$CERT"
fi

# 客户端 pinning 用：证书 DER 的 SHA-256（小写十六进制），与 Dart
# 的 sha256.convert(x509.der).toString() 一致。
PIN=$(openssl x509 -in "$CERT" -outform DER | openssl dgst -sha256 -r | awk '{print $1}')

echo
echo "=== 写入 nginx 站点（HTTP 跳转 + HTTPS 反代）==="
cat > /etc/nginx/sites-enabled/default <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    # 统一跳转到 HTTPS；健康检查除外（便于用 http 做存活探测）
    location = /healthz { default_type text/plain; return 200 'ok'; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;

    ssl_certificate     $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:4m;
    ssl_session_timeout 1h;

    charset utf-8;
    server_tokens off;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Strict-Transport-Security "max-age=31536000" always;

    client_max_body_size 32k;
    client_body_timeout 15s;
    client_header_timeout 15s;

    location = /healthz { default_type text/plain; return 200 'ok'; }

    # ---- 保留原有静态资源（旧客户端会来取）----
    location = /quietstart-rules/v1.json {
        alias /var/www/html/quietstart-rules-v1.json;
        default_type application/json;
        add_header Cache-Control "no-cache";
        limit_except GET { deny all; }
    }

    location = /quietstart/terms.html {
        alias /var/www/html/quietstart/terms.html;
        default_type text/html;
        add_header Cache-Control "public, max-age=300";
        limit_except GET { deny all; }
    }

    # ---- 元数据 API 反代（服务未启动时返回 502/504 而非挂起）----
    location /api/ {
        proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 3s;
        proxy_read_timeout 20s;
        proxy_next_upstream error timeout http_502 http_503 http_504;
    }

    location / { return 404 '{"ok":false,"error":{"code":"NOT_FOUND"}}'; }
}
EOF

echo
echo "=== 语法校验 ==="
if ! nginx -t 2>&1 | grep -q successful; then
  echo "  !! 语法错误，回退"
  nginx -t 2>&1 | sed 's/^/    /'
  [ -f "$BK/default" ] && cp -a "$BK/default" /etc/nginx/sites-enabled/default
  exit 1
fi
echo "  nginx 语法 OK"
systemctl reload nginx
echo "  已 reload"

echo
echo "=== 本机验证 ==="
echo "  http  /healthz  -> $(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1/healthz)"
echo "  https /healthz  -> $(curl -sk -m 5 -o /dev/null -w '%{http_code}' https://127.0.0.1/healthz)"
echo "  https /api/v1/apps -> $(curl -sk -m 5 -o /dev/null -w '%{http_code}' https://127.0.0.1/api/v1/apps)  （预期 200，服务未启动则 502）"

echo
echo "================ 客户端 pinning 指纹 ================"
echo "PIN=$PIN"
echo "构建命令示例："
echo "  ./tools/build-app.sh release \\"
echo "    --base https://$IP --pin $PIN"
echo "===================================================="
