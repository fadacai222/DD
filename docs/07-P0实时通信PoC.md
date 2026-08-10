# P0 实时通信 PoC｜历史结论与当前正式化状态

> 更新时间：2026-08-11（P6-P10 演进状态同步）
>
> 本文不再作为“待做 PoC 清单”，而是记录实时通信 PoC 得出了什么结论，以及哪些能力已经进入正式主链。

---

# 1. P0 当初要验证什么

最初未知点：

- Flutter Windows/Android/Web 是否能稳定连接 Go WebSocket。
- Origin / CORS / 局域网地址如何配置。
- 断网、进程重启、重连行为是否可控。
- 同一协议是否能跨三端复用。

P0 目标不是完整聊天，而是验证：

```text
Go REST + WebSocket
↔ Flutter Windows / Web / Android
```

可行。

---

# 2. 已验证结论

P0 已完成并被后续正式代码继承：

- Go HTTP 服务可作为 Core API。
- Flutter 三端可使用同一实时协议。
- WebSocket 连接可进行 Origin 检查。
- 客户端可心跳、断线重连。
- 局域网 Android 需要使用可达的 PC LAN IP，而不是 `127.0.0.1`。
- Windows/Web/Android 可以围绕同一 API Origin 进行联调。

这些结论已经不再只是 PoC：正式 `/api/v1/realtime`、MessagingCoordinator 与 Sync 都在使用类似能力。

---

# 3. 当前实时架构已发生的升级

旧 PoC 心智：

```text
WebSocket = 实时消息本身
```

当前正式心智：

```text
PostgreSQL = 事实
Outbox = 可靠异步出口
Sync Events = 用户可恢复增量
WebSocket = 低延迟唤醒/提示
Redis = 跨 API 节点 hint
```

这是后续可靠消息最重要的架构升级。

---

# 4. 当前入口

### 正式

```text
GET Upgrade /api/v1/realtime
```

需要用户鉴权。

### 兼容

```text
GET Upgrade /ws
```

保留给历史 PoC / 兼容工具，不应成为新客户端首选。

---

# 5. 当前服务器行为

Realtime server 当前具备：

- WebSocket Upgrade。
- Origin policy。
- 鉴权模式。
- Ping/Pong/连接管理。
- 用户在线连接路由。
- 与 Redis realtime bus 的可选桥接。
- Call event 等兼容实时事件。

详细实现以 `server/internal/httpapi`、`server/internal/realtimev1`、`server/internal/realtimebus` 为准。

---

# 6. 当前客户端行为

正式 Flutter 客户端不依赖 `clients/realtime_poc` 作为主 UI。

真正业务入口在：

```text
clients/app/lib/features/messaging/application/messaging_coordinator.dart
```

客户端：

1. 启动后加载本地/服务端会话。
2. 建立 realtime。
3. 收到新状态 hint。
4. 拉 Sync/API 事实。
5. 更新本地 UI。
6. 断线后重连并补 Sync。

---

# 7. 为什么不能只靠 WebSocket

WebSocket 可能因为以下原因丢事件：

- 手机后台冻结。
- Wi-Fi ↔ 蜂窝切换。
- NAT 过期。
- API 重启。
- 用户暂时离线。
- 浏览器 tab 挂起。
- Redis 暂时不可用。

如果“消息是否收到”只依赖 socket event，就会产生静默缺口。

所以当前必须保持：

```text
socket for latency
sync for correctness
```

---

# 8. Realtime Event 设计原则

事件尽量表达：

```text
某用户有新状态需要拉取
```

而不是把所有业务事实仅塞进瞬时 WebSocket frame。

这样：

- 事件重复可容忍。
- 顺序临时错乱可通过 Sync 修正。
- 多 API 节点更容易扩展。

---

# 9. 客户端重连要求

必须：

- 有退避。
- 有 jitter。
- 有最大间隔。
- 网络恢复后快速尝试。
- 重连成功立即 Sync。
- Access Token 刷新后更新连接凭据。

禁止：

- 10ms 无限重连打爆服务端。
- 重连后仅显示“已连接”但不补数据。

---

# 10. 多节点

当前 Redis bus 为多 API 节点提供 hint。

节点 A 写消息：

```text
Postgres commit
→ Outbox/Sync
→ Redis hint
→ 节点 B 通知该用户 socket
```

Redis 短暂失败不能变成数据库事务失败的默认原因。

---

# 11. Push 与 Realtime 的区别

当前 realtime 连接只有 App 进程活跃/系统允许时才可靠。

真正“App 被杀死也收到通知”需要：

```text
FCM / APNs / UnifiedPush
```

P10 Push 已开始数据模型设计，最终应做：

```text
new sync event
→ Push Worker
→ OS wake/notification
→ client opens/reconnects
→ Sync
```

Push 不是消息存储。

---

# 12. P0 回归命令

历史脚本仍存在：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-poc.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\test-poc.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\test-realtime-protocol.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\test-reconnect.ps1
```

实际参数以脚本为准。

---

# 13. 当前测试要求

## 自动

- Upgrade method。
- Origin。
- malformed frames。
- auth failure。
- heartbeat。
- reconnect state machine。
- Redis bus publish/consume。
- Sync after disconnect。

## 真人

- Windows → Android 消息。
- Android → Windows 消息。
- Web 同账号/另一账号。
- 断 Wi-Fi 10～60 秒恢复。
- 服务端重启。
- App 后台再前台。
- 同一用户多设备。

判定标准：

```text
最终消息一致
未读一致
重复 = 0
```

---

# 14. P0 已完成与未完成的边界

### 已完成

- 实时技术路线验证。
- 正式鉴权 realtime 入口。
- Messaging realtime + Sync 主链。
- Redis 可选跨节点 hint。

### 尚未完成

- P10 `000022_push` 真实 PostgreSQL roundtrip 与稳定 migration gate。
- 完整 Push domain/API/Worker。
- FCM/APNs/UnifiedPush provider 与客户端 token 注册。
- 超大规模 fanout 压测。
- 多地域部署。
- Realtime metrics/alerting 完整生产化。

因此 P0 技术路线可视为 `HUMAN-PASS` 的历史基础，但实时系统整体仍需要随消息/通知模块持续回归。
