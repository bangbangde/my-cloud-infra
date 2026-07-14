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
- **自动更新** - 应用镜像更新时自动触发部署
- **健康检查** - 部署后自动验证服务健康状态
- **一键回滚** - 支持基于镜像 digest 的快速回滚

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

| 变量名                    | 说明               | 示例                                                             |
| ------------------------- | ------------------ | ---------------------------------------------------------------- |
| `TENCENTCLOUD_SECRET_ID`  | 腾讯云 API 密钥 ID | 从[腾讯云控制台](https://console.cloud.tencent.com/cam/capi)获取 |
| `TENCENTCLOUD_SECRET_KEY` | 腾讯云 API 密钥    | 从腾讯云控制台获取                                               |
| `DOMAIN_NAME`             | 主域名             | `codebuff.tech`                                                  |
| `ACME_EMAIL`              | 证书申请邮箱       | `your-email@example.com`                                         |
| `DASHBOARD_USERS`         | Dashboard 认证信息 | 使用 `htpasswd` 生成                                             |
| `MY_PAGES_VERSION`        | 应用版本           | `latest`                                                         |
| `MY_PAGES_DOMAIN_NAME`    | 应用域名           | `codebuff.tech`                                                  |

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
│       ├── deploy.yml          # GitHub Actions 部署配置（支持自动触发）
│       └── rollback.yml        # GitHub Actions 回滚配置
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

项目包含两个 GitHub Actions 工作流：

#### 部署工作流（Auto Deploy）

支持两种触发方式：

1. **手动触发**：在 Actions 页面选择 "Auto Deploy" 工作流，输入服务名（如 `my-pages`、`blog`、`api`）并输入 `YES` 确认

2. **自动触发**：当应用镜像更新时，源仓库通过 `repository_dispatch` 事件发送服务名，自动触发对应服务的部署

配置 Secrets：
| Secret | 说明 |
|--------|------|
| `SERVER_HOST` | 服务器地址 |
| `SERVER_USER` | SSH 用户名 |
| `SERVER_SSH_KEY` | SSH 私钥 |
| `GHCR_TOKEN` | GitHub Container Registry 访问令牌 |

部署流程：

```
代码拉取 → 记录当前镜像 digest（用于回滚）→ 拉取最新镜像 → 启动服务 → 健康检查 → 清理旧镜像
```

#### 回滚工作流（Rollback）

当部署失败时，可手动触发回滚：

1. 在 Actions 页面选择 "Rollback" 工作流
2. 选择要回滚的服务并输入 `YES` 确认
3. 系统自动使用上一次部署的镜像 digest 进行回滚

### 源应用仓库配置

在应用源仓库的 CI 配置中添加以下步骤，当镜像推送成功后自动触发部署：

```yaml
- name: Trigger infrastructure deployment
  uses: peter-evans/repository-dispatch@v3
  with:
    token: ${{ secrets.INFRA_REPO_TOKEN }}
    repository: bangbangde/my-cloud-infra
    event-type: app-update
    client-payload: '{"service": "my-pages"}'
```

需要在源仓库配置 Secret：

- `INFRA_REPO_TOKEN`: 具有 `repo` 权限的 GitHub Personal Access Token

**多应用支持**：当有多个应用服务时，只需在 `client-payload` 中指定对应的服务名即可。例如：

```yaml
# my-pages 应用
client-payload: '{"service": "my-pages"}'

# blog 应用
client-payload: '{"service": "blog"}'

# api 应用
client-payload: '{"service": "api"}'
```

## 📚 相关资源

- [Traefik 官方文档](https://doc.traefik.io/traefik/)
- [Let's Encrypt 文档](https://letsencrypt.org/docs/)
- [腾讯云 DNS API 文档](https://cloud.tencent.com/document/api/1427/56153)
- [Docker Compose 文档](https://docs.docker.com/compose/)
