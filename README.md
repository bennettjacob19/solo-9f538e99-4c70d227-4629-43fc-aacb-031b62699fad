# 制品目录历史查询服务

发布值班工程师追查“误上线时制品目录实际指向哪个版本”、以及“某笔版本变更
是否经过网页成组操作”的历史查询系统。源 PostgreSQL 中的制品目录
（制品编号 / 服务名 / 版本 / SHA-256）通过 **一致基线 + 逻辑复制** 被完整
捕获到本地 SQLite 仅增日志，可按任意已捕获提交点回看整张目录，支持删除后
编号重用、多行事务整体可见；每个源事务额外携带**网页操作号来源**，可区分
“网页成组操作”与“来源未登记”（普通 SQL 直改或升级前旧事务，不能据此
断言写入者）。

## 1. 架构与正确性设计

```
PostgreSQL 源库 (artifacts 固定四列)
   │  ① 建逻辑复制槽 test_decoding + pg_export_snapshot 导出一致性快照
   │  ② 另开连接 SET TRANSACTION SNAPSHOT 复用快照做整表基线
   │  ③ 从槽 LSN 持续消费逻辑变更流（walsender）
   ▼
捕获工作线程（FastAPI 进程内 daemon thread）
   │  每个源事务：先整体写 SQLite（行变更 + 提交点同一事务）
   │              落盘成功后才 send_feedback 推进源端槽位
   ▼
SQLite 历史库（WAL，仅增不改）  ←→  FastAPI 网页 / JSON API
```

### 关键不变量

| 需求 | 实现方式 |
| --- | --- |
| 一致基线，普通 SQL 不中断 | 建槽与 `pg_export_snapshot()` 在同一事务完成；基线用 `SET TRANSACTION SNAPSHOT` 读一致性快照，源库无需停机、普通读写照常提交 |
| 基线前开始、基线后提交的事务不漏 | 该事务对导出快照不可见（不进基线），但其提交记录的 LSN 晚于槽起始 LSN，必然出现在逻辑流中被补捕获（自测第 2 组确定性验证） |
| 多行事务整体可见 | 一个源事务的全部行变更与提交点在**同一个 SQLite 事务**落盘，不存在半条事务 |
| 删除后重用编号保留旧历史 | `artifact_history` 仅追加，每行带 `change_type` 与提交点；按编号取“最后一条 ≤ 查询点”的记录重建目录，DELETE 与后续 INSERT 各自留痕 |
| 源断连 / 强杀重启后续接 | 复制槽持久化在源库；应用重启从槽位重放，SQLite 以源事务 xid 为主键幂等去重；断线自动指数/固定退避重连 |
| 不确认尚未落盘的更改 | 严格“先 SQLite commit，后 `send_feedback(flush_lsn=...)`”；keepalive 与无关消息一律不回送反馈。自测断言槽 `confirmed_flush_lsn` 永不超前已落盘提交点 |
| 初始化未完成不开放历史 | 状态机 `INITIALIZING → STREAMING / ERROR`；未到 STREAMING 时 `/api/points`、`/api/directory`、`/api/history/*` 一律 503 |
| 固定结构的增改删 | 网页/API 只接受 `insert/update/delete` 三类操作，pydantic 判别联合按 `op` 分流，仅四列，sha256 强制 64 位十六进制；无任何 DDL/任意 SQL 通道 |
| 来源与目录修改同事务成败 | 网页先生成操作号 `operation_id`，`apply_operations` 在**同一个源事务**里先写 `operation_origins(operation_id, xid=txid_current())` 再改目录；提交则同生，回滚则来源与修改一起消失，不留可查来源 |
| 普通 SQL 直改无操作号 | 只有网页成组操作写 `operation_origins`；直连 SQL 改目录的事务在逻辑流中没有来源消息，SQLite 中 `operation_id` 为 NULL，网页标“来源未登记”，且明确不能据此断言写入者 |
| 来源不缺失、不串事务、不重复 | 捕获线程在每个源事务 BEGIN 时重置、COMMIT 时把操作号与该事务全部目录变更写入**同一个 SQLite 事务**；断线/重放靠 xid 幂等去重，操作号随事务唯一关联 |
| 待捕获不得显示为已审计 | `GET /api/operations/{id}` 先查 SQLite（`CAPTURED`/`audited=true`），查无再查源库登记表：源库有而 SQLite 无 → `PENDING_CAPTURE`/`audited=false`；两边都无 → 404（未提交或已回滚） |
| 响应丢失仍可追溯 | 源事务提交后 HTTP 响应可能丢失，但操作号已随事务持久化；客户端凭操作号轮询状态接口即可得到最终结果，不依赖原请求的响应 |

### 源库与 SQLite 表结构

源 PostgreSQL（`init/01_schema.sql`，应用启动时幂等执行）：

- `artifacts`：制品目录固定四列（不变）。
- `operation_origins`：网页成组操作的事务来源登记，
  `operation_id TEXT PRIMARY KEY, xid BIGINT, created_at TIMESTAMPTZ`。
  仅网页成组操作在其业务事务内写入；普通 SQL 直改不写此表。

SQLite 历史库（`/data/history.db`）：

- `capture_state`：阶段、槽名、基线 LSN、最近提交点/消息 LSN、错误信息。
- `txns`：源事务 xid（主键）、提交 LSN、提交时间、`operation_id`
  （NULL=来源未登记）。旧版历史库启动时自动 `ALTER TABLE` 加列，
  旧事务一律 NULL，只标未登记。
- `artifact_history`：仅增变更链（BASELINE/INSERT/UPDATE/DELETE），带 xid、
  提交 LSN 与数值化 LSN，支持按提交点过滤与编号重建；单编号历史经
  `LEFT JOIN txns` 带出来源操作号。

## 2. 用 Docker Compose 启动（交付方式）

```bash
docker compose up --build
# 网页：http://localhost:8000/
# 源 PostgreSQL：localhost:5432（user/pass/db = postgres/postgres/postgres）
```

- `postgres` 服务：`postgres:16-bookworm`，已开启 `wal_level=logical`，
  命名卷 `pgdata` 持久化；首次启动自动执行 `init/01_schema.sql`
  幂等建表并播种 3 行示例数据。
- `app` 服务：本仓库构建的 Python 3.12 镜像，命名卷 `historydata`
  挂载到 `/data` 持久化 SQLite；`restart: unless-stopped`，源库健康检查
  通过后才启动。
- 两侧均为命名卷，`docker compose down` 不丢数据，`down -v` 才清空。

## 3. 网页功能（单页应用，无前端构建）

1. **捕获进度**：阶段徽章、复制槽、基线/最近提交 LSN、已捕获事务数、
   历史行数、最近错误，3 秒自动刷新。
2. **成组修改源目录**：可先生成 UUID 操作号（也可手填，留空则服务端
   生成），动态增删 insert/update/delete 行，整组与来源登记在一个源事务
   提交；任一操作失败整组回滚；成功后回显操作号，响应丢失时可凭它查询。
3. **按操作号查询捕获状态**：`CAPTURED`（已捕获/已审计，附提交点与
   变更行数）或 `PENDING_CAPTURE`（源库已提交、SQLite 未捕获，明确
   未审计）；查不到为 404（未提交或事务已回滚）。
4. **提交点回看**：列出 BASELINE 与每个源事务提交点（LSN、xid、时间、
   变更行数、**网页操作号或“来源未登记”**），点击任一行即查看该时刻
   整张目录。
5. **单编号完整历史**：含 BASELINE/INSERT/UPDATE/DELETE 全链与每条
   变更所属事务的网页来源，直观验证“删除后重用编号，旧历史保留”。

## 4. HTTP API

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/progress` | 捕获状态与进度（初始化期也可用） |
| GET | `/api/source/artifacts` | 源库当前目录 |
| POST | `/api/source/operations` | 成组增改删，单源事务，来源登记同事务；body 可带 `operation_id`，缺省自动生成；重复操作号返回 409 |
| GET | `/api/operations/{operation_id}` | 按操作号查 `CAPTURED` / `PENDING_CAPTURE`（未审计）/ 404 |
| GET | `/api/points` | 全部可查询提交点，含每事务 `operation_id` 与 `origin_registered`（未就绪时 503） |
| GET | `/api/directory?point=0/16B3748` | 该提交点（含）的整目录 |
| GET | `/api/history/{artifact_no}` | 单编号完整变更链（含来源操作号） |

请求示例：

```bash
curl -X POST localhost:8000/api/source/operations -H 'Content-Type: application/json' -d '{
  "operation_id": "5f8c2e9a-7b3d-4f1a-9c2e-6a8b0d1f2e34",
  "operations": [
    {"op":"insert","artifact_no":1004,"service_name":"cart-svc","version":"3.1.0",
     "sha256":"abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234"},
    {"op":"delete","artifact_no":1003}
  ]}'
curl localhost:8000/api/operations/5f8c2e9a-7b3d-4f1a-9c2e-6a8b0d1f2e34
curl 'localhost:8000/api/directory?point=0/16B3748'
```

## 5. 自测

### 5.1 解析器单元测试

```bash
python3 -m unittest tests.test_decoder -v
```

覆盖 BEGIN/COMMIT、带空格与转义引号的值、DELETE 仅主键、其他表/DDL 忽略。

### 5.2 端到端自测（78 项断言）

`tests/selftest.sh` 在本机自动拉起一个便携 PostgreSQL（不依赖 Docker）、
启停应用并完成全链路验证：

```bash
# 可选：指定本机 PostgreSQL 二进制位置
export PGBIN=/path/to/postgresql/bin PGCLIENT=/path/to/client/bin
bash tests/selftest.sh
```

覆盖场景：

1. 初始化窗口历史接口 503，完成后 STREAMING 与基线目录正确；
2. **跨基线事务**：通过应用内置测试钩子
   （`TEST_INFLIGHT_ARTIFACT_NO` 环境变量，默认关闭）确定性构造
   “基线快照点之后打开、基线落盘之后提交”的事务，断言不进基线、
   不被遗漏、在其提交点可见；
3. 多行事务只产生一个提交点、同事务插入/删除同时生效；
4. 删除后重用编号，旧历史链完整（BASELINE,DELETE,INSERT）；
5. 失败整组回滚、非法 sha256/非法 LSN/非法操作号参数校验；
6. `kill -9` 强杀应用后重启：事务数不重复、最后更新仍在、
   槽 `confirmed_flush_lsn` 不超前已落盘 LSN、续接后新变更继续捕获；
7. 源 PostgreSQL 重启后应用自动重连恢复 STREAMING，恢复后变更不丢；
8. **来源追踪**：网页操作号随源事务登记并在提交点/单编号历史显示；
   普通 SQL 直改标“来源未登记”；不存在操作号 404；重复操作号 409 且
   整组回滚；
9. **待捕获不冒充已审计**：确定性拉长捕获窗口（`TEST_CAPTURE_DELAY_MS`），
   断言落盘前状态为 `PENDING_CAPTURE`、`audited=false`，捕获后才置真；
10. **回滚不留来源**：网页失败组与直连 ROLLBACK 两种方式，来源登记均
    零残留、操作号查询 404；
11. **响应丢失**：`TEST_EXIT_AFTER_COMMIT=1` 让进程在源事务提交后、
    HTTP 响应前退出，断言源库来源与目录修改都在，重启重放后操作号被
    捕获、不缺失不重复；另测响应挂起（`TEST_DELAY_AFTER_COMMIT_S`）
    期间操作号已可查；
12. **强杀重放与断线重连**：来源不重复、不缺失、不串相邻事务，旧事务
    的“来源未登记”语义不被改写；
13. SQLite 与 PostgreSQL 数据目录均落盘持久化。

最近一次结果：**78 passed / 0 failed**。

## 6. 配置（环境变量）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `PG_DSN` | 本地开发 DSN | 源库 libpq 连接串，Compose 中指向 `postgres` 服务 |
| `SQLITE_PATH` | `/tmp/capture/history.db` | 历史库路径（Compose 中为 `/data/history.db`） |
| `REPLICATION_SLOT` | `artifacts_history_slot` | 逻辑复制槽名 |
| `SOURCE_TABLE` | `artifacts` | 捕获的源表（结构固定） |
| `SOURCE_ORIGIN_TABLE` | `operation_origins` | 网页操作号来源登记表名 |
| `REPL_STATUS_INTERVAL_S` | `5` | 复制协议 keepalive 间隔 |
| `REPL_RECONNECT_BACKOFF_S` | `2` | 断线重连退避秒数 |
| `CAPTURE_INIT_SLEEP_MS` | `0` | 测试钩子：拉长初始化窗口 |
| `TEST_INFLIGHT_ARTIFACT_NO` | `0`(关) | 测试钩子：跨基线事务编号 |
| `TEST_INFLIGHT_SLEEP_S` | `3` | 测试钩子：在途事务持有秒数 |
| `TEST_EXIT_AFTER_COMMIT` | `0`(关) | 测试钩子：源事务提交后、HTTP 响应前退出进程（模拟响应丢失） |
| `TEST_DELAY_AFTER_COMMIT_S` | `0`(关) | 测试钩子：提交后延迟 N 秒再返回响应（模拟响应挂起） |
| `TEST_CAPTURE_DELAY_MS` | `0`(关) | 测试钩子：捕获线程每个 COMMIT 落盘前等待毫秒数（确定性待捕获窗口） |

## 7. 已知边界 / 未完成项

- 逻辑解码使用 PostgreSQL 内置 `test_decoding`（无需安装插件），解析器
  依赖本项目固定的表结构；表结构变更不在支持范围内（需求明确禁止 DDL）。
- “来源未登记”是**缺失证据**而非证据缺失：它只表示该源事务没有网页
  操作号（普通 SQL 直改，或升级前的旧事务），不能据此断言具体写入者；
  反过来，带操作号的事务一定经过网页成组接口（登记表与目录修改同事务）。
- 历史库为单进程 SQLite，适合值班排查类读多写少场景；如需多副本水平扩展
  需更换存储层。
- 复制槽若被人工从源库删除，应用进入 ERROR 并在 `/api/progress` 暴露，
  不会自动重建（重建会使旧 LSN 失效，需人工确认后清空历史库重新基线）。
- 沙箱环境未提供 Docker 守护进程，Compose 文件未经本机 `docker compose`
  实跑（YAML 已校验）；但应用本体与新来源追踪链路已用便携
  PostgreSQL 15.18 + uvicorn 在本机完成 78 项端到端断言与 9 项解析器
  单元测试，Compose 镜像基于官方 `python:3.12-slim` 与
  `postgres:16-bookworm`，启动路径与本机自测一致。
