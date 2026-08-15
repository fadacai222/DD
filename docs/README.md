# DD 文档中心｜开发唯一入口

> 更新时间：2026-08-15（Wave2 已集成至 `6ac4e6e`；Admin Telegram Relay 已提交；Wave3 真人修复待复测）
>
> 适用仓库：`C:\Users\admin\Desktop\复刻微信`
>
> 本目录是 **DD 后续开发的主规格、状态与架构入口**。任何新功能、Bug 修复、接口、migration、客户端能力或发布门禁变化，都必须在同一轮开发中同步这里。

---

## 1. 事实优先级

遇到“文档、旧 Todo、历史对话、测试结果与代码冲突”时，按以下顺序判断：

1. **当前工作区源代码、runtime route、数据库 migration、当前自动测试/构建结果**。
2. **本文件 + `15-当前实现状态与开发路线.md`**。
3. `01-产品需求规格书-PRD.md` 与对应专题规格。
4. `decisions/` ADR。
5. 根目录开发进度、人工测试、Bug 清单。
6. `tasks/*.md`、归档需求与旧对话，只作为历史输入。

如果代码已经改变而 docs 没变，**代码是事实，docs 必须立即追平**；如果代码存在但当前门禁失败，禁止继续沿用上一轮 `AUTO-VERIFIED` 状态。

---

## 2. 统一状态模型

| 状态 | 含义 |
|---|---|
| `IMPLEMENTED` | 当前代码已经存在对应实现。 |
| `AUTO-VERIFIED` | 当前代码已有可重复自动测试/build/contract gate 证明主要路径。 |
| `HUMAN-PASS` | 目标真实平台已人工验收通过。 |
| `FIXED-PENDING-RETEST` | 真人曾报失败，代码已有针对性修复，但真人未复测。 |
| `KNOWN-FAILURE` | 当前代码、测试、构建或真实客户端仍存在已知失败。 |
| `IN-PROGRESS` | 已开始实现，但还没有形成可验收闭环。 |
| `PLANNED` | 规格已定义，当前代码尚未实现。 |
| `OUT-OF-SCOPE` | 当前阶段明确不做。 |

**硬规则：** `IMPLEMENTED` ≠ `AUTO-VERIFIED` ≠ `HUMAN-PASS`。

---

## 3. 2026-08-15 当前一句话状态

DD 已从基础 IM 进入大功能扩展后的收敛阶段。2026-08-13 U30 iOS 五条并行支线已经在独立总集成 worktree 合流：iOS 15.0 Platform Foundation、Push/APNs/Auth lease、Media/File/Camera/QR、LiveKit/CallKit/Audio 和 Release/Codemagic 已完成公共 Xcode Sources/`NativeServiceRegistrar`/AppDelegate 接线。本地总门禁为 `dart analyze --fatal-infos` 0 issue、iOS/Push/Media/QR/Calls 定向合同持续通过、Flutter 459 PASS / 5 SKIP、Go test/vet PASS、PostgreSQL 18.4 的 33 migrations + Auth/Push integration PASS、Release/native scan pipeline 与 full-history Secret Scan PASS。**这仍不等于产品 release-green**：真实 macOS/Xcode compile/archive、Apple/Firebase Secret、APNs/TestFlight/iPhone/iPad，以及 Android/Windows 历史真人回归、公网网络、生产签名与 Environment reviewer 仍需项目所有者或真人环境验收。

### 2026-08-15 Wave2 / Wave3 收敛状态

Wave1 已物理合流并继续形成 Wave2 集成分支 `integrate/2026-08-14-wave2 @ 6ac4e6e6c2d37a234cde3219bb4ce5685a0c5298`。Wave2 包含 viewer-relative 备注名、durable group mentions、Voice 播放/STT foundation、Windows clipboard image adapter 与 iOS Live Photo paired media；全量门禁曾达到 Flutter 525 PASS / 5 条件 SKIP / 0 FAIL、analyzer 0、Go test/vet PASS、Windows Release 与 Android Debug 构建 PASS。

2026-08-14 真人复测后，Wave3 单写者已针对聊天热点继续修复：备注保存后刷新会话事实、群昵称弹窗 `_dependents.isEmpty` 红屏、置顶会话透明导致快捷按钮透出、语音转文字改成长按菜单，以及 Android 来电通知的 CALL channel / full-screen intent。当前客户端自动证据为 Flutter 530 PASS / 5 条件 SKIP / 0 FAIL、analyzer 0，相关 server 定向 test/vet PASS；这些仍统一属于 `FIXED-PENDING-RETEST`，不能冒充真人通过。

当前真人阻塞仍包括：Android 真后台 Push、语音转文字 provider、群通话生产链。生产环境已补入 `dd-chat-3701e` 的 FCM service-account secret，LiveKit runtime secret 校验通过；STT endpoint/model 仍为空，生产 API/Worker 仍需从 `0.4.0-cloud.3` 升级到 Wave2 代码后再复测。Admin Telegram Sticker Relay 已在 `master` 提交为 `195eae7`，另有 `integrate/2026-08-15-admin` 用于把该能力接到 Wave2 基线。

当前功能主体：

- P0/P2/P3/P4/P5 主链已经形成账号、联系人、DIRECT/SELF 消息、媒体、Sticker、可靠同步和多端客户端；
- **P6 Group** 已有正式 PostgreSQL domain、HTTP/OpenAPI、Flutter 创建/聊天/群详情和自动测试；
- **P7 Calls** 已从实验内存 CallStore 正式化为 `server/internal/calls` + PostgreSQL 状态机 + `/api/v1/calls` + Bearer Principal + 多设备接听仲裁；
- **P8 Moments** 已有朋友圈 Feed、最多 9 图/单视频、点赞评论/回复、单条可见范围、长期隐私偏好和私有媒体授权；2026-08-12 新增服务端持久互动未读与发现页 `1..99 / 99+` 红色数字角标，Push 不再是未读事实源；同日 `GET /api/v1/moment-activity` 扩展最近 30 条互动明细，自己的朋友圈封面下方新增“互动焦点”，点开可查看最近谁点赞/评论、评论正文与时间，已读后历史仍保留；
- **P9 QR** 服务端与 Flutter 主链已完成主体收口；2026-08-11 的 QR 定向证据为 4 个测试文件 10/10、Windows/Web/Android 构建成功。本轮 Shell/Sticker 类型可见性 analyzer 回归已修复；真人扫码与多端设备验收仍未完成；
- **P10 Push** 主体代码已形成正式闭环：`internal/push`、HTTP API、durable job、Worker、FCM/APNs/UnifiedPush provider、Flutter token 注册/偏好/UI 均已实现并自动验证；U08 生产运维层也已补齐 provider 指标/认证失败分类、backlog/invalid ratio、INVALID endpoint 30 天后分批清理、credential rotation/排障 runbook 与正式告警；Android Firebase 项目已正式接入，真实 FCM 服务账号可被 Worker 成功加载；2026-08-12 修复后台系统托盘绕过 DD 自定义通知链导致“只有首字母头像/小标错误”的问题：Android FCM 改为 data-only，后台 handler 统一用 MessagingStyle 渲染，服务端下发 24h HMAC 签名 sender-avatar capability（HIDDEN 预览不下发），本地通知点击可恢复会话；2026-08-14 进一步加固 Android 杀进程链：Firebase 初始化先于 background handler 注册，killed isolate 改走独立最小通知初始化/显示路径，失败写固定分类诊断且不记录 token/正文/账号或会话 ID，Android 前台设置页可直接区分应用通知权限与 `dd_messages_v2` 频道是否被关闭。当前状态 `FIXED-PENDING-RETEST`，仍需最新 APK 真机复测前台/后台/最近任务划掉/系统回收；Android Force Stop 属于系统 stopped-package 语义的对照组，不能由 App 绕过；iPhone APNs delivery 也仍是 `HUMAN-PENDING`；
- **P5 Sticker/Media 本轮收口**：自定义 Sticker 支持 PNG/WebP/GIF/MP4/WebM（单项 ≤64 MiB），从 Telegram Pack/已收到消息加入个人库时同时允许 TGS；Telegram Pack Relay 现完整覆盖静态 WebP/PNG、动态 TGS 与视频 WebM，TGS 由 Flutter Lottie gzip decoder 循环渲染，WebM 复用静音循环视频 Sticker 播放链；失败/取消/重试上传会立即释放 reservation；2026-08-12 TG 表情包整包分享进一步改为正式 `STICKER_PACK` 消息：服务端强制取该包排序第一项作为 PRIMARY 预览媒体并生成 `dd://stickers/telegram/...` 导入元数据，接收方即使尚未添加该包也能看到真实首个表情缩略图，转发后仍保留缩略图与导入能力；同时保留面板 4 秒静默账号同步和真实 16 MiB GIF 流式回归，并修复“视频自定义表情刚上传可播、关闭再打开候选格永久转圈”的 BottomSheet 入场可见性回归。视频 Sticker 现不再只依赖临时签名 URL：首次加载会进入 DD 的 `VideoFileCache` 持久缓存，聊天气泡、候选格和分享预览跨面板复用本地文件；缓存受统一容量预算/LRU 和 30 天年龄约束。地址解析/播放器打开超过 15 秒则进入可重试失败态并记录客户端日志，不再无限转圈。
- **需求0812 性能/稳定性收口**：性能页提供节能模式、减少动画、视频自动预览与硬件加速视频解码；本轮已把 `外观 / 聊天背景 / 媒体与缓存 / 性能 / 传输中心` 从内层设置迁移到“我的”外层，并把原“账号、隐私与设备”收敛为“隐私与设备”。2026-08-12 Android 真机再次复现大视频闪退后，ADB Logcat 已把根因定位到文件选择返回阶段 Java 堆 OOM：约 128 MiB / 503 MiB 样本分别触发同量级整块内存申请，而进程堆增长上限约 256 MiB。聊天相册、文件和自定义表情 Android 选择入口现改为 DD 原生 `ACTION_OPEN_DOCUMENT`，在后台以 64 KiB 缓冲流式复制到 App cache，仅向 Dart 返回路径/元数据；后续继续使用原生缩放 poster + `uploadStream`，不再在选择阶段把整文件 materialize 成 `byte[]`。新增大文件选择合同测试通过、相关 Dart analyzer 0 issue，仓库标准 Android Debug APK 已重新构建成功；状态为 `FIXED-PENDING-RETEST`，仍需真人用同一 100 MiB/500 MiB 级样本复测。Telegram 表情包分享计时器用例已改为有界 pump，`text_chat_page_test.dart` 当前 39/39 全绿。
- **需求0812 账号/表情/链接新增**：删除独立“刷新登录会话 / 切换账号”入口，新增“账号管理”；Native 客户端按 `origin + userId` 在安全存储中保存最多 8 个独立 Refresh Token 槽位，已有有效会话可直接切换，失效槽位回落密码登录，“添加账号”进入登录页但不撤销原账号。发现页“更多能力”替换为“表情”，复用现有自定义 Sticker + Telegram Pack 管理链。文本消息中的 HTTP/HTTPS URL 现为蓝色可点击实体，每条消息首链接可加载服务端 `/api/v1/link-preview` 元数据卡，点击文字或卡片交给系统外部浏览器/处理器；服务端预览强制鉴权并拦截私网/回环/链路本地/危险端口/不安全重定向，限制 5 秒、512 KiB HTML。Windows 窗口层新增全局 `Esc` 返回上一层：局部 Escape 处理优先，未被消费时根 Navigator `maybePop`，主导航根层不退出/不缩托盘。Native 多账号、链接 UI/客户端和服务器均有自动回归；Web 不持久化多份 Refresh Token，因此直接切换会话仍按 Web 安全模型回落重新认证。
- P11 E2EE 已于 2026-08-11 明确移出 V1 范围；P12 Admin/Governance/Data Rights 与 P13 U20-U25 Production Self-host/Release 主链已完成代码闭环。P13 剩余的是 `SECRET/HUMAN-PENDING`：真实原生签名证书与 GitHub production approval policy、公网 TURN/跨运营商、真实规模 RPO/RTO、真实告警接收方等；P14 iOS U30 已完成本地总集成与自动门禁，含 iOS 15.0 Runner、Push/Auth lease、Media/QR、Calls/CallKit 和 native service 公共接线；2026-08-13 首次连接 `api.85746.pro` 真云端后暴露的 iOS 连接中断/错误恢复、头像 Photos picker、通话非联系人误报、旧 AppIcon 已完成针对性代码修复；2026-08-14 又补齐 AppIcon 0.86 白边根因与聊天 wallpaper/footer 色块回归，iOS AppIcon 改由品牌母版 full-bleed 生成且 composer 外层改为透出聊天背景。上述真人失败项状态统一为 `FIXED-PENDING-RETEST`，需新 iOS 包真人复测。macOS U31 仍为 `PLANNED`。
- **客户端下载落地页**：根目录新增 `download-site/` 纯静态页面；Windows/普通桌面显示 Windows、Android 两个真实下载入口以及 iOS/macOS“敬请期待”，Android 浏览器仅显示 Android APK 下载入口，iOS/macOS 浏览器仅显示对应“敬请期待”；页面自带 `assets/banner.svg` 品牌 Banner，不依赖外部前端库。
- **本地双端一键打包**：根目录 `一键打包Windows和安卓.bat` 调用正式 `scripts/build-client.ps1 -Target windows-android`，一次构建 Windows Release + Android Debug，并在根目录生成 `DD-Windows.zip`、`DD-Windows.lnk` 与 `DD-Android.apk`；`build_win_fresh` 等构建目录和根目录交付产物继续由 `.gitignore` 排除，不进入 Git 历史。
- **客户端构建垃圾一键清理**：根目录 `一键清理客户端构建垃圾.bat` 调用 `scripts/clean-client-build-junk.ps1`，只删除可重建的 `clients/app/build`、历史 `build_win_*` / `build_windows_*`、Flutter build cache、Windows ephemeral 与 Android Gradle/CMake 临时目录；不删除源码、Git、配置、签名材料、依赖定义或全局 Pub/Gradle 缓存。2026-08-15 针对 Android/Gradle 生成的 300+ 字符深路径，删除核心改为受路径白名单约束的 `git -c core.longpaths=true clean -fdx -- <target>`，并在删除前停止 Gradle daemon 与目标构建目录内仍运行的 EXE；BAT 启动壳保持纯 ASCII，规避 CMD 对 UTF-8 中文批处理内容的误解析。

当前不能宣称 Stable 1.0，也不能把“今晚能运行开发环境”写成“商业上线完成”。

---

## 4. 当前数据库与正式模块快照

当前 migration 已出现：

```text
000001_instance_settings
...
000016_stickers
000017_groups
000018_calls
000019_moments
000020_calls_conversation
000021_qr
000022_push           ← Push 基础 schema
...
000026_push_product_chain ← Push 产品链补充约束/索引
000027_custom_sticker_video ← Custom Sticker MP4/WebM MIME 前向扩展
000028_moment_activity      ← Moments 点赞/评论/回复持久未读事实
000029_telegram_sticker_dynamic_video ← Telegram TGS/WebM + Custom TGS MIME 前向扩展
000030_sticker_pack_share ← STICKER_PACK 消息类型与首表情分享缩略图
000031_admin_auth ← 独立 Admin identity/session/MFA
000032_admin_governance ← 举报/治理/审计
000033_data_rights ← 数据导出/账号注销生命周期
000034_message_mentions ← GROUP durable @ 提醒事实/当前 viewer 未读 mention 查询索引
```

当前 Go 正式业务模块包括：

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

P10 Push 已形成正式 domain package、HTTP surface、Worker consumer 与客户端接入。

---

## 5. 当前 API 合同快照

正式 `/api/v1` 已覆盖原有 Auth/Contacts/Messaging/Media/Stickers，并新增：

```text
Groups
Moments
Moment Activity (`GET /api/v1/moment-activity`, `POST /api/v1/moment-activity/read`)
Moment Preferences
Formal Calls
Group QR Invite/Redeem
QR Login create/status/scan/confirm/consume
Push preferences/endpoints/test
Media upload cancel (`DELETE /api/v1/media/uploads/{uploadId}/cancel`)
```

Calls 正式入口已经是：

```text
POST /api/v1/calls
GET  /api/v1/calls/active
POST /api/v1/calls/{callId}/actions
POST /api/v1/calls/{callId}/token
```

旧 `/api/calls...` 只属于兼容/历史实验面，**不得再作为新客户端开发导向**。

QR 正式入口包括：

```text
POST   /api/v1/group-qr-invites
DELETE /api/v1/group-qr-invites/{inviteId}
POST   /api/v1/group-qr/redeem
POST   /api/v1/qr-login
POST   /api/v1/qr-login/status
POST   /api/v1/qr-login/scan
POST   /api/v1/qr-login/confirm
POST   /api/v1/qr-login/consume
```

`TestOpenAPIFormalRuntimeSurface` 继续作为 runtime route ↔ OpenAPI 的防漂移门禁。

---

## 6. 当前自动门禁事实（更新至 2026-08-13）

### Server

`go test ./...`、`go vet ./...` 当前全量通过；Admin/Data Rights/Moments/QR/Push 均已有真实 PostgreSQL 18.4 integration 证据。U30 总集成又在 33 migrations 的当前 schema 上实跑 Auth 与 Push lifecycle PASS；Flutter analyzer 0 issue、iOS/Push/Media/QR/Calls 定向 46/46、Flutter 全量 447 PASS / 5 SKIP。OpenAPI/runtime、Release/native scan 与 YAML 门禁全绿；最终 U30 integration HEAD 的 full-history Gitleaks 在 Git worktree 中真实验证 96/96 commits，Git fatal/0 commits 假绿和 injected credential detector self-test 均被验证。

### P6 Group

`IMPLEMENTED + AUTO-VERIFIED / HUMAN-PENDING`。

2026-08-12 修复“更换/移除群头像时请求只带 `avatarMediaId` 被误判为无更新”的服务端校验遗漏；新增 `TestUpdateGroupInputHasChanges`，Flutter `groups_api_client_test.dart` 的 avatar-only 请求回归也继续通过。真人更换/移除群头像仍为 `FIXED-PENDING-RETEST`。

2026-08-14 Wave2 AI07 新增 `000034_message_mentions`。GROUP 的 server-authoritative `MENTION` / 合法 `MENTION_ALL` 与消息写入同事务落 durable viewer 索引；编辑重建索引、撤回删除索引，conversation summary 对当前 principal 返回 `latestUnreadMentionMessageId` / `latestUnreadMentionSequence`，并继续用 `conversation_members.last_read_sequence` 自然清除。真实 PostgreSQL 18.4 durable mention lifecycle 与 000034 up/down roundtrip 已通过；最终 UI 接线仍待后续单写者完成，状态 `FIXED-PENDING-RETEST`。

### P7 Calls

`IMPLEMENTED + AUTO-VERIFIED + HUMAN-PASS（基础公网 1:1） / HUMAN-PENDING（长时/弱网/后台/更多网络组合）`。

自动证据包含正式 Bearer API、多设备仲裁、Block/非联系人拒绝、错误设备不能取 LiveKit token/控制 Call、终态通话记录服务端事务化等。2026-08-14 生产环境已真人复测通过基础公网 1:1 来电、接听、语音与视频媒体主链；同日修复群通话生产配置路径：`groups.Service` 不再直接读取明文 LiveKit 环境变量，而是接收 `appconfig.Load()` 已解析的 LiveKit URL/key/secret（含 production `*_FILE` secret）及人数上限，缺失配置继续 fail closed。群通话生产状态为 `FIXED-PENDING-RETEST`；30 分钟长时通话、弱网/多网络切换、后台/锁屏与更多跨运营商组合仍需真人环境。

### P8 Moments

`IMPLEMENTED + AUTO-VERIFIED / HUMAN-PENDING`。

真实 PostgreSQL 历史覆盖单条可见范围、长期隐私偏好、Block、删除好友后旧动态失权、互动身份可见性、媒体授权和 Outbox；本轮新增 `000028_moment_activity`、未读读取/已读 API、Realtime `moment-*` 刷新与 Flutter 发现 Footer/桌面 Rail/朋友圈入口三处数字角标，并把 Activity API 扩展为“未读数 + 最近 30 条互动明细”。Flutter Feed 现已在封面下显示互动焦点，点击打开最近点赞/评论列表；已读只更新 `read_at`，不会删除历史。对应 API/Feed 定向测试已补，真实数据库新断言仍需在配置 `DD_MOMENTS_TEST_DATABASE_URL` 后复核，真人状态保持 `FIXED-PENDING-RETEST`。

### P9 QR

当前状态：

```text
SERVER: IMPLEMENTED + AUTO-VERIFIED
FLUTTER: IMPLEMENTED + QR-DIRECTED-AUTO-EVIDENCE / GLOBAL-GATE-PASS
OVERALL: AUTO-GATE-PASS / HUMAN-PENDING
```

2026-08-11 04:42 历史定向验证：

- `dart analyze --fatal-infos`：0 issue；
- `dd_qr_payload_test.dart`、`qr_api_client_test.dart`、`qr_login_page_test.dart`、`qr_scanner_page_test.dart`：10/10 通过；
- Windows Release：构建成功；
- Web Release：构建成功；
- Android Debug APK：构建成功并发布到根目录 `DD-Android.apk`；
- Windows 单实例恢复逻辑修复：残留无窗口进程不再导致后续双击静默退出。

QR 自身旧阻断已解除，2026-08-12 当前全 App analyzer/test 也已重新通过。下一步继续真人扫码、相机权限、跨设备登录确认等真实设备验收；不能因此直接标 `HUMAN-PASS`。

### P10 Push

当前状态：

```text
SERVER: IMPLEMENTED + AUTO-VERIFIED
ANDROID FIREBASE BUILD: HISTORICAL-AUTO-EVIDENCE
FLUTTER APP GATE: AUTO-GATE-PASS
REAL DEVICE DELIVERY: FIXED-PENDING-RETEST / HUMAN-PENDING
OVERALL: AUTO-GATE-PASS / HUMAN-PENDING
```

已完成：

- `user_notification_preferences` / `device_push_endpoints` / `push_jobs`；
- `server/internal/push` 正式 service；
- `/api/v1/push/preferences`、`/api/v1/push/endpoints`、`/api/v1/push/test`；
- Outbox → durable Push Job；
- 普通消息、好友申请、1:1 来电、群通话、朋友圈互动 Push 生产；
- Worker retry/backoff/dedupe、失效 token 自动 INVALID；
- FCM HTTP v1、APNs、UnifiedPush provider；Android FCM user-visible 消息现使用 data-only + HIGH priority，由客户端自行渲染，iOS FCM 路径保留 APNS-specific alert；
- Flutter token 注册、token refresh、Push 点击打开会话、通知偏好与测试入口；Android 后台 handler 为顶层 `@pragma('vm:entry-point')`，Firebase 初始化完成后注册，killed isolate 使用 `AppNotificationService` 的后台安全最小路径创建消息频道并渲染 sender avatar large icon、DD monochrome small icon；冷启动/运行中本地通知点击仍恢复导航；失败仅记录固定结果分类，不写 FCM token 或消息私密内容；
- sender avatar Push 采用短期 HMAC capability URL，不把 Access/Refresh Token 放入 FCM；`HIDDEN` 预览不携带 avatar URL；开发 runner 使用设备可达私网 origin，生产仍要求 HTTPS；
- Android `google-services.json` + Google Services Gradle 插件正式接入；
- 真 Firebase Admin service-account 可被本地 Worker 成功加载并启动；
- Push PostgreSQL integration、provider mock、Flutter API 定向测试、Go 全量测试、OpenAPI strict 均有通过证据；2026-08-12 当前全 App Flutter analyzer 与全量测试已重新通过；
- Android Firebase Debug APK 已构建并发布到根目录 `DD-Android.apk`；
- U08 Push 运维闭环：FCM/APNs/UnifiedPush 固定低基数 provider metrics、provider auth failure/backlog/retry/invalid endpoint ratio、失效 endpoint 30 天保留后 Worker 分批清理、secret `_FILE`/rotation/故障诊断 runbook；
- U24 Observability/Alerting：API latency/status/active requests、DB pool/query errors、Redis/realtime、WebSocket、Outbox、Push、S3、SMTP、Worker/runtime 指标；独立 `infra/observability` Prometheus/Grafana/blackbox/node-exporter overlay 与 19 条带 `for` 的正式告警规则。真实 FCM/APNs delivery/click 不能由 provider HTTP success 代替，仍为 `HUMAN-PENDING`。

Push 的设备级退出项仍是：真实 Android 设备安装后取得 FCM token，并验证前台、后台、被系统杀进程三种状态下的通知到达、真实 sender avatar、DD 小标与点击恢复。2026-08-12 本轮重新执行 `go test ./...`、全 App `dart analyze --fatal-infos` 与 Flutter 全量测试均已通过；下一步直接继续 APK/真机 Push 最终验收。2026-08-11 23:35 ADB 安装曾被设备侧 `INSTALL_FAILED_ABORTED: User rejected permissions` 拒绝，属于真人设备权限门槛，不是服务端代码失败。

---

## 7. 文档地图

| 文档 | 用途 |
|---|---|
| `00-需求完善总览.md` | 产品范围与当前完成度总览。 |
| `01-产品需求规格书-PRD.md` | 最终产品行为与功能要求。 |
| `02-技术架构与模块设计.md` | 当前真实架构、模块边界和数据流。 |
| `03-安全隐私与威胁模型.md` | Auth/Group/Calls/Moments/QR/Push/E2EE 安全边界。 |
| `04-部署运维与开源交付规范.md` | 开发/生产部署、构建、Worker、migration、发布。 |
| `05-API与数据模型草案.md` | 当前正式 API、migration 和数据实体。 |
| `06-测试验收与发布标准.md` | 自动门禁、真人验收和发布阻断条件。 |
| `07-P0实时通信PoC.md` | Realtime PoC 历史结论与正式主链关系。 |
| `08-P0音视频通话PoC.md` | LiveKit/TURN PoC 与已正式化 P7 Calls 的演进。 |
| `09-P0-E2EE候选库评估.md` | 历史 E2EE PoC 研究档案；V1 已明确不开发 E2EE。 |
| `10-P2账号认证垂直切片.md` | Auth/User/Device 与 QR trusted-session 关系。 |
| `11-P3好友关系链.md` | DDID、好友、Block 与 Group/Moments/QR 联动。 |
| `12-产品体验与UI功能基线.md` | Windows/Android/Web、朋友圈、二维码等 UI/体验基线。 |
| `13-2026-08-09-1(1)-体验与能力增量需求.md` | 历史体验增量吸收与回归索引。 |
| `14-2026-08-09-登录联系人媒体缓存稳定性增量.md` | 登录、联系人、媒体缓存回归索引。 |
| `15-当前实现状态与开发路线.md` | **每轮开发必读：真实状态、阻断、下一步。** |
| `16-2026-08-11-全量文档同步记录.md` | 2026-08-11 从 P5/R16 旧视角追平到 P6-P10 的历史同步记录。 |
| `17-2026-08-12-代码事实同步记录.md` | 2026-08-12 再次按当前 worktree 清理 P9/P10/Sticker/性能/CI 等文档漂移。 |
| `18-2026-08-13-U30总集成与全量文档同步记录.md` | 2026-08-13 U30 iOS 总集成、自动证据与全仓 Markdown 漂移清理记录。 |
| `decisions/*.md` | 已接受/废弃架构决策；P9/P10 新增 ADR-010/ADR-011。 |

---

## 8. 后续开发唯一顺序

当前不再从 P6 重新开始。开发主线是：

```text
Stop-the-line 修复当前真人回归新问题
→ U30 iOS Codemagic/Xcode + Apple/Firebase Secret + TestFlight/iPhone 验收
→ 配置 U25 Android/Windows/iOS production signing Secret / GitHub Environment reviewer policy
→ P13 公网 TURN / DR / Observability 真人生产验收
→ U31 macOS 正式客户端
→ U16 普通用户 MFA / U17 Passkey（非当前 V1 主链阻断）
```

P6/P7/P8 同时保留真人多端/弱网/规模验收债务，但不能把已实现模块重新写回 `PLANNED`。

---

## 9. 后续 AI / 开发者开工流程

1. 读本文件。
2. 读 `15-当前实现状态与开发路线.md`。
3. 根据当前阶段读一到两个对应专题文档。
4. 再读 runtime route、migration、测试和当前 worktree。
5. 先修 `KNOWN-FAILURE`，再开发下一大模块。
6. 修改代码后重新跑受影响门禁。
7. 同一轮同步 docs。
8. 真人未测的用户体验只能写 `HUMAN-PENDING` / `FIXED-PENDING-RETEST`，禁止冒充 `HUMAN-PASS`。

---

## 10. 文档维护 Definition of Done

一次文档更新至少需要做到：

- 当前 route 与 API 文档一致；
- 当前 migration 序列一致；
- 实现状态和最新测试结果一致；
- 已知失败没有被旧“完成”描述覆盖；
- ADR 与代码现实不冲突；
- 所有内部 Markdown 引用可解析；
- `15-当前实现状态与开发路线.md` 的下一任务与真实 worktree 一致。
