#!/bin/bash
# ==============================================================================
# Remnawave Deployment Script
# Optimized by vlongx (Final: Auto Firewall + Let's Encrypt + Proxy Fix)
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

# --- 5. 开放防火墙 ---
step_open_firewall() {
    log_info "正在尝试自动放行防火墙端口 (80/443)..."
    
    # 尝试 iptables
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || true
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1 || true
    fi

    # 尝试 ufw (Ubuntu常用)
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q "Status: active"; then
            ufw allow 80/tcp >/dev/null 2>&1 || true
            ufw allow 443/tcp >/dev/null 2>&1 || true
            log_success "已通过 UFW 放行端口"
        fi
    fi
}

# --- 6. 网关与 SSL ---
step_setup_gateway() {
    log_info "配置 Nginx 网关与 SSL..."
    mkdir -p "$NGINX_DIR"
    
    # 安装 acme.sh
    local acme_script="$HOME/.acme.sh/acme.sh"
    if [[ ! -f "$acme_script" ]]; then
        curl https://get.acme.sh | sh -s email="$SSL_EMAIL" >/dev/null
    fi

    # 临时停止可能的 80 端口占用
    systemctl stop nginx >/dev/null 2>&1 || true
    systemctl stop apache2 >/dev/null 2>&1 || true

    # 强制切换证书机构
    "$acme_script" --set-default-ca --server letsencrypt >/dev/null 2>&1
    "$acme_script" --register-account -m "$SSL_EMAIL" --server letsencrypt >/dev/null 2>&1 || true

    log_info "开始申请证书 (Let's Encrypt)..."
    
    # 申请证书
    if "$acme_script" --issue --server letsencrypt --standalone -d "$DOMAIN" \
        --key-file "$NGINX_DIR/privkey.key" \
        --fullchain-file "$NGINX_DIR/fullchain.pem" \
        --force; then
        
        log_success "SSL 证书申请成功！"
    else
        echo
        log_error "SSL 证书申请依然失败！\n\n[严重] 请务必检查您的【云服务器后台安全组】：\n确保 TCP 80 和 TCP 443 端口已对外开放！\n(脚本已尝试放行系统内部防火墙，但无法控制云厂商的安全组)"
    fi

    # 生成 Nginx 配置 (已修复 Proxy Headers)
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
        
        # 基础代理头
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        
        # 真实 IP 透传
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        
        # 关键修复：告诉后端这是 HTTPS 请求，防止 "Reverse proxy required" 报错
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
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
    step_open_firewall
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
