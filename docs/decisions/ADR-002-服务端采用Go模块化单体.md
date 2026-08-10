# ADR-002：核心服务端采用 Go 模块化单体

## 状态

Accepted

## 日期

- 提议：2026-08-07
- 确认落地：2026-08-10
- 当前实现复核：2026-08-11

## 背景

DD 需要处理：

- HTTP API。
- WebSocket 长连接。
- 账号/关系/消息事务。
- Outbox/Sync。
- 媒体元数据。
- Sticker Relay。
- RTC 控制面。

首版如果直接拆成大量微服务，会把复杂度转移到服务发现、分布式事务、事件一致性和部署运维。

## 决策

核心业务采用 Go 模块化单体。

当前部署单元：

```text
server/cmd/api
server/cmd/worker
server/cmd/migrate
```

当前业务模块：

```text
auth
contacts
messaging
media
stickers
realtime
platform
protocol
```

P6-P9 后续已经新增正式 `internal/groups`、`internal/calls`、`internal/moments`、`internal/qrcode` 模块。P10 Push 当前仅有 migration 草案，完成后也应以独立 `internal/push` domain 接入 Worker，而不是把 provider 逻辑堆进 httpapi。

## 数据一致性策略

业务事实以 PostgreSQL 为核心。

跨实时/异步边界使用：

```text
transaction
→ outbox
→ worker
→ sync events
→ realtime hint
```

在没有容量证据前，不为了“看起来企业级”拆数据库或拆服务。

## 理由

- Go 的并发/网络模型适合大量 HTTP/WebSocket I/O。
- 单二进制部署简单。
- 关键关系/消息操作可在一个 PostgreSQL transaction 内保证一致性。
- 代码可通过 `internal/<domain>` 保持模块边界。
- 当前 `go test ./...` 能快速验证整套服务端。

## Worker 为什么独立

Worker 独立不是微服务化，而是运行职责隔离：

- Outbox dispatch。
- media cleanup。
- P10 Push/其它后台任务（当前 Push consumer 尚未实现）。

这样 API 请求不被长耗时后台任务阻塞，同时仍共享 Go domain package 和数据库合同。

## 备选方案

### Python/FastAPI

可用于工具/AI/离线任务，但不作为当前核心重写目标。

拒绝切换原因：当前 Go 业务/测试/migration 已形成大量资产，重写收益不足。

### Node/NestJS

技术上可行，但没有理由替换当前稳定 Go 主链。

### 微服务

当前拒绝。

除非指标证明：

- 某模块必须独立扩缩容；
- 数据边界稳定；
- 团队可以承担 tracing/deploy/schema/versioning 复杂度。

## 后果

正面：

- 部署简单。
- 本地事务强。
- 测试快。
- 小团队可维护。

风险：

- 模块间可能逐渐互相穿透。
- 单 API 进程热点可能影响其它模块。
- Worker/API 共享 schema 需要严格 migration discipline。

## 约束

- 新 domain 优先建立 `internal/<domain>` service，而不是把所有逻辑继续塞 `httpapi`。
- HTTP handler 只负责 transport/validation/mapping，不承载核心业务事务。
- 跨模块调用通过明确 service contract。
- 数据库 migration 不允许被各模块随意修改历史文件。
- 只有新 ADR 才能正式拆服务。
