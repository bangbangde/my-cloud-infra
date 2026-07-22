# 服务器运维

## 日常原则

- 生命周期变更优先使用 `bash scripts/ops.sh`。
- 原始 Compose 命令必须在目标栈目录执行。
- 共享基础设施只允许手动部署，并在变更持久化服务前创建可恢复备份。
- 应用部署必须指定明确镜像标签。
- `.env` 保存 Compose 插值和当前部署标签，`.env.runtime` 保存传入常驻容器的变量，`.env.migration` 保存只传入一次性迁移容器的变量。
- 不手动编辑 Git 跟踪文件来修复服务器运行状态。

## 环境文件命名升级

已有服务器拉取包含新命名的版本后、执行下一次 `ops.sh` 前，先在确认目标文件不存在的前提下完成以下改名；内容与权限保持不变：

| 旧文件 | 新文件 |
| --- | --- |
| `infrastructure/traefik/runtime.env` | `infrastructure/traefik/.env.runtime` |
| `infrastructure/postgres/runtime.env` | `infrastructure/postgres/.env.runtime` |
| `infrastructure/garage/runtime.env` | `infrastructure/garage/.env.runtime` |
| `apps/codebuff-next/runtime.env` | `apps/codebuff-next/.env.runtime` |
| `apps/codebuff-next/migration.runtime.env` | `apps/codebuff-next/.env.migration` |

尚未创建的应用文件不需要改名，直接从新的 `.example` 模板创建。改名不会修改容器或数据库内的配置；下一次部署时 Compose 才会从新路径读取同一组值。

## 手动 Compose 操作

Traefik：

```bash
cd ~/my-cloud-infra/infrastructure/traefik
docker compose config
docker compose ps
docker compose logs -f traefik
```

PostgreSQL：

```bash
cd ~/my-cloud-infra/infrastructure/postgres
docker compose config
docker compose ps
docker compose logs -f postgres
```

Garage：

```bash
cd ~/my-cloud-infra/infrastructure/garage
docker compose config
docker compose ps
docker compose logs -f garage
```

应用：

```bash
APP_ID=your-app-id
cd ~/my-cloud-infra/apps/"$APP_ID"
docker compose config
docker compose ps
docker compose logs -f "$APP_ID"
```

因为 Compose 文件与 `.env` 位于同一目录，这些命令不会读取其他栈的环境文件。自动化脚本仍会显式传入 `--project-directory` 和 `--env-file`。

## 从旧目录布局迁移

这次迁移会改变 Compose 项目名并移除 `container_name`。旧容器和旧 `traefik-net` 不能与新栈直接并存，首次切换需要短暂停机。

### 1. 盘点并记录旧资源

在操作前：

1. 暂停可能触发 `repository_dispatch` 的应用发布。
2. 确认可以通过云厂商控制台或现有 SSH 会话访问服务器。
3. 记录当前应用镜像标签、Compose 项目、容器、网络和数据卷。
4. 确认所有持久化数据已有可恢复的备份。
5. 检查旧 `dynamic/` 是否存在 `.gitkeep` 之外的文件；如果存在，先把有效配置迁入 `infrastructure/traefik/dynamic/` 并提交到仓库，再开始切换。

```bash
docker compose ls
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Labels}}'
docker network ls
docker volume ls
docker system df -v

# 把数组内容替换为实际的旧应用容器名
OLD_APP_CONTAINERS=(app-a app-b)
for container in "${OLD_APP_CONTAINERS[@]}"; do
  docker inspect "$container" --format '{{.Name}} {{.Config.Image}}'
done
docker inspect traefik --format '{{.Config.Image}}'
```

不要仅凭名称猜测资源归属。Compose 创建的容器、网络和数据卷通常带有 `com.docker.compose.project` 标签，可结合 `docker inspect <资源名>` 确认。

### 2. 拉取新布局并初始化环境文件

拉取新布局：

```bash
cd ~/my-cloud-infra
git pull --ff-only origin main
```

旧根目录 `.env` 是未跟踪文件，Git 不会删除它。复制引导配置，把旧值迁移到 JSON，并为 `apps/` 下每个实际目录增加目标文件映射：

```bash
cp config/env.example.json config/env.json
chmod 600 config/env.json
${EDITOR:-vi} config/env.json
bash scripts/ops.sh init-env config/env.json
```

把所有由腾讯云 DNS 托管、需要预申请根域和通配符证书的域名写入 `traefik.domains` 数组。`DOMAIN_NAME` 必须是数组中的一项；初始化脚本会把数组展开为 `infrastructure/traefik/.env.runtime` 中的 Traefik 索引环境变量，无需手工维护编号。

所有应用 `.env` 中的 `IMAGE_REPOSITORY`、`APP_DOMAIN` 和初始 `IMAGE_TAG` 都必须在恢复 `repository_dispatch` 自动部署前配置完成；`ops.sh` 不再从公开仓库推断这些值。已有目标环境文件会被初始化脚本跳过而不会覆盖。

如果需要部署共享 PostgreSQL，同时为 `infrastructure/postgres/.env` 和 `infrastructure/postgres/.env.runtime` 填写与模板一致的值。数据库密码只保存在受保护的引导配置和服务器运行时文件中；初始化完成后删除 `config/env.json`，或者把它作为密钥备份保护。

如果需要部署共享 Garage，同时填写 `infrastructure/garage/.env` 和 `infrastructure/garage/.env.runtime`。公开媒体域名必须解析到服务器；RPC 密钥和 S3 初始化凭据只保存在运行时文件和受保护的备份中。生成格式、单节点风险和首次验证步骤见 [Garage 对象存储运维](garage.md)。

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
| 需要预申请证书的根域名 | `config/env.json` 的 `traefik.domains` 数组；初始化后展开到 `infrastructure/traefik/.env.runtime` |
| `DOMAIN_NAME` | `infrastructure/traefik/.env` |
| `ACME_EMAIL` | `infrastructure/traefik/.env` |
| `DASHBOARD_USERS` | `infrastructure/traefik/.env` |
| `TENCENTCLOUD_SECRET_ID` | `infrastructure/traefik/.env.runtime` |
| `TENCENTCLOUD_SECRET_KEY` | `infrastructure/traefik/.env.runtime` |
| 应用镜像仓库 | 对应应用 `.env` 的 `IMAGE_REPOSITORY` |
| 应用访问域名 | 对应应用 `.env` 的 `APP_DOMAIN` |
| `<APP>_VERSION` | 对应应用 `.env` 的 `IMAGE_TAG`；后续由 `ops.sh deploy` 更新 |

旧文档可能把 `DASHBOARD_USERS` 中的 `$` 保存成 `$$`。新布局通过 `.env` 变量整体注入 Label，应重新执行 `htpasswd -nB admin`，在 `.env` 中用单引号包裹结果并保留原始单个 `$`。

### 3. 验证配置并清理旧 Docker 资源

先验证配置：

```bash
bash scripts/ops.sh validate
```

进入受控停机窗口后，优先使用旧 Compose 项目的原始 Compose 文件停止并删除它管理的容器和项目网络：

```bash
cd <旧 Compose 项目目录>
docker compose down --remove-orphans
```

这里不要加 `-v`。如果旧 Compose 文件已经不可用，则回到仓库目录，根据第 1 步确认的清单定向删除旧容器；数组中还应加入盘点到的其他旧项目容器：

```bash
cd ~/my-cloud-infra
OLD_APP_CONTAINERS=(app-a app-b)
docker rm -f "${OLD_APP_CONTAINERS[@]}" traefik

# 确认没有仍需保留的容器连接后，再删除旧 external 网络
docker network inspect traefik-net
docker network rm traefik-net
```

数据卷与持久化业务数据分开处理：

```bash
docker volume inspect <待确认的数据卷>

# 只有在确认备份可恢复且该卷确实废弃后，才按名字删除
docker volume rm <已确认废弃的数据卷>
```

迁移中不要运行 `docker volume prune` 或 `docker system prune -a --volumes`。这些命令作用于整台 Docker 主机，而不是当前仓库，可能删除其他项目暂时未挂载的数据。镜像清理也应放到新栈验证完成之后；`docker image prune` 默认只清理悬空镜像，执行前仍应阅读 Docker 给出的清单并确认。

### 4. 启动并验证新栈

然后按顺序启动新栈：

```bash
bash scripts/ops.sh deploy traefik
bash scripts/ops.sh deploy postgres
bash scripts/ops.sh deploy garage
bash scripts/ops.sh deploy <app-id> <已记录的标签>
# 对 apps/ 下的每个应用重复上一条命令
```

验证：

```bash
bash scripts/ops.sh status
bash scripts/ops.sh status postgres
bash scripts/ops.sh status garage
bash scripts/ops.sh check garage
curl -fsS https://traefik.<你的域名>/
curl -fsS https://<应用的 APP_DOMAIN>/
docker system df
```

全部正常后，可以删除旧的根 `.env`、`.rollback_digest_*` 和不再需要的 `config/env.json`。如果要保留引导 JSON，必须把它当作密钥文件存放在受保护的备份中，不能提交到 Git。

## 部署失败和旧版本重新部署

`ops.sh deploy` 要求应用 `.env` 已存在，并使用临时 `.env.next.*` 只替换其中的 `IMAGE_TAG`。拉取目标镜像后，脚本会检查启用 `migration` profile 时是否存在 `<app-id>-migrate` 服务；存在时先以目标镜像运行一次迁移，成功后才启动应用。没有声明迁移服务的应用保持原部署行为。

迁移失败发生在替换应用容器之前：脚本删除临时目标环境文件、保留当前运行版本和已记录的镜像标签，并以非零状态结束。迁移成功后才启动目标应用，全部成功后才替换当前 `.env`；应用启动失败时仍会尝试恢复旧标签。数据库迁移不会自动反向执行，因此旧版本应用必须能兼容已经成功提交的新结构。

共享基础设施使用仓库中固定的镜像版本，不接受运行时镜像标签。PostgreSQL 变更前必须先按照 [PostgreSQL 运维](postgres.md) 创建异机备份；Garage 变更前必须同时保护元数据卷和数据卷，详见 [Garage 对象存储运维](garage.md)。基础设施部署失败不会自动更换数据卷或执行降级。

自动部署会在 `git pull` 之前获取与 `ops.sh` 相同的 `.ops.lock`，避免 Action 更新仓库文件时服务器上正好存在手动部署或重启操作。

需要手动回退时，从应用构建记录、GHCR 或历史 Action 日志找到旧标签：

```bash
bash scripts/ops.sh deploy <app-id> sha-previous
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
docker network inspect postgres-net
docker network inspect garage-net

# Traefik 与 Socket Proxy 状态
cd ~/my-cloud-infra/infrastructure/traefik
docker compose ps
docker compose logs --tail 100 traefik socket-proxy

# PostgreSQL 状态与备份
cd ~/my-cloud-infra
bash scripts/ops.sh status postgres
bash scripts/ops.sh backup postgres ~/backups/postgres

# Garage 状态与容量边界
bash scripts/ops.sh status garage
bash scripts/ops.sh check garage

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
