# 应用 Compose 契约

本契约让 `scripts/ops.sh` 和 GitHub Actions 可以通过目录结构发现应用，而不在工作流中维护服务白名单。

## 必须遵守

假设应用 ID 为 `my-app`：

1. 应用目录必须是 `apps/my-app/`。
2. Compose 文件固定为 `apps/my-app/compose.yaml`。
3. Compose 顶层 `name` 必须是 `my-app`。
4. 主应用 service 必须命名为 `my-app`。
5. 主镜像必须由 `IMAGE_REPOSITORY` 和 `IMAGE_TAG` 组合，不能硬编码部署账号或镜像命名空间。
6. 不得声明 `container_name`。
7. 对外服务必须加入名为 `traefik-net` 的 external network。
8. 不得直接发布宿主机端口，除非文档记录了明确原因。
9. `IMAGE_REPOSITORY`、`APP_DOMAIN` 和 `IMAGE_TAG` 属于 Compose 插值，保存在忽略的 `.env`；容器运行时变量使用 `runtime.env` 或 `<service>.runtime.env`。
10. 新应用应提供有效 HEALTHCHECK；暂时没有时，部署会在容器 running 后成功并输出警告。
11. 应用必须启用 `no-new-privileges`，并使用 Docker `local` 日志驱动限制日志占用。

基础结构：

```yaml
name: my-app

services:
  my-app:
    image: ${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required}:${IMAGE_TAG:?IMAGE_TAG is required}
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    logging:
      driver: local
      options:
        max-size: "10m"
        max-file: "3"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.my-app.rule=Host(`${APP_DOMAIN:?APP_DOMAIN is required}`)"
      - "traefik.http.routers.my-app.entrypoints=websecure"
      - "traefik.http.routers.my-app.tls.certresolver=letsencrypt"
    networks:
      - traefik-net

networks:
  traefik-net:
    external: true
    name: traefik-net
```

对应 `.env.example`：

```dotenv
IMAGE_REPOSITORY=ghcr.io/example/my-app
APP_DOMAIN=my-app.example.com
IMAGE_TAG=sha-REPLACE_ME
```

模板只使用保留的示例域名和通用镜像命名空间。部署环境的真实值写入同目录 `.env`，不得提交。`scripts/ops.sh deploy` 仅替换其中唯一的 `IMAGE_TAG`，其余配置保持不变。

首次服务器初始化时，在忽略的 `config/env.json` 中为该目标文件增加同名键。`bash scripts/ops.sh init-env config/env.json` 会要求 JSON 目标路径与仓库内模板一一对应，并要求变量名完全一致；它只创建缺失文件，不覆盖现有环境文件。

## 多域名

基础设施需要为多个根域预申请证书时，在服务器的 `config/env.json` 中填写 `traefik.domains` 字符串数组。初始化脚本会为每个根域生成一组 Traefik 索引环境变量，证书内容包含根域和对应的 `*.<根域>`；所有 DNS Zone 必须能由同一组腾讯云凭据管理。Traefik `.env` 中的 `DOMAIN_NAME` 必须出现在该数组中，并只用于 Dashboard 地址。

不同应用的 `APP_DOMAIN` 可以属于不同根域，Traefik 会根据每个 Router 的 `Host(...)` 规则分别路由并申请证书。`infrastructure/traefik/.env` 中的 `DOMAIN_NAME` 不是应用域名白名单。

同一个应用需要多个入口域名时，保留 `APP_DOMAIN` 作为主域名，并增加命名明确的附加变量：

```dotenv
APP_DOMAIN=my-app.example.com
APP_ALT_DOMAIN=my-app.example.net
```

```yaml
labels:
  - "traefik.http.routers.my-app.rule=Host(`${APP_DOMAIN:?APP_DOMAIN is required}`) || Host(`${APP_ALT_DOMAIN:?APP_ALT_DOMAIN is required}`)"
```

对应 `.env.example` 和 `config/env.json` 必须同时增加 `APP_ALT_DOMAIN`。不要使用逗号分隔字符串冒充 Router 规则；需要更多域名时继续增加明确变量和 `Host(...)` 条件。

## 应用运行时变量

需要运行时变量时，在 Compose 中声明：

```yaml
services:
  my-app:
    env_file:
      - path: ./runtime.env
        required: true
```

同时提交 `runtime.env.example`，但不能提交实际 `runtime.env`。需要按服务隔离变量时，使用成对的 `<service>.runtime.env` 与 `<service>.runtime.env.example`；校验脚本会把 Compose 文件和模板复制到受控临时目录完成模型验证，不会在真实栈目录生成运行时文件。运维脚本会在部署前要求实际文件存在。

## 私有数据库

数据库属于单个应用时，与应用放在同一个 Compose 项目：

```yaml
services:
  my-app:
    networks:
      - traefik-net
      - backend

  mysql:
    image: mysql:<固定版本>
    env_file:
      - path: ./mysql.runtime.env
        required: true
    volumes:
      - mysql-data:/var/lib/mysql
    networks:
      - backend

networks:
  traefik-net:
    external: true
    name: traefik-net
  backend:
    internal: true

volumes:
  mysql-data:
```

应用通过 `mysql:3306` 访问数据库。MySQL 不加入 `traefik-net`，也不发布 `3306` 到宿主机。

提交 `mysql.runtime.env.example` 作为字段模板；实际 `mysql.runtime.env` 只保存在服务器上，并由 Git 忽略。

持久化服务还必须补充备份和恢复说明，禁止把 `docker compose down -v` 当作常规操作。

## 共享数据库

数据库被多个应用使用时，它不再属于任何单一应用，应由 `infrastructure/<service>/` 中的独立 Compose 项目管理。当前共享 PostgreSQL 栈位于 `infrastructure/postgres/`，并创建内部 `postgres-net`。

需要访问 PostgreSQL 的应用只把自己的主服务加入该 external network：

```yaml
services:
  my-app:
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

应用使用 `postgres:5432` 作为内部地址。PostgreSQL 不加入 `traefik-net`；其宿主机端口仅绑定到 `127.0.0.1:5432`，供 SSH 隧道运维使用，不对公网监听。每个应用必须使用独立数据库和登录角色，凭据保存在该应用忽略的运行时环境文件中；不得使用 PostgreSQL 超级用户作为应用凭据。

共享数据库的首次部署、备份、恢复与升级以 [PostgreSQL 运维](postgres.md) 为准。数据库栈必须先于消费者部署；单个应用的发布和回退不得删除或重建共享数据卷。

## 共享对象存储

共享 Garage 栈位于 `infrastructure/garage/`，并创建 internal `garage-net`。需要 S3 API 的应用只把自己的后端服务加入该 external network，使用 `http://garage:3900`、`region=garage` 和 path-style URL；不要把 Garage Access Key 写入前端代码。

每个应用使用独立 Access Key，按 Bucket 授予最小读写权限。初始化 Key 只用于引导和运维。应用数据库保存 Bucket、Object Key、MIME、大小和校验和，不保存文件二进制或固定公网 URL。

公开对象由 Traefik 路由到 Garage 的 3902 Web endpoint。当前不对公网路由 3900 S3 API，因此浏览器预签名直传不属于默认契约；如需启用，必须单独评审公网域名、CORS、有效期、文件大小、类型校验和滥用防护。

Garage 的网络、Bucket/Key 创建、容量边界、备份和恢复以 [Garage 对象存储运维](garage.md) 为准。应用发布和回退不得删除 `garage-meta`、`garage-data` 或重建共享 Bucket。

## 新增应用流程

1. 创建 `apps/<id>/compose.yaml`。
2. 创建包含 `IMAGE_REPOSITORY`、`APP_DOMAIN` 和 `IMAGE_TAG` 的 `.env.example`，只填写示例值。
3. 在服务器的 `config/env.json` 中增加对应目标路径和真实值，运行 `bash scripts/ops.sh init-env config/env.json`。
4. 执行 `bash scripts/validate.sh`。
5. 在应用仓库构建不可变标签镜像。
6. 配置带有 `service` 和 `image_tag` 的 repository dispatch。
7. 首次部署后验证容器健康、HTTPS 路由和日志。
