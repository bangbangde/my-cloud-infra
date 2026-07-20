# PostgreSQL 运维

## 定位与恢复目标

`infrastructure/postgres/` 提供当前服务器上由多个应用共享的 PostgreSQL 实例。它面向个人服务的低连接数负载，恢复目标为：

- RPO：24 小时，通过每日逻辑备份满足。
- RTO：不限定，采用人工恢复，不维护热备或自动故障切换。
- PostgreSQL 不加入 `traefik-net`；同机应用通过内部 `postgres-net` 连接，宿主机 `5432` 仅绑定回环地址，供 SSH 隧道运维使用。

每个应用应拥有独立数据库和登录角色。共享实例不等于共享数据库、Schema 或超级用户。

## 首次初始化

在服务器受保护的 `config/env.json` 中填写：

- `infrastructure/postgres/.env`
- `infrastructure/postgres/runtime.env`

使用足够长的随机密码，例如：

```bash
openssl rand -base64 32
```

然后从仓库根目录执行：

```bash
bash scripts/ops.sh init-env config/env.json
bash scripts/ops.sh validate
bash scripts/ops.sh deploy postgres
bash scripts/ops.sh status postgres
```

首次部署后确认资源归属：

```bash
docker network inspect postgres-net
docker volume inspect postgres-data
```

PostgreSQL 官方镜像只在空数据目录的首次初始化中读取 `POSTGRES_USER`、`POSTGRES_PASSWORD`、`POSTGRES_DB` 和 `POSTGRES_INITDB_ARGS`。初始化后仅修改 `runtime.env` 不会修改数据库内的角色或密码；密码轮换必须在 PostgreSQL 中执行，再同步更新受保护的环境配置。

不要删除或重新创建 `postgres-data` 来应用环境变量。禁止把 `docker compose down -v` 当作常规操作。

## 为应用创建数据库

进入 PostgreSQL：

```bash
cd ~/my-cloud-infra/infrastructure/postgres
docker compose exec postgres psql --username postgres --dbname postgres
```

以下示例为 `my-blog` 创建独立角色和数据库；密码通过 `psql` 交互输入，不进入 Shell 历史：

```sql
CREATE ROLE my_blog LOGIN;
\password my_blog
CREATE DATABASE my_blog OWNER my_blog;
REVOKE ALL ON DATABASE my_blog FROM PUBLIC;
GRANT CONNECT ON DATABASE my_blog TO my_blog;
```

应用服务同时加入 `traefik-net` 和 `postgres-net`：

```yaml
services:
  my-blog:
    networks:
      - traefik-net
      - postgres-net

networks:
  traefik-net:
    external: true
    name: traefik-net
  postgres-net:
    external: true
    name: postgres-net
```

应用在内部网络中使用 `postgres:5432` 连接。连接串或拆分后的数据库凭据属于应用的 `runtime.env`，不得提交。初始连接池建议从每个应用实例 5 个连接开始；只有观察到连接压力后才引入 PgBouncer。

## 从本机数据库客户端连接

PostgreSQL 在服务器上仅监听 `127.0.0.1:5432`，不得把端口映射改为 `5432:5432` 或 `0.0.0.0:5432:5432`。在本机建立 SSH 隧道：

```bash
ssh -N -L 15432:127.0.0.1:5432 <server-user>@<server-host>
```

保持该 SSH 会话运行，并在 DBeaver、DataGrip 或 pgAdmin 中使用：

- Host：`127.0.0.1`
- Port：`15432`
- Database：目标业务数据库名；管理操作可使用初始化时的 `POSTGRES_DB`
- Username：目标业务角色；管理操作可使用初始化时的 `POSTGRES_USER`
- Password：对应角色的数据库密码

本机端口 `15432` 可以替换为其他未占用端口。不要把管理员凭据保存到仓库文件中。

如果后续需要把迁移权限与运行时权限分离，再为该应用增加独立 migration role；当前个人服务不预先增加这层复杂度。

## 每日备份

先创建仅运维用户可访问的本机暂存目录：

```bash
install -d -m 700 ~/backups/postgres
```

执行备份：

```bash
cd ~/my-cloud-infra
bash scripts/ops.sh backup postgres ~/backups/postgres
```

每个归档包含：

- `globals.sql`：角色和其他集群级对象。
- `databases/*.dump`：除默认 `postgres` 数据库外的每个业务数据库，使用 PostgreSQL custom format。
- `manifest.txt`：创建时间、PostgreSQL 版本和数据库清单。
- `SHA256SUMS`：归档内文件校验值。

归档权限设置为 `0600`。其中包含业务数据和角色密码哈希，仍应按敏感数据处理。

可使用服务器计划任务每天调用同一命令，例如每天 03:15 执行。计划任务还必须把成功生成的归档复制到受保护的异机存储，并监控失败状态；只保存在 `/var/lib/docker` 同一块系统盘上的归档不能满足灾难恢复目标。

建议异机保留 7 份每日备份和 4 份每周备份。本仓库不自动删除备份，也不预设云存储供应商。确认异机副本存在且校验通过后，再按明确文件名清理本机旧归档。

## 恢复演练

恢复操作会创建或覆盖数据库对象，不应直接对仍在提供服务的实例盲目执行。先停止所有数据库消费者，并优先在空数据卷或隔离环境中演练。

解压并校验归档：

```bash
mkdir -p /tmp/postgres-recovery
tar -xzf postgres-<timestamp>.tar.gz -C /tmp/postgres-recovery
cd /tmp/postgres-recovery
sha256sum -c SHA256SUMS
```

确保目标 PostgreSQL 已使用相同主版本启动。先恢复全局对象：

```bash
cd ~/my-cloud-infra/infrastructure/postgres
docker compose exec -T postgres \
  psql --username postgres --dbname postgres \
  < /tmp/postgres-recovery/globals.sql
```

新实例已经拥有初始化时创建的 `postgres` 角色，因此恢复 `globals.sql` 时对应的 `CREATE ROLE postgres` 可能报告已存在；后续角色属性语句仍会继续执行。该提示可以接受，但必须检查并处理其他错误。

然后逐个恢复业务数据库：

```bash
find /tmp/postgres-recovery/databases -type f -name '*.dump' -print0 \
  | while IFS= read -r -d '' dump; do
      docker compose exec -T postgres \
        pg_restore --username postgres --create --dbname postgres \
        < "$dump"
    done
```

恢复后检查数据库、角色和应用连接：

```bash
docker compose exec postgres psql --username postgres --dbname postgres --command '\l'
docker compose exec postgres psql --username postgres --dbname postgres --command '\du'
bash ~/my-cloud-infra/scripts/ops.sh status postgres
```

首次部署后应立即完成一次恢复演练，之后至少每季度验证一次。备份命令成功不等于恢复一定成功。

## 升级

补丁版本升级前：

1. 创建并复制一份新的异机备份。
2. 更新 `compose.yaml` 中的精确镜像版本和 digest。
3. 运行 `bash scripts/ops.sh validate`。
4. 手动执行 `bash scripts/ops.sh deploy postgres`。
5. 检查健康状态、日志和应用读写。

PostgreSQL 大版本不能只替换镜像。大版本升级必须另行设计 `pg_upgrade` 或逻辑导出/导入流程，并预留旧数据和新数据同时存在的磁盘空间。

## 容量检查

日常观察：

```bash
cd ~/my-cloud-infra/infrastructure/postgres
docker stats --no-stream "$(docker compose ps -q postgres)"
df -h /var/lib/docker
docker system df
docker volume inspect postgres-data
```

不要依赖容器名执行生命周期操作。系统盘达到 75% 使用率时检查增长来源，在达到 80% 前完成清理或扩容。图片、视频和附件应保存在对象存储或文件存储中，不进入 PostgreSQL。
