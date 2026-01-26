#!/usr/bin/env bash
# Remnawave 一键安装脚本

set -e

INSTALL_DIR="/opt/remnawave"
NGINX_DIR="/opt/remnawave/nginx"

echo "=========================================="
echo " Remnawave 一键安装脚本"
echo "=========================================="
echo "注意事项："
echo "1. 请确保域名已解析到本机 IP。"
echo "2. 阿里云/腾讯云/AWS 等用户请务必在网页后台安全组放行 80 和 443 端口。"
echo "=========================================="
echo "本脚本将完成以下操作："
echo "1. 安装 Docker（如未安装）"
echo "2. 拉取 Remnawave 官方 docker-compose 与 .env"
echo "3. 自动生成 JWT / Postgres 等随机密钥"
echo "4. 设置订阅域名 SUB_PUBLIC_DOMAIN"
echo "5. 启动 Remnawave 面板容器"
echo "6. 切换 CA 到 Let's Encrypt 并申请证书"
echo "7. 生成 Nginx 配置（包含 HTTP 跳转）并启动"
echo "=========================================="

#------------------------#
# 0. 检查 root 权限
#------------------------#
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 运行本脚本（例如：sudo bash remnawave-onekey.sh）"
  exit 1
fi

#------------------------#
# 1. 交互获取域名与邮箱
#------------------------#
read -rp "请输入用于【面板访问】的域名（例如 panel.example.com）: " MAIN_DOMAIN
if [ -z "$MAIN_DOMAIN" ]; then
  echo "域名不能为空，退出。"
  exit 1
fi

read -rp "请输入用于【订阅地址】的域名（可留空，留空则与面板域名相同）: " SUB_DOMAIN
if [ -z "$SUB_DOMAIN" ]; then
  SUB_DOMAIN="$MAIN_DOMAIN"
fi

read -rp "请输入用于申请证书的邮箱（例如 admin@example.com）: " EMAIL
if [ -z "$EMAIL" ]; then
  echo "邮箱不能为空，退出。"
  exit 1
fi

echo
echo "面板域名: $MAIN_DOMAIN"
echo "订阅域名: $SUB_DOMAIN"
echo "证书邮箱: $EMAIL"
echo

#------------------------#
# 2. 安装基础依赖与防火墙配置
#------------------------#
echo ">>> [1/8] 更新软件源并安装依赖 (curl, socat, cron, openssl, iptables)..."
apt-get update -y
apt-get install -y curl socat cron openssl iptables ufw

echo ">>> [2/8] 正在配置防火墙放行 80/443 端口..."
# 尝试使用 UFW
if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw reload
        echo "   - UFW 规则已添加。"
    fi
fi

# 尝试使用 iptables (强制放行)
if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 80 -j ACCEPT
    iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    echo "   - iptables 规则已添加。"
fi

#------------------------#
# 3. 安装 Docker
#------------------------#
if ! command -v docker >/dev/null 2>&1; then
  echo ">>> [3/8] 未检测到 Docker，正在安装..."
  curl -fsSL https://get.docker.com | sh
else
  echo ">>> [3/8] Docker 已安装，跳过。"
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "警告：未检测到 docker compose 插件，请确认 Docker 安装正确。"
fi

#------------------------#
# 4. 下载文件并修复格式错误
#------------------------#
echo ">>> [4/8] 创建目录并下载配置文件..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# 下载 docker-compose.yml
if [ ! -f docker-compose.yml ]; then
  echo "   - 正在下载 docker-compose.yml..."
  curl -o docker-compose.yml https://raw.githubusercontent.com/vlongx/remnawave-installer/refs/heads/main/docker-compose.yml
  
  # === 关键修复步骤 ===
  # 远程文件里有一行 "/opt/remnawave/nginx:..." 被错误放在了 networks 下
  # 这里使用 sed 自动删除那一行，防止 "undefined network" 报错
  echo "   - 正在自动修复 docker-compose.yml 中的格式错误..."
  sed -i '/\/opt\/remnawave\/nginx/d' docker-compose.yml
else
  echo "提示：已存在 docker-compose.yml，跳过下载。"
fi

# 下载 .env.sample
if [ ! -f .env ]; then
  curl -o .env https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample
else
  echo "提示：已存在 .env，跳过下载 .env.sample。"
fi

#------------------------#
# 5. 配置 .env 并启动后端
#------------------------#
echo ">>> [5/8] 生成密钥并启动后端..."

if grep -q "JWT_AUTH_SECRET=changeme" .env; then
    sed -i "s/^JWT_AUTH_SECRET=.*/JWT_AUTH_SECRET=$(openssl rand -hex 64)/" .env
    sed -i "s/^JWT_API_TOKENS_SECRET=.*/JWT_API_TOKENS_SECRET=$(openssl rand -hex 64)/" .env
    sed -i "s/^METRICS_PASS=.*/METRICS_PASS=$(openssl rand -hex 64)/" .env
    sed -i "s/^WEBHOOK_SECRET_HEADER=.*/WEBHOOK_SECRET_HEADER=$(openssl rand -hex 64)/" .env
    
    pw=$(openssl rand -hex 24)
    sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$pw/" .env
    sed -i "s|^\(DATABASE_URL=\"postgresql://postgres:\)[^@]*\(@.*\)|\1$pw\2|" .env
fi

# 设置订阅域名
if grep -q "^SUB_PUBLIC_DOMAIN=" .env; then
  sed -i "s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=${SUB_DOMAIN}/api/sub|" .env
else
  echo "SUB_PUBLIC_DOMAIN=${SUB_DOMAIN}/api/sub" >> .env
fi

# 启动后端
docker compose up -d
echo ">>> Remnawave 后端容器已启动。"

#------------------------#
# 6. 申请 SSL 证书
#------------------------#
echo ">>> [6/8] 配置 acme.sh 并申请证书..."

# 确保网络存在
docker network create remnawave-network >/dev/null 2>&1 || true

# 安装 acme.sh
if [ ! -d "$HOME/.acme.sh" ]; then
  curl https://get.acme.sh | sh -s email="$EMAIL"
fi
ACME_SH="$HOME/.acme.sh/acme.sh"
mkdir -p "$NGINX_DIR"

# 切换 CA 为 Let's Encrypt (修复 ZeroSSL 限流问题)
echo "   - 切换 CA 为 Let's Encrypt..."
$ACME_SH --set-default-ca --server letsencrypt
$ACME_SH --register-account -m "$EMAIL" || true

# 停止可能占用 80 端口的容器
docker stop remnawave-nginx >/dev/null 2>&1 || true

echo "   - 开始申请证书 (Standalone 模式)..."
$ACME_SH --issue --standalone -d "$MAIN_DOMAIN" \
  --key-file "$NGINX_DIR/privkey.key" \
  --fullchain-file "$NGINX_DIR/fullchain.pem" \
  --force

if [ ! -f "$NGINX_DIR/fullchain.pem" ]; then
    echo "❌ 证书申请失败！请检查防火墙是否放行 80 端口。"
    exit 1
fi
echo "✅ 证书申请成功。"

#------------------------#
# 7. 生成 Nginx 配置
#------------------------#
echo ">>> [7/8] 生成 Nginx 配置文件..."

cat > "$NGINX_DIR/nginx.conf" <<EOF
upstream remnawave {
    server remnawave:3000;
}

server {
    listen 80;
    listen [::]:80;
    server_name $MAIN_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    server_name $MAIN_DOMAIN;

    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
    
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;
    ssl_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/privkey.key";
}
EOF

#------------------------#
# 8. 启动 Nginx
#------------------------#
echo ">>> [8/8] 启动 Nginx 反代容器..."

cat > "$NGINX_DIR/docker-compose.yml" <<'EOF'
services:
  remnawave-nginx:
    image: nginx:alpine
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
      - ./privkey.key:/etc/nginx/ssl/privkey.key:ro
    restart: always
    ports:
      - '0.0.0.0:80:80'
      - '0.0.0.0:443:443'
    networks:
      - remnawave-network

networks:
  remnawave-network:
    name: remnawave-network
    external: true
EOF

cd "$NGINX_DIR"
docker compose down --remove-orphans >/dev/null 2>&1 || true
docker compose up -d

echo
echo "=========================================="
echo " ✅ Remnawave 安装完成！"
echo " 面板地址：https://$MAIN_DOMAIN"
echo " 订阅域名：$SUB_DOMAIN"
echo "=========================================="
