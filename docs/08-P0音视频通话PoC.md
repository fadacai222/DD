# P0 音视频通话 PoC｜LiveKit/TURN 历史结论与 P7 正式 Calls

> 更新时间：2026-08-11 03:36
>
> 本文保留 P0 的技术选型结论，同时描述 **P7 已经正式化的 Calls 状态机**。旧 `/api/calls` / 内存 CallStore 只属于历史背景，不再代表当前正式架构。

---

# 1. 选型结论

DD 音视频继续采用：

```text
Signaling / authorization: DD Go API + PostgreSQL
Media plane:              LiveKit
NAT traversal:            ICE / STUN / TURN
Client media:             livekit_client
```

保留 LiveKit 的原因：

- 不自研 WebRTC SFU/媒体服务器；
- Windows/Android/Web 已验证 SDK 路线；
- 服务端可签发短 TTL、room-scoped token；
- TURN/STUN 与实际 RTC 平面边界清晰。

---

# 2. P0 曾经验证了什么

P0 解决了：

- Flutter 能创建/加入 LiveKit 房间；
- Windows ↔ Android 能进入语音/视频通话页面；
- 音视频轨道、摄像头开关、麦克风开关可工作；
- Android 来电页 overflow 等基础 UI 问题可修；
- 通话计时、结束自动退出、视频主画面 + 本地小窗的产品形态可实现；
- LiveKit/TURN 是可继续投入的路线。

P0 当时没有解决：

- Call 状态持久化；
- Bearer Principal 全链授权；
- 多设备接听仲裁；
- API 重启恢复；
- 联系人/Block 权限；
- 正式 OpenAPI；
- 服务端唯一通话结果消息。

这些已在 P7 主体中补齐。

---

# 3. 当前正式 Call API

正式新客户端使用：

```text
POST /api/v1/calls
GET  /api/v1/calls/active
POST /api/v1/calls/{callId}/actions
POST /api/v1/calls/{callId}/token
```

旧：

```text
/api/calls...
```

只属于兼容/历史实验面，不能再作为新功能开发依据。

---

# 4. 当前正式服务端 Domain

```text
server/internal/calls
server/internal/httpapi/formal_calls.go
migrations/000018_calls
migrations/000020_calls_conversation
```

核心事实：

- Call 状态写 PostgreSQL，不再放 API 进程内 map；
- caller identity/device 来自 Bearer Access Token Principal；
- callee 必须是 active contact；
- 双方任一 Block 均拒绝新 Call；
- caller 自己不能呼叫自己；
- active Call 竞争由 PostgreSQL transaction/lock 控制；
- Call 与 DIRECT conversation 绑定。

---

# 5. Call 状态机

当前持久状态：

```text
ringing
accepted
rejected
ended
```

终止原因用于区分：

```text
cancelled
ended
rejected
timeout
其它受控 reason
```

数据库约束保证：

- ringing 不能已经有 accepted/ended 信息；
- accepted 必须有 `accepted_at + answered_device_id`；
- rejected/ended 必须有终态时间；
- `version` 非负，用于状态竞争控制；
- ring expiry 晚于创建时间。

---

# 6. 多设备模型

## caller

Call 绑定 `caller_device_id`。

同一 caller 的其它设备：

- 不应冒充发起设备控制 Call；
- 不能获取该 Call 的媒体 token。

## callee

ringing 时 callee 多台设备可以同时看到来电。

第一台成功 accept 后：

```text
answered_device_id = winner device
```

其它 callee 设备立即失去后续媒体控制权：

- 不能取 LiveKit token；
- 不能挂断；
- 不应继续显示自己是当前通话控制端。

真实 PostgreSQL integration 已覆盖这条边界。

---

# 7. LiveKit Token 安全

客户端不持有：

```text
LIVEKIT_API_SECRET
```

Token 由 DD API 在确认 caller/callee 与设备有权控制当前 accepted Call 后签发。

原则：

- room name 服务端决定；
- participant identity/name 服务端决定；
- token 短 TTL；
- 非 Call 参与者不能构造 room 任意加入；
- losing callee device 不能取 token。

---

# 8. 通话恢复

客户端正式 Realtime 使用：

```text
/api/v1/realtime
```

重连/启动时：

```text
GET /api/v1/calls/active
```

服务端根据 authenticated user/device 返回有权恢复的 active Call。

与旧内存 CallStore 不同，API 进程重启不会单纯因为内存清空就丢失数据库中的 Call 状态。

仍需生产验证：

- API 多实例；
- LiveKit 服务重启；
- Redis/realtime hint 丢失；
- 客户端完全离线后靠 Sync/active recovery 补齐。

---

# 9. 通话结果消息

P7 已把“结束后客户端自己补一条聊天文本”的双写真相向服务端收口。

目标/当前主体：

```text
Call 进入终态
→ 同一服务端事务
→ DIRECT conversation 分配 sequence
→ SYSTEM call result message
→ Message Outbox
→ 多设备 Sync
```

这样可以避免：

- 客户端崩溃导致没有通话记录；
- 双端同时写出两条重复记录；
- Call 状态已结束但聊天记录仍显示另一套事实。

真人需要确认最终显示文案、语音/视频图标与时长格式。

---

# 10. Flutter 当前通话链

主要目录：

```text
features/calls/
  data/
    call_session_api.dart
    http_call_session_api.dart
    call_signaling_client.dart
  domain/
    call_session.dart
  presentation/
    two_party_call_controller.dart
    chat_call_page.dart
    call_video_stage.dart
```

正式客户端已经切到：

- Bearer `/api/v1/calls`；
- authenticated `/api/v1/realtime`；
- Access Token refresh 后更新后续 realtime reconnect credential。

旧测试/factory 可以保留兼容路径，但产品代码不能退回客户端自报身份。

---

# 11. 当前自动证据

已存在/跑过：

- `server/internal/calls/service_integration_test.go`；
- 正式 Call HTTP tests；
- `http_call_session_api_formal_test.dart`；
- `two_party_call_controller_test.dart`；
- call video stage / debug controller 回归。

真实 PostgreSQL 已覆盖：

- caller 多设备；
- callee 多设备同时 ringing；
- 首台 accept 获权；
- losing device token/hangup 拒绝；
- busy；
- 非联系人；
- Block；
- reject；
- timeout；
- accepted 后结束与时长记录。

当前阶段状态：

```text
IMPLEMENTED + AUTO-VERIFIED
HUMAN-PENDING
```

---

# 12. TURN / 公网部署仍是生产阻断项

开发环境能进入 LiveKit 房间不等于生产 RTC 完成。

正式上线至少验证：

- WSS；
- STUN；
- UDP candidate；
- TURN/UDP；
- ICE/TCP fallback；
- 目标网络需要时 TURN/TLS 443；
- Windows 与 Android 不同 ISP/不同 NAT；
- VPN/移动数据/Wi-Fi 切换；
- 代理/企业网限制。

旧诊断曾出现：

```text
No public IPv4 UDP
Server is not configured for ICE/TCP
TURN/TLS unavailable
```

所以不能拿 localhost/LAN 通过替代公网验收。

---

# 13. 产品体验基线

### 音频

- 来电/去电状态清晰；
- 系统/自有提示音自然；
- 接通后计时；
- 挂断后约 1 秒自动退出；
- 聊天里出现结构化结果与时长。

### 视频

- 对方视频作为主画面；
- 本地画面右下小窗；
- Android 产品页面不因视频内容横向而自动旋转整套 UI；
- 摄像头关闭有明确占位；
- 切换摄像头、静音、扬声器按钮状态同步。

---

# 14. 仍需真人/生产验收

以下尚不能被自动测试替代：

1. Windows ↔ Android 真机互打。
2. Android ↔ Android 不同网络。
3. Windows ↔ Web。
4. 30 分钟音频。
5. 30 分钟视频。
6. Wi-Fi ↔ 移动网络切换。
7. 强制 TURN relay。
8. 后台/锁屏来电与 P10 Push 联动。
9. 蓝牙耳机/扬声器/听筒路由。
10. 长时间 CPU/GPU/内存/电量。

---

# 15. 与 P10 Push 的关系

当前 realtime 只能在进程活跃/系统允许时可靠收到来电提示。

P10 完成后，离线/后台 Call invite 应通过最小 Push hint 唤醒客户端，再通过正式 Call API 获取真实状态；Push payload 不能成为 Call 状态机本身。正式 `/api/v1/calls` 的 realtime 也遵循同一原则：`event_available` 只作为 availability hint，客户端收到 `call-created/call-updated/call-timeout` 后通过 `/api/v1/calls/active` 恢复权威状态，不能再依赖旧 `/api/calls` 直接发送的 `call.incoming` payload。

---

# 16. 与 P11 E2EE 的关系

音视频媒体端到端加密与消息 E2EE 是不同问题。

P11 不能因为文字消息加密就宣称 LiveKit 通话已经 E2EE；如果产品以后承诺 RTC E2EE，需要单独选型、密钥交换、设备验证和跨端测试。

---

# 17. 当前结论

```text
LiveKit/TURN route: ACCEPTED
P7 server call state: FORMAL / PERSISTED
Formal Call API: IMPLEMENTED
Multi-device arbitration: AUTO-VERIFIED
Call result server transaction: IMPLEMENTED 主体
Public TURN/TLS: HUMAN/PRODUCTION PENDING
30-minute / weak-network: HUMAN PENDING
```

后续开发不能再把 P7 写成“需要从内存 CallStore 迁移”的待办；真正剩余的是 **公网 RTC、长时稳定、弱网、多节点和真人体验验收**。
