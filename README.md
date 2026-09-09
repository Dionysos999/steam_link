# steam_link

**PlayPilot** 项目的 Steam 连接功能服务模块。

PlayPilot 是一个面向 PC 玩家的游戏平台，提供「游戏情报聚合 + 攻略检索 + AI 问答 + Steam 游戏画像 + 社区」五大能力。本仓库承担其中 **Steam 账号关联与游戏数据采集** 的职责，是「Steam 游戏画像」的数据底座——上层的 AI 问答、攻略推荐与社区展示都依赖本模块产出的游戏库、成就与游玩会话数据。

## 模块职责

| 编号 | 能力 | 说明 |
|---|---|---|
| F1 | 账号关联 | 通过 Steam 官方 OpenID 2.0 授权，将 Steam 账号绑定到 PlayPilot 账号 |
| F2 | 游戏库列表 | 用户拥有的全部游戏，含名称、图标、累计时长、最后游玩时间 |
| F3 | 游戏成就 | 全库完整成就数据：成就定义、用户解锁状态与解锁时刻、全球解锁率 |
| F4 | 时长监控 | 持续监控游戏行为，产出「何时玩了哪款游戏、玩了多久」的会话事件流 |

这些数据共同构成用户的 **Steam 游戏画像**：品类偏好、活跃时段、投入深度、成就完成度，供 PlayPilot 上层的情报推送与 AI 问答消费。

## 在 PlayPilot 中的位置

```
PlayPilot
├── 游戏情报聚合
├── 攻略检索
├── AI 问答
├── Steam 游戏画像  ←── 本模块（steam_link）提供数据
└── 社区
```

## 域边界

| 属于这里 | 不属于这里 |
|---|---|
| Steam 账号绑定与解绑（OpenID 2.0 验证归属） | **PlayPilot 账号本身、登录、密码** → `services/user_center` |
| 从 Steam 采集游戏库、成就、游玩会话 | 校验登录态、注入 `X-User-Id` → `services/gateway` |
| 采集调度、限流、退避重试、补偿 | 帖子、评论、资讯 → `services/content_center` |
| 会话事件流与时长的**原始事实**（含精度标注） | 页面展示与图表 → `apps/playpilot-web` |
| 与 Steam Web API 打交道的全部细节 | 基于画像的推荐算法与排序 —— **尚无归属**，实现时再定 |

**本仓是「Steam 游戏画像」的数据底座，产出事实而非结论。**
品类偏好、活跃时段这类派生解读由消费方计算 —— 本仓只保证原始数据准确、
并诚实标注哪些是实测、哪些是推断补齐（`source=reconcile`）。

**steam_link 完全不碰登录态。** 它不解析 Cookie 或 Bearer token、不读写会话 Redis，
只读 Gateway 注入的 `X-User-Id`。绑定关系用 `userId` 引用 PlayPilot 用户，不复制用户档案字段。

跨仓的接口与身份约定见 [`../../docs/conventions/api-contract.md`](../../docs/conventions/api-contract.md)。

## 技术栈

| 层 | 选型 |
|---|---|
| 语言 | Go |
| HTTP 框架 | Gin |
| ORM | GORM |
| 主存储 | MySQL 8（utf8mb4） |
| 缓存与限流 | Redis 7 |
| 异步任务 | 本地事务表 + 定时扫描补偿（不引入消息队列） |
| 配置 | YAML 分环境 + viper，实例地址与密钥由 `.env` / 环境变量注入 |
| 日志 | 标准库 `log/slog` 结构化日志 |

## 采集架构

Steam 不提供任何推送机制，时长监控本质是「定期采样 + 快照差分」。采集分四层，由上一层观测到的**变化**驱动：

| 层 | 接口 | 触发方式 | 职责 |
|---|---|---|---|
| L0 | `GetPlayerSummaries` | 按 tier 定时，批量 100 人/次 | 检测「谁正在玩什么」 |
| L1 | `GetRecentlyPlayedGames` | 会话结束事件，延迟 5 分钟 | 获取精确时长增量，落会话 |
| L2 | `GetPlayerAchievements` | 该游戏时长有增量时 | 同步成就解锁 |
| L3 | `GetOwnedGames` | 每用户每日一次 | 同步游戏库 + 兜底补漏 |

L0 的批量能力是成本支点：1000 个用户全量探测一轮仅需 10 次调用。稳态日调用量约 3,300 次，占配额（100,000/天）的 3.3%。

## 目录结构

```
cmd/
  api/            Gin HTTP 服务：OpenID 登录、数据查询接口
  worker/         采集进程，可多实例水平扩展
configs/          服务自己的非敏感分环境 YAML
scripts/db/       初始化 DDL 与增量迁移脚本
scripts/dev/      本地依赖启动与测试脚本
internal/
  config/         viper 加载与校验
  logging/        slog Logger 构造
  steam/          Steam Web API 客户端 —— 唯一对外发起请求的包
  domain/         会话状态机与业务规则（纯函数，无 IO）
  collector/      L0–L3 各层 job 处理器
  task/           本地事务表：入队、扫描、租约、退避重试
  auth/           OpenID 2.0 验证 + 签名 state
  store/          GORM repository
  api/            Gin handler 与 DTO
```

## 环境与配置

三套环境，由 `APP_ENV` 选择（默认 `local`；取值写错会启动即失败，不会静默沿用基础配置）：

| `APP_ENV` | 服务跑在 | 连接的 MySQL / Redis |
|---|---|---|
| `local` | 本机 | 本机 docker 实例 |
| `test` | 本机 | 阿里云实例（公网 IP） |
| `prod` | 阿里云 | 阿里云实例（内网 IP） |

`configs/` 保存服务自己的非敏感 YAML；工作空间统一保存共享 env：

```
configs/
  config.yaml           基础配置，所有环境共享（会提交）
  config.local.yaml     ┐
  config.test.yaml      ├ 各环境的非敏感覆盖项（会提交）
  config.prod.yaml      ┘

../../deploy/demo/env/
  local.env             ┐
  test.env              ├ 跨服务实例地址与密钥（根仓库忽略）
  prod.env              ┘
  *.env.example         无敏感值模板（会提交）
```

优先级从低到高：`config.yaml` → `config.{env}.yaml` → 共享 `{env}.env` → 真实环境变量。
最后一层意味着部署时用容器环境变量可覆盖 `.env` 里的任意一项，无需先删掉文件。

实例地址与密钥全部走 `.env`，YAML 中一律留空：

| 配置键 | 环境变量 |
|---|---|
| `steam.api_key` | `STEAMLINK_STEAM_API_KEY` |
| `mysql.host` / `port` / `user` / `password` | `PLAYPILOT_MYSQL_HOST` / `_PORT` / `_USERNAME` / `_PASSWORD` |
| `mysql.database` | `STEAMLINK_MYSQL_DATABASE` |
| `redis.host` / `port` / `password` | `PLAYPILOT_REDIS_HOST` / `_PORT` / `_PASSWORD` |
| `redis.db` | `STEAMLINK_REDIS_DATABASE` |
| `auth.state_secret` | `STEAMLINK_AUTH_STATE_SECRET` |
| `http.base_url`（仅 prod 必填，且必须 https） | `STEAMLINK_HTTP_BASE_URL` |

其中 `steam.api_key`、`mysql.password`、`auth.state_secret` 为必填，缺失时启动即失败并指明缺哪一项 —— 而不是等到第一次调用 Steam 才暴露。

新环境从模板起步：

```bash
cp ../../deploy/demo/env/test.env.example ../../deploy/demo/env/test.env
chmod 600 ../../deploy/demo/env/test.env
```

> 连阿里云（`test`）时记得把本机出口 IP 加进 RDS / Redis 的白名单，否则连接会超时。

## 本地开发

```bash
./scripts/dev/up.sh    # 起依赖并应用 scripts/db/init.sql（可重复执行）
./scripts/dev/test.sh  # go vet + 全量测试（集成测试需要 MySQL 与 Redis 就绪）

go run ./cmd/api       # HTTP 服务
go run ./cmd/worker    # 采集进程
```

`up.sh` 默认复用本机常驻的 `dev-mysql` / `dev-redis` 容器；找不到时回退到本仓库的 `docker-compose.yml`。

### 测试库

集成测试打的是真实 MySQL —— `SKIP LOCKED`、生成列、`ON DUPLICATE KEY UPDATE` 的行为在 SQLite 上完全不同，用它测等于没测。

`go test ./...` 直接跑即可，不需要 `-p 1`。**每个测试包用自己的库**：`internal/testsupport` 在包路径派生的库名上建库并应用 `scripts/db/init.sql` 与 `scripts/db/migrations/*.sql`，于是 `internal/store` 用 `steamlink_internal_store`、`internal/e2e` 用 `steamlink_internal_e2e`，依此类推。这些包的用例会在每个用例前清表，共用一个库的话 Go 默认的跨包并行就会让它们互相清掉对方的数据。

因此测试**不碰** `up.sh` 建的 `steamlink` 开发库，也不要求先跑 `up.sh` 建表 —— 只要 MySQL 在跑，测试库会自己建出来。服务器地址与库名前缀用 `TEST_MYSQL_DSN` 覆盖（后缀照样追加，`.../mydb` → `mydb_internal_store`）：

```bash
TEST_MYSQL_DSN='root:pw@tcp(127.0.0.1:3306)/mydb?parseTime=true&loc=UTC&charset=utf8mb4' go test ./...
```

`parseTime=true` 与 `loc=UTC` 是必须的，否则 `DATETIME` 扫描进 `time.Time` 会失败或带错时区。

Redis 集成测试使用隔离的 DB 15（`internal/steam`）；登录会话由 user_center 签发并由
Gateway 校验，steam_link 不再读写登录态 Redis。

要求 **Go 1.24+**、**MySQL 8.0.1+**（低于此版本 `SELECT ... FOR UPDATE SKIP LOCKED` 不可用，整个任务表方案失效）。

## API 与身份信任边界

公网请求必须先经过 Gateway。免登录入口位于 `/noauth/steam/**`，业务接口位于
`/api/steam/**`；steam_link 不解析 Cookie 或 Bearer token，只读取 Gateway
注入的 `X-User-Id`。

> **安全前提：禁止把 steam_link 端口直接暴露到公网。** 客户端可以任意伪造
> `X-User-Id`，只有 Gateway 会先删除伪造值再注入真实身份，绕过 Gateway 直连
> 即等同于绕过鉴权。为此 `configs/config.yaml` 的 `http.addr` 默认就是
> `127.0.0.1:9994`：服务以裸机 systemd 部署（见 `scripts/systemd/`），
> 没有 Docker 端口发布那层兜底，这一行就是唯一的防线，不要为图方便改成 `:9994`。
> 若改回容器部署则相反 —— `http.addr` 必须放开成 `:9994`（否则容器不可达），
> 改由 `127.0.0.1:9994:9994` 的端口发布把关，并确保只有 Gateway 所在的受信
> 网络能直连该服务。

当前路由：

- `GET /noauth/steam/login`
- `GET /noauth/steam/callback`
- `GET /api/steam/library`
- `DELETE /api/steam/link`
- `POST /api/steam/link/recheck`
- `GET /api/steam/games/:appid/achievements`
- `GET /api/steam/achievements/recent`

## 已知约束

- **OpenID 不返回访问凭证**：绑定的技术含义是「验证该 SteamID 归属该用户」，而非获得数据访问授权。所有数据仍以服务端自己的 API Key 读取该 SteamID 的**公开**数据。
- **隐私墙是静默的**：游戏详情非公开时 Steam 返回 HTTP 200 空对象而非错误码，必须在绑定时同步探测并向用户给出明确引导。
- **存在不可消除的精度损失**：短于探针间隔的会话、隐身用户的会话由每日校准推断补齐，并以 `source=reconcile` 标记，在数据模型层面与实测数据严格区分。

## 文档

- [设计文档](docs/01-design.md) — 平台约束、数据模型、采集管线、可靠性设计
- [逆向规格](../../docs/specs/spec-steamlink-overview.md) — 从代码反推的实现规格（工作空间文档）

> 早期的 `docs/02-implementation.md`（分阶段落地细节）已在实施完成后删除，不再维护。
