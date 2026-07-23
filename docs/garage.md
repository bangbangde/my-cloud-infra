# Garage 对象存储运维

## 服务边界

Garage 是当前服务器上的共享 S3 兼容对象存储，运行于 `infrastructure/garage/`。当前部署只有一个节点和一块系统盘：`replication_factor = 1` 仅提供对象存储接口，不提供副本、高可用或整机故障保护。服务器或系统盘损坏时，对象可能全部丢失。

当前网络入口：

| 入口 | 地址 | 可见范围 | 用途 |
| --- | --- | --- | --- |
| S3 API | `http://garage:3900` | Docker 网络 | 应用后端上传、下载和管理对象 |
| S3 API 运维入口 | `http://127.0.0.1:3900` | 宿主机回环，经 SSH 隧道访问 | 桌面客户端上传、下载和管理对象 |
| Web endpoint | `http://garage:3902` | Traefik 后端 | 对外只读提供公开对象 |
| RPC | `127.0.0.1:3901` | Garage 容器回环 | 单节点内部管理通信 |

Compose 仅把 S3 API 3900 发布到宿主机 `127.0.0.1:3900`，供运维人员通过 SSH 隧道访问；它不监听公网地址。Traefik 只路由 3902，不路由 S3 API 3900，因此当前不支持浏览器直接使用公网预签名 URL 上传；应用上传仍应由同机后端通过 `garage-net` 完成。需要浏览器直传时，应另行评审公网 S3 域名、CORS、上传大小限制和滥用防护。

## 配置与持久化

目录内容：

- `.env`：公开媒体域名和首次创建的公开 Bucket 名称。
- `.env` 同时定义公开 Bucket 的最大容量与对象数；部署时会幂等应用配额。
- `.env.runtime`：RPC 密钥、初始化 Access Key 和 Secret Key。
- `garage.toml`：无密钥的 Garage 服务配置。
- `garage-meta`：SQLite 元数据、节点身份和每日元数据快照。
- `garage-data`：对象数据块。

元数据和对象数据都启用 `fsync`。元数据使用 SQLite，并每 24 小时创建一次一致性快照。快照与原数据仍在同一块系统盘，只能辅助处理元数据损坏，不能替代异机备份。

不得执行 `docker compose down -v`，也不得手动修改卷内文件。

## 首次初始化

在 `config/env.json` 中补充 Garage 两个目标文件。密钥可在服务器生成：

```bash
openssl rand -hex 32
printf 'GK%s\n' "$(openssl rand -hex 16)"
openssl rand -hex 32
```

三行依次用于：

1. `GARAGE_RPC_SECRET`：64 个小写十六进制字符。
2. `GARAGE_DEFAULT_ACCESS_KEY`：`GK` 加 32 个小写十六进制字符。
3. `GARAGE_DEFAULT_SECRET_KEY`：64 个小写十六进制字符。

公开配置示例：

```json
"infrastructure/garage/.env": {
  "GARAGE_PUBLIC_DOMAIN": "media.example.com",
  "GARAGE_PUBLIC_BUCKET": "public-media",
  "GARAGE_PUBLIC_BUCKET_MAX_SIZE": "5GiB",
  "GARAGE_PUBLIC_BUCKET_MAX_OBJECTS": "100000"
}
```

`GARAGE_PUBLIC_DOMAIN` 必须解析到当前服务器，其根域名应已包含在 `traefik.domains` 中。`GARAGE_PUBLIC_BUCKET` 使用 3～63 位、DNS 兼容的小写名称。

生成运行文件并部署：

```bash
cd ~/my-cloud-infra
bash scripts/ops.sh init-env config/env.json
bash scripts/ops.sh deploy traefik
bash scripts/ops.sh deploy garage
```

部署命令会先检查 Docker 所在文件系统的容量，启动单节点 Garage，然后幂等设置默认 Bucket 的 `5GiB / 100000 objects` 配额并启用只读网站访问。需要调整时，修改 `.env` 中的两个配额值后重新部署 Garage。

## 验证

```bash
cd ~/my-cloud-infra
bash scripts/ops.sh status garage
bash scripts/ops.sh check garage
bash scripts/ops.sh logs garage

cd infrastructure/garage
docker compose exec -T garage /garage status
docker compose exec -T garage /garage bucket info public-media

curl -fsSI https://media.example.com/
```

根路径没有 `index.html` 时，最后一条命令返回 404 是正常的；上传一个对象后，应使用完整对象路径验证，例如 `https://media.example.com/images/example.webp`。

## 桌面客户端通过 SSH 隧道接入

Garage 的宿主机端口只绑定 `127.0.0.1:3900`。在本机建立 SSH 隧道，把任意未占用的本地端口转发到该入口：

```bash
ssh -N -L 13900:127.0.0.1:3900 <user>@<server>
```

保持 SSH 会话运行，并在 Cyberduck、WinSCP、AWS CLI 或其他 S3 客户端中使用：

```text
endpoint: http://127.0.0.1:13900
region: garage
forcePathStyle: true
```

SSH 隧道负责加密本机到服务器的链路，因此该回环入口不额外启用 TLS。桌面客户端使用独立 Access Key，只授予需要管理的 Bucket 及最小读写权限；不要复制初始化 Key。不得把端口映射改为未指定宿主机地址的 `3900:3900` 或 `0.0.0.0:3900:3900`。

## 应用接入

需要访问 Garage 的应用把主服务加入 external `garage-net`：

```yaml
services:
  my-app:
    networks:
      - traefik-net
      - garage-net

networks:
  traefik-net:
    external: true
    name: traefik-net
  garage-net:
    external: true
    name: garage-net
```

应用 S3 客户端使用：

```text
endpoint: http://garage:3900
region: garage
forcePathStyle: true
bucket: public-media
```

初始化 Access Key 拥有默认 Bucket 的管理权限，只用于引导和运维，不直接复制给应用。为每个应用创建独立 Key，并只授予必要权限：

```bash
cd ~/my-cloud-infra/infrastructure/garage
docker compose exec garage /garage key create my-app
docker compose exec garage /garage bucket allow \
  --read \
  --write \
  public-media \
  --key my-app
```

把命令输出的 Key ID 和 Secret Key 放入该应用被 Git 忽略的运行时环境文件。应用数据库保存 Bucket、Object Key、原始文件名、MIME、大小和校验和，不保存对象二进制或固定公网 URL。

## 容量边界

系统盘当前总容量约 40 GiB、剩余约 18 GiB。第一阶段只为对象数据规划约 5 GiB，至少为系统、Docker 更新、PostgreSQL 和日志保留 10 GiB。

`bash scripts/ops.sh check garage` 检查 Docker Root 所在文件系统：

- 使用率达到 70%：输出告警。
- 使用率达到 75%，或可用空间低于 10 GiB：返回失败。
- Garage 部署前会自动执行同一检查。

公开 Bucket 另有部署时应用的硬配额，但容量检查仍覆盖 Garage、PostgreSQL、镜像和日志共用的整个 Docker 文件系统，也不会自动撤销其他 Bucket 或已经运行应用的写权限。应用上传入口仍须限制单文件大小；达到停止阈值后，应暂停上传并清理可确认删除的对象或扩容。不要直接删除 `garage-data` 中的数据块。

## 备份与恢复

在没有第二个存储位置时，对象存储无法承诺 24 小时灾难 RPO。相同系统盘上的副本或元数据快照不能抵御云盘损坏。

存在个人电脑、NAS 或其他已有存储后，备份必须同时覆盖：

- `garage-meta` 卷。
- `garage-data` 卷。
- 忽略的 `.env` 与 `.env.runtime`。

最简单的可靠流程是在停止写入后停止 Garage，把两个卷作为同一恢复点复制到异机，再重新启动；恢复演练应在临时卷上验证对象列表、随机对象校验和和公开读取。不要只备份 `garage-data`，否则丢失元数据后无法把数据块直接当普通文件使用。

## 更新与故障处理

Garage 镜像同时固定版本和多架构 digest。更新前：

1. 阅读目标版本升级说明。
2. 创建并验证异机备份。
3. 记录当前镜像 digest、卷和环境文件。
4. 先在临时卷验证启动、上传、下载、删除和重启。

容器无法启动时，先保留两个数据卷并查看日志；不得通过删除元数据卷来“重新初始化”。只有在确认恢复副本可用后，才执行卷替换或数据库转换。
