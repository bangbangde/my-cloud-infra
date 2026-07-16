# 服务器运维

## 日常原则

- 生命周期变更优先使用 `bash scripts/ops.sh`。
- 原始 Compose 命令必须在目标栈目录执行。
- 应用部署必须指定明确镜像标签。
- `.env` 保存 Compose 插值和当前部署标签，`runtime.env` 保存传入容器的变量。
- 不手动编辑 Git 跟踪文件来修复服务器运行状态。

## 手动 Compose 操作

Traefik：

```bash
cd ~/my-cloud-infra/infrastructure/traefik
docker compose config
docker compose ps
docker compose logs -f traefik
```

应用：

```bash
cd ~/my-cloud-infra/apps/my-pages
docker compose config
docker compose ps
docker compose logs -f my-pages
```

因为 Compose 文件与 `.env` 位于同一目录，这些命令不会读取其他栈的环境文件。自动化脚本仍会显式传入 `--project-directory` 和 `--env-file`。

## 从旧目录布局迁移

这次迁移会改变 Compose 项目名并移除 `container_name`。旧容器和旧 `traefik-net` 不能与新栈直接并存，首次切换需要短暂停机。

在操作前：

1. 暂停可能触发 `repository_dispatch` 的应用发布。
2. 确认可以通过云厂商控制台或现有 SSH 会话访问服务器。
3. 记录当前应用镜像标签。
4. 检查旧 `dynamic/` 是否存在 `.gitkeep` 之外的文件；如果存在，先把有效配置迁入 `infrastructure/traefik/dynamic/` 并提交到仓库，再开始切换。

```bash
docker inspect my-pages --format '{{.Config.Image}}'
docker inspect codebuff-next --format '{{.Config.Image}}'
docker inspect traefik --format '{{.Config.Image}}'
```

拉取新布局：

```bash
cd ~/my-cloud-infra
git pull --ff-only origin main
```

旧根目录 `.env` 是未跟踪文件，Git 不会删除它。根据旧 `.env` 手动创建新文件：

```bash
cp infrastructure/traefik/.env.example infrastructure/traefik/.env
cp infrastructure/traefik/runtime.env.example infrastructure/traefik/runtime.env
cp apps/my-pages/.env.example apps/my-pages/.env
cp apps/codebuff-next/.env.example apps/codebuff-next/.env

vim infrastructure/traefik/.env
vim infrastructure/traefik/runtime.env
vim apps/my-pages/.env
vim apps/codebuff-next/.env
```

两个应用 `.env` 中的 `IMAGE_REPOSITORY` 和 `APP_DOMAIN` 必须在恢复 `repository_dispatch` 自动部署前配置完成；`ops.sh` 不再从公开仓库推断这些值。

保留现有 ACME 账户和证书状态，避免切换时重新申请证书：

```bash
if [[ -f acme/acme.json ]]; then
  install -m 600 acme/acme.json infrastructure/traefik/state/acme/acme.json
fi
```

`infrastructure/traefik/state/acme/acme.json` 已被 Git 忽略，不能提交到仓库。

字段迁移关系：

| 旧变量 | 新位置 |
| --- | --- |
| `DOMAIN_NAME` | `infrastructure/traefik/.env` |
| `ACME_EMAIL` | `infrastructure/traefik/.env` |
| `DASHBOARD_USERS` | `infrastructure/traefik/.env` |
| `TENCENTCLOUD_SECRET_ID` | `infrastructure/traefik/runtime.env` |
| `TENCENTCLOUD_SECRET_KEY` | `infrastructure/traefik/runtime.env` |
| 应用镜像仓库 | 对应应用 `.env` 的 `IMAGE_REPOSITORY` |
| 应用访问域名 | 对应应用 `.env` 的 `APP_DOMAIN` |
| `<APP>_VERSION` | 对应应用 `.env` 的 `IMAGE_TAG`；后续由 `ops.sh deploy` 更新 |

旧文档可能把 `DASHBOARD_USERS` 中的 `$` 保存成 `$$`。新布局通过 `.env` 变量整体注入 Label，应重新执行 `htpasswd -nB admin`，在 `.env` 中用单引号包裹结果并保留原始单个 `$`。

先验证配置：

```bash
bash scripts/ops.sh validate
```

进入受控停机窗口后，清理旧容器和旧项目网络：

```bash
docker rm -f my-pages codebuff-next traefik
docker network rm traefik-net
```

然后按顺序启动新栈：

```bash
bash scripts/ops.sh deploy traefik
bash scripts/ops.sh deploy my-pages <已记录的标签>
bash scripts/ops.sh deploy codebuff-next <已记录的标签>
```

验证：

```bash
bash scripts/ops.sh status
curl -fsS https://traefik.<你的域名>/
curl -fsS https://<my-pages 的 APP_DOMAIN>/
curl -fsS https://<codebuff-next 的 APP_DOMAIN>/
```

全部正常后可以删除旧的根 `.env` 和 `.rollback_digest_*` 文件。

## 部署失败和旧版本重新部署

`ops.sh deploy` 要求应用 `.env` 已存在，并使用临时 `.env.next.*` 只替换其中的 `IMAGE_TAG` 后启动目标镜像。成功后才替换当前 `.env`；失败时保留旧 `.env`、域名和镜像仓库配置，并尝试恢复旧标签。

自动部署会在 `git pull` 之前获取与 `ops.sh` 相同的 `.ops.lock`，避免 Action 更新仓库文件时服务器上正好存在手动部署或重启操作。

需要手动回退时，从应用构建记录、GHCR 或历史 Action 日志找到旧标签：

```bash
bash scripts/ops.sh deploy my-pages sha-previous
```

不再使用独立 Rollback Action 或 `.rollback_digest_*` 文件。

## 常见检查

```bash
# Compose 项目
docker compose ls

# 容器与镜像
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

# 网络成员
docker network inspect traefik-net

# Traefik 与 Socket Proxy 状态
cd ~/my-cloud-infra/infrastructure/traefik
docker compose ps
docker compose logs --tail 100 traefik socket-proxy

# 配置验证
cd ~/my-cloud-infra
bash scripts/validate.sh
```

Traefik 版本升级必须把 `compose.yaml` 中的补丁版本改为明确值，经 Validate 工作流通过后再部署。不要恢复为 `traefik:v3` 浮动标签。

排查资源问题时先运行：

```bash
docker stats --no-stream
docker system df
```

先观察实际峰值，再决定单个服务的 CPU、内存或磁盘约束；不要直接复制与服务器规格无关的限制值。
