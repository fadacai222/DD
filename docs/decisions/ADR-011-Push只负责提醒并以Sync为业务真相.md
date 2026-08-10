# ADR-011：Push 只负责提醒/唤醒，业务真相仍由 PostgreSQL + Sync/API 获取

## 状态

Accepted（P10 implementation in progress）

## 日期

2026-08-11

## 背景

移动端/桌面端进程被系统冻结或杀死后，Realtime WebSocket 不能保证到达。DD 需要 FCM/APNs/UnifiedPush 等后台 Push。

但如果把完整消息/关系/Call 状态复制进 Push 队列，就会出现：

- 第二套业务事实库；
- 消息已撤回但旧 Push 仍代表“真相”；
- E2EE 后 Push 队列泄露明文；
- provider retry 与消息状态竞争；
- token/provider 故障影响核心消息 durability。

## 决策

Push 采用独立的 **设备提醒投递层**：

```text
Business transaction / durable state
→ derive minimal Push Job
→ push_jobs
→ Push Worker
→ FCM / APNs / UnifiedPush
→ OS wakes/notifies client
→ client reconnects
→ Cursor Sync / Call API / Relationship API 获取真实状态
```

业务事实优先级：

```text
PostgreSQL business state
> Sync / formal API
> Push hint
```

## 数据模型

P10 当前草案 `000022_push.up.sql`：

```text
user_notification_preferences
device_push_endpoints
push_jobs
```

### endpoint

每个 device/provider 独立保存：

- endpoint；
- endpoint_hash 去重；
- provider；
- app/environment；
- ACTIVE/INVALID/DISABLED；
- success/failure diagnostics。

### preview

预览策略：

```text
FULL
SENDER_ONLY
HIDDEN
```

默认应偏向最小披露。E2EE 场景不得为了通知方便把正文重新上传到服务端 Push payload。

### job

Job 保存最小资源引用、recipient/actor、dedupe/retry 状态，不保存一份可替代业务表的完整消息副本。

## Provider

目标 provider：

- FCM HTTP v1；
- APNs；
- optional UnifiedPush。

Provider credential 只在 Worker/Secret 配置中存在，不进入 Flutter、Git、普通 API response 或日志。

## Failure semantics

- transient provider failure → bounded exponential backoff；
- permanent/unregistered token → endpoint 标记 INVALID；
- duplicate business event → dedupe key 防重复 Job；
- Push 丢失不得导致消息丢失；
- Push 成功不得替代 read/delivery receipt。

## Worker

Push consumer 放 `server/cmd/worker` 或后续独立 Worker deployment，不阻塞 API 请求事务。

## 当前实现状态

截至 2026-08-11：

```text
000022_push.up.sql exists
000022_push.down.sql exists
Push domain/API missing
Push Worker consumer missing
FCM/APNs/UnifiedPush adapter missing
Flutter token registration missing
```

up/down migration 已配对，但真实 PostgreSQL roundtrip、Push domain/API/Worker/provider/client token registration 仍未完成。因此架构决策已接受，P10 产品能力仍为 `IN-PROGRESS`。

## 与 E2EE

P11 后 Push 应进一步最小化：

- 不发送明文正文；
- 可发送 opaque event/resource hint；
- 客户端唤醒后从 Sync 获取密文并本地解密；
- Mention 等需要重新设计客户端产生的安全 notification hint。
