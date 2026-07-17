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
│   └── <app-id>/
│       ├── compose.yaml
│       └── .env.example
├── config/
│   └── env.example.json
├── scripts/
│   ├── init-env.sh
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

### 首次初始化

首次拉取仓库后，使用一份本机 JSON 同时生成基础设施和所有应用的环境文件：

```bash
cp config/env.example.json config/env.json
chmod 600 config/env.json
${EDITOR:-vi} config/env.json
bash scripts/ops.sh init-env config/env.json
```

`config/env.json` 已被 Git 忽略。把示例中的 `apps/<app-id>/.env` 替换或复制为 `apps/` 下的每个实际目录；如果某个栈还有 `runtime.env.example` 或 `<service>.runtime.env.example`，也要加入对应的目标文件。`files` 中的目标文件和变量名必须与仓库模板完全一致，环境变量值都必须是字符串。`traefik.domains` 是唯一的数组字段，填写所有需要自动申请根域和通配符证书的域名；`infrastructure/traefik/.env` 中的 `DOMAIN_NAME` 必须是该数组中的一项。JSON 不支持注释，实际说明保留在本节和示例文件旁的公开文档中，避免把说明文字与密钥混在同一份文件。

脚本会先校验整份 JSON，再以 `0600` 权限创建缺失文件。已有文件只会报告 `SKIP`，不会被覆盖，因此也可以在以后新增应用时再次运行。初始化完成后，`config/env.json` 只是敏感的引导输入；应删除它或存放在受保护的备份中，实际运维仍以各栈同目录的环境文件为准。

如果服务器曾创建旧的 `config/env.yml`，Git 不会迁移这个被忽略的本机文件。已经生成的各栈 `.env` 不受影响；只有再次初始化时才需要把真实值转入 `config/env.json`，确认后删除旧 YAML，避免留下两份密钥清单。

Traefik 的 `.env` 包含 Dashboard 所用根域名、ACME 邮箱和认证信息，`runtime.env` 包含腾讯云 DNS API 凭据，以及初始化脚本根据 `traefik.domains` 生成的 Traefik TLS 域名变量。Dashboard bcrypt 值使用 `htpasswd -nB admin` 生成；在 JSON 字符串中保留原始单个 `$`，不要执行旧版文档中的美元符号双写转换。

每个应用的 `.env` 至少包含 `IMAGE_REPOSITORY`、`APP_DOMAIN` 和 `IMAGE_TAG`。`scripts/ops.sh deploy` 只更新 `IMAGE_TAG`，不会覆盖其他环境级配置；实际域名和镜像命名空间不进入公开仓库。

## 前置要求

- Linux 服务器
- Docker Engine
- Docker Compose 2.24+
- Bash
- `flock`（通常由 `util-linux` 提供）
- `python3`（仅首次 JSON 初始化需要）
- 已解析到服务器的域名
- 腾讯云 DNS API 凭据

## 运维命令

```bash
# 验证全部配置
bash scripts/ops.sh validate

# 从受保护的 JSON 创建缺失环境文件
bash scripts/ops.sh init-env config/env.json

# 部署 Traefik
bash scripts/ops.sh deploy traefik

# 部署应用；建议使用不可变的 Git SHA 标签
bash scripts/ops.sh deploy <app-id> sha-abc123

# 查看状态
bash scripts/ops.sh status
bash scripts/ops.sh status <app-id>

# 查看日志或重启主服务
bash scripts/ops.sh logs <app-id>
bash scripts/ops.sh restart <app-id>
```

如需回退，使用同一个 Deploy 入口重新部署之前的不可变镜像标签，不再维护独立 Rollback 工作流。

## 多域名

在初始化 JSON 中使用数组声明由腾讯云 DNS 托管的根域名：

```json
"traefik": {
  "domains": [
    "example.com",
    "example.net"
  ]
}
```

初始化脚本会为每一项生成 Traefik 支持的索引环境变量，使证书解析器分别申请根域名和对应的通配符域名，例如 `example.com` 与 `*.example.com`。这些生成变量保存在忽略的 `infrastructure/traefik/runtime.env` 中，不需要手工展开数组。腾讯云凭据必须有权管理数组中每个域名所属的 DNS Zone。

`DOMAIN_NAME` 必须选择数组中的一个根域名，仅用于 Dashboard 的 `traefik.<DOMAIN_NAME>` 地址。每个应用目录仍拥有自己的 `APP_DOMAIN`；应用 Router 会从 `Host(...)` 规则提取具体域名，且可直接复用相应的通配符证书。

当前应用契约默认一应用一个 `APP_DOMAIN`。如果同一个应用需要多个入口域名，保留 `APP_DOMAIN` 作为主域名，在该应用的 `.env.example` 中增加 `APP_ALT_DOMAIN` 等明确变量，并把 Router 规则写成 ``Host(`${APP_DOMAIN}`) || Host(`${APP_ALT_DOMAIN}`)``；Traefik 会把多个 Host 合并到同一张证书的主域名和 SAN 中。不要把逗号分隔域名直接塞入 `APP_DOMAIN`，因为它不是 Traefik Router 规则。

需要对外访问的具体域名必须正确解析到当前服务器；`traefik.domains` 只声明预申请证书的根域名，不是路由白名单。

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
      {"service":"<app-id>","image_tag":"sha-${{ github.sha }}"}
```

`service` 必须对应 `apps/<service>/compose.yaml`，`image_tag` 必填。Traefik 只允许手动部署。

### Validate

Pull Request 和 main push 会验证：

- 所有 Compose 模型
- 应用目录、主 service 和必要部署变量
- 禁止 `container_name` 和应用宿主机端口
- 禁止提交实际环境文件
- Traefik 镜像固定和 Docker Socket 关键边界
- Gitleaks 扫描当前提交可达的完整 Git 历史
- ShellCheck
- actionlint

`scripts/validate.sh` 只强制执行会直接影响部署安全和可恢复性的核心规则；完整应用约定仍以 `docs/app-contract.md` 为准，并通过代码评审维护。

## 公开仓库安全边界

仓库只提交可公开的配置结构和示例值。以下内容必须保留在服务器、GitHub Secrets 或其他密钥管理系统中：

- 实际 `.env`、`runtime.env` 和 `*.runtime.env`
- `acme.json`、SSH 私钥、API Token、云厂商凭据和数据库密码
- 不希望公开的服务器地址、实际业务域名和私有镜像命名空间

提交前运行 `bash scripts/validate.sh`；CI 还会使用 Gitleaks 检查当前提交可达的完整历史。如果凭据曾经进入提交，删除当前文件并不等于完成处置：应先撤销或轮换凭据，再评估是否需要清理 Git 历史。

Git 提交的作者姓名和邮箱也是公开历史的一部分；不希望公开真实邮箱时，应在产生新提交前配置 GitHub 提供的 `noreply` 地址。

安全问题请按 [安全策略](SECURITY.md) 私下报告，不要在公开 Issue 中附带漏洞细节或凭据。

## 文档

- [应用 Compose 契约](docs/app-contract.md)
- [服务器运维与旧布局迁移](docs/operations.md)
