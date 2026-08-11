# DD Observability / Alerting 运维手册

> 目标：让 API、Worker、队列、依赖与 Push 在生产环境出现故障时，可以从指标与告警直接定位“哪里坏、影响多大、先查什么”。

## 1. 部署形态

Observability 与正式 Production Compose 解耦，位于：

```text
infra/observability/
```

它是 **Compose overlay**，不会修改 `infra/prod/compose.yml`。集成时由 Production Compose 提供 `api`、`worker`、`livekit`、`turn` 等正式 service；overlay 只补监控监听与 Prometheus/Grafana/Exporter。

典型组合命令：

```bash
docker compose \
  --env-file infra/prod/.env \
  -f infra/prod/compose.yml \
  -f infra/observability/compose.yml \
  up -d
```

实际生产 service 名如果不是 `api` / `worker` / `livekit` / `turn`，必须同步修改 overlay 与 `prometheus.yml` 的固定 target，不能让 Prometheus 靠猜服务名。

API/Worker metrics 默认不会额外开放监听。overlay 显式设置：

```text
DD_API_OBSERVABILITY_ADDR=:9464
DD_WORKER_OBSERVABILITY_ADDR=:9465
```

正式部署应只在 Compose 内部网络暴露 9464/9465，**不要直接映射到公网**。Prometheus/Grafana 默认 UI 也只绑定宿主机 `127.0.0.1`。

Grafana admin 密码必须用 `DD_GRAFANA_ADMIN_PASSWORD_FILE` 指向仓库外的 secret 文件；`.env.example` 不包含真实密码。

## 2. 采集范围

### HTTP / API

```text
dd_http_requests_total{method,route,status_class}
dd_http_request_duration_seconds{method,route}
dd_http_active_requests
```

`route` 来自 Go `ServeMux` 的静态匹配 pattern，而不是原始 URL；`status_class` 只保留 `2xx/3xx/4xx/5xx`，避免动态 ID 造成高基数。

### PostgreSQL

```text
dd_postgres_queries_total{operation,result}
dd_postgres_query_duration_seconds{operation}
dd_postgres_pool_connections{state}
dd_dependency_up{dependency="postgres"}
```

SQL 只按固定操作类型统计，不把 SQL 文本、参数、用户 ID 放入 labels。`pgx.ErrNoRows` 归类为 `not_found`，不把正常“没找到”误算成数据库错误。

### Redis / Realtime / WebSocket

```text
dd_redis_operations_total{operation,result}
dd_redis_reconnects_total
dd_websocket_connections{mode}
dd_realtime_publish_failures_total{reason}
dd_realtime_queue_dropped_total
dd_dependency_up{dependency="redis"}
```

### Durable Outbox

```text
dd_outbox_backlog
dd_outbox_oldest_pending_seconds
```

### Push

详见 `docs/runbooks/push-provider-operations.md`。主要指标：

```text
dd_push_jobs{state}
dd_push_oldest_pending_seconds
dd_push_running
dd_push_retries_total
dd_push_failed_total
dd_push_provider_requests_total{provider,result}
dd_push_provider_duration_seconds{provider}
dd_push_provider_auth_failures_total{provider}
dd_push_invalid_endpoint_ratio{provider}
dd_push_provider_configured{provider}
```

### Object Storage

```text
dd_object_storage_requests_total{operation,result}
dd_object_storage_duration_seconds{operation}
```

当前网络 I/O 指标覆盖 `Stat` / `Delete`。Presign 只在本机做签名计算，不代表 S3 网络健康，因此不拿本地 Presign 延迟冒充对象存储延迟。客户端直传 S3/MinIO 的 PUT 数据面不经过 Go API，服务端不能假装拥有那段上传链路的真实 latency；正式上传完成仍通过服务端 `Stat` 校验和客户端侧错误证据共同判断。

### SMTP

```text
dd_smtp_send_total{result}
dd_smtp_send_duration_seconds
```

### Worker

```text
dd_worker_ready
dd_worker_last_heartbeat_timestamp_seconds
dd_worker_cycles_total{result}
```

heartbeat 跟随真实 Outbox/Push dispatch loop 更新，所以“进程活着但主循环卡死”也能被识别。

### Process / Runtime / Disk

Prometheus Go/Process collector 自动提供：

```text
go_*
process_*
```

`node-exporter` 提供宿主机 filesystem 指标，正式 disk capacity 告警不依赖应用进程自己猜磁盘剩余量。

### LiveKit / TURN

`blackbox-exporter` 对：

```text
livekit:7880 HTTP
turn:3478 TCP
turn:5349 TLS
```

做主动探测。**这只能证明监听/握手层健康，不等于公网 NAT 穿透、UDP 媒体或跨运营商通话一定成功。** 完整公网通话仍归 U21 真人/网络环境验收。

## 3. 告警清单

`infra/observability/alerts.yml` 当前提供最小正式规则：

| 告警 | 触发方向 | `for` |
|---|---|---:|
| `DDAPIUnavailable` | API scrape 不可达 | 2m |
| `DDAPIHigh5xxRate` | 5xx > 2% 且有实际流量 | 10m |
| `DDAPIHighP95Latency` | p95 > 1s | 10m |
| `DDAPIHighP99Latency` | p99 > 2s | 10m |
| `DDPostgresUnavailable` | API/Worker PostgreSQL health fail | 2m |
| `DDPostgresPoolSaturated` | pool acquired/max > 90% | 10m |
| `DDRedisUnavailable` | Redis health fail | 2m |
| `DDObjectStorageFailureRate` | S3/MinIO 网络操作失败率 > 5% | 10m |
| `DDSMTPSendFailures` | 15m 内至少 3 次发送失败 | 10m |
| `DDOutboxBacklog` | oldest > 120s 或 backlog > 1000 | 10m |
| `DDPushBacklog` | oldest > 300s 或等待 > 500 | 10m |
| `DDPushFailureRate` | provider failure > 10% | 10m |
| `DDPushProviderAuthenticationFailure` | provider auth failure | 5m |
| `DDWorkerStopped` | scrape fail 或 heartbeat > 60s | 2m |
| `DDRealtimePublishFailures` | 10m 内重复 realtime failure | 5m |
| `DDLiveKitUnavailable` | LiveKit probe fail | 2m |
| `DDTurnTCPUnavailable` | TURN TCP probe fail | 5m |
| `DDTurnTLSUnavailable` | TURN TLS probe fail | 5m |
| `DDDiskCapacityLow` | filesystem free < 10% | 15m |

这些阈值是 **首版生产基线**，不是永久真理。上线后应根据真实流量/SLO 调优，但不能把 `for` 全删掉来追求“更灵敏”；瞬时抖动疯狂告警的运维价值很低。

## 4. 排障入口

### API unavailable

1. `up{job="dd-api"}`。
2. 检查 API `/live` 与 observability listener `/live` 是否都可达。
3. 如果 app listener 正常但 9464 不正常，查 overlay/env 与容器网络；不要误判为业务 API 已宕机。

### API 5xx

```text
sum by (route) (rate(dd_http_requests_total{job="dd-api",status_class="5xx"}[5m]))
```

```text
histogram_quantile(0.99, sum by (le,route) (rate(dd_http_request_duration_seconds_bucket{job="dd-api",route!~"/ws|/api/v1/realtime"}[5m])))
```

再用同一时间窗口的结构化日志与 `requestId` 查具体请求；**requestId 只进日志，不进 metric label**。

### API latency

先按 route 找慢接口，再分别看：

- PostgreSQL query latency/pool saturation；
- Redis failure/reconnect；
- object storage latency；
- active requests 是否持续上升。

### PostgreSQL unavailable

1. `dd_dependency_up{dependency="postgres"}`；
2. `dd_postgres_pool_connections`；
3. PostgreSQL 服务自身日志/连接上限/磁盘；
4. 检查网络与 secret file，但禁止把 `DATABASE_URL` 打进告警描述或 metrics。

### PostgreSQL pool

```text
max(dd_postgres_pool_connections{state="acquired"})
/
clamp_min(max(dd_postgres_pool_connections{state="max"}),1)
```

如果长期高占用，先找慢查询/阻塞，不要直接把 MaxConns 无限加大把压力转嫁给 PostgreSQL。

### Redis unavailable

1. `dd_redis_operations_total{result="error"}`；
2. `dd_redis_reconnects_total`；
3. Redis health/内存/连接数；
4. 核对网络和 `REDIS_URL_FILE`。

Realtime Redis 故障时客户端 durable sync 可以兜底部分提示，但这不等于故障可忽略；跨节点实时性会退化。

### Outbox backlog

```text
dd_outbox_backlog
```

```text
dd_outbox_oldest_pending_seconds
```

同时检查 Worker heartbeat、PostgreSQL、Push provider；Worker 当前顺序是先 DispatchOutbox，再 DispatchJobs，Outbox 持续失败会阻断同一轮 Push dispatch。

### Worker stopped

```text
time() - dd_worker_last_heartbeat_timestamp_seconds
```

- `up=0`：进程/容器/网络层；
- `up=1` 但 heartbeat 过旧：进程还活着但 dispatch loop 卡住或停止推进；
- heartbeat 持续但 `worker_cycles_total{result="error"}` 上升：主循环仍运行但业务依赖反复失败。

### Object storage

看 `dd_object_storage_requests_total{result="error"}` 和 latency，随后检查 S3/MinIO health、DNS、证书、Bucket 权限和网络。不要把 AccessKey/SecretKey 加进日志。

### SMTP

查看 SMTP result/latency，再检查 STARTTLS、账号权限、DNS/出口和 provider 限流。邮件地址不进入 metrics label。

### Realtime

如果 `dd_realtime_queue_dropped_total` 增长，表示本地 4096 hint queue 已满；客户端 sync 能恢复事实，但实时提示正在退化。若 `publish_failures` 与 Redis reconnect 同时增长，优先处理 Redis/网络。

### LiveKit / TURN

Blackbox 失败先确认 service name/port 是否与 Production Compose 一致，然后查证书/监听/防火墙。Blackbox 成功之后仍需要 U21 的真实 UDP/TCP/TLS、NAT、移动网络和跨运营商通话测试。

### Disk capacity

低于 10% 持续 15m 会报警。优先确认是哪块持久卷：PostgreSQL、Prometheus TSDB、Grafana、Docker、日志或对象存储；不要只删数据库 WAL/对象文件来“止血”而破坏数据完整性。

## 5. Cardinality / 隐私合同

Prometheus labels **禁止**：

```text
userId
deviceId
messageId
conversationId
requestId
email
raw URL
Access Token / Refresh Token
FCM/APNs endpoint/token/secret
message content
raw error message
SQL text / SQL 参数
```

允许的是固定小枚举：method、ServeMux route pattern、status class、provider、provider result、dependency、operation、state。

如果未来新增指标，测试必须证明动态输入不会原样进入 labels。高基数不是“小优化问题”，它会同时造成 Prometheus 内存膨胀和隐私数据扩散。

## 6. 配置检查

提交/部署前至少执行：

```bash
promtool check config infra/observability/prometheus.yml
promtool check rules infra/observability/alerts.yml
```

以及 Compose 合并后的：

```bash
docker compose \
  --env-file infra/prod/.env \
  -f infra/prod/compose.yml \
  -f infra/observability/compose.yml \
  config
```

**overlay 单独不是完整业务 Compose**，因为 `api` / `worker` 的 image/build、正式网络与依赖由 `infra/prod/compose.yml` 提供；必须检查“合并后的最终配置”。

## 7. 当前边界

已自动验证的是：指标 contract、固定 labels、Go instrumentation、Push provider 分类、告警/Prometheus 配置语法以及代码测试。

没有真实 FCM/APNs/Android/iPhone 环境时，下面仍必须标记：

```text
HUMAN-PENDING
```

- 真实 provider 凭据轮换演练；
- FCM 前台/后台/杀进程到达；
- APNs Sandbox/Production 真机到达；
- 用户点击与页面恢复；
- Alertmanager 到短信/邮件/IM 的最终接收通道（本 overlay 当前只定义 Prometheus alert rules，不替用户假设 pager 供应商）；
- U21 公网 LiveKit/TURN 的真实媒体质量与 NAT 穿透。
