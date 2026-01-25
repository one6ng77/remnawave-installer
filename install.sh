#!/usr/bin/env bash
# Remnawave 一键安装脚本 (修复 YAML 格式错误版)
# 仅适用于 Debian / Ubuntu 系发行版

# 遇到错误立即退出
set -e

# --- 核心路径 ---
INSTALL_DIR="/opt/remnawave"
NGINX_DIR="/opt/remnawave/nginx"
NETWORK_NAME="remnawave-network"

echo "==============================="
echo " Remnawave 修复部署"
echo "==============================="

# 0. 检查 Root
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 运行本脚本"
  exit 1
fi

# 1. 采集信息
read -rp "请输入面板域名 (例如: panel.example.com): " MAIN_DOMAIN
[[ -z "$MAIN_DOMAIN" ]] && echo "域名不能为空" && exit 1

read -rp "请输入订阅域名 (留空同上): " SUB_DOMAIN
[[ -z "$SUB_DOMAIN" ]] && SUB_DOMAIN="$MAIN_DOMAIN"

read -rp "请输入 SSL 邮箱: " EMAIL
[[ -z "$EMAIL" ]] && echo "邮箱不能为空" && exit 1

SUB_URL="https://${SUB_DOMAIN}/api/sub"

# 2. 基础依赖与 Docker
echo ">>> 检查依赖..."
apt-get update -y >/dev/null 2>&1
apt-get install -y curl socat cron openssl lsof iptables ufw git >/dev/null 2>&1

if ! command -v docker >/dev/null 2>&1; then
  echo ">>> 安装 Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
fi

# 3. 重新生成配置文件 (修复缩进问题)
echo ">>> 重新生成 Remnawave 配置..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# 删除旧文件，防止干扰
rm -f docker-compose.yml

# 下载 .env 模板
if [ ! -f .env ]; then
  curl -o .env https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample >/dev/null 2>&1
fi

# ----------------------------------------------------------------------
# 重点修复：生成纯净的 docker-compose.yml，严禁在 YAML 中乱加注释
# ----------------------------------------------------------------------
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
# ----------------------------------------------------------------------

# 自动配置 .env
echo ">>> 配置密钥..."
if grep -q "JWT_AUTH_SECRET=change_me" .env; then
  sed -i "s/^JWT_AUTH_SECRET=.*/JWT_AUTH_SECRET=$(openssl rand -hex 64)/" .env
  sed -i "s/^JWT_API_TOKENS_SECRET=.*/JWT_API_TOKENS_SECRET=$(openssl rand -hex 64)/" .env
  sed -i "s/^METRICS_PASS=.*/METRICS_PASS=$(openssl rand -hex 64)/" .env
  sed -i "s/^WEBHOOK_SECRET_HEADER=.*/WEBHOOK_SECRET_HEADER=$(openssl rand -hex 64)/" .env
  
  pw=$(openssl rand -hex 24)
  sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$pw/" .env
  sed -i "s|^\(DATABASE_URL=\"postgresql://postgres:\)[^@]*\(@.*\)|\1$pw\2|" .env
fi

if grep -q "^SUB_PUBLIC_DOMAIN=" .env; then
  sed -i "s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=${SUB_URL}|" .env
else
  echo "SUB_PUBLIC_DOMAIN=${SUB_URL}" >> .env
fi

# 启动后端
echo ">>> 启动 Remnawave 后端..."
docker compose up -d

# 4. 申请证书
echo ">>> 准备申请证书..."
mkdir -p "$NGINX_DIR"

# 清理端口
docker stop remnawave-nginx >/dev/null 2>&1 || true
docker rm remnawave-nginx >/dev/null 2>&1 || true
systemctl stop nginx >/dev/null
