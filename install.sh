#!/bin/bash
# ==============================================================================
# Remnawave Deployment Script
# Optimized by vlongx (Modular Edition)
# ==============================================================================

# 启用严格模式
set -o errexit
set -o pipefail
set -o nounset

# --- 核心路径定义 ---
INSTALL_DIR="/opt/remnawave"
NGINX_DIR="/opt/remnawave/nginx"
NETWORK_NAME="remnawave-network"

# --- 日志函数 ---
C_RESET='\033[0m'
C_CYAN='\033[36m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'

log_info() { printf "${C_CYAN}[INFO] %s${C_RESET}\n" "$1"; }
log_warn() { printf "${C_YELLOW}[WARN] %s${C_RESET}\n" "$1"; }
log_error() { printf "${C_RED}[ERROR] %s${C_RESET}\n" "$1"; exit 1; }
log_success() { printf "${C_GREEN}[SUCCESS] %s${C_RESET}\n" "$1"; }
generate_key() { openssl rand -hex "$1"; }

# 权限校验
if [[ $EUID -ne 0 ]]; then
    log_error "必须使用 ROOT 权限运行此脚本 (sudo bash install.sh)"
fi

# --- 1. 信息采集 ---
step_collect_input() {
    echo ""
    echo "================================================="
    echo "   Remnawave One-Click Installer"
    echo "================================================="
    
    read -rp "请输入面板域名 (例如: panel.example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && log_error "域名不能为空"

    read -rp "请输入订阅域名 (留空则同上): " SUB_DOMAIN
    [[ -z "$SUB_DOMAIN" ]] && SUB_DOMAIN="$DOMAIN"

    read -rp "请输入 SSL 证书邮箱: " SSL_EMAIL
    [[ -z "$SSL_EMAIL" ]] && log_error "邮箱不能为空"

    SUB_URL="https://${SUB_DOMAIN}/api/sub"
    log_info "安装目录: ${INSTALL_DIR}"
}

# --- 2. 环境依赖 ---
step_check_dependencies() {
    log_info "检查系统依赖..."
    apt-get update -qq >/dev/null
    for pkg in curl socat cron openssl git; do
        if ! command -v "$pkg" &> /dev/null; then
            apt-get install -y "$pkg" >/dev/null 2>&1
        fi
    done

    # Docker 检查
    if ! command -v docker &> /dev/null; then
        log_info "安装 Docker..."
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    fi

    if ! docker compose version &> /dev/null; then
        log_error "未检测到 Docker Compose 插件，请检查 Docker 版本。"
    fi
}

# --- 3. 核心部署 ---
step_install_core() {
    log_info "部署 Remnawave 核心..."
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    local REMOTE_BASE="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main"

    # 下载配置文件
    if [[ ! -f docker-compose.yml ]]; then
        curl -sL -o docker-compose.yml "${REMOTE_BASE}/docker-compose-prod.yml"
    fi

    if [[ ! -f .env ]]; then
        log_info "生成安全配置文件 (.env)..."
        curl -sL -o .env "${REMOTE_BASE}/.env.sample"

        local db_pwd=$(generate_key 24)
        
        # 生成随机密钥
        sed -i \
            -e "s/^JWT_AUTH_SECRET=.*/JWT_AUTH_SECRET=$(generate_key 64)/" \
            -e "s/^JWT_API_TOKENS_SECRET=.*/JWT_API_TOKENS_SECRET=$(generate_key 64)/" \
            -e "s/^METRICS_PASS=.*/METRICS_PASS=$(generate_key 64)/" \
            -e "s/^WEBHOOK_SECRET_HEADER=.*/WEBHOOK_SECRET_HEADER=$(generate_key 64)/" \
            -e "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${db_pwd}/" \
            .env

        # 更新数据库连接串
        sed -i "s|^\(DATABASE_URL=\"postgresql://postgres:\)[^@]*\(@.*\)|\1${db_pwd}\2|" .env

        # 设置订阅域名
        if grep -q "^SUB_PUBLIC_DOMAIN=" .env; then
            sed -i "s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=${SUB_URL}|" .env
        else
            echo "SUB_PUBLIC_DOMAIN=${SUB_URL}" >> .env
        fi
    fi

    log_info "启动后端容器..."
    docker compose up -d --quiet-pull
}

# --- 4. 网络配置 ---
step_configure_network() {
    log_info "配置 Docker 网络桥接..."
    
    # 创建网络
    docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || docker network create "$NETWORK_NAME" >/dev/null

    # 查找容器 ID
    local target_cid=""
    # 尝试通过标签查找
    target_cid=$(docker ps --filter "label=com.docker.compose.project=remnawave" -q | head -n 1)
    # 如果失败，尝试通过名称关键字查找
    if [[ -z "$target_cid" ]]; then
        target_cid=$(docker ps | grep "remnawave" | awk '{print $1}' | head -n 1)
    fi

    if [[ -n "$target_cid" ]]; then
        # 连接网络 (忽略已存在错误)
        docker network connect "$NETWORK_NAME" "$target_cid" >/dev/null 2>&1 || true
        log_success "后端容器已加入网络: ${NETWORK_NAME}"
    else
        log_warn "自动桥接失败: 未找到后端容器，Nginx 可能无法连接，请手动检查。"
    fi
}

# --- 5. 网关与 SSL ---
step_setup_gateway() {
    log_info "配置 Nginx 网关与 SSL..."
    mkdir -p "$NGINX_DIR"
    
    # 安装 acme.sh
    local acme_script="$HOME/.acme.sh/acme.sh"
    if [[ ! -f "$acme_script" ]]; then
        curl https://get.acme.sh | sh -s email="$SSL_EMAIL" >/dev/null
    fi

    log_info "申请 SSL 证书 (Standalone 模式)..."
    
    # 使用标准 fullchain.pem 和 privkey.key 命名
    "$acme_script" --issue --standalone -d "$DOMAIN" \
        --key-file "$NGINX_DIR/privkey.key" \
        --fullchain-file "$NGINX_DIR/fullchain.pem" \
        --force >/dev/null 2>&1

    if [[ ! -f "$NGINX_DIR/fullchain.pem" ]]; then
        log_error "SSL 证书申请失败，请检查 80 端口占用或域名解析。"
    fi

    # 生成 Nginx 配置
    cd "$NGINX_DIR"
    
    cat > nginx.conf <<EOF
upstream backend_pool {
    server remnawave:3000;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.key;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    client_max_body_size 50M;

    location / {
        proxy_pass http://backend_pool;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

    # 生成 Docker Compose (Nginx)
    cat > docker-compose.yml <<EOF
services:
  nginx-gateway:
    image: nginx:alpine
    container_name: remnawave-nginx
    restart: always
    ports:
      - "80:80"
      - "443:443"
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

    log_info "启动 Nginx 网关..."
    docker compose up -d
}

# --- 主程序 ---
main() {
    clear
    step_collect_input
    step_check_dependencies
    step_install_core
    step_configure_network
    step_setup_gateway
    
    echo
    echo "=========================================="
    echo " Remnawave + Nginx 部署完成！"
    echo "------------------------------------------"
    echo "面板访问地址：https://${DOMAIN}"
    echo "订阅域名（SUB_PUBLIC_DOMAIN）：${SUB_DOMAIN}"
    echo
    echo "常用命令："
    echo "  进入 Remnawave 目录：cd ${INSTALL_DIR}"
    echo "  启动/停止面板：docker compose up -d / docker compose down"
    echo "  进入 Nginx 目录：cd ${NGINX_DIR}"
    echo "  启动/停止 Nginx：docker compose up -d / docker compose down"
    echo "=========================================="
}

main
