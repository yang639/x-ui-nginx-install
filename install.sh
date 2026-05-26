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
XUI_PATH="$(gen_uuid)-xui"   # x-ui 路径
XUI_PORT=$(gen_port)         # x-ui 监听端口

echo ""
echo -e "${YELLOW}[信息] 域名:       ${DOMAIN}${NC}"
echo -e "${YELLOW}[信息] 分流路径:   /${SPLIT_PATH}${NC}"
echo -e "${YELLOW}[信息] Xray 端口:   ${XRAY_PORT}${NC}"
echo -e "${YELLOW}[信息] x-ui 路径:   /${XUI_PATH}${NC}"
echo -e "${YELLOW}[信息] x-ui 端口:   ${XUI_PORT}${NC}"
echo ""

# 1. 更新包列表并安装 curl
echo -e "${YELLOW}[1/8] 更新包列表并安装 curl...${NC}"
apt update && apt install curl -y

# 2. 安装 x-ui（自动应答交互式安装）
echo -e "${YELLOW}[2/8] 安装 x-ui...${NC}"
printf 'y\nadmin\nadmin\n%s\n' "${XUI_PORT}" | bash <(curl -Ls https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh)

# ========== 配置 x-ui 面板 ==========
echo -e "${YELLOW}[*] 配置 x-ui 面板...${NC}"

# 安装依赖
apt install sqlite3 jq openssl -y

# 等待 x-ui 完全启动并创建数据库
sleep 5

# 端口已在安装时设为 XUI_PORT，无需再改
XUI_PANEL_PORT="${XUI_PORT}"

# 从数据库读取凭据（已在安装时设为 admin/admin）
XUI_USER=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webUser'" 2>/dev/null || echo "admin")
XUI_PASS=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webPass'" 2>/dev/null || echo "admin")
echo -e "${YELLOW}[信息] x-ui 端口: ${XUI_PANEL_PORT}, 用户: ${XUI_USER}${NC}"

# 设置面板 URL 路径前缀
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='/${XUI_PATH}' WHERE key='webBasePath'" 2>/dev/null || true
systemctl restart x-ui 2>/dev/null || x-ui restart 2>/dev/null || true
sleep 5

# 切换 Xray 到最新版 (设置标记，x-ui 重启后自动拉取)
echo -e "${YELLOW}[信息] 切换 Xray 到最新版本...${NC}"
set +e
sqlite3 /etc/x-ui/x-ui.db "INSERT OR REPLACE INTO settings (key, value) VALUES ('xrayVersion', 'latest');" 2>/dev/null
# API 兜底
LOGIN_RES=$(curl -s -c /tmp/xui-cookie -X POST \
  "http://127.0.0.1:${XUI_PANEL_PORT}/login" \
  --data-raw "user=${XUI_USER}&pass=${XUI_PASS}" 2>/dev/null || true)
if echo "${LOGIN_RES}" | grep -qiE '"success"\s*:\s*true'; then
  curl -s -b /tmp/xui-cookie -X POST \
    "http://127.0.0.1:${XUI_PANEL_PORT}/xui/setting/update" \
    -H "Content-Type: application/json" \
    -d '{"xrayVersion":"latest"}' > /dev/null 2>&1 || true
fi
echo -e "${YELLOW}[信息] Xray 将在 x-ui 重启后自动更新${NC}"
set -e

# 直接写入数据库添加入站 (绕过 API 兼容性问题)
echo -e "${YELLOW}[信息] 添加入站规则 (直接写库)...${NC}"
INBOUND_SETTINGS=$(jq -n --arg id "${SPLIT_PATH}" \
  '{clients: [{id: $id, alterId: 0, security: "auto"}]}')
INBOUND_STREAM=$(jq -n --arg path "/${SPLIT_PATH}" \
  '{network: "ws", security: "none", wsSettings: {path: $path}}')
INBOUND_SNIFF='{"enabled":true,"destOverride":["http","tls"]}'

# 检测入站表名 (不同 x-ui 版本表名不同: inbound / inbounds 等)
echo -e "${YELLOW}[调试] 数据库表列表:${NC}"
sqlite3 /etc/x-ui/x-ui.db ".tables" 2>&1 || true
INBOUND_TABLE=$(sqlite3 /etc/x-ui/x-ui.db ".tables" 2>/dev/null | tr ' ' '\n' | grep -i 'inbound' | head -1)
if [ -z "${INBOUND_TABLE}" ]; then
  echo -e "${RED}[错误] 找不到入站表，x-ui 数据库可能未初始化，请检查 x-ui 是否正常运行。${NC}"
  echo -e "${YELLOW}[调试] 完整 schema:${NC}"
  sqlite3 /etc/x-ui/x-ui.db ".schema" 2>&1 || true
else
  echo -e "${YELLOW}[调试] 检测到入站表: ${INBOUND_TABLE}${NC}"

  # 检测列名是否使用 settings 还是其它
  SCHEMA=$(sqlite3 /etc/x-ui/x-ui.db ".schema ${INBOUND_TABLE}" 2>/dev/null)
  echo -e "${YELLOW}[调试] 表结构: ${SCHEMA}${NC}"

  # 构建并执行 INSERT
  cat > /tmp/xui-inbound.sql << SQLEOF
INSERT INTO ${INBOUND_TABLE} (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
VALUES (1, 0, 0, 0, '', 1, 0, '127.0.0.1', ${XRAY_PORT}, 'vmess', '${INBOUND_SETTINGS}', '${INBOUND_STREAM}', 'inbound-${XRAY_PORT}', '${INBOUND_SNIFF}');
SQLEOF

  echo -e "${YELLOW}[调试] 写入的 SQL:${NC}"
  cat /tmp/xui-inbound.sql

  if sqlite3 /etc/x-ui/x-ui.db < /tmp/xui-inbound.sql 2>&1; then
    INBOUND_COUNT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT COUNT(*) FROM ${INBOUND_TABLE} WHERE port=${XRAY_PORT};" 2>/dev/null || echo "0")
    echo -e "${GREEN}[信息] 入站添加成功 (端口 ${XRAY_PORT}，当前共 ${INBOUND_COUNT} 条)${NC}"
  else
    echo -e "${RED}[错误] 入站添加失败，尝试用 API 兜底...${NC}"
    # API 兜底
    LOGIN_RES=$(curl -s -c /tmp/xui-cookie -X POST \
      "http://127.0.0.1:${XUI_PANEL_PORT}/login" \
      --data-raw "user=${XUI_USER}&pass=${XUI_PASS}" 2>/dev/null || true)
    if echo "${LOGIN_RES}" | grep -qiE '"success"\s*:\s*true'; then
      curl -s -b /tmp/xui-cookie -X POST \
        "http://127.0.0.1:${XUI_PANEL_PORT}/xui/inbound/add" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
          --arg remark "" \
          --arg protocol "vmess" \
          --arg listen "127.0.0.1" \
          --argjson port "${XRAY_PORT}" \
          --argjson total 0 \
          --argjson expiryTime 0 \
          --arg settings "${INBOUND_SETTINGS}" \
          --arg streamSettings "${INBOUND_STREAM}" \
          --arg sniffing "${INBOUND_SNIFF}" \
          '{up: 0, down: 0, total: $total, remark: $remark,
            enable: true, expiryTime: $expiryTime,
            listen: $listen, port: $port, protocol: $protocol,
            settings: $settings, streamSettings: $streamSettings,
            sniffing: $sniffing}')" > /dev/null 2>&1 || true
      echo -e "${YELLOW}[信息] API 入站添加已尝试${NC}"
    fi
  fi
  rm -f /tmp/xui-inbound.sql
fi

# 最终重启 x-ui 使所有配置生效
echo -e "${YELLOW}[信息] 重启 x-ui 使配置生效...${NC}"
systemctl restart x-ui 2>/dev/null || x-ui restart 2>/dev/null || true
sleep 3

# 生成 VMess 分享链接
echo -e "${YELLOW}[信息] 生成 VMess 分享链接...${NC}"
VMESS_JSON=$(jq -n \
  --arg add "${DOMAIN}" \
  --arg port "443" \
  --arg id "${SPLIT_PATH}" \
  --arg net "ws" \
  --arg path "/${SPLIT_PATH}" \
  --arg tls "tls" \
  '{add: $add, port: $port, id: $id,
    net: $net, path: $path, tls: $tls}')

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

# 创建伪装网盘登录页面
echo -e "${YELLOW}[*] 创建伪装网盘登录页面...${NC}"
mkdir -p /var/www/html
cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AList | 登录</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);min-height:100vh;display:flex;justify-content:center;align-items:center}
.login-card{background:#fff;border-radius:12px;padding:40px;width:380px;box-shadow:0 20px 60px rgba(0,0,0,0.3)}
.logo{text-align:center;font-size:32px;font-weight:700;color:#333;margin-bottom:8px;letter-spacing:2px}
.subtitle{text-align:center;color:#999;font-size:13px;margin-bottom:32px}
.input-group{margin-bottom:20px}
.input-group label{display:block;font-size:13px;color:#555;margin-bottom:6px}
.input-group input{width:100%;height:42px;border:1px solid #e0e0e0;border-radius:6px;padding:0 14px;font-size:14px;transition:border-color .2s;outline:none}
.input-group input:focus{border-color:#667eea}
.btn-login{width:100%;height:44px;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);border:none;border-radius:6px;color:#fff;font-size:16px;cursor:pointer;margin-top:10px;letter-spacing:2px}
.btn-login:hover{opacity:0.9}
.footer{text-align:center;margin-top:24px;color:#bbb;font-size:12px}
</style>
</head>
<body>
<div class="login-card">
<div class="logo">AList</div>
<div class="subtitle">个人网盘 · 文件管理</div>
<div class="input-group"><label>用户名</label><input type="text" placeholder="请输入用户名"></div>
<div class="input-group"><label>密码</label><input type="password" placeholder="请输入密码"></div>
<button class="btn-login" type="button">登 录</button>
<div class="footer">AList v3 · Powered by Go</div>
</div>
</body>
</html>
HTMLEOF

# 生成自签名占位证书（后续被 acme.sh 正式证书替换）
echo -e "${YELLOW}[*] 生成占位 SSL 证书...${NC}"
mkdir -p /etc/x-ui
openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
  -keyout /etc/x-ui/server.key \
  -out /etc/x-ui/server.crt \
  -subj "/CN=${DOMAIN}" 2>/dev/null || true

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
            root /var/www/html;
            index index.html;
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

        location /${XUI_PATH} {
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
if [ ! -f /root/.acme.sh/acme.sh ]; then
  echo -e "${RED}[错误] acme.sh 安装失败，请检查网络。${NC}"
  exit 1
fi

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
    --reloadcmd "systemctl enable nginx 2>/dev/null; systemctl force-reload nginx 2>/dev/null || systemctl start nginx"

# 最终重启 nginx 确保配置生效
echo -e "${YELLOW}[*] 最终重启 nginx...${NC}"
nginx -t 2>&1 || true
systemctl restart nginx 2>/dev/null || systemctl start nginx 2>/dev/null || true

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}   全部完成！${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "  域名:       ${GREEN}${DOMAIN}${NC}"
echo -e "  分流路径:   ${GREEN}/${SPLIT_PATH}${NC}"
echo -e "  Xray 端口:  ${GREEN}${XRAY_PORT}${NC}"
echo -e "  x-ui 路径:  ${GREEN}/${XUI_PATH}${NC}"
echo -e "  x-ui 端口:  ${GREEN}${XUI_PORT}${NC}"
echo -e "  x-ui 账号:  ${GREEN}${XUI_USER}${NC}"
echo -e "  x-ui 密码:  ${GREEN}${XUI_PASS}${NC}"
echo -e "  证书路径:   ${GREEN}/etc/x-ui/server.crt${NC}"
echo -e "  私钥路径:   ${GREEN}/etc/x-ui/server.key${NC}"
echo ""
echo -e "${YELLOW}  证书将在 90 天后自动续期，无需手动操作。${NC}"
echo ""
