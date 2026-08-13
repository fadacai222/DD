# DD：开源、自托管、多端即时通讯

> 当前代码快照：2026-08-13
> 当前状态：U30 iOS 已完成本地总集成与自动验证；真实 Xcode/Apple signing/TestFlight/iPhone 验收待完成
> Flutter 客户端版本：`0.4.0+5`
> 项目路径：`C:\Users\admin\Desktop\复刻微信`

DD 是一个正在开发中的**自托管即时通讯系统**。

可以把它理解成：

- 产品交互尽量保持微信那种直接、克制、容易上手；
- 媒体、表情、群聊、通话和多端能力参考 Telegram 的开放性；
- 服务端、数据库、文件、Push、音视频都可以由自己部署和控制；
- Windows、Android、Web、iOS 共用大部分 Flutter 主业务代码；iOS U30 本地 native 总集成已经完成；
- 目标不是做一个聊天 Demo，而是逐步做到可以长期自托管和正式发布的完整 IM 产品。

目前项目已经越过“基础 Demo”阶段，处于 **Alpha/Beta 收敛期**：主要业务主链已经存在，当前重点已经从“把聊天做出来”转向 **iOS 云端 Xcode/签名/TestFlight/真机验收、其他多端真人回归、生产签名、公网音视频和最终发布收口**。

> **注意：当前还不能称 Stable 1.0，也不能因为本地 Docker 能启动、自动测试能通过，就直接认为已经适合生产商用。**

---

## 1. 先给运维看的：现在开发到哪一步了？

| 模块 / 平台 | 当前状态 | 人话说明 |
|---|---|---|
| 服务端核心 | ✅ 已实现并有自动测试 | 账号、好友、聊天、群聊、通话、朋友圈、二维码、Push、后台管理等都已经进入正式代码 |
| Windows | ✅ 主功能已实现 | 可以构建 Release；托盘、窗口、文件、媒体、聊天等已经有正式实现，仍有部分真人回归项 |
| Android | ✅ 主功能已实现 | 可以构建 APK；Firebase Push、大视频、媒体、文件分享等已经接入，仍有部分真机复测项 |
| Web | ✅ 主功能已实现 | 共用 Flutter 主业务代码，可构建 Web Release |
| iOS | 🧪 本地总集成已完成 | iOS 15.0 Runner、Keychain Auth、多账号 Push lease、APNs/FCM、Files/Photos/Camera/QR、LiveKit/CallKit/Audio 和 native Xcode Sources/registrar/AppDelegate 接线已完成并通过本地自动门禁；真实 Xcode、Apple/Firebase Secret、APNs/TestFlight/iPhone 仍待验证 |
| macOS | ⏳ 尚未正式交付 | 当前没有完整 macOS 产品工程和发布验收 |
| 生产部署 | ✅ 代码链已形成 | Production Compose、HTTPS/WSS、TURN、备份恢复、升级回滚、监控告警已有实现 |
| 正式发布 | 🚧 代码链已形成，真人配置未闭环 | GitHub Release、SBOM、Trivy、签名合同、Attestation 已有；真实 JKS/PFX、审批策略和生产发布仍需实际配置 |
| E2EE | ➖ V1 不做 | 当前 V1 明确不提供生产级端到端加密，不应宣传成“服务器看不到消息” |

### 当前真正的开发主线

现在不是从头继续做聊天，而是：

```text
核心 IM 主链已经形成
        ↓
继续收真人回归 Bug
        ↓
iOS U30 Codemagic/Xcode + Apple/Firebase Secret + TestFlight/iPhone 验收
        ↓
Android / Windows / Web / iOS 多端真机验收
        ↓
公网 TURN / Push / 备份恢复 / 告警实测
        ↓
真实生产签名 + GitHub Production Approval
        ↓
Stable 1.0 候选
```

U30 iOS 的本地代码与公共 native 接线已经完成：Push/Media/Calls Swift services 已进入 Runner Sources 和 `NativeServiceRegistrar`，AppDelegate 也保留 Flutter/FlutterFire delegate chain 接好了 APNs/foreground/tap。**但在真实 macOS/Xcode compile/archive、Apple/Firebase Secret、App Store Connect/TestFlight 和 iPhone/iPad 验收完成之前，README 仍不会把 iOS 写成“正式可交付”。**

---

## 2. 已经实现了什么？

下面只列当前仓库里已经有正式代码的主要能力，不把“计划做”写成“已经完成”。

### 账号、登录和设备

已经实现：

- 邮箱注册、登录；
- 邮箱验证码；
- 忘记密码 / 重置密码；
- Access Token + Refresh Token；
- 登录失败限流；
- 当前用户资料；
- 多设备登录；
- 查看设备列表；
- 远程退出单台设备；
- 全部设备退出；
- 密码重置后撤销旧会话；
- Native 客户端多账号保存和切换；
- 账号注销生命周期；
- 用户数据导出生命周期。

普通用户的 TOTP/MFA 和 Passkey/WebAuthn 还没有完成，属于后续扩展。

### 联系人

已经实现：

- DDID；
- 搜索 / 添加联系人；
- 好友申请；
- 接受 / 拒绝；
- 删除好友；
- 拉黑 / 解除拉黑；
- 备注；
- 标签；
- 星标联系人；
- 隐私边界；
- 联系人资料页。

### 消息

已经实现：

- 1 对 1 聊天；
- SELF 自己给自己发送；
- WebSocket 实时消息；
- Durable Outbox；
- Cursor Sync；
- 离线后重新同步；
- 未读数；
- 已读；
- 回复；
- 转发；
- 编辑；
- 撤回；
- 搜索；
- 会话置顶；
- 会话归档；
- 消息免打扰；
- URL 蓝色链接和安全链接预览；
- Windows `Esc` 返回上一层。

简单说：**消息不是只靠 WebSocket“在线发一下”就算完，而是有数据库、Outbox 和 Sync 做可靠性兜底。**

### 图片、视频、文件、语音、表情

已经实现：

- 图片消息；
- GIF；
- 普通文件；
- 语音消息；
- 视频消息；
- 本地媒体缓存；
- 下载 / 打开 / 分享；
- 媒体上传进度与取消；
- Android 大文件流式选择，避免直接把数百 MiB 文件一次性塞进 Java 堆；
- 视频缩略图 / poster；
- 可视区视频自动预览；
- 自定义 Sticker；
- PNG / WebP / GIF / MP4 / WebM Sticker；
- Telegram Sticker Pack 导入；
- Telegram TGS 动态表情；
- Telegram WebM 视频表情；
- Sticker Pack 整包分享；
- 视频 Sticker 持久缓存和 LRU 清理。

当前自定义 Sticker 单项上限为 **64 MiB**。

### 群聊

已经实现正式 PostgreSQL 群组主链：

- 创建群；
- Owner / Admin / Member；
- 邀请成员；
- 踢人；
- 退出群；
- 群主转让；
- 解散群；
- 群名称；
- 群公告；
- 群头像；
- 群昵称；
- 邀请制；
- 入群审批；
- 群消息；
- 群未读；
- 群媒体 / Sticker；
- `@成员`；
- `@all` 权限控制；
- 群通话入口。

群聊代码已经不是内存 Demo，但 500 人边界、弱网和长时间多端运行仍要继续真人压测。

### 语音 / 视频通话

已经实现正式 Calls 主链：

- PostgreSQL 通话状态机；
- `/api/v1/calls` 正式 API；
- Bearer 鉴权；
- LiveKit Token；
- 1 对 1 语音 / 视频；
- 多设备同时响铃；
- 第一台设备接听后仲裁；
- 其他设备失去控制权；
- busy / reject / timeout / end；
- 好友关系和 Block 权限校验；
- 通话记录回写会话；
- 群通话基础产品链。

底层媒体传输依赖 **LiveKit + WebRTC + TURN/STUN**。

本地能打通不代表公网一定能打通。生产环境必须继续验证 UDP、防火墙、NAT、TURN/TLS、跨运营商和移动网络切换。

### 朋友圈

已经实现：

- Feed；
- 纯文字；
- 最多 9 图；
- 单视频；
- 视频 poster；
- 可视区静音循环预览；
- 点赞 / 取消点赞；
- 评论；
- 回复评论；
- 删除评论；
- 删除动态；
- 联系人可见；
- 私密；
- 排除指定联系人；
- “不看他”；
- “不让他看”；
- Block 联动；
- 朋友圈互动未读数字角标；
- “谁点赞 / 谁评论”的互动焦点；
- 私有朋友圈媒体授权。

### 二维码

已经实现：

- 个人二维码；
- 群二维码；
- 群邀请二维码过期 / 撤销 / 使用限制；
- 扫码登录；
- 登录确认；
- 跨设备登录状态流转。

仍需继续做 Android 真相机、PC/Web 扫码登录等真人验收。

### Push 通知

服务端已经有完整 Push Domain 和异步任务链：

- Push endpoint；
- 用户通知偏好；
- durable Push Job；
- Worker 重试 / backoff / dedupe；
- INVALID endpoint；
- FCM HTTP v1；
- APNs provider；
- UnifiedPush；
- 好友申请 Push；
- 普通消息 Push；
- 来电 Push；
- 群通话 Push；
- 朋友圈互动 Push；
- Android data-only FCM；
- 自定义 sender avatar；
- DD small icon；
- 点击通知恢复对应会话；
- Push provider 指标和告警。

注意：**provider 返回 HTTP success 只能说明 Push 服务商接受了请求，不能证明手机一定展示通知。** 所以 Android FCM 和 iPhone APNs 仍保留真实设备验收项。

### 管理后台和治理

已经实现独立 Admin 身份体系：

- Admin 登录；
- 独立 Admin Security Secret；
- Admin TOTP MFA；
- Recovery Code；
- RBAC；
- CSRF；
- 用户治理；
- 举报；
- 审计；
- 普通用户 Bearer Token 不能直接进入 Admin API。

### 数据权利

已经实现：

- 用户发起数据导出；
- 导出状态；
- 异步生成；
- 短时授权下载；
- 导出过期；
- 账号注销申请；
- 冷静期；
- 取消注销；
- Token / Device / Push 撤销；
- 共享数据匿名化；
- 对象存储清理 Worker 生命周期。

---

## 3. 底层到底用了什么技术？

如果你是普通运维，可以先看这张表：

| 层 | 技术 | 它负责什么 |
|---|---|---|
| 用户客户端 | Flutter + Dart | Windows / Android / Web / iOS 共用大部分 UI 和业务逻辑 |
| Android 原生桥 | Kotlin | 文件选择、系统分享、安装 APK、通知等系统能力 |
| Windows 原生桥 | C++ / Win32 | 窗口、托盘、系统通知等桌面能力 |
| iOS 原生桥 | Swift | iOS 15.0 Runner 已接 Push/APNs、Files/Photos/Camera、Media、CallKit/Audio 等 native services，并统一通过 `NativeServiceRegistrar` 接入 |
| 服务端 | Go | 登录、联系人、消息、群聊、朋友圈、二维码、Push、管理等业务 API |
| API | REST + OpenAPI | 客户端与服务端之间的正式接口合同 |
| 实时通信 | WebSocket | 在线消息和实时事件 |
| 主数据库 | PostgreSQL | 用户、消息、群组、通话、朋友圈等核心业务数据 |
| 实时总线 / 缓存 | Redis | 多节点 realtime bus 等实时辅助能力 |
| 文件存储 | S3 兼容对象存储 | 图片、视频、文件、头像等；本地开发默认可用 MinIO |
| 音视频 | LiveKit + WebRTC | 语音 / 视频媒体会话 |
| NAT 穿透 | TURN / STUN | 解决不同网络、NAT、防火墙下的通话连接问题 |
| Android Push | Firebase Cloud Messaging | Android 系统通知唤醒和提醒 |
| iOS Push | APNs | iPhone 系统 Push |
| 后台异步任务 | Go Worker | Push、数据导出 / 注销等需要后台持续处理的任务 |
| 管理后台 | React + TypeScript + Vite | Admin 管理界面 |
| 指标 | Prometheus client | 暴露 API / DB / Redis / Push / Worker 等指标 |
| 可视化 | Grafana | 看监控图表 |
| 外部探测 | Blackbox Exporter | 探测 HTTP / TCP 等服务可用性 |
| 部署 | Docker Compose | 开发和生产自托管组件编排 |
| HTTPS 入口 | Caddy / HAProxy | TLS、反向代理和生产入口 |
| CI | GitHub Actions | 测试、构建、Secret Scan、Release |
| iOS CI | Codemagic | 配置 unsigned Release compile + unsigned archive，以及正式 signed IPA/App Store Connect workflow；真实云运行/Apple Secret 仍待提供 |

### 为什么服务端不是一堆微服务？

DD 当前服务端采用的是**模块化单体 + 独立 Worker**。

也就是说：业务代码内部按模块拆开，但 API 主体仍然主要编译成一个 Go 服务，而不是为了“看起来高级”拆成几十个微服务。

对于自托管运维，这样更实际：

- 服务数量少；
- 部署简单；
- 日志容易查；
- 数据一致性更好处理；
- 小规模和中等规模不需要先承担微服务运维成本。

主要 Go 模块当前包括：

```text
auth
contacts
groups
calls
messaging
moments
media
stickers
qrcode
realtimebus
realtimev1
push
admin
datarights
observability
```

---

## 4. 一条消息到底是怎么走的？

普通文字消息大致可以理解成：

```text
Windows / Android / Web / iOS
            │
            │ REST / WebSocket
            ▼
        Go API Server
            │
      ┌─────┼───────────┐
      │     │           │
      ▼     ▼           ▼
PostgreSQL Redis    Object Storage
  消息事实  实时事件     图片/视频/文件
      │
      ▼
 Durable Outbox
      │
      ├── WebSocket 实时投递
      │
      └── Push Job → Worker → FCM / APNs / UnifiedPush
```

关键点：

1. **数据库是消息事实源。** WebSocket 断了以后还能靠 Sync 补回来。
2. **Push 不是消息数据库。** Push 只负责提醒 / 唤醒。
3. **图片视频不直接塞数据库。** 文件主体进入 S3/MinIO，对应权限和元数据进入业务系统。
4. **异步任务走 Worker。** 不让 API 请求一直卡着等 Push、导出之类慢操作。

---

## 5. 语音 / 视频通话怎么走？

```text
客户端
  │
  ├── Go API：创建通话、鉴权、状态机、生成 LiveKit Token
  │
  └── LiveKit / WebRTC：真正传输音频和视频
             │
             └── TURN/STUN：在复杂 NAT / 防火墙网络下辅助建立连接
```

所以排查通话问题时要分清：

- API 创建通话失败；
- LiveKit Token 失败；
- WebSocket / Realtime 状态失败；
- ICE 候选失败；
- UDP 被挡；
- TURN/TLS 不通；
- 客户端麦克风 / 摄像头权限失败。

不能看到“通话失败”就只查一个服务。

---

## 6. 当前数据库进度

数据库 migration 当前到：

```text
000033_data_rights
```

近期关键 migration：

```text
000017_groups
000018_calls
000019_moments
000021_qr
000022_push
000026_push_product_chain
000027_custom_sticker_video
000028_moment_activity
000029_telegram_sticker_dynamic_video
000030_sticker_pack_share
000031_admin_auth
000032_admin_governance
000033_data_rights
```

迁移采用 **forward-only** 思路：已经发布 / 应用过的 migration 不应回头修改 checksum。新结构继续增加新的 migration。

---

## 7. 当前项目目录怎么理解？

```text
复刻微信\
├─ clients\app\          Flutter 主客户端
│  ├─ lib\               主要业务 UI / 状态 / API 客户端
│  ├─ android\           Android 原生工程
│  ├─ windows\           Windows 原生工程
│  ├─ web\               Web 工程
│  └─ ios\               iOS Runner / 当前适配中的平台工程
│
├─ server\               Go 服务端
│  ├─ cmd\api\           API 服务
│  ├─ cmd\worker\        后台 Worker
│  ├─ cmd\migrate\       数据库迁移工具
│  ├─ cmd\adminctl\      Admin CLI
│  ├─ internal\           业务模块
│  └─ migrations\        PostgreSQL migration
│
├─ admin\                React 管理后台
├─ infra\dev\            本地开发基础设施
├─ infra\prod\           生产自托管部署
├─ infra\observability\  Prometheus / Grafana / Blackbox 等监控
├─ scripts\               Windows / CI / 构建 / 运维脚本
├─ release\               Release 合同和发布相关文件
├─ docs\                  产品、架构、运维、安全、测试文档
├─ .github\workflows\    CI / Secret Scan / Release
├─ codemagic.yaml         iOS macOS Runner 构建验证
├─ DD-Android.apk         当前根目录 Android 快捷产物
└─ DD-Windows.lnk         Windows 快捷入口
```

---

## 8. 本地开发怎么启动？

### 启动完整开发环境

```powershell
cd C:\Users\admin\Desktop\复刻微信
powershell -ExecutionPolicy Bypass -File .\scripts\run-auth-dev.ps1
```

停止：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop-auth-dev.ps1
```

脚本会处理本地开发需要的主要组件，并维护 `.data` 状态。已有 `infra/dev/.env` 会原地升级：保留原开发凭据，并自动补齐后来新增的必需配置（包括独立的 `ADMIN_SECURITY_SECRET`），不需要为了升级配置使用 `-Force` 全量轮换。

如果 API/Worker 启动失败，失败轮次的 `.data/dd-auth-dev-*.out.log` / `.err.log` 会保留下来供排障；下一次启动前才会清理旧日志。如果关键端口被未知进程占用，不应直接“强杀所有同名进程”；现有脚本会尽量避免误杀未知进程。

### 构建客户端

Android：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1 -Target android
```

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1 -Target windows
```

Web：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1 -Target web
```

发布根目录快捷产物：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\publish-client-artifacts.ps1
```

Android 一键更新：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\update-android-client.ps1
```

---

## 9. 生产环境大概需要哪些东西？

最少需要理解这些角色：

```text
Caddy / HAProxy
      │
      ▼
   DD API ───── PostgreSQL
      │
      ├──────── Redis
      │
      ├──────── S3 / MinIO
      │
      ├──────── LiveKit / TURN
      │
      └──────── Worker → FCM / APNs
```

生产部署代码主要在：

```text
infra/prod/
```

当前已经包含：

- Production Compose；
- HTTPS / WSS；
- Caddy / HAProxy；
- LiveKit embedded TURN；
- MinIO / external S3；
- backup；
- restore；
- restore drill；
- upgrade；
- rollback；
- compatibility drill；
- production preflight；
- secrets 目录约定。

**仍然必须由真实生产环境补齐：**

- 公网域名；
- TLS 证书；
- 防火墙；
- UDP / TURN 端口；
- Firebase / APNs 凭据；
- Android JKS；
- Windows PFX；
- iOS signing / provisioning；
- GitHub Environment reviewer；
- 真实备份介质；
- 真实告警接收人。

---

## 10. 监控现在能看到什么？

当前已经有 Prometheus-compatible 指标和生产 observability overlay。

覆盖的主要方向包括：

- HTTP 请求数量；
- API 延迟；
- HTTP 状态码 / 错误率；
- active requests；
- PostgreSQL 连接池；
- PostgreSQL 查询错误；
- Redis 连接 / 重连；
- WebSocket 连接数；
- realtime publish failure；
- Outbox backlog；
- Push queued / running / retry / failed；
- Push invalid endpoint ratio；
- FCM / APNs provider failure；
- 对象存储延迟 / 错误；
- SMTP failure；
- Worker health；
- LiveKit / TURN listener 探测；
- 主机磁盘等基础资源。

相关目录：

```text
server/internal/observability
infra/observability
```

当前已有一组带持续时间判断的正式告警规则，避免瞬时毛刺就疯狂报警。

---

## 11. CI / Release 已经做到哪？

当前 GitHub Actions：

```text
.github/workflows/ci.yml
.github/workflows/secret-scan.yml
.github/workflows/release.yml
```

主要门禁已经覆盖：

- Go format；
- `go test ./...`；
- `go vet ./...`；
- PostgreSQL migration / integration；
- Auth / Contacts / Groups / Calls / Messaging / Moments / QR / Push 等测试；
- Redis realtime cross-node；
- OpenAPI runtime contract；
- Redocly strict lint；
- Flutter analyzer；
- Flutter tests；
- Web build；
- Android build；
- Windows build；
- Secret Scan；
- 完整 Git 历史 Gitleaks；
- Release source exact-SHA gate；
- SHA-256；
- SPDX SBOM；
- Trivy；
- Sigstore / GitHub Attestation；
- Android / Windows production signing contract；
- Production Environment approval；
- rollback artifact retention。

iOS 当前另外有：

```text
codemagic.yaml
```

用于 macOS Runner 上的 Flutter analyze / test、`flutter build ios --release --no-codesign`、unsigned Release archive，以及受保护的 signed IPA / App Store Connect 发布链。Codemagic 还会在 Apple publishing 前验证 resolved-native dependency evidence 并执行 Syft/Trivy fail-closed gate。

> CI 绿灯只能证明“自动门禁范围内通过”，不能替代摄像头、通知、真实 APNs/FCM、公网 TURN、DPI、系统分享、安装器等真人设备能力。

---

## 12. 当前还没完成什么？

### 仍需要开发

当前明确还没有完整闭环的主要功能：

- iOS 云端 Xcode compile/archive、Apple/Firebase Secret、signed IPA / App Store Connect / TestFlight 和真机发布闭环；
- macOS 正式客户端；
- 普通用户 TOTP/MFA；
- Passkey / WebAuthn；
- 地图 / 定位消息；
- 定时发送；
- 频道；
- 完整多语言 i18n；
- 全服务器搜索。

其中后五项属于扩展 backlog，不一定阻塞 V1。

### 代码有了，但还需要真人验收

主要包括：

- Android FCM 前台 / 后台 / 杀进程；
- iPhone APNs Sandbox/Production、通知点击、Camera/Photos/Files/QR、Keychain 多账号、CallKit/Bluetooth/锁屏后台/网络切换；
- Android 100 MiB / 500 MiB 大视频；
- Telegram TGS / WebM Pack；
- Windows 托盘 / Alt+F4 / DPI / Resize；
- 500 人群聊边界；
- 弱网群聊同步；
- 30 分钟真实语音 / 视频通话；
- Wi-Fi ↔ 移动网络切换；
- Android 真相机扫码；
- PC / Web 扫码登录；
- 朋友圈真实大媒体连续发布；
- 公网 TURN / TLS；
- 生产规模备份恢复 RPO / RTO；
- 真实 Prometheus 告警接收；
- Admin 正式初始化和 MFA 恢复码保管；
- Data Rights 真实用户生命周期；
- 正式 Android / Windows / iOS 生产签名；
- GitHub Production Required Reviewers；
- 一次完整正式 tag release。

所以当前最准确的描述是：

> **核心功能已经基本进入正式代码，工程化和生产基础也已经形成；现在最大的债务不是“功能完全没写”，而是真实多端、真实网络、真实签名、真实生产环境的最后验收。**

---

## 13. 安全边界必须说清楚

1. **V1 没有 Production E2EE。**
   - 传输使用 HTTPS / WSS / TLS；
   - 服务端做鉴权和对象权限控制；
   - 但服务端在授权边界内仍然可以读取消息明文。

2. **不要把 Token 放进 Push payload。**
   - 当前 Push 头像使用短时 capability URL；
   - Access Token / Refresh Token 不应进入 FCM/APNs payload。

3. **敏感凭据不能进 Git。**
   - Telegram Bot Token；
   - Firebase service account；
   - APNs key；
   - JKS / PFX；
   - 数据库密码；
   - S3 Secret；
   - Admin Security Secret。

4. **公网通话必须认真做网络层。**
   - UDP；
   - NAT；
   - TURN/TLS；
   - 防火墙；
   - 带宽；
   - 跨运营商。

5. **当前架构优先自托管单实例 / 单集群。**
   - 不是跨实例联邦协议；
   - 也不是 Matrix 那种 Federation 模式。

---

## 14. 开发阶段编号怎么理解？

内部文档仍使用 P 阶段编号：

| 阶段 | 内容 | 当前判断 |
|---|---|---|
| P0 | Realtime / 通话 PoC 基础 | 已完成基础 |
| P2 | Auth / User / Device | 主链已完成；普通用户 MFA/Passkey 待扩展 |
| P3 | Contacts | 主链已完成 |
| P4 | Messaging / Outbox / Sync | 主链已完成 |
| P5 | Media / Voice / Video / Sticker | 主链已完成，继续真人回归 |
| P6 | Groups | 已实现 + 自动验证，真人验收中 |
| P7 | Formal Calls | 已实现 + 自动验证，公网真人验收中 |
| P8 | Moments | 已实现 + 自动验证，真人验收中 |
| P9 | QR | 已实现 + 自动验证，真人验收中 |
| P10 | Push | 服务端和 Android 主链已实现，真实设备验收中 |
| P11 | E2EE | V1 明确不做 |
| P12 | Admin / Governance / Data Rights | 主链已完成 |
| P13 | Production Self-host / Release | 代码闭环基本形成，生产真人验收中 |
| P14 | iOS / macOS | iOS U30 `LOCAL-AUTO-VERIFIED / CLOUD-SECRET-HUMAN-PENDING`；macOS U31 尚未正式交付 |

---

## 15. 文档从哪里看？

开发和排障建议按这个顺序：

1. [docs/README.md](docs/README.md)
   文档中心、事实优先级和状态定义。

2. [docs/15-当前实现状态与开发路线.md](docs/15-当前实现状态与开发路线.md)
   当前真实做到哪、哪里坏、下一步先做什么。

3. [开发进度跟踪.md](开发进度跟踪.md)
   产品和研发进度快照。

4. [未开发任务.md](未开发任务.md)
   仍未开发或没有正式闭环的事项。

5. 专题文档：

- [产品需求规格书](docs/01-产品需求规格书-PRD.md)
- [技术架构与模块设计](docs/02-技术架构与模块设计.md)
- [安全隐私与威胁模型](docs/03-安全隐私与威胁模型.md)
- [部署运维与开源交付规范](docs/04-部署运维与开源交付规范.md)
- [API 与数据模型](docs/05-API与数据模型草案.md)
- [测试验收与发布标准](docs/06-测试验收与发布标准.md)
- [产品体验与 UI / 功能基线](docs/12-产品体验与UI功能基线.md)
- [架构决策记录](docs/decisions/)

---

## 16. 最后用一句话概括

如果你是第一次接手 DD 的运维，可以先这样理解：

> **DD 现在已经有一套完整度较高的自托管 IM 主体：Flutter 做多端客户端，Go 做业务服务，PostgreSQL 存业务事实，Redis 做实时辅助，S3/MinIO 存媒体，LiveKit/TURN 负责音视频，FCM/APNs 负责系统 Push，Docker Compose 负责部署，Prometheus/Grafana 负责监控。iOS U30 本地总集成也已经完成；现在主要债务是云端 Xcode/Apple signing/TestFlight、真实多端/公网网络/Push 和生产发布的最后验收。**
