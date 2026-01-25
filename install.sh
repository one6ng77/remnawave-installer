#!/usr/bin/env bash
# Remnawave 一键安装脚本（修复版 V2）
# 修复了 volumes 插入位置错误导致 YAML 报错的问题

set -e

INSTALL_DIR="/opt/remnawave"
NGINX_DIR="/opt/remnawave/nginx"

echo "==============================="
echo " Remnawave 一键安装脚本 (修复版)"
echo "==============================="
echo
echo "本脚本将完成以下操作："
echo "1. 安装 Docker（如未安装）"
echo "2. 拉取 Remnawave 官方 docker-compose 与 .env"
echo "3. 精准修改 docker-compose.yml 增加证书映射"
echo "4. 自动生成 JWT / Postgres 等随机密钥"
echo "5. 设置订阅域名 SUB_PUBLIC_DOMAIN"
echo "6. 启动 Remnawave 面板容器"
echo "7. 安装 acme.sh 申请证书"
echo "8. 生成 Nginx 配置并启动反向代理容器"
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
  systemctl enable docker
  systemctl start docker
else
  echo ">>> 已检测到 Docker，跳过安装。"
fi

# 确保 docker compose 子命令可用
if ! docker compose version >/dev/null 2>&1; then
  echo "警告：未检测到 docker compose 插件，尝试安装插件..."
  apt-get install -y docker-compose-plugin || echo "自动安装插件失败，请确保 'docker compose' 命令可用"
fi

#------------------------#
# 4. 创建项目目录并下载官方文件
#------------------------#
echo ">>> 创建 Remnawave 目录并下载 docker-compose 与 .env.sample ..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# 下载 docker-compose.yml
if [ ! -f docker-compose.yml ]; then
  curl -o docker-compose.yml https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml
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
# 4.1 修改 docker-compose.yml 增加证书映射 (修复逻辑)
#------------------------#
echo ">>> 修改 docker-compose.yml 增加 SSL 证书路径映射..."

# 修复点：不再匹配所有 "volumes:"，而是匹配 remnawave 服务独有的 ".env" 映射行
# 在该行后面追加 Nginx 证书映射
TARGET_LINE="- ./.env:/app/.env"
ADD_LINE="      - '/opt/remnawave/nginx:/var/lib/remnawave/configs/xray/ssl'"

if grep -q "/var/lib/remnawave/configs/xray/ssl" docker-compose.yml; then
  echo ">>> 提示：证书映射路径已存在，跳过修改。"
else
  # 查找 .env 映射行，并在其后追加新的一行
  # 使用 | 作为 sed 分隔符以避免路径斜杠冲突
  sed -i "\|$TARGET_LINE|a \\$ADD_LINE" docker-compose.yml
  echo ">>> 已成功将 Nginx 证书目录映射添加到 docker-compose.yml (Remnawave 服务下)"
fi

#------------------------#
# 5. 自动配置 .env（生成密钥 & DB 密码）
#------------------------#
echo ">>> 自动生成 JWT / API / METRICS / WEBHOOK 等随机密钥..."

sed -i "s/^JWT_AUTH_SECRET=.*/JWT_AUTH_SECRET=$(openssl rand -hex 64)/" .env
sed -i "s/^JWT_API_TOKENS_SECRET=.*/JWT_API_TOKENS_SECRET=$(openssl rand -hex 64)/" .env
sed -i "s/^METRICS_PASS=.*/METRICS_PASS=$(openssl rand -hex 64)/" .env
sed -i "s/^WEBHOOK_SECRET_HEADER=.*/WEBHOOK_SECRET_HEADER=$(openssl rand -hex 64)/" .env

echo ">>> 生成 Postgres 密码并写入 .env ..."
pw=$(openssl rand -hex 24)
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$pw/" .env
# 更新 DATABASE_URL 中的密码 (使用 | 作为分隔符以避免冲突)
sed -i "s|^\(DATABASE_URL=\"postgresql://postgres:\)[^@]*\(@.*\)|\1$pw\2|" .env

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
docker compose up -d

echo ">>> Remnawave 后端容器已启动。"

#------------------------#
# 8. 创建 Docker 网络并连接
#------------------------#
echo ">>> 配置 Docker 网络..."
# 创建网络（如果不存在）
docker network create remnawave-network >/dev/null 2>&1 || true

# 将 Remnawave 容器加入到 remnawave-network，以便 Nginx 可以访问
echo ">>> 将后端容器连接至 remnawave-network..."
docker network connect remnawave-network remnawave >/dev/null 2>&1 || true

#------------------------#
# 9. 安装 acme.sh 并申请证书
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

echo ">>> 使用 acme.sh 申请证书（standalone 模式）..."
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
echo ">>> 生成 Nginx 配置文件 nginx.conf ..."

cat > "$NGINX_DIR/nginx.conf" <<EOF
upstream remnawave {
    server remnawave:3000;
}

# HTTP 跳转 HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $MAIN_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    server_name $MAIN_DOMAIN;

    listen 443 ssl reuseport;
    listen [::]:443 ssl reuseport;
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
    ssl_protocols          TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;

    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets    off;
    ssl_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/privkey.key";
    
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl
