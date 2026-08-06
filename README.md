# 复刻微信：开源自托管 IM 项目企划

> 项目代号：OpenIMX（临时名，正式发布前必须更换为原创品牌名）

这是一个面向个人、团队和小型社区的开源自托管即时通讯系统。目标是让任何拥有公网服务器、域名和基础 Docker 运维能力的人，都能搭建一套独立可控的 IM 服务。

## 项目目标

- 仅使用邮箱注册和登录，不强制绑定手机号。
- 支持好友、单聊、群聊、语音消息、语音通话、视频通话、朋友圈和扫码。
- 同时提供 Web、Windows/macOS/Linux、Android、iOS 客户端。
- 数据、账号、媒体文件和通信基础设施由部署者自行掌控。
- 默认通过 Docker Compose 完成单机部署，并保留后续横向扩展能力。
- 采用模块化单体起步，避免首版被微服务复杂度拖死。
- 加密功能只使用经过审计的协议和实现，不自行发明密码学。

## 重要边界

1. **不会像素级复制微信。** 可以复用用户熟悉的信息架构和交互习惯，但不能复制微信名称、商标、图标、插画、提示音、文案和专有素材，否则存在版权、商标和应用商店审核风险。
2. **首版为单实例自托管。** 不同部署实例之间默认不能互加好友或跨服聊天。跨服务器联邦属于后续独立大版本。
3. **iOS 后台推送无法完全摆脱 Apple Push Notification service。** 自托管服务器仍需由部署者配置 APNs 证书或密钥。
4. **音视频需要公网 UDP、较大带宽和正确的 NAT/TURN 配置。** 只有普通 HTTP 反向代理并不足以保证通话可用。
5. **朋友圈并不天然适合端到端加密。** 首版采用精细可见范围、传输加密和服务端静态加密；真正的朋友圈端到端加密需要另行设计密钥分发和成员变更机制。

## 文档导航

- [需求完善总览](docs/00-需求完善总览.md)
- [产品需求规格书 PRD](docs/01-产品需求规格书-PRD.md)
- [技术架构与模块设计](docs/02-技术架构与模块设计.md)
- [安全隐私与威胁模型](docs/03-安全隐私与威胁模型.md)
- [部署运维与开源交付规范](docs/04-部署运维与开源交付规范.md)
- [API 与数据模型草案](docs/05-API与数据模型草案.md)
- [测试验收与发布标准](docs/06-测试验收与发布标准.md)
- [P0 实时通信 PoC](docs/07-P0实时通信PoC.md)
- [开发实施计划](tasks/plan.md)
- [开发 Todolist](tasks/todo.md)
- [架构决策记录](docs/decisions/)

## 推荐技术路线

- 多端客户端：Flutter，统一覆盖 Android、iOS、Web、Windows、macOS、Linux。
- 管理后台：React + TypeScript，仅用于实例管理员。
- 核心服务端：Go 模块化单体。
- API：REST + OpenAPI；实时事件：WebSocket；音视频：WebRTC。
- 数据：PostgreSQL + Redis + S3 兼容对象存储（默认 MinIO）。
- 音视频：自托管 LiveKit；必要时配置内置 TURN 或外置 coturn。
- 入口：Caddy 或 Nginx。
- 部署：Docker Compose 起步；后续提供 Kubernetes Helm Chart。

## 官方技术依据

- Flutter 支持移动端、桌面端和 Web：
  https://docs.flutter.dev/reference/supported-platforms
- Flutter Web：
  https://docs.flutter.dev/platform-integration/web
- LiveKit 自托管：
  https://docs.livekit.io/transport/self-hosting/
- LiveKit 生产部署和 TURN：
  https://docs.livekit.io/transport/self-hosting/deployment/
- coturn：
  https://github.com/coturn/coturn
- Signal X3DH：
  https://signal.org/docs/specifications/x3dh/
- Signal Double Ratchet：
  https://signal.org/docs/specifications/doubleratchet/
- Signal Sesame 多设备会话管理：
  https://signal.org/docs/specifications/sesame/

## 当前状态

P0 实时通信链路已经完成第一轮验证：

- Go 实时服务端：`/health`、`/version`、`/ws`。
- WebSocket `hello/hello_ack/server_ready/ping/pong/error` 最小协议。
- 可复用 Dart 实时客户端：自动重连、事件游标去重、HTTP 健康检查。
- 正式 Flutter 调试 App：服务器配置、连接控制、Ping/Pong、状态和事件日志。
- 服务端重启后，客户端能够检测断线、自动重连并继续接收事件。
- Go、Dart、Flutter 测试和静态分析已通过。
- Windows Release、Web Release、Android Debug APK 已成功构建。
- 一键检查、重连测试和三端构建脚本已经提供。

当前仍未验证 iOS、macOS、Linux 构建和 Android 真机 UI。详见 [P0 实时通信 PoC](docs/07-P0实时通信PoC.md)。

仍需冻结的高风险决策：

- 项目正式名称与开源许可证。
- 是否要求首个公开版本必须包含私聊端到端加密。
- 是否允许公开注册，还是默认邀请制/管理员审批。
- iOS 推送与 App Store 发布路线。
