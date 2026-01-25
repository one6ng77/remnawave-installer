#!/bin/bash
# ==============================================================================
# Remnawave Deployment Script
# Optimized by vlongx (Final: Auto Firewall + Let's Encrypt + Proxy Fix + SSL Mount)
# ==============================================================================

# 启用严格模式 (为防止 pipefail 导致某些 grep 退出，这里仅保留 errexit 和 nounset，或根据需要调整)
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

# --- 3. 核心部署 (已修改：包含 Volume 映射) ---
step_install_core() {
    log_info "部署 Remnawave 核心..."
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    local REMOTE_BASE="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main"

    # [关键修改] 直接生成 docker-compose.yml 以包含自定义 Volume 映射
    # 不再下载官方文件，防止修改困难
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
      # ↓↓↓ 这里是你要求的 SSL 证书目录映射 ↓↓↓
      - '/opt/remnawave/nginx:/var/lib/remnawave/configs/xray/ssl'
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
    # 设置为 false 让 compose 自动创建网络，避免手动创建的麻烦
    external: false
EOF

    # 生成 .env 文件
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
    log_info "验证 Docker 网络配置..."
    # 由于我们在 docker-compose.yml 中定义了网络，这里只需确保网络正常
    # 并且不需要再手动 join，因为 docker-compose up 已经处理了
    if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        log_success "网络 ${NETWORK_NAME} 准备就绪"
    else
        log_warn "网络可能未正确创建，尝试手动创建..."
        docker network create "$NETWORK_NAME" >/dev/null 2>&1
    fi
}

# --- 5. 开放防火墙 ---
step_open_firewall() {
    log_info "正在尝试自动放行防火墙端口 (80/443)..."
    
    # 尝试 iptables
    if command -v iptables >/dev/null 2>&1; then
        # -I 插入到最前面确保生效
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
    if command -v fuser >/dev/null 2>&1; then
        fuser -k 80/tcp >/dev/null 2>&1 || true
    fi

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
        log_error "SSL 证书申请依然失败！\n请检查域名解析是否正确，以及云服务商后台安全组是否放行了 80 端口。"
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
        
        # 关键修复：告诉后端这是 HTTPS 请求
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
    echo "订阅域名：${SUB_DOMAIN}"
    echo "SSL 证书目录映射：/opt/remnawave/nginx -> /var/lib/remnawave/configs/xray/ssl"
    echo "=========================================="
}

main
