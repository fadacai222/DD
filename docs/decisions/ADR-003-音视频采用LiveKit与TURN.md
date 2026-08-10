# ADR-003：音视频采用 LiveKit + WebRTC + TURN

## 状态

Accepted

## 日期

- 提议：2026-08-07
- 确认落地：2026-08-10
- P7 正式实现复核：2026-08-11

## 背景

DD 需要一对一语音/视频，并未来可能扩展多人通话。自研 WebRTC SFU、NAT traversal、拥塞控制和多平台媒体栈风险过高。

## 决策

采用：

```text
LiveKit Server
+ WebRTC
+ STUN/TURN
+ Flutter LiveKit SDK
```

Go API 负责：

- 通话业务权限。
- Call session 状态。
- LiveKit room/token 授权。

LiveKit 负责：

- WebRTC transport。
- Track publish/subscribe。
- SFU。
- ICE/TURN 集成。

## 当前真实落地

开发 Compose 已有 LiveKit：

```text
HTTP/WSS  17880
ICE/TCP  17881
RTC UDP  17882/udp
TURN UDP 13478/udp
```

当前 P7 正式 Call API 已支持：

- `/api/v1/calls` create；
- PostgreSQL active recovery；
- accept/reject/cancel/end 等 action；
- accepted/有权设备 scoped token；
- caller/callee Bearer Principal 授权；
- 多设备首台接听仲裁；
- Contacts/Block 联动。

Flutter 已有一对一语音/视频 controller/page。

## 为什么必须 TURN

P2P/host/STUN candidate 不能覆盖：

- 对称 NAT。
- 企业网络。
- UDP blocked。
- CGNAT。

因此生产“能打电话”的定义必须包含 TURN fallback。

## 生产要求

至少：

- `wss://` LiveKit。
- TURN/UDP。
- ICE/TCP。
- 对严苛网络最好提供 TURN/TLS 443。
- 正确公网 node IP/NAT mapping。
- TLS certificate。

局域网成功不算生产验证。

## Token 安全

客户端不得持有：

```text
LIVEKIT_API_SECRET
```

正确：

```text
DD API authenticates user
→ verifies call membership/state
→ signs short-lived room-scoped participant token
```

P7 已完成这项正式化：participant/user/device 由 Auth Principal 与服务端 Call state 决定，不再信任客户端自报 caller identity。

## 备选方案

### 自研 WebRTC signaling + SFU

拒绝：成本、安全、兼容性、运维风险过高。

### 只做 P2P

拒绝：NAT/多人扩展/网络质量不可控。

### 第三方 SaaS RTC

可作为托管部署选项，但 DD 自托管目标要求有自建 LiveKit 路线。

## 后果

正面：

- 快速获得成熟多端媒体能力。
- TURN/SFU 路线明确。
- Flutter SDK 可复用。

风险：

- LiveKit 是重要外部基础设施。
- 公网端口/TURN 配置复杂。
- 版本升级需兼容测试。
- RTC 质量还依赖部署者网络。

## 约束

- Call 业务状态属于 DD，不属于 LiveKit room 本身。
- 不用“房间是否存在”代替好友/拉黑/参与者权限。
- 默认不录音录像。
- Calls 业务状态已经迁入 PostgreSQL `server/internal/calls`；后续扩容不得重新引入关键进程内 Call 真相。
- P7 剩余阻断是公网 TURN/TLS、长时/弱网、多节点和真人验收，而不是“从内存迁移”本身。
