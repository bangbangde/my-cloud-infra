# My Cloud Infrastructure

基于 Traefik 的云基础设施项目，提供自动 HTTPS、泛域名证书和简化的服务部署方案。

## ✨ 特性

- **自动 HTTPS** - 自动将 HTTP 流量重定向到 HTTPS
- **泛域名证书** - 使用 Let's Encrypt 自动申请和续期泛域名 SSL 证书
- **DNS 验证** - 支持腾讯云 DNS 验证，无需暴露 80 端口即可申请证书
- **服务发现** - 基于 Docker 的自动服务发现和路由配置
- **安全防护** - Dashboard 支持基础认证和访问频率限制
- **动态配置** - 支持动态配置文件，无需重启即可更新路由规则
- **CI/CD 集成** - GitHub Actions 自动化部署流程

## 📋 前置要求

- Docker Engine 20.10+
- Docker Compose v2+
- 域名（已解析到服务器 IP）
- 腾讯云账号（用于 DNS 验证）

## 🚀 快速开始

### 1. 克隆项目

```bash
git clone https://github.com/bangbangde/my-cloud-infra.git
cd my-cloud-infra
```

### 2. 配置环境变量

```bash
# 复制环境变量模板
cp .env.example .env

# 编辑环境变量
vim .env
```

需要配置以下变量：

| 变量名 | 说明 | 示例 |
|--------|------|------|
| `TENCENTCLOUD_SECRET_ID` | 腾讯云 API 密钥 ID | 从[腾讯云控制台](https://console.cloud.tencent.com/cam/capi)获取 |
| `TENCENTCLOUD_SECRET_KEY` | 腾讯云 API 密钥 | 从腾讯云控制台获取 |
| `DOMAIN_NAME` | 主域名 | `codebuff.tech` |
| `ACME_EMAIL` | 证书申请邮箱 | `your-email@example.com` |
| `DASHBOARD_USERS` | Dashboard 认证信息 | 使用 `htpasswd` 生成 |
| `MY_PAGES_VERSION` | 应用版本 | `latest` |
| `MY_PAGES_DOMAIN_NAME` | 应用域名 | `codebuff.tech` |

### 3. 生成 Dashboard 认证信息

```bash
# 使用 htpasswd 生成密码（需要安装 apache2-utils）
htpasswd -nB admin | sed 's/\$/\$\$/g'

# 或使用在线工具
# https://hostingcanada.org/htpasswd-generator/
```

将生成的结果填入 `.env` 文件的 `DASHBOARD_USERS` 变量。

### 4. 启动服务

```bash
# 启动 Traefik
docker compose up -d

# 启动应用（可选）
docker compose -f apps/my-pages.yml up -d
```

### 5. 验证部署

- **Dashboard**: 访问 `https://traefik.yourdomain.com`
- **应用**: 访问 `https://yourdomain.com`

## 📁 项目结构

```
my-cloud-infra/
├── .github/
│   └── workflows/
│       └── deploy.yml          # GitHub Actions 部署配置
├── acme/
│   └── .gitkeep                # ACME 证书存储目录
├── apps/
│   └── my-pages.yml            # 应用服务配置示例
├── dynamic/
│   └── .gitkeep                # 动态配置目录
├── .env.example                # 环境变量模板
├── .gitignore                  # Git 忽略文件
├── docker-compose.yml          # Traefik 服务配置
├── traefik.yml                 # Traefik 静态配置
└── README.md                   # 项目文档
```

## ⚙️ 配置说明

### Traefik 配置

主要配置文件 `traefik.yml` 包含：

- **API 配置**: 启用 Dashboard，禁用不安全模式
- **入口点配置**: 
  - `web` (80): 自动重定向到 HTTPS
  - `websecure` (443): HTTPS 入口，自动申请证书
- **服务发现**: Docker 和文件两种提供者
- **证书解析器**: Let's Encrypt + 腾讯云 DNS 验证

### 添加新服务

1. 在 `apps/` 目录创建新的 Compose 文件：

```yaml
services:
  my-service:
    image: your-image:tag
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.my-service.rule=Host(`service.yourdomain.com`)"
      - "traefik.http.routers.my-service.entrypoints=websecure"
      - "traefik.http.routers.my-service.tls.certresolver=letsencrypt"
    networks:
      - traefik-net

networks:
  traefik-net:
    external: true
```

2. 启动服务：

```bash
docker compose -f apps/my-service.yml up -d
```

### 动态配置

在 `dynamic/` 目录添加配置文件，支持：

- 中间件配置（认证、限流等）
- 路由规则
- 服务配置

示例 `dynamic/middleware.yml`：

```yaml
http:
  middlewares:
    redirect-www:
      redirectRegex:
        regex: "^https://www\\.(.+)"
        replacement: "https://${1}"
```

## 🚢 部署

### 手动部署

```bash
# 拉取最新代码
git pull origin main

# 重启服务
docker compose up -d

# 或重启特定服务
docker compose -f apps/my-pages.yml up -d
```

### GitHub Actions 自动部署

项目包含 GitHub Actions 工作流，支持手动触发部署：

1. 在 GitHub 仓库设置中配置 Secrets：
   - `SERVER_HOST`: 服务器地址
   - `SERVER_USER`: SSH 用户名
   - `SERVER_SSH_KEY`: SSH 私钥

2. 在 Actions 页面选择 "Manual Deploy" 工作流

3. 选择要部署的服务并输入 `YES` 确认


## 📚 相关资源

- [Traefik 官方文档](https://doc.traefik.io/traefik/)
- [Let's Encrypt 文档](https://letsencrypt.org/docs/)
- [腾讯云 DNS API 文档](https://cloud.tencent.com/document/api/1427/56153)
- [Docker Compose 文档](https://docs.docker.com/compose/)
