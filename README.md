🔗 官方资源
- GitHub 仓库: https://github.com/remnawave/panel
- 官方文档: https://docs.rw/

🌟 功能特性
- 🐳 **全自动 Docker 部署**: 自动检测环境并安装 Docker 和 Docker Compose。
- 🔒 **自动 HTTPS**: 集成 acme.sh，自动申请 Let's Encrypt 证书 (Standalone 模式)。
- ⚙️ **Nginx 反代**: 自动生成 Nginx 配置文件，预置 WebSocket 支持与安全标头。
- 🔑 **安全配置**: 自动生成高强度随机密钥 (JWT, Postgres, Webhook 等)。
- 🌐 **网络自动修复**: 自动创建 Docker 网络并修复后端与 Nginx 之间的通信连接。
- 📂 **标准路径**: 严格遵循标准目录结构，方便后续维护。

💻 系统要求
- OS: Debian 10+, Ubuntu 20.04+
- 架构: amd64 / arm64
- 权限: 必须使用 Root 用户运行
- 端口: 80, 443 (安装过程中需未被占用)

📂 目录结构说明
脚本将文件安装在以下标准路径，方便查阅：
| 内容 | 路径 | 说明 |
|------|---------|------|
| 项目根目录| /opt/remnawave | 包含 docker-compose.yml 和 .env 配置文件 |
| Nginx 网关 | /opt/remnawave/nginx | 包含 nginx.conf 及 SSL 证书文件 |
| SSL 证书 | /opt/remnawave/nginx/vlongx.pem | 公钥证书 (自动生成) |
| SSL 密钥 | /opt/remnawave/nginx/vlongx.key | 私钥文件 (自动生成) |



## 🚀 一键安装
请在服务器终端执行以下命令：
```bash
curl -sSL [https://raw.githubusercontent.com/vlongx/remnawave-installer/main/install.sh](https://raw.githubusercontent.com/vlongx/remnawave-installer/main/install.sh) | sudo bash
```
🛠️ 常用维护命令
管理面板后端：
```bash
cd /opt/remnawave
docker compose up -d   # 启动
docker compose down    # 停止
docker compose logs -f # 查看日志
```
管理 Nginx 网关：
```bash
cd /opt/remnawave/nginx
docker compose up -d   # 启动/重启网关
docker compose down    # 停止网关
```
