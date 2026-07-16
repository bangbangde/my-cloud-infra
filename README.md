# My Cloud Infrastructure

本仓库用于维护服务器上的 Traefik 与 Docker Compose 应用，并通过统一运维脚本和 GitHub Actions 提供自动部署、手动指定版本部署及旧版本重新部署能力。

服务器主机配置、密钥实际值、持久化业务数据和完整运行状态不由本仓库管理。

## 能力范围

- Traefik 反向代理、HTTPS 和 Docker 服务发现
- 受限 Docker Socket Proxy、容器健康检查和优雅停止
- 每个应用独立的 Compose 项目与环境文件
- 应用镜像构建完成后的自动部署
- 从 GitHub Actions 手动指定镜像标签部署
- 部署失败时尝试恢复服务器上记录的旧标签
- Compose、脚本和项目约定的持续验证

## 目录结构

```text
my-cloud-infra/
├── infrastructure/
│   └── traefik/
│       ├── compose.yaml
│       ├── static.yaml
│       ├── dynamic/
│       ├── state/acme/
│       ├── .env.example
│       └── runtime.env.example
├── apps/
│   ├── my-pages/
│   │   ├── compose.yaml
│   │   └── .env.example
│   └── codebuff-next/
│       ├── compose.yaml
│       └── .env.example
├── scripts/
│   ├── ops.sh
│   └── validate.sh
├── docs/
│   ├── app-contract.md
│   └── operations.md
└── .github/workflows/
    ├── deploy.yml
    └── validate.yml
```

仓库根目录不是 Compose 项目。所有 Compose 命令都应在具体栈目录执行，日常操作优先使用 `scripts/ops.sh`。

## 环境文件边界

每个 Compose 栈只读取同目录下自己的环境文件：

| 文件 | 用途 | Git |
| --- | --- | --- |
| `.env` | 当前环境的域名、镜像仓库等 Compose 插值，以及当前部署标签 | 忽略 |
| `.env.example` | `.env` 字段模板 | 跟踪 |
| `runtime.env` / `<service>.runtime.env` | 传入容器的运行时变量或密钥 | 忽略 |
| 对应的 `*.env.example` | 运行时变量字段模板 | 跟踪 |

`.env` 不会因为存在就自动传入容器。容器运行时变量必须通过 Compose 的 `env_file` 或 `environment` 显式声明。运行时文件在 Compose 中设置 `required: true`，缺失时手动操作也会立即失败。

### Traefik

```bash
cp infrastructure/traefik/.env.example infrastructure/traefik/.env
cp infrastructure/traefik/runtime.env.example infrastructure/traefik/runtime.env
```

编辑两个文件：

- `.env`：域名、ACME 邮箱和 Dashboard 认证信息
- `runtime.env`：腾讯云 DNS API 凭据

Dashboard bcrypt 值使用 `htpasswd -nB admin` 生成，在 `.env` 中用单引号包裹并保留原始单个 `$`。这里不要执行旧版文档中的美元符号双写转换。

### 应用

每个应用先从模板创建自己的 `.env`：

```bash
cp apps/my-pages/.env.example apps/my-pages/.env
```

首次部署前编辑其中的 `IMAGE_REPOSITORY` 和 `APP_DOMAIN`。`scripts/ops.sh deploy` 只更新 `IMAGE_TAG`，不会覆盖这些环境级配置。实际域名和镜像命名空间不进入公开仓库。

应用需要数据库连接等运行时变量时，另行创建 `runtime.env` 并在 Compose 中显式引用。

## 前置要求

- Linux 服务器
- Docker Engine
- Docker Compose 2.24+
- Bash
- `flock`（通常由 `util-linux` 提供）
- 已解析到服务器的域名
- 腾讯云 DNS API 凭据

## 运维命令

```bash
# 验证全部配置
bash scripts/ops.sh validate

# 部署 Traefik
bash scripts/ops.sh deploy traefik

# 部署应用；建议使用不可变的 Git SHA 标签
bash scripts/ops.sh deploy my-pages sha-abc123
bash scripts/ops.sh deploy codebuff-next sha-def456

# 查看状态
bash scripts/ops.sh status
bash scripts/ops.sh status my-pages

# 查看日志或重启主服务
bash scripts/ops.sh logs my-pages
bash scripts/ops.sh restart my-pages
```

如需回退，使用同一个 Deploy 入口重新部署之前的不可变镜像标签，不再维护独立 Rollback 工作流。

## 网络模型

Traefik 栈创建并拥有 `traefik-net`，应用将它作为 external network 使用。应用服务不发布宿主机端口，由 Traefik 负责对外路由。

Traefik 不直接挂载 Docker Socket。`socket-proxy` 是唯一挂载 Socket 的服务，并只在内部 `docker-api` 网络上开放 Traefik 服务发现需要的只读 API；该网络不发布宿主机端口。

私有数据库或缓存由应用 Compose 创建 `internal: true` 的内部网络。应用同时加入 `traefik-net` 和内部网络，数据库只加入内部网络。

共享 MySQL 等基础设施应放在 `infrastructure/<service>/`，并由该基础设施栈创建它提供给应用的网络；不维护独立的空网络 Compose 项目。

## 运行安全与资源边界

- Traefik 使用精确补丁版本；Socket Proxy 同时固定版本和镜像 digest。
- 所有现有服务启用 `no-new-privileges`。
- Docker `local` 日志驱动保留最多 3 个、每个约 10 MB 的日志文件，避免日志无限占用磁盘。
- Traefik 常规日志使用 `INFO`；临时排障才切换为 `DEBUG`，完成后应恢复。
- 默认 TLS 策略要求 TLS 1.2 或更高版本并启用严格 SNI；Dashboard 额外启用基础认证、限流和安全响应头。
- Traefik 与 Socket Proxy 都有健康检查，Traefik 更新时为活动请求保留优雅停止窗口。
- CPU 和内存限制应根据服务器上的 `docker stats` 观察结果设置，本仓库不使用未经测量的统一猜测值。

## GitHub Actions

### Deploy

支持：

- `workflow_dispatch` 手动部署 Traefik 或应用
- `repository_dispatch: app-update` 自动部署应用

基础设施仓库需要配置：

| Secret | 说明 |
| --- | --- |
| `SERVER_HOST` | 服务器地址 |
| `SERVER_USER` | SSH 用户 |
| `SERVER_SSH_KEY` | SSH 私钥 |
| `GHCR_TOKEN` | 拉取私有 GHCR 镜像的令牌 |
| `GHCR_USERNAME` | GHCR 令牌所属用户名；未设置时回退到触发者用户名 |

建议将这些 Secrets 配置在 `production` Environment。

应用仓库推送镜像后发送：

```yaml
- name: Trigger infrastructure deployment
  # v4.0.1
  uses: peter-evans/repository-dispatch@28959ce8df70de7be546dd1250a005dd32156697
  with:
    token: ${{ secrets.INFRA_REPO_TOKEN }}
    repository: your-github-user/my-cloud-infra
    event-type: app-update
    client-payload: >-
      {"service":"my-pages","image_tag":"sha-${{ github.sha }}"}
```

`service` 必须对应 `apps/<service>/compose.yaml`，`image_tag` 必填。Traefik 只允许手动部署。

### Validate

Pull Request 和 main push 会验证：

- 所有 Compose 模型
- 应用目录和主 service 命名契约
- 禁止 `container_name`
- 禁止旧的应用专属版本变量
- 禁止提交实际环境文件，以及在应用 Compose 中硬编码部署域名或镜像命名空间
- Gitleaks 扫描当前工作树和完整 Git 历史
- ShellCheck
- actionlint

## 公开仓库安全边界

仓库只提交可公开的配置结构和示例值。以下内容必须保留在服务器、GitHub Secrets 或其他密钥管理系统中：

- 实际 `.env`、`runtime.env` 和 `*.runtime.env`
- `acme.json`、SSH 私钥、API Token、云厂商凭据和数据库密码
- 不希望公开的服务器地址、实际业务域名和私有镜像命名空间

提交前运行 `bash scripts/validate.sh`；CI 还会使用 Gitleaks 检查工作树与完整提交历史。如果凭据曾经进入提交，删除当前文件并不等于完成处置：应先撤销或轮换凭据，再评估是否需要清理 Git 历史。

Git 提交的作者姓名和邮箱也是公开历史的一部分；不希望公开真实邮箱时，应在产生新提交前配置 GitHub 提供的 `noreply` 地址。

安全问题请按 [安全策略](SECURITY.md) 私下报告，不要在公开 Issue 中附带漏洞细节或凭据。

## 文档

- [应用 Compose 契约](docs/app-contract.md)
- [服务器运维与旧布局迁移](docs/operations.md)
