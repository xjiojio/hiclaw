# manager-watch 落地任务拆解（方案 A）

本文档将“manager-watch：监控 + 页面展示 + 一键重启 + Matrix 告警”的方案拆解为可执行、可验收的开发任务清单，便于按里程碑落地。

## 目标

- 在 HiClaw 现有架构（Manager 全家桶容器 + 多 Worker 容器 + Higress 统一入口）上新增一个守护服务 manager-watch
- manager-watch 周期探测以下对象的存活与可用性，并在异常时发送 Matrix 告警到名为 `manager-watch` 的 Room
  - Higress（gateway/console/pilot/controller/apiserver 等）
  - Tuwunel Matrix Server
  - Element Web
  - MinIO
  - Manager Agent
  - Worker 容器（OpenClaw / CoPaw）
- 提供一个 Web 页面展示所有服务的状态，并支持点击按钮对服务执行启动/重启
- Web 页面与 API 通过 Higress 统一入口对外暴露（Higress 反向代理），并具备基础鉴权、限流/防抖与审计

## 非目标（本阶段不做）

- 不引入 Prometheus/Grafana 等完整监控栈（后续可在方案 B 做）
- 不将 UI “嵌入” Higress Console 前端（本阶段采用 Higress 路由转发集成）
- 不做复杂的 SLO/告警抑制/告警聚合（仅做最小可用的状态变更告警与防抖）
- 不做跨宿主机/跨集群的 Worker 运维（以本机 docker/podman socket 可控为前提）

## 总体架构与对接点

- 运行位置：manager-watch 作为 Manager 容器内的一个 supervisord program
- 状态探测：
  - Manager 容器内进程：通过 `supervisorctl status <program>`
  - HTTP 可用性：对本地端口探测（127.0.0.1:6167/8088/9000/8001/8080 等）
  - Worker 容器：复用 `/opt/hiclaw/scripts/lib/container-api.sh` 通过容器运行时 socket 查询状态并执行 stop/start/create
- 告警发送：通过 Matrix Client API 发送消息到 Room（名称 `manager-watch`）
- Web 集成：Higress 配置一条 route（域名或路径）转发到 manager-watch 的 HTTP 服务

## 里程碑与任务列表

### Milestone 0：准备与约束确认（半天）

- 明确 manager-watch 的访问入口与域名策略
  - 默认建议：`watch-local.hiclaw.io`（需要 hosts 解析到 127.0.0.1 或网关所在 IP）
  - 或路径模式：挂到 `aigw-local.hiclaw.io` 的 `/watch/`（避免新增域名）
- 明确鉴权方式
  - 最小可用：HTTP Basic Auth（浏览器友好，便于快速落地）
  - 后续增强：Higress key-auth consumer（操作 API 强鉴权，read-only 端点可弱鉴权）

验收标准：
- 输出一份配置项清单（env/域名/端口），并与安装脚本输出信息一致

### Milestone 1：manager-watch 后端服务骨架（1 天）

任务：
- 新增 manager-watch 服务进程（建议 Python 标准库实现，避免额外依赖）
  - `GET /`：返回状态页（HTML）
  - `GET /api/status`：返回 JSON 状态
  - `POST /api/actions/restart`：执行重启动作
  - `GET /api/audit`（可选）：读取最近 N 条审计日志
- 提供统一的“目标清单”与状态模型（建议字段）
  - `id`：唯一标识（如 `minio`、`tuwunel`、`manager-agent`、`worker:alice`）
  - `kind`：`supervisor` | `http` | `worker`
  - `process_status`：RUNNING/STOPPED/FATAL（supervisor）或 running/exited/not_found（worker）
  - `probe_status`：UP/DOWN/DEGRADED/UNKNOWN
  - `last_checked_at`：时间戳
  - `reason`：失败原因摘要（超时/非 2xx/连接拒绝等）

验收标准：
- 在 Manager 容器内可通过 curl 访问 `http://127.0.0.1:<watch_port>/api/status` 并返回结构化 JSON

### Milestone 2：探测实现（1 天）

任务：
- 实现 supervisor 进程探测：
  - 读取固定 program 白名单（来自 supervisord.conf）
  - 使用 `supervisorctl status <name>` 获取状态
- 实现 HTTP 探测：
  - Tuwunel：`/_matrix/client/versions`（HTTP 200 即认为 UP）
  - Element Web：`/`（HTTP 200/302/304 认为 UP）
  - MinIO：`/minio/health/ready`（HTTP 200 UP）
  - Higress Console：`/`（HTTP 可连通即可）
  - Higress Gateway：`/` 或 TCP 连通性（本阶段以“可连通”为主）
- 实现 Worker 容器探测：
  - 通过 container-api.sh 的 `container_status_worker` 获取状态
  - 若 socket 不可用，显示 UNKNOWN，并提示“未挂载容器运行时 socket”
- 探测调度与防抖：
  - 周期：默认每 10s（可配置）
  - 连续失败阈值：默认 3 次判定 DOWN（可配置）
  - 恢复阈值：默认 1 次成功判定 UP（可配置）
- 状态持久化：
  - 将上一轮状态写入 `/data/manager-watch/state.json`（用于识别状态变化与去重告警）

验收标准：
- 人为停止某组件（如 `supervisorctl stop minio`）后，页面状态在 30 秒内变为 DOWN 并包含明确 reason
- 恢复组件后，页面状态在 30 秒内恢复为 UP

### Milestone 3：重启能力（1 天）

任务：
- 重启 supervisor 组件：
  - `POST /api/actions/restart` 支持 `{kind:"supervisor", name:"minio"}` 之类请求
  - 仅允许白名单内的 program 名称
- 重启 Worker 容器：
  - 支持 `{kind:"worker", name:"alice"}`
  - 策略：
    - running：先 stop 再 start（或直接 restart）
    - exited：start
    - not_found：create（可配置开关，默认 create 以恢复自愈）
  - 仅允许匹配 `hiclaw-worker-<name>` 前缀的容器名（避免任意容器操作）
- 操作审计：
  - 将每次重启动作写入 `/data/manager-watch/audit.log`（JSON Lines）
  - 记录：时间、操作者（从 auth 中解析）、动作、目标、执行结果、错误摘要
- 操作防抖/限流：
  - 同一目标在 60s 内最多 1 次重启（可配置）

验收标准：
- 页面点击“重启 minio”后，minio 状态在 30 秒内恢复为 RUNNING/UP
- 页面点击“重启某 worker”后，该 worker 容器状态恢复为 running（或被创建）

### Milestone 4：Matrix 告警（含 manager-watch room 自动创建）（1 天）

任务：
- Room 目标：告警发送到名为 `manager-watch` 的 Room
- Room 自动发现/创建策略（不需要人工提供 room_id）：
  1. 启动时使用 Manager 账号登录 Matrix（优先使用现成 token，否则用密码登录换 token）
  2. 拉取已加入房间列表并查找名称为 `manager-watch` 的 Room
     - 如果找到：记录其 `room_id` 到 `/data/manager-watch/room.json`
     - 如果未找到：创建 Room（name=`manager-watch`，建议 private + invite）
  3. 邀请必要成员：
     - 人工管理员：`@${HICLAW_ADMIN_USER}:${HICLAW_MATRIX_DOMAIN}`（注意 domain 带端口）
     - manager 自身（如果创建时没默认加入）
  4. 发送一条启动成功消息，包含 watch 页面入口链接
- 告警触发条件：
  - 状态从 UP/DEGRADED → DOWN：立即发送告警
  - 可选：DOWN → UP 发送恢复消息
- 告警内容模板（建议）：
  - 标题：`[manager-watch] <service> DOWN`
  - 详情：失败原因、最近一次探测时间
  - 链接：`http://<watch_domain>:<gateway_port>/?focus=<service>`

验收标准：
- 停止 minio 后，Room `manager-watch` 在 30 秒内收到告警
- 恢复 minio 后，Room 收到恢复消息（若启用）
- 重启 Manager 容器后，Room 不重复创建，但仍能继续发送告警（room_id 持久化生效）

### Milestone 5：Higress 集成（半天）

任务：
- 在 `setup-higress.sh` 增加：
  - `manager-watch` service-source：`127.0.0.1:<watch_port>`
  - `manager-watch` route：
    - 域名模式：`watch-local.hiclaw.io` → `manager-watch.static:<watch_port>`
    - 或路径模式：`aigw-local.hiclaw.io` + `/watch/` 前缀
- 对 API 端点加鉴权策略（最小可用）
  - 第一阶段：manager-watch 内部 Basic Auth 保护所有页面/API
  - 第二阶段：将操作 API（POST）改为 Higress key-auth（allowedConsumers 仅 `watch-admin`）

验收标准：
- 通过网关入口可访问状态页（而非仅 127.0.0.1 直连）

### Milestone 6：集成到 Manager 镜像启动流程（半天）

任务：
- 在 `supervisord.conf` 添加 `program:manager-watch`
- 编写启动脚本 `start-manager-watch.sh`
  - 读取 env，落默认值
  - 确保数据目录 `/data/manager-watch` 存在
  - 以非 daemon 模式启动 HTTP 服务
- 增加日志输出到 `/var/log/hiclaw/manager-watch*.log`

验收标准：
- 全新安装后无需额外手动步骤，manager-watch 自动启动并可访问

## 配置项清单（建议）

- `HICLAW_WATCH_PORT`：manager-watch 监听端口（容器内），默认 `19090`
- `HICLAW_WATCH_DOMAIN`：对外访问域名，默认 `watch-local.hiclaw.io`
- `HICLAW_WATCH_ROOM_NAME`：告警房间名，固定为 `manager-watch`
- `HICLAW_WATCH_INTERVAL_SECONDS`：探测周期，默认 `10`
- `HICLAW_WATCH_FAIL_THRESHOLD`：连续失败阈值，默认 `3`
- `HICLAW_WATCH_RESTART_COOLDOWN_SECONDS`：重启冷却时间，默认 `60`
- `HICLAW_WATCH_USER` / `HICLAW_WATCH_PASSWORD`：Basic Auth 账号密码（默认复用 admin/password）

## 风险与控制措施

- 高危操作面：重启/创建容器需要 socket 权限
  - 控制：白名单 + 审计 + 冷却时间 + 鉴权
- 误报与抖动：
  - 控制：连续失败阈值 + reason 透明 + 恢复通知可选
- Higress setup 的幂等性：
  - 控制：将 manager-watch 的 service-source/route 放入 setup-higress 的“可幂等更新”逻辑（GET 存在则 PUT，否则 POST），避免受 first-boot marker 影响

## 最终验收（端到端）

- 访问：浏览器打开网关入口的状态页，能看到所有组件当前状态
- 告警：任意组件挂掉后，Room `manager-watch` 收到告警，并含状态页链接
- 自愈：在状态页点击重启按钮后，组件恢复，页面状态更新，且审计日志可追溯

