# ADR-003：音视频采用 LiveKit 与 TURN

## 状态

Proposed

## 日期

2026-08-07

## 背景

语音和视频通话需要 WebRTC 信令、NAT 穿透、弱网适配、媒体转发、多端 SDK 和生产部署能力。自行实现 SFU 风险极高。

## 决策

- 使用自托管 LiveKit 负责 WebRTC 媒体。
- 优先使用 LiveKit 推荐 TURN 配置；复杂场景可使用 coturn。
- Core API 管理业务呼叫状态和签发短期房间 Token。
- 一对一通话优先，群通话后续开放。

官方依据：

- https://docs.livekit.io/transport/self-hosting/
- https://docs.livekit.io/transport/self-hosting/deployment/
- https://github.com/livekit/livekit
- https://github.com/coturn/coturn

## 备选方案

### 纯 P2P WebRTC

优点：服务器媒体成本低。

拒绝原因：复杂 NAT 下可靠性差，多设备、群通话、网络切换和统计能力弱。

### 自研 SFU

拒绝原因：协议、编码、拥塞控制、安全和跨平台工作量不可接受。

### 只使用第三方云 RTC

拒绝原因：违背完整自托管目标，可作为可选适配器但不能是唯一方案。

## 后果

- 部署者必须配置公网 IP、TLS、UDP 和 TURN。
- 通话容量受 CPU 和带宽影响，需压测后给出容量表。
- Docker 生产部署可能需要 host network，不能只依赖普通反代。
- 通话 E2EE 必须单独验证密钥管理和跨平台互操作。
