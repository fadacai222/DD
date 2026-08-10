# ADR-007：可靠消息采用 PostgreSQL Outbox + Cursor Sync + Realtime Hint

## 状态

Accepted

## 日期

2026-08-10（对现有实现补录）

- 当前实现复核：2026-08-11

## 背景

即时通讯不能把“WebSocket frame 成功发出去”当作消息可靠性的定义。

客户端可能：

- 离线。
- 后台被冻结。
- Wi-Fi/蜂窝切换。
- 错过 socket frame。

服务端可能：

- API 重启。
- Redis 暂时不可用。
- realtime 节点与目标 socket 不在同一进程。

如果数据库消息提交和 realtime publish 是两个无事务关联的动作，就会出现经典 dual-write 丢事件。

## 决策

DD 可靠消息采用：

```text
PostgreSQL business transaction
+ transactional outbox
+ per-user sync_events cursor
+ WebSocket realtime hint
+ optional Redis cross-node bus
```

正确性优先级：

```text
PostgreSQL state
> Sync Events
> Realtime hint
```

## 发送流程

```text
BEGIN
→ authorize
→ allocate conversation sequence
→ insert message
→ update conversation last message
→ insert outbox event
COMMIT
```

message 与 outbox 必须同事务。

## Worker

```text
claim pending outbox
→ resolve target users
→ create sync_events
→ publish realtime hint if available
→ mark published
```

如果 realtime publish 暂时失败：

- 不删除已经提交的 message。
- 通过 retry / later sync 恢复。

## Client

```text
WebSocket event
→ trigger fetch/sync
→ merge by stable ids/sequence
→ persist cursor
```

WebSocket reconnect 后必须 Sync。

## Redis

Redis 只用于跨 API 节点 hint。

不把 Redis Pub/Sub 当持久消息队列或事实库。

## 为什么不用“只靠 Kafka”

当前规模没有必要把所有事务改成分布式事件驱动。

PostgreSQL transaction + Outbox 能提供更简单的本地一致性。

未来如果 fanout/backlog 指标需要 Kafka/NATS，可在 Outbox 下游增加 broker，而不改变发送事务事实。

## 为什么不用“客户端收到 socket 就算成功”

socket 不是 durable receipt。

发送成功的业务定义是：

> 服务端事务已持久化并返回 message/sequence；目标客户端最终可通过 Sync 获取。

## Read/Recall/Edit 等事件

不仅新消息需要可靠同步。

以下状态变化也应通过 Outbox/Sync 或等价可靠机制传播：

- message created。
- message edited。
- recall。
- read。
- conversation preferences。
- relationship events。
- Group lifecycle/membership events。
- Moment events。
- Call terminal SYSTEM message/outbox。

## 后果

正面：

- socket 丢失不丢业务消息。
- 支持离线补账。
- 多设备更容易一致。
- API/Redis 重启影响降低。

成本：

- Outbox backlog/worker 运维。
- Sync event 存储增长。
- 客户端必须做幂等 merge。

## 与 P10 Push 的关系

Push 不能替代本 ADR。P10 的 `push_jobs` 是设备提醒投递队列：它可以由业务事件/Sync 事实派生，但不能成为消息、群、朋友圈或 Call 的唯一事实库。客户端收到 Push 后仍通过 Sync/正式 API 获取真实业务状态。

## 约束

- 新模块需要实时同步时，优先复用 Outbox/Sync，不自己再造第二套只靠 socket 的事件事实。
- Worker backlog 必须监控。
- Sync cursor 兼容性必须版本化。
- 任何优化不能让 realtime publish 重新进入核心 DB transaction 成为脆弱外部依赖。
