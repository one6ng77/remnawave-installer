#!/bin/bash
# ==============================================================================
# VLONGX DEPLOYMENT SCRIPT - REMNAWAVE (STANDARD PATH EDITION)
# Codebase: Modular Bash
# Tag: vlongx-v2
# ==============================================================================

# 启用安全模式
set -o errexit
set -o pipefail
set -o nounset

# --- 核心路径定义 (保持原版结构) ---
VX_ROOT_PATH="/opt/remnawave"
VX_NGINX_PATH="/opt/remnawave/nginx"
VX_NET_ID="remnawave-network" # 保持原版网络名称以兼容默认配置

# --- UI 与日志函数 ---
C_RESET='\033[0m'
C_CYAN='\033[36m'
C_YELLOW='\033[33m'
C_RED='\033[31m'
C_GREEN='\033[32m'

vx_msg() { printf "${C_CYAN}[VLONGX] %s${C_RESET}\n" "$1"; }
vx_alert() { printf "${C_YELLOW}[VLONGX | ATTENTION] %s${C_RESET}\n" "$1"; }
vx_fail() { printf "${C_RED}[VLONGX | ERROR] %s${C_RESET}\n" "$1"; exit 1; }
vx_done() { printf "${C_GREEN}[VLONGX | SUCCESS] %s${C_RESET}\n" "$1"; }
vx_keygen() { openssl rand -hex "$1"; }

# 权限校验
if [[ $EUID -ne 0 ]]; then
    vx_fail "必须使用 ROOT 权限运行此脚本 (sudo bash install.sh)"
fi

# --- 1. 数据采集模块 ---
module_input() {
    echo ""
    echo "================================================="
    echo "   Remnawave Deployment (Vlongx Optimized)"
    echo "================================================="
    
    read -rp "请输入面板域名 (例如: panel.com): " VX_DOMAIN
    [[ -z "$VX_DOMAIN" ]] && vx_fail "域名不能为空"

    read -rp "请输入订阅域名 (留空则同上): " VX_SUB
    [[ -z "$VX_SUB" ]] && VX_SUB="$VX_DOMAIN"

    read -rp "请输入 SSL 证书邮箱: " VX_EMAIL
    [[ -z "$VX_EMAIL" ]] && vx_fail "邮箱不能为空"

    VX_SUB_URL="https://${VX_SUB}/api/sub"
    vx_msg "目标路径: ${VX_ROOT_PATH}"
}

# --- 2. 环境依赖模块 ---
module_dependencies() {
    vx_msg "初始化系统依赖..."
    apt-get update -qq >/dev/null
    for pkg in curl socat cron openssl git; do
        if ! command -v "$pkg" &> /dev/null; then
            apt-get install -y "$pkg" >/dev/null 2>&1
        fi
    done

    # Docker 检查
    if ! command -v docker &> /dev/null; then
        vx_msg "安装 Docker..."
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    fi

    if ! docker compose version &> /dev/null; then
        vx_fail "未检测到 Docker Compose 插件，请检查 Docker 版本。"
    fi
}

# --- 3. 核心应用部署模块 ---
module_core_install() {
    vx_msg "部署 Remnawave 核心..."
    mkdir -p "$VX_ROOT_PATH"
    cd "$VX_ROOT_PATH"

    local REMOTE_BASE="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main"

    # 配置文件下载与处理
    if [[ ! -f docker-compose.yml ]]; then
        curl -sL -o docker-compose.yml "${REMOTE_BASE}/docker-compose-prod.yml"
    fi

    if [[ ! -f .env ]]; then
        vx_msg "生成高强度安全密钥 (.env)..."
        curl -sL -o .env "${REMOTE_BASE}/.env.sample"

        local db_pwd=$(vx_keygen 24)
        
        # 使用 sed 批量替换，保持代码整洁
        sed -i \
            -e "s/^JWT_AUTH_SECRET=.*/JWT_AUTH_SECRET=$(vx_keygen 64)/" \
            -e "s/^JWT_API_TOKENS_SECRET=.*/JWT_API_TOKENS_SECRET=$(vx_keygen 64)/" \
            -e "s/^METRICS_PASS=.*/METRICS_PASS=$(vx_keygen 64)/" \
            -e "s/^WEBHOOK_SECRET_HEADER=.*/WEBHOOK_SECRET_HEADER=$(vx_keygen 64)/" \
            -e "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${db_pwd}/" \
            .env

        # 深度替换数据库连接串
        sed -i "s|^\(DATABASE_URL=\"postgresql://postgres:\)[^@]*\(@.*\)|\1${db_pwd}\2|" .env

        # 订阅域名注入
        if grep -q "^SUB_PUBLIC_DOMAIN=" .env; then
            sed -i "s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=${VX_SUB_URL}|" .env
        else
            echo "SUB_PUBLIC_DOMAIN=${VX_SUB_URL}" >> .env
        fi
    fi

    vx_msg "启动后端容器..."
    docker compose up -d --quiet-pull
}

# --- 4. 网络修复模块 ---
module_network_fix() {
    vx_msg "执行 Docker 网络桥接修复..."
    
    # 确保网络存在
    docker network inspect "$VX_NET_ID" >/dev/null 2>&1 || docker network create "$VX_NET_ID" >/dev/null

    # 智能搜寻容器 ID (兼容性写法)
    local target_cid=""
    # 尝试方法 A: 通过 Label
    target_cid=$(docker ps --filter "label=com.docker.compose.project=remnawave" -q | head -n 1)
    # 尝试方法 B: 通过 Image 名称关键字
    if [[ -z "$target_cid" ]]; then
        target_cid=$(docker ps | grep "remnawave" | awk '{print $1}' | head -n 1)
    fi

    if [[ -n "$target_cid" ]]; then
        # 忽略已连接的错误
        docker network connect "$VX_NET_ID" "$target_cid" >/dev/null 2>&1 || true
        vx_done "后端容器已桥接至 ${VX_NET_ID}"
    else
        vx_alert "自动桥接失败: 未找到后端容器，Nginx 可能无法连接。"
    fi
}

# --- 5. 证书与 Nginx 模块 ---
module_gateway_layer() {
    vx_msg "配置 Nginx 网关层..."
    mkdir -p "$VX_NGINX_PATH"
    
    # ACME 证书申请
    local acme_script="$HOME/.acme.sh/acme.sh"
    if [[ ! -f "$acme_script" ]]; then
        curl https://get.acme.sh | sh -s email="$VX_EMAIL" >/dev/null
    fi

    vx_msg "申请 SSL 证书 (Standalone Mode)..."
    # 使用 vlongx 命名前缀以示区别，但在 Nginx 配置中对应即可
    "$acme_script" --issue --standalone -d "$VX_DOMAIN" \
        --key-file "$VX_NGINX_PATH/vlongx.key" \
        --fullchain-file "$VX_NGINX_PATH/vlongx.pem" \
        --force >/dev/null 2>&1

    if [[ ! -f "$VX_NGINX_PATH/vlongx.pem" ]]; then
        vx_fail "SSL 证书申请失败，请检查 80 端口占用或域名解析。"
    fi

    # 生成 Nginx 配置
    cd "$VX_NGINX_PATH"
    
    cat > nginx.conf <<EOF
# VLONGX GENERATED CONFIG
upstream backend_pool {
    server remnawave:3000;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${VX_DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${VX_DOMAIN};

    ssl_certificate /etc/nginx/ssl/vlongx.pem;
    ssl_certificate_key /etc/nginx/ssl/vlongx.key;
    
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

    # 生成 Nginx Compose
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
      - ./vlongx.pem:/etc/nginx/ssl/vlongx.pem:ro
      - ./vlongx.key:/etc/nginx/ssl/vlongx.key:ro
    networks:
      - ${VX_NET_ID}

networks:
  ${VX_NET_ID}:
    external: true
EOF

    vx_msg "启动 Nginx 网关..."
    docker compose up -d
}

# --- 主执行流 ---
main() {
    clear
    module_input
    module_dependencies
    module_core_install
    module_network_fix
    module_gateway_layer
    
    echo ""
    echo "========================================================"
    vx_done "安装流程结束 [vlongx-edition]"
    echo "========================================================"
    echo " > 面板地址: https://${VX_DOMAIN}"
    echo " > 订阅 API: ${VX_SUB_URL}"
    echo " > 安装路径: ${VX_ROOT_PATH}"
    echo "========================================================"
}

main
