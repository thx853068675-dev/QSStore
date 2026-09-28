#!/usr/bin/env bash
# 把 nginx 根路径从「反代已停用的 LobeChat」改为健康检查页
# 同时保留原有的 /quietstart-rules/ 与 /quietstart/terms.html
set -uo pipefail

BK=/root/ts-pre-hardening/$(date +%Y%m%d-%H%M%S)-nginx
mkdir -p "$BK"
cp -a /etc/nginx/sites-enabled/default "$BK/default"
echo "  已备份到 $BK/default"

cat > /etc/nginx/sites-enabled/default <<'EOF'
# HAP 商店元数据服务 · nginx 站点
# 说明：根路径返回健康检查；/api/ 将在 M1 反代到本地 Fastify 服务
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    charset utf-8;
    server_tokens off;

    # 安全响应头
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    client_max_body_size 32k;
    client_body_timeout 15s;
    client_header_timeout 15s;

    # 健康检查（M0 后用于存活探测）
    location = / {
        default_type application/json;
        return 200 '{"ok":true,"service":"hapstore-api","stage":"M0","note":"metadata service not deployed yet"}';
    }

    location = /healthz {
        default_type text/plain;
        return 200 'ok';
    }

    # ---- 保留原有静态资源 ----
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

    # ---- M1 预留：元数据 API 反代（服务未启动时返回 503 而非超时）----
    location /api/ {
        proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 3s;
        proxy_read_timeout 20s;
        proxy_next_upstream error timeout http_502 http_503 http_504;
    }

    # 其余路径 404（不再反代到已停用的 LobeChat）
    location / {
        return 404 '{"ok":false,"error":{"code":"NOT_FOUND"}}';
    }
}
EOF

echo "  新站点配置已写入"

echo
echo "=== 语法校验 ==="
if nginx -t 2>&1 | grep -q successful; then
  echo "  nginx 配置语法 OK"
  systemctl reload nginx
  echo "  已 reload"
else
  echo "  !! 语法错误，回退"
  nginx -t 2>&1 | sed 's/^/    /'
  cp -a "$BK/default" /etc/nginx/sites-enabled/default
  exit 1
fi

echo
echo "=== 本机验证 ==="
echo "  /          -> $(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1/)"
echo "  /healthz   -> $(curl -s -m 5 http://127.0.0.1/healthz)"
echo "  /v1.json   -> $(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1/quietstart-rules/v1.json)"
echo "  /api/v1/x  -> $(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1/api/v1/apps)  (预期 502/503，服务未启动)"
echo "  根路径响应体:"
curl -s -m 5 http://127.0.0.1/ | sed 's/^/    /'
echo
echo "NGINX_UPDATED_DONE"
