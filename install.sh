#!/bin/bash

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 生成随机 UUID
gen_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# 生成随机端口 (10000-65535)
gen_port() {
    echo $((RANDOM % 55536 + 10000))
}

clear
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}   x-ui + Nginx + SSL 一键安装脚本${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

# 绑定域名
read -p "绑定域名：" DOMAIN

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}[错误] 域名不能为空，请重新运行脚本。${NC}"
    exit 1
fi

# 自动生成随机配置
SPLIT_PATH=$(gen_uuid)       # 分流路径
XRAY_PORT=$(gen_port)        # Xray 端口
XUI_PATH=$(gen_uuid)         # x-ui 路径
XUI_PORT=$(gen_port)         # x-ui 监听端口

echo ""
echo -e "${YELLOW}[信息] 域名:       ${DOMAIN}${NC}"
echo -e "${YELLOW}[信息] 分流路径:   /${SPLIT_PATH}${NC}"
echo -e "${YELLOW}[信息] Xray 端口:   ${XRAY_PORT}${NC}"
echo -e "${YELLOW}[信息] x-ui 路径:   /${XUI_PATH}-xui${NC}"
echo -e "${YELLOW}[信息] x-ui 端口:   ${XUI_PORT}${NC}"
echo ""

# 1. 更新包列表并安装 curl
echo -e "${YELLOW}[1/8] 更新包列表并安装 curl...${NC}"
apt update && apt install curl -y

# 2. 安装 x-ui
echo -e "${YELLOW}[2/8] 安装 x-ui...${NC}"
bash <(curl -Ls https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh)

# ========== 配置 x-ui 面板 ==========
echo -e "${YELLOW}[*] 配置 x-ui 面板...${NC}"

# 安装依赖
apt install sqlite3 jq -y

# 获取 x-ui 当前面板端口
XUI_PANEL_PORT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webPort'" 2>/dev/null || echo "54321")
echo -e "${YELLOW}[信息] 当前 x-ui 面板端口: ${XUI_PANEL_PORT}${NC}"

# 将 x-ui 面板端口和路径改为我们生成的随机值
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='${XUI_PORT}' WHERE key='webPort'"
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='/${XUI_PATH}-xui' WHERE key='webBasePath'"
systemctl restart x-ui 2>/dev/null || x-ui restart 2>/dev/null || true
sleep 3
XUI_PANEL_PORT="${XUI_PORT}"

# 登录 x-ui（默认账号 admin/admin）
echo -e "${YELLOW}[信息] 登录 x-ui 面板 API...${NC}"
LOGIN_RES=$(curl -s -c /tmp/xui-cookie -X POST \
  "http://127.0.0.1:${XUI_PANEL_PORT}/login" \
  --data-raw "user=admin&pass=admin")
echo -e "${YELLOW}[信息] 登录结果: ${LOGIN_RES}${NC}"

# 切换 Xray 到最新版
echo -e "${YELLOW}[信息] 切换 Xray 到最新版本...${NC}"
# 获取当前设置，修改 xrayVersion 为 latest
SETTINGS_DATA=$(curl -s -b /tmp/xui-cookie \
  "http://127.0.0.1:${XUI_PANEL_PORT}/xui/setting/all")
echo "${SETTINGS_DATA}" | jq '.xrayVersion = "latest"' 2>/dev/null | \
  curl -s -b /tmp/xui-cookie -X POST \
  "http://127.0.0.1:${XUI_PANEL_PORT}/xui/setting/update" \
  -H "Content-Type: application/json" -d @- > /dev/null || true

# 构建设置 JSON
SETTINGS_JSON=$(jq -n --arg id "${SPLIT_PATH}" \
  '{clients: [{id: $id, alterId: 0, security: "auto"}]}')
STREAM_JSON=$(jq -n --arg path "/${SPLIT_PATH}" \
  '{network: "ws", security: "none", wsSettings: {path: $path}}')
SNIFFING_JSON='{"enabled":true,"destOverride":["http","tls"]}'

# 添加入站规则
echo -e "${YELLOW}[信息] 添加入站规则...${NC}"
ADD_RESULT=$(curl -s -b /tmp/xui-cookie -X POST \
  "http://127.0.0.1:${XUI_PANEL_PORT}/xui/inbound/add" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg remark "" \
    --arg protocol "vmess" \
    --arg listen "127.0.0.1" \
    --argjson port "${XRAY_PORT}" \
    --argjson total 0 \
    --argjson expiryTime 0 \
    --arg settings "${SETTINGS_JSON}" \
    --arg streamSettings "${STREAM_JSON}" \
    --arg sniffing "${SNIFFING_JSON}" \
    '{up: 0, down: 0, total: $total, remark: $remark,
      enable: true, expiryTime: $expiryTime,
      listen: $listen, port: $port, protocol: $protocol,
      settings: $settings, streamSettings: $streamSettings,
      sniffing: $sniffing}')")

echo -e "${YELLOW}[信息] 入站添加结果: ${ADD_RESULT}${NC}"

# 生成 VMess 分享链接
echo -e "${YELLOW}[信息] 生成 VMess 分享链接...${NC}"
VMESS_JSON=$(jq -n \
  --arg v "2" \
  --arg ps "" \
  --arg add "${DOMAIN}" \
  --arg port "443" \
  --arg id "${SPLIT_PATH}" \
  --arg aid "0" \
  --arg net "ws" \
  --arg type "none" \
  --arg host "" \
  --arg path "/${SPLIT_PATH}" \
  --arg tls "tls" \
  '{v: $v, ps: $ps, add: $add, port: $port, id: $id,
    aid: $aid, net: $net, type: $type, host: $host,
    path: $path, tls: $tls}')

VMESS_LINK="vmess://$(echo -n "${VMESS_JSON}" | base64 -w 0)"

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}   VMess 分享链接${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "  ${GREEN}${VMESS_LINK}${NC}"
echo ""

# 3. 安装 nginx
echo -e "${YELLOW}[3/8] 安装 nginx...${NC}"
apt install nginx -y

# 4. 生成 nginx 配置
echo -e "${YELLOW}[4/8] 生成 nginx 配置...${NC}"
cat > /etc/nginx/nginx.conf << NGINX_EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    gzip on;

    server {
        listen 443 ssl;

        server_name ${DOMAIN};
        ssl_certificate       /etc/x-ui/server.crt;
        ssl_certificate_key   /etc/x-ui/server.key;

        ssl_session_timeout 1d;
        ssl_session_cache shared:MozSSL:10m;
        ssl_session_tickets off;
        ssl_protocols    TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers off;

        location / {
            proxy_pass https://pan.aaaab3n.moe/;
            proxy_redirect off;
            proxy_ssl_server_name on;
            sub_filter_once off;
            sub_filter "pan.aaaab3n.moe" \$server_name;
            proxy_set_header Host "pan.aaaab3n.moe";
            proxy_set_header Referer \$http_referer;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header User-Agent \$http_user_agent;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header Accept-Encoding "";
            proxy_set_header Accept-Language "zh-CN";
        }


        location /${SPLIT_PATH} {
            proxy_redirect off;
            proxy_pass http://127.0.0.1:${XRAY_PORT};
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }

        location /${XUI_PATH}-xui {
            proxy_redirect off;
            proxy_pass http://127.0.0.1:${XUI_PORT};
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
        }
    }

    server {
        listen 80;
        location /.well-known/ {
               root /var/www/html;
            }
        location / {
                rewrite ^(.*)\$ https://\$host\$1 permanent;
            }
    }
}
NGINX_EOF

# 5. 安装 acme.sh
echo -e "${YELLOW}[5/8] 安装 acme.sh...${NC}"
curl https://get.acme.sh | sh
ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh

# 6. 设置默认 CA
echo -e "${YELLOW}[6/8] 设置默认 CA 为 Let's Encrypt...${NC}"
acme.sh --set-default-ca --server letsencrypt

# 7. 签发证书
echo -e "${YELLOW}[7/8] 签发 ECC 证书 (域名: ${DOMAIN})...${NC}"
acme.sh --issue -d "$DOMAIN" -k ec-256 --webroot /var/www/html

# 8. 安装证书并重载 nginx
echo -e "${YELLOW}[8/8] 安装证书到 /etc/x-ui/ 并重载 nginx...${NC}"
acme.sh --install-cert -d "$DOMAIN" --ecc \
    --key-file /etc/x-ui/server.key \
    --fullchain-file /etc/x-ui/server.crt \
    --reloadcmd "systemctl force-reload nginx"

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}   全部完成！${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "  域名:       ${GREEN}${DOMAIN}${NC}"
echo -e "  分流路径:   ${GREEN}/${SPLIT_PATH}${NC}"
echo -e "  Xray 端口:  ${GREEN}${XRAY_PORT}${NC}"
echo -e "  x-ui 路径:  ${GREEN}/${XUI_PATH}-xui${NC}"
echo -e "  x-ui 端口:  ${GREEN}${XUI_PORT}${NC}"
echo -e "  证书路径:   ${GREEN}/etc/x-ui/server.crt${NC}"
echo -e "  私钥路径:   ${GREEN}/etc/x-ui/server.key${NC}"
echo ""
echo -e "${YELLOW}  证书将在 90 天后自动续期，无需手动操作。${NC}"
echo ""
