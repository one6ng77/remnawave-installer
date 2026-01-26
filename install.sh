#!/usr/bin/env bash
# Remnawave 一键安装脚本（面板 + 证书 + Nginx 反代）
# 修复：切换 Let's Encrypt，增加 80->443 跳转

set -e

INSTALL_DIR="/opt/remnawave"
NGINX_DIR="/opt/remnawave/nginx"

echo "==============================="
echo " Remnawave 一键安装脚本 "
echo "==============================="
echo
echo "本脚本将完成以下操作："
echo "1. 安装 Docker（如未安装）"
echo "2. 拉取 Remnawave 官方 docker-compose 与 .env"
echo "3. 自动生成 JWT / Postgres 等随机密钥"
echo "4. 设置订阅域名 SUB_PUBLIC_DOMAIN"
echo "5. 启动 Remnawave 面板容器"
echo "6. 切换 CA 到 Let's Encrypt 并申请证书"
echo "7. 生成 Nginx 配置（包含 HTTP 跳转）并启动"
echo

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
# 2. 安装基础依赖
#------------------------#
echo ">>> 更新软件源并安装基础依赖 (curl, socat, cron, openssl)..."
apt-get update -y
apt-get install -y curl socat cron openssl

#------------------------#
# 3. 安装 Docker
#------------------------#
if ! command -v docker >/dev/null 2>&1; then
  echo ">>> 未检测到 Docker，正在安装 Docker..."
  curl -fsSL https://get.docker.com | sh
else
  echo ">>> 已检测到 Docker，跳过安装。"
fi

# 确保 docker compose 子命令可用
if ! docker compose version >/dev/null 2>&1; then
  echo "警告：未检测到 docker compose 插件，请确认 Docker 已正确安装支持 'docker compose' 子命令。"
fi

#------------------------#
# 4. 创建项目目录并下载官方文件
#------------------------#
echo ">>> 创建 Remnawave 目录并下载 docker-compose 与 .env.sample ..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# 下载 docker-compose.yml
# 注意：这里我们使用官方/原来的文件，只用于启动后端
if [ ! -f docker-compose.yml ]; then
  curl -o docker-compose.yml https://raw.githubusercontent.com/vlongx/remnawave-installer/refs/heads/main/docker-compose.yml
else
  echo "提示：已存在 docker-compose.yml，跳过下载。"
fi

# 下载 .env.sample 并复制为 .env
if [ ! -f .env ]; then
  curl -o .env https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample
else
  echo "提示：已存在 .env，跳过下载 .env.sample。"
fi

#------------------------#
# 5. 自动配置 .env（生成密钥 & DB 密码）
#------------------------#
echo ">>> 自动生成 JWT / API / METRICS / WEBHOOK 等随机密钥..."

# 仅当密钥未设置时才生成，避免重复运行覆盖
if grep -q "JWT_AUTH_SECRET=changeme" .env; then
    sed -i "s/^JWT_AUTH_SECRET=.*/JWT_AUTH_SECRET=$(openssl rand -hex 64)/" .env
    sed -i "s/^JWT_API_TOKENS_SECRET=.*/JWT_API_TOKENS_SECRET=$(openssl rand -hex 64)/" .env
    sed -i "s/^METRICS_PASS=.*/METRICS_PASS=$(openssl rand -hex 64)/" .env
    sed -i "s/^WEBHOOK_SECRET_HEADER=.*/WEBHOOK_SECRET_HEADER=$(openssl rand -hex 64)/" .env
    
    echo ">>> 生成 Postgres 密码并写入 .env ..."
    pw=$(openssl rand -hex 24)
    sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$pw/" .env
    # 更新 DATABASE_URL 中的密码
    sed -i "s|^\(DATABASE_URL=\"postgresql://postgres:\)[^@]*\(@.*\)|\1$pw\2|" .env
else
    echo ">>> 检测到 .env 已配置过密钥，跳过生成。"
fi

#------------------------#
# 6. 设置订阅域名 SUB_PUBLIC_DOMAIN
#------------------------#
echo ">>> 设置 SUB_PUBLIC_DOMAIN 为: ${SUB_DOMAIN}/api/sub"

if grep -q "^SUB_PUBLIC_DOMAIN=" .env; then
  sed -i "s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=${SUB_DOMAIN}/api/sub|" .env
else
  echo "SUB_PUBLIC_DOMAIN=${SUB_DOMAIN}/api/sub" >> .env
fi

#------------------------#
# 7. 启动 Remnawave 容器
#------------------------#
echo ">>> 启动 Remnawave 面板容器..."
# 确保没有 Nginx 配置干扰主文件
docker compose up -d

echo ">>> Remnawave 后端容器已启动。"

#------------------------#
# 8. 创建 Docker 网络（供 Nginx 使用）
#------------------------#
echo ">>> 确保 remnawave-network 网络存在..."
docker network create remnawave-network >/dev/null 2>&1 || true

#------------------------#
# 9. 安装 acme.sh 并申请证书 (关键修复)
#------------------------#
echo ">>> 安装 acme.sh ..."
if [ ! -d "$HOME/.acme.sh" ]; then
  curl https://get.acme.sh | sh -s email="$EMAIL"
else
  echo "提示：已检测到 ~/.acme.sh，跳过安装。"
fi

# 使用绝对路径调用 acme.sh
ACME_SH="$HOME/.acme.sh/acme.sh"
mkdir -p "$NGINX_DIR"

# --- 修复核心：切换到 Let's Encrypt ---
echo ">>> 正在切换默认 CA 为 Let's Encrypt (解决 ZeroSSL 限流问题)..."
$ACME_SH --set-default-ca --server letsencrypt

# 注册账户（防止未注册错误）
$ACME_SH --register-account -m "$EMAIL" || true

echo ">>> 使用 acme.sh 申请证书（standalone 模式，端口 80）..."
# 停止占用 80 端口的进程（如果有）
docker stop remnawave-nginx >/dev/null 2>&1 || true

$ACME_SH --issue --standalone -d "$MAIN_DOMAIN" \
  --key-file "$NGINX_DIR/privkey.key" \
  --fullchain-file "$NGINX_DIR/fullchain.pem" \
  --force

echo ">>> 证书申请完成，已保存到："
echo "    $NGINX_DIR/privkey.key"
echo "    $NGINX_DIR/fullchain.pem"

#------------------------#
# 10. 生成 nginx.conf
#------------------------#
echo ">>> 生成 Nginx 配置文件 nginx.conf (包含 HTTP->HTTPS 跳转)..."

cat > "$NGINX_DIR/nginx.conf" <<EOF
upstream remnawave {
    server remnawave:3000;
}

server {
    listen 80;
    listen [::]:80;
    server_name $MAIN_DOMAIN;
    # 强制跳转 HTTPS
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

    # SSL Configuration
    ssl_protocols           TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;

    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets    off;
    
    # 证书路径（容器内）
    ssl_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/privkey.key";
    
    ssl_stapling           on;
    ssl_stapling_verify    on;
    resolver               1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 valid=60s;
    resolver_timeout       2s;

    # Gzip
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;
}
EOF

#------------------------#
# 11. 生成 Nginx 的 docker-compose.yml
#------------------------#
echo ">>> 生成 Nginx docker-compose.yml ..."

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
    driver: bridge
    external: true
EOF

#------------------------#
# 12. 启动 Nginx 反代容器
#------------------------#
echo ">>> 启动 Nginx 反向代理容器 ..."
cd "$NGINX_DIR"
# 先停止可能存在的旧容器，防止冲突
docker compose down --remove-orphans >/dev/null 2>&1 || true
docker compose up -d

echo
echo "=========================================="
echo " Remnawave 面板 + Nginx 已全部部署完成！"
echo "------------------------------------------"
echo "面板访问地址：https://$MAIN_DOMAIN"
echo "订阅域名（SUB_PUBLIC_DOMAIN）：$SUB_DOMAIN"
echo
echo "常用命令："
echo "  进入 Remnawave 目录：cd $INSTALL_DIR"
echo "  启动/停止面板：docker compose up -d / docker compose down"
echo "  进入 Nginx 目录：cd $NGINX_DIR"
echo "  启动/停止 Nginx：docker compose up -d / docker compose down"
echo "=========================================="
