#!/usr/bin/env bash
# Remnawave 一键安装脚本（最终稳定版）

set -e

INSTALL_DIR="/opt/remnawave"
NGINX_DIR="/opt/remnawave/nginx"

echo "==============================="
echo " Remnawave 一键安装脚本 (最终稳定版)"
echo "==============================="
echo
echo "本脚本将完成以下操作："
echo "1. 环境清理与重置"
echo "2. 生成正确的 docker-compose.yml (含 SSL 映射)"
echo "3. 自动配置 .env 密钥"
echo "4. 使用 Let's Encrypt 申请证书 (解决卡顿问题)"
echo "5. 启动 Nginx 反代"
echo

#------------------------#
# 0. 检查 root 权限
#------------------------#
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 运行本脚本"
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

#------------------------#
# 2. 安装 Docker & 依赖
#------------------------#
echo ">>> 安装基础依赖..."
apt-get update -y
apt-get install -y curl socat cron openssl lsof

if ! command -v docker >/dev/null 2>&1; then
  echo ">>> 安装 Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
fi

if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y docker-compose-plugin || echo "尝试安装插件..."
fi

#------------------------#
# 3. 重置项目目录与配置文件
#------------------------#
echo ">>> 正在重置配置文件..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# 删除旧配置防止冲突
rm -f docker-compose.yml

# 下载 .env 模板 (如果不存在)
if [ ! -f .env ]; then
  echo ">>> 下载 .env.sample..."
  curl -o .env https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample
fi

#------------------------#
# 4. 写入正确的 docker-compose.yml
#------------------------#
echo ">>> 生成预配置的 docker-compose.yml..."

cat > docker-compose.yml <<EOF
services:
  remnawave:
    image: ghcr.io/remnawave/backend:latest
    restart: always
    depends_on:
      - postgres
    ports:
      - "3000:3000"
    env_file:
      - .env
    volumes:
      - ./.env:/app/.env
      # 证书映射路径
      - /opt/remnawave/nginx:/var/lib/remnawave/configs/xray/ssl
    networks:
      - remnawave-network

  postgres:
    image: postgres:16-alpine
    restart: always
    volumes:
      - remnawave-db:/var/lib/postgresql/data
    env_file:
      - .env
    networks:
      - remnawave-network

volumes:
  remnawave-db:

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: false
EOF

#------------------------#
# 5. 自动配置 .env
#------------------------#
echo ">>> 配置 .env 密钥..."
# 仅当密钥未设置时才生成
if grep -q "JWT_AUTH_SECRET=change_me" .env; then
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

#------------------------#
# 6. 启动 Remnawave
#------------------------#
echo ">>> 启动 Remnawave 面板..."
docker compose up -d

#------------------------#
# 7. Nginx 与 证书 (核心修复部分)
#------------------------#
echo ">>> 准备申请证书..."
mkdir -p "$NGINX_DIR"

# 停止可能占用 80 端口的 Nginx 容器，防止 acme 失败
echo ">>> 暂时停止 Nginx 容器以释放 80 端口..."
docker stop remnawave-nginx >/dev/null 2>&1 || true

# 安装 acme.sh
if [ ! -d "$HOME/.acme.sh" ]; then
  curl https://get.acme.sh | sh -s email="$EMAIL"
fi
ACME_SH="$HOME/.acme.sh/acme.sh"

# 切换到 Let's Encrypt (比 ZeroSSL 更稳定)
echo ">>> 切换 CA 为 Let's Encrypt..."
$ACME_SH --set-default-ca --server letsencrypt

# 申请证书
echo ">>> 开始申请证书 (Standalone 模式)..."
$ACME_SH --issue --standalone -d "$MAIN_DOMAIN" \
  --key-file "$NGINX_DIR/privkey.key" \
  --fullchain-file "$NGINX_DIR/fullchain.pem" \
  --force

if [ ! -f "$NGINX_DIR/fullchain.pem" ]; then
    echo "错误：证书申请失败！请检查："
    echo "1. 您的域名 $MAIN_DOMAIN 是否已解析到本机 IP？"
    echo "2. 防火墙是否放行了 80 端口？"
    exit 1
fi

# 写入 Nginx 配置
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

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
    ssl_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/privkey.key";
    
    gzip on;
    gzip_proxied any;
    gzip_types text/plain text/css application/json application/javascript image/svg+xml;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/privkey.key";
    return 444;
}
EOF

# 写入 Nginx Compose
cat > "$NGINX_DIR/docker-compose.yml" <<'EOF'
services:
  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    restart: always
    ports:
      - '80:80'
      - '443:443'
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
      - ./privkey.key:/etc/nginx/ssl/privkey.key:ro
    networks:
      - remnawave-network

networks:
  remnawave-network:
    name: remnawave-network
    external: true
EOF

# 启动 Nginx
echo ">>> 启动 Nginx..."
cd "$NGINX_DIR"
docker compose up -d

echo
echo "=========================================="
echo " 部署完成！"
echo " 面板地址：https://$MAIN_DOMAIN"
echo "=========================================="
