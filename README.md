# DD：开源自托管多端即时通讯

> 当前事实快照：2026-08-12 04:xx
>
> 项目路径：`C:\Users\admin\Desktop\复刻微信`

DD 是一个正在收敛中的自托管即时通讯产品。产品方向是：**信息层级与交互克制参考微信；媒体能力、性能、开放性与响应速度参考 Telegram；品牌、图标、提示音和素材保持 DD 原创。**

当前仓库已经不是基础 Demo：账号、联系人、可靠消息、媒体/Sticker、群聊、正式通话、朋友圈、二维码与 Push 主链都已经进入正式代码。项目仍处于 **Alpha/Beta 收敛期**，不能宣称 Stable 1.0 或“商业上线完成”。

> **当前 worktree 还有一个新的 Flutter 全局门禁失败：** 2026-08-12 本轮重新执行 ASCII 短路径 `dart analyze --fatal-infos` 时，`clients/app/lib/features/shell/presentation/main_shell_page.dart:1122` 报 `StickerPanelResult` 不是可见类型；该类型实际定义在 `features/messaging/domain/sticker_models.dart`，当前 Shell 缺少对应可见引用/导入，同时还有 3 个 directive ordering info。服务端 `go test ./...` 当前通过。修掉此 Flutter gate 之前，当前提交不能称 release-green。

## 当前可交付平台

当前仓库实际存在并持续构建的 Flutter 平台：

```text
Windows
Web
Android
```

当前**没有** `clients/app/ios/`、`clients/app/macos/`、`clients/app/linux/` 正式平台工程，因此不能把 Flutter 理论支持写成已经交付。

根目录当前发布物：

```text
DD-Windows.lnk
DD-Android.apk
```

Web 通过 `scripts/start-dd-web.ps1` 启动已构建的 Release 静态文件。

## 已形成的正式主链

| 阶段 | 当前状态 | 主要能力 |
|---|---|---|
| P0 | `IMPLEMENTED` | REST/WebSocket/Realtime、LiveKit/TURN PoC 基础 |
| P2 | `IMPLEMENTED + AUTO-VERIFIED` | 邮箱注册登录、验证码、密码重置、Access/Refresh、设备管理、资料隐私 |
| P3 | `IMPLEMENTED + AUTO-VERIFIED` | DDID、好友申请、联系人、Block、备注/标签/星标 |
| P4 | `IMPLEMENTED + AUTO-VERIFIED` | Durable Outbox、Cursor Sync、未读、编辑/撤回/回复/转发/搜索/置顶/归档 |
| P5 | `IMPLEMENTED / MODULE-AUTO-EVIDENCE / GLOBAL-GATE-PASS` | 图片/GIF/Sticker/文件/语音/视频、缓存、传输中心、Emoji、自定义表情、Telegram Sticker Relay |
| P6 | `IMPLEMENTED / MODULE-AUTO-EVIDENCE / GLOBAL-GATE-PASS / HUMAN-PENDING` | 群聊、角色、审批、群头像、群消息、群昵称、群通话入口 |
| P7 | `IMPLEMENTED / MODULE-AUTO-EVIDENCE / GLOBAL-GATE-PASS / HUMAN-PENDING` | 正式 PostgreSQL Calls、Bearer Principal、多设备接听仲裁、LiveKit token |
| P8 | `IMPLEMENTED / MODULE-AUTO-EVIDENCE / GLOBAL-GATE-PASS / HUMAN-PENDING` | 朋友圈 Feed、9 图/单视频、点赞评论回复、隐私、互动未读与互动焦点 |
| P9 | `IMPLEMENTED / QR-DIRECTED-AUTO-EVIDENCE / GLOBAL-GATE-PASS / HUMAN-PENDING` | 个人码、群二维码、扫码登录 |
| P10 | `IMPLEMENTED / PUSH-DIRECTED-AUTO-EVIDENCE / GLOBAL-GATE-PASS / HUMAN-PENDING` | Push job/Worker、FCM/APNs/UnifiedPush、Flutter token、Android data-only FCM |
| P11 | `OUT-OF-SCOPE` | V1 明确不做 Production E2EE |
| P12 | `PLANNED` | Admin / Abuse / Data Rights |
| P13 | `PARTIAL INFRA` | Production Self-host / Backup / Upgrade / Observability |
| P14 | `PLANNED` | iOS / macOS 正式交付 |

详细状态以 [开发进度跟踪.md](开发进度跟踪.md) 和 [未开发任务.md](未开发任务.md) 为准。

## 2026-08-12 最近收口重点

当前 worktree 已包含以下新实现/修复，均以代码事实为准；没有真人复测的项目仍保持 `FIXED-PENDING-RETEST`：

- Telegram Sticker Relay 已支持静态 WebP/PNG、动态 TGS、视频 WebM；TGS 使用 gzip Lottie 渲染，WebM/MP4 使用静音循环视频 Sticker。
- Telegram Sticker Pack 已有 4 秒静默账号同步，整包分享使用正式 `STICKER_PACK` 消息并携带首个表情真实缩略图。
- 视频 Sticker 已接入持久 `VideoFileCache`，重新打开表情面板不再依赖每次重新完整下载。
- 自定义 Sticker 支持 PNG/WebP/GIF/MP4/WebM，单项上限 64 MiB；失败/取消会释放媒体 reservation。
- Android 大视频选择已改为原生 `ACTION_OPEN_DOCUMENT` + 64 KiB 流式复制到 App cache，针对 100 MiB/500 MiB 级文件选择阶段 Java 堆 OOM 的修复已落代码。
- Android FCM 用户可见消息改为 data-only + HIGH priority，由 DD 自己的通知链统一渲染 sender avatar、DD small icon 与点击导航；头像使用短时 HMAC capability URL，不在 Push payload 放 Access/Refresh Token。
- 朋友圈互动未读已持久化，发现页/桌面 Rail/朋友圈入口显示 `1..99 / 99+`；自己的朋友圈封面下有“互动焦点”，可查看点赞/评论历史。
- 设置已新增“性能”页，包含节能、减少动画、视频自动预览、硬件加速视频解码，并持久化为设备本地设置。
- Windows 系统托盘、联系人详情、Mention 资料悬浮窗、群聊目录分栏、群通话入口、全局 SnackBar/Dialog/Input、Android 文件打开/分享/APK 安装器链等均已有本轮修复和定向测试。

## 关键技术栈

- 客户端：Flutter
- 管理后台：React + TypeScript + Vite
- 服务端：Go 模块化单体
- API：REST + OpenAPI
- 实时：WebSocket + Redis realtime bus
- 数据库：PostgreSQL
- 对象存储：S3 兼容存储（开发默认 MinIO）
- 音视频：LiveKit + TURN/STUN
- Push：FCM HTTP v1 / APNs / UnifiedPush
- 本地开发基础设施：Docker Compose

当前正式 Go 业务包主要包括：

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
```

数据库 migration 当前推进到 `000030_sticker_pack_share`。

## 本地开发

### 启动完整开发环境

```powershell
cd C:\Users\admin\Desktop\复刻微信
powershell -ExecutionPolicy Bypass -File .\scripts\run-auth-dev.ps1
```

停止：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop-auth-dev.ps1
```

脚本会检查 Docker、自动识别本机私网 IPv4、构建 API/Worker/客户端并维护 `.data` 状态。若已有状态文件或关键端口被未知进程占用，脚本会拒绝误杀未知进程。

### 构建客户端

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1 -Target android
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1 -Target windows
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

## 自动门禁

当前 `.github/workflows/ci.yml` 已定义以下门禁结构。2026-08-12 本轮复核已重新通过 ASCII 短路径 `dart analyze --fatal-infos` 与 Flutter 全量测试；workflow 存在仍不等于真实设备/生产环境已经 release-green：

- Go format / `go test ./...` / `go vet ./...`
- migration apply
- Auth / Contacts / Groups / Calls / Messaging / Push PostgreSQL integration
- Redis realtime cross-node integration
- OpenAPI runtime contract + Redocly strict lint
- Admin typecheck/build
- Flutter analyze/test/Web Release/Android Release
- Windows Release + real-engine MP4 poster smoke
- Web/Android/Windows artifact upload

当前仍缺的重要 CI 门禁：

- 独立 Secret Scan
- Moments 指定 PostgreSQL integration step
- QR 指定 PostgreSQL integration step
- iOS/macOS runner
- 真 FCM/APNs 设备级 delivery/click 不适合伪造成普通 CI，需要真实设备/受控环境验收

## 安全边界

1. **V1 不提供端到端加密。** 当前聊天依赖 TLS/WSS、服务端鉴权、私有对象存储和权限控制；服务端在授权边界内仍能读取消息明文，禁止宣传“服务器无法读取消息”。
2. Telegram Bot Token、Firebase service-account、Push provider 密钥等必须通过 `.env` / 私密文件注入，不进入 Git。
3. Push 只负责提醒和唤醒，消息数据库与业务真相仍由 Sync/Calls/Moments API 提供。
4. 媒体下载使用短时授权；Push 头像使用短时 capability URL，不下发用户 Access/Refresh Token。
5. 当前首版仍是单实例优先，不支持跨实例联邦。
6. 公网音视频仍需要正确配置 UDP、TURN/TLS、带宽和 NAT；开发环境通过不等于生产公网通过。

## 文档入口

开发时按以下顺序读：

1. [docs/README.md](docs/README.md) —— 文档中心和事实优先级。
2. [docs/15-当前实现状态与开发路线.md](docs/15-当前实现状态与开发路线.md) —— 当前真实状态与下一步。
3. [开发进度跟踪.md](开发进度跟踪.md) —— 根目录产品/研发快照。
4. [未开发任务.md](未开发任务.md) —— 只列仍缺代码或闭环的事项。
5. 再按任务加载对应专题文档。

主要专题：

- [产品需求规格书](docs/01-产品需求规格书-PRD.md)
- [技术架构与模块设计](docs/02-技术架构与模块设计.md)
- [安全隐私与威胁模型](docs/03-安全隐私与威胁模型.md)
- [部署运维与开源交付规范](docs/04-部署运维与开源交付规范.md)
- [API 与数据模型](docs/05-API与数据模型草案.md)
- [测试验收与发布标准](docs/06-测试验收与发布标准.md)
- [产品体验与 UI / 功能基线](docs/12-产品体验与UI功能基线.md)
- [架构决策记录](docs/decisions/)

## 当前真正剩余的大项

开发主线不再是重做 P6/P7/P8/P9/P10，而是：

```text
修复当前真人回归暴露的问题
→ CI Secret Scan + Moments/QR 指定 PG 门禁
→ P12 Admin / Abuse / Data Rights
→ P13 Production Self-host / Backup / Upgrade / Observability
→ P14 iOS / macOS
```

并行保留 P6/P7/P8/P9/P10 的多端、弱网、真机、长时通话、二维码、Push 和大媒体人工验收债务。
