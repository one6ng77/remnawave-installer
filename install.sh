#!/bin/bash
# ==============================================================================
# Remnawave 终极整合版 V3 (含 SSL 映射 + 防火墙修复)
# ==============================================================================

# 设置 Shell 选项
set -o pipefail
set -o nounset

# --- 核心路径定义 ---
INSTALL_DIR="/opt/remnawave"
NGINX_DIR="/opt/remnawave/nginx"
NETWORK_NAME="remnawave-network"

# --- 日志颜色 ---
C_RESET='\033[0m'
C_RED='\033[31m'
C_CYAN='\033[36m'
C_GREEN='\033[32m'

log_info() { printf "${C_CYAN}[INFO] %s${C_RESET}\n" "$1"; }
log_error() { printf "${C_RED}[ERROR] %s${C_RESET}\n" "$1"; exit 1; }
log_success() { printf "${C_GREEN}[SUCCESS] %s${C_RESET}\n" "$1"; }

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
    log_error "必须使用 ROOT 权限运行此脚本"
fi

# ==============================================================================
# 1. 信息采集
# ==============================================================================
echo ""
echo "================================================="
echo "   Remnawave 一键部署 (SSL 路径整合版)"
echo "================================================="

read -rp "请输入面板域名 (例如: panel.example.com): " MAIN_DOMAIN
[[ -z "$MAIN_DOMAIN" ]] && log_error "域名不能为空"

read -rp "请输入订阅域名 (留空则同上): " SUB_DOMAIN
[[ -z "$SUB_DOMAIN" ]] && SUB_DOMAIN="$MAIN_DOMAIN"

read -rp "请输入 SSL 证书邮箱: " EMAIL
[[ -z "$EMAIL" ]] && log_error "邮箱不能为空"

SUB_URL="https://${SUB_DOMAIN}/api/sub"

# ==============================================================================
# 2. 环境准备
# ==============================================================================
log_info "安装依赖..."
apt-get update -y >/dev/null 2>&1
apt-get install -y curl socat cron openssl lsof iptables ufw git >/dev/null 2>&1

if ! command -v docker >/dev/null 2>&1; then
    log_info "安装 Docker..."
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    systemctl enable docker
    systemctl start docker
fi

# ==============================================================================
# 3. 核心修复：防火墙强制放行
# ==============================================================================
log_info "配置系统防火墙..."
iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || true
iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1 || true

if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
        ufw allow 80/tcp >/dev/null 2>&1 || true
        ufw allow 443/tcp >/dev/null 2>&1 || true
    fi
fi

# ==============================================================================
# 4. 部署 Remnawave (写入整合后的配置)
# ==============================================================================
log_info "生成 Remnawave 配置文件..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# 下载 .env 模板
if [ ! -f .env ]; then
  curl -o .env https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample >/dev/null 2>&1
fi

# -----------------------------------------------------------
# [关键步骤] 直接写入 docker-compose.yml，包含 SSL 映射
# -----------------------------------------------------------
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
      # ↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓
      # 这里就是你要求的 SSL 路径映射，直接整合进去了
      - /opt/remnawave/nginx:/var/lib/remnawave/configs/xray/ssl
      # ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑
    networks:
      - ${NETWORK_NAME}

  postgres:
    image: postgres:16-alpine
    restart: always
    volumes:
      - remnawave-db:/var/lib/postgresql/data
    env_file:
      - .env
    networks:
      - ${NETWORK_NAME}

volumes:
  remnawave-db:

networks:
  ${NETWORK_NAME}:
    name: ${NETWORK_NAME}
    driver: bridge
    external: false
EOF
# -----------------------------------------------------------

# 自动生成密钥
if grep -q "JWT_AUTH_SECRET=change_me" .env; then
    log_info "生成随机密钥..."
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
  sed -i "s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=${SUB_URL}|" .env
else
  echo "SUB_PUBLIC_DOMAIN=${SUB_URL}" >> .env
fi

log_info "启动 Remnawave 后端..."
docker compose up -d

# ==============================================================================
# 5. 申请 SSL 证书
# ==============================================================================
log_info "准备申请证书..."
mkdir -p "$NGINX_DIR"

# 暴力清理端口
log_info "清理端口占用..."
docker stop remnawave-nginx >/dev/null 2>&1 || true
docker rm remnawave-nginx >/dev/null 2>&1 || true
systemctl stop nginx >/dev/null 2>&1 || true
if command -v fuser >/dev/null 2>&1; then
    fuser -k 80/tcp >/dev/null 2>&1 || true
fi

# 安装 acme.sh
if [ ! -d "$HOME/.acme.sh" ]; then
  curl https://get.acme.sh | sh -s email="$EMAIL" >/dev/null 2>&1
fi
ACME_SH="$HOME/.acme.sh/acme.sh"

"$ACME_SH" --set-default-ca --server letsencrypt >/dev/null 2>&1

log_info "开始申请证书..."
if "$ACME_SH" --issue --standalone -d "$MAIN_DOMAIN" \
  --key-file "$NGINX_DIR/privkey.key" \
  --fullchain-file "$NGINX_DIR/fullchain.pem" \
  --force; then
    log_success "证书申请成功！"
else
    echo
    log_error "证书申请失败。请检查：\n1. 域名解析是否正确\n2. Vultr/阿里云安全组是否放行了 80 端口 (Important!)"
fi

# ==============================================================================
# 6. 启动 Nginx
# ==============================================================================
log_info "配置 Nginx..."
cd "$NGINX_DIR"

# Nginx 配置
cat > nginx.conf <<EOF
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

    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://remnawave;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

# Nginx Docker Compose
cat > docker-compose.yml <<EOF
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
      - ${NETWORK_NAME}

networks:
  ${NETWORK_NAME}:
    external: true
EOF

log_info "启动 Nginx..."
docker compose up -d

echo
echo "=========================================="
echo " 部署完成！"
echo " 面板: https://$MAIN_DOMAIN"
echo "=========================================="
