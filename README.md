# DD：开源自托管 IM

> 当前项目名：DD。项目目标是提供独立、自托管、多端即时通讯能力；**UI 与交互习惯参考微信，功能开放性与能力丰富度参考 Telegram，WhatsApp 不作为产品设计参考**；品牌、图标和素材保持 DD 原创。

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
- [P0 音视频通话 PoC](docs/08-P0音视频通话PoC.md)
- [P0 E2EE 候选库评估](docs/09-P0-E2EE候选库评估.md)
- [P2 账号认证垂直切片](docs/10-P2账号认证垂直切片.md)
- [P3 好友与关系链](docs/11-P3好友关系链.md)
- [产品体验与 UI / 功能基线](docs/12-产品体验与UI功能基线.md)
- [开发进度跟踪](开发进度跟踪.md)
- [当前人工测试](人工测试.md)
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

截至 2026-08-08，项目已经推进到 **P2 正式账号主体完成 + P3 好友关系链主体完成，准备进入 P4 可靠文字消息与同步**。

### P0 已完成当前 Windows / Web / Android 验收批次

- REST / WebSocket 实时通信 PoC 已通过。
- Windows ↔ Web、Windows ↔ Android、Web ↔ Android 音视频人工验收均通过。
- 呼叫、来电、接听、拒绝、取消、45 秒超时、挂断同步均通过。
- Windows / Web / Android TURN relay-only 人工诊断通过。
- TURN/UDP 使用 `3478` 入口和 `30000-30019/udp` relay 范围。
- Android 后台 / 锁屏 / 短时断网恢复、媒体控制、窄屏适配通过本轮人工验收。
- 公网 TURN/TLS、4G/5G 跨运营商、iOS/macOS/Linux 仍属于后续专项。

### P1 工程基础已经形成

仓库已有：

```text
Go: api / worker / migrate
Flutter: Windows / Web / Android
Admin: React + TypeScript
PostgreSQL / Redis / MinIO / Mailpit / LiveKit
OpenAPI / Realtime Schema / Migration / CI
```

### P2 正式账号主体已落地

当前已包含：

- 邮箱验证码、注册事务、Argon2id。
- 登录失败限流和 Auth 安全审计。
- Access / Refresh Token、轮换、Family 重放整族撤销。
- 密码找回 / 重置，成功后撤销全部旧会话。
- `/api/v1/me` 资料和隐私。
- 设备列表、指定设备远程退出、全部退出。
- 被撤销设备的 Access Token 下一次请求立即失效。
- Native `flutter_secure_storage` + App 启动自动恢复。
- Web HttpOnly Cookie + 页面启动自动恢复，不把 Refresh Token 放进 JS 存储。
- Flutter 注册、登录、密码找回、资料、隐私、设备管理 UI。
- PostgreSQL + Mailpit 真实账号生命周期集成测试已进入 CI。

### P3 好友关系链主体已落地

正式关系链现在支持：

- 精确 Handle 搜索，不返回邮箱。
- 好友申请、接受、拒绝、撤销、过期。
- 同向重复申请幂等。
- 双方并发互相申请自动收敛为好友。
- 接受好友时原子创建双向 contacts，并创建/复用 DIRECT conversation。
- 联系人备注、标签、星标。
- 删除好友但保留历史会话语义。
- 拉黑、解除拉黑、取消 PENDING、搜索隐藏和再申请阻断。
- Flutter “搜索 / 申请 / 联系人 / 黑名单”四 Tab 页面。
- PostgreSQL 真库并发集成和 P3 Flutter Widget/API Client 自动测试。

详细设计见 [P3 好友与关系链](docs/11-P3好友关系链.md)。

本地人工验收现在统一使用：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-auth-dev.ps1
```

测试完成：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop-auth-dev.ps1
```

具体只看根目录 [人工测试.md](人工测试.md)，不要重复跑已经归档的 P0/P2/P3 测试。2026-08-08 的 P4 真人验收暴露出的 Web 置顶/免打扰、误已读/红点、回车发送、移动菜单、Android 键盘、Windows 原生窗口、头像大图、通知和聊天内 LiveKit 通话问题，当前修复版已经完成自动回归与 Windows/Web/Android 构建。下一步是**先 stop/start 一次旧 auth-dev，让新版主开发环境启动 LiveKit，再按人工测试文档复测失败项**；Sticker/GIF、图片消息、语音条、独立“已送达”和杀进程 Push 仍属于后续阶段。

详细当前完成度见 [开发进度跟踪.md](开发进度跟踪.md)。

仍需冻结的高风险决策：

- 项目正式名称与开源许可证。
- 是否要求首个公开版本必须包含私聊端到端加密。
- 是否允许公开注册，还是默认邀请制/管理员审批。
- iOS 推送与 App Store 发布路线。
