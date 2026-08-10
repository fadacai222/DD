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

截至 2026-08-09，项目已经推进到 **P4 可靠消息/同步主链基本形成 + P5 私有媒体主链持续收口**，当前重点不是继续堆大模块，而是把 Android / Windows / Web 的真人交互、媒体缓存、Saved Messages、自聊/直聊、通知、通话与商业客户端细节验收关闭。

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
- 最近 5 个历史登录账号（头像/昵称/DDID/邮箱）、切换账号、资料自动保存。
- Windows 单实例 + Native 安全存储串行化/Auth bundle，Access Token 401 单飞刷新并重试。
- PostgreSQL + Mailpit 真实账号生命周期集成测试已进入 CI。

### P3 联系人关系链主体已落地

正式关系链现在支持：

- 精确 DDID 搜索（底层 API 字段仍兼容 `handle`），不返回邮箱。
- 好友申请、接受、拒绝、撤销、过期。
- 同向重复申请幂等。
- 双方并发互相申请自动收敛为好友。
- 接受好友时原子创建双向 contacts，并创建/复用 DIRECT conversation。
- 联系人备注、标签、星标。
- 删除好友但保留历史会话语义。
- 拉黑、解除拉黑、取消 PENDING、搜索隐藏和再申请阻断。
- Flutter 联系人正式信息架构：新的朋友、标签、联系人分组、资料详情、添加朋友与黑名单管理；桌面端为通讯录目录 + 详情双栏。
- 好友关系现在用于联系人管理；非好友知道 DDID 也能直接私聊，Block 才阻断新消息。
- PostgreSQL 真库并发集成和 P3 Flutter Widget/API Client 自动测试。

详细设计见 [P3 好友与关系链](docs/11-P3好友关系链.md)。

### P4 / P5 当前在制主链

当前工作树已包含：

- PostgreSQL sequence + Durable Outbox + Sync cursor + Redis 跨节点唤醒 + pending 幂等重试。
- 未读/已读可见性、不限时撤回、回复定位、全局文本搜索。
- 会话归档、最多 10 个置顶、Android 左右滑快捷操作。
- `我的收藏` 唯一 SELF 自聊、普通消息收藏复制、单目标转发、会话内消息置顶。
- IMAGE / GIF / STICKER / FILE / VOICE 真实消息链；文件流式上传/下载；Windows 拖拽确认。
- 图片/GIF/Sticker/语音按 `userId + mediaId` 隔离的 512 MiB 本地持久化媒体缓存。
- 新的朋友关系 Outbox/实时刷新与好友接受 SYSTEM 消息。

这些能力以“代码已实现 / 待真人关闭”为主，不等于当前批次已经全部人工通过。完整状态看 `开发进度跟踪.md` 和 `人工测试.md`。

本地人工验收现在统一使用：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-auth-dev.ps1
```

测试完成：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop-auth-dev.ps1
```

具体只看根目录 [人工测试.md](人工测试.md)，不要重复跑已经归档的 P0/P2/P3 测试。当前代码已经进一步加入：DDID 非好友直接私聊（好友审批不再是聊天前置，Block 才是硬阻断）、Android 会话左右滑、Telegram 式唯一 `我的收藏` SELF 自聊、归档/最多 10 个置顶、转发/消息置顶/全局搜索、历史登录/切换账号、关系实时刷新、图片/GIF/Sticker/文件/语音真实媒体链与本地持久化缓存。**这些最新在制改动仍要按人工测试文档做 Windows/Android 跨端关闭，不能因为代码存在就写成真人已通过。** 独立“已送达”、完整 SQLite、本地剪贴板媒体发送、杀进程可靠 Push、正式 P7 通话持久化、公网 TURN/TLS 等仍未完成。

详细当前完成度见 [开发进度跟踪.md](开发进度跟踪.md)。

仍需冻结的高风险决策：

- 开源许可证最终选择（项目产品名已统一为 **DD**）。
- 是否要求首个公开版本必须包含私聊端到端加密。
- 是否允许公开注册，还是默认邀请制/管理员审批。
- iOS 推送与 App Store 发布路线。
