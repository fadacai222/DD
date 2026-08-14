# 2026-08-14 实测 Bug 并行修复总计划

> 总负责人：最终集成由主会话负责人执行。  
> 需求来源：根目录 `实测需求与bug.md`（2026-08-14 01:34 最新版）。  
> 冻结基线：`396e672339429100ae5288f3408e20f9d3858dcd`。  
> Git 事实：当前 `master == origin/master`。  
> 当前主工作区额外存在未跟踪文件 `DD-Windows.bat`、`实测需求与bug.md`、`tasks/2026-08-14-bugfix/`；任何并行 AI **不得删除、覆盖、add、commit 用户未授权的未跟踪文件**。

## 1. 总原则

1. 所有并行 AI 必须从冻结基线创建独立 Git worktree；禁止直接改 `master`，禁止 merge/rebase master。
2. 每个 AI 只处理分配范围；禁止顺手重构、统一格式、升级依赖、改无关 UI。
3. 每个 Bug 必须先找到“可复现证据/代码根因”，再改；不能只根据旧文档宣称已修。
4. 真人报告问题修完后统一标记 `FIXED-PENDING-RETEST`；只有目标真实平台重新验证后才可改 `HUMAN-PASS/VERIFIED`。
5. 每个 AI 必须提交独立原子 commit，并交付：commit hash、改动文件、自动测试、真人待测、已知风险。
6. 共享热点文件实行单写者原则，尤其：
   - `clients/app/lib/features/messaging/presentation/text_chat_page.dart`
   - `clients/app/lib/features/messaging/application/messaging_coordinator.dart`
   - `clients/app/lib/features/shell/presentation/main_shell_page.dart`
   - `clients/app/lib/features/messaging/presentation/conversations_page.dart`
   - `clients/app/lib/features/messaging/domain/messaging_models.dart`
   - `server/internal/messaging/*`
7. 并行分支不要反复改公共状态文档。每个 AI 只写自己的 `tasks/2026-08-14-bugfix/reports/AIxx.md`；最后由总负责人统一同步 `docs/README.md`、`docs/15-当前实现状态与开发路线.md`、`开发进度跟踪.md`。
8. 不允许吞异常。用户可操作失败必须有稳定、可见、可定位的错误提示；服务端保留结构化错误语义。
9. 涉及公网、Push、LiveKit、iOS/Android 真机的项目，自动测试通过不等于真人验证通过。
10. **禁止回退当前已验证的 1:1 Calls 主链**：基线已包含 `a6d33ba fix(calls): recover incoming calls from shared realtime`、`943de00 fix calls formal livekit token`，且 `396e672` 已记录基础公网 1:1 来电/接听/语音/视频 HUMAN-PASS。

## 2. 17 项需求归档与代码判断

> 为保持上一版提示词/报告编号稳定，原 B01-B15 不重排；本次新增项追加为 B16/B17。

| ID | 原始问题 | 类型 | 优先级 | 当前代码证据 / 初步根因 | 负责流 |
|---|---|---|---|---|---|
| B01 | iOS icon 尺寸不对、有白边 | 回归 | P1 | iOS AppIcon 生成链存在 canonical 资源缩放/白背景风险，需验证最终像素 full-bleed | AI03 |
| B02 | iOS 聊天底栏与聊天背景有色差 | 回归 | P1 | `_composerBar()` 外层不透明 `Material(color: surface)` 会覆盖 `ChatWallpaperSurface` | AI03 |
| B03 | 全平台以备注为唯一显示名 | 语义缺口 | P1 | 联系人已有 remark，但 Messaging/Group/Calls/Push 多处仍使用公共 `display_name`；remark 是 viewer-private，不能泄漏 | AI06 + 总集成 |
| B04 | 语音点击播放有停顿 | UX 回归 | P1 | 当前 `_toggleVoicePlayback()` 先完整 `_mediaBytesFor()`，cache miss 时 UI/声音都要等下载 | AI08 + 总集成 |
| B05 | 缺语音转文字 + 全部自动转文字 | 新功能 | P1 | 当前无正式 STT provider/API/跨端持久化模型 | AI08 + 总集成 |
| B06 | 首次语音条缺红点 | UX 缺口 | P1 | 已有持久 `heardVoiceMessageIds`，可作为未听事实源 | AI08 + 总集成 |
| B07 | 多个首次语音条不会自动播放 | UX 缺口 | P1 | player completion 目前没有“下一条未听远端语音”队列状态机 | AI08 + 总集成 |
| B08 | 发照片缺 Live Photo | 新功能 | P1 | iOS PHPicker 当前只复制单个 image/movie representation，Live Photo still + paired motion 会丢一半 | AI10 + 总集成 |
| B09 | 首页左右滑连键 | 回归 | P1 | `_ConversationSwipeActions` 直接累计 `_offset`，开启一侧后可反向穿越到另一侧，缺离散 opened/closed 状态机 | AI04 |
| B10 | 朋友圈评论不允许红色 | 视觉回归保护 | P2 | 当前评论正文应为普通文本、作者/回复名为蓝色；需合同测试防止 danger/red 继承 | AI04 |
| B11 | 群通话服务未上线 | 功能阻断 | P0 | 生产 Compose 给 API `LIVEKIT_API_KEY_FILE/SECRET_FILE`，但 `groups/calls.go` 直接读 raw `LIVEKIT_API_KEY/SECRET`，可能在进入媒体网络前直接 `GROUP_CALL_UNAVAILABLE` | AI01 |
| B12 | 群头像长按 @；群内外红字“有人@你”；点击直达 | 能力闭环 | P0 | mention entities 已 server-authoritative，但当前只有即时通知语义，缺 durable unread mention summary + 头像长按入口 + 精确定位 | AI07 + 总集成 |
| B13 | Telegram 贴纸包添加失败无提示 | 回归 | P1 | 已有错误码映射，但可见反馈依赖当前 sheet/context；还需核对生产 relay/API 错误码 | AI05 |
| B14 | Windows Ctrl+V 不能粘贴剪贴板图片 | 功能缺口 | P1 | 已依赖 `pasteboard`，聊天输入未接 Windows image clipboard shortcut/adapter | AI09 + 总集成 |
| B15 | Android 杀后台后无 Push | 功能阻断 | P0 | FCM 已 data-only + HIGH，background handler 存在但异常全吞；必须区分 task swipe/process kill 与 Android Force Stop | AI02 |
| B16 | 注册验证码发送成功后按钮 60 秒灰色倒计时；提示改为垃圾箱说明 | UX/防误操作 | P1 | **服务端已经固定 `registrationCodeCooldown = 60s`**；客户端 `auth_page.dart` 仍是常驻“发送验证码”，成功文案还是开发期 Mailpit 文案 | AI11 |
| B17 | 锁屏后回 App 实时绿点变灰，不自动重连；需要“连接中”反馈 | 稳定性阻断 | P0 | `RealtimeClient` 本身有 heartbeat/backoff，但 App suspend 后 timer/socket 状态不能假定可靠；`MainShellPage.didChangeAppLifecycleState(resumed)` 当前刷新 Moments/Push/Call，**没有主动 `MessagingCoordinator.recover()`/Realtime 恢复** | AI12 |

## 3. 新增两项的防返工结论

### 3.1 B16 注册验证码倒计时

服务端当前正式契约已经是：

```text
registrationCodeTTL      = 10 minutes
registrationCodeCooldown = 60 seconds
registrationCodeWindow   = 15 minutes
registrationCodeMaxBurst = 5
```

因此本轮**不需要新 migration，也不应为了一个 UI 倒计时新增数据库状态**。

客户端要求：

- 仅在发送接口成功后开始 `60 → 1` 秒倒计时；
- 倒计时期间按钮灰色禁用，显示如 `59 秒后重试`；
- 失败请求不能启动假倒计时；
- Timer 必须在页面 dispose 时取消；
- 普通 rebuild/Tab 切换不能把计时器重复创建；
- 成功文案固定为：`验证码发送成功，收不到就去邮箱垃圾箱看看`；
- Server rate-limit 继续作为权威防线，客户端倒计时只是 UX，不得代替服务端限流。

### 3.2 B17 锁屏恢复 Realtime

当前 `RealtimeClient` 已经有：

```text
heartbeat 5s
heartbeat timeout 5s
exponential reconnect 1/2/4/8/16/30s
```

问题不应通过“再造第二套无限重连 timer”修复。正确方向：

- App `resumed` 是显式恢复信号；
- Shell/Coordinator 在 resume 时做**幂等**恢复：REST cursor sync + pending flush + 必要时 Realtime reconnect；
- 如果 socket 看起来还是 `connected`，也要考虑锁屏期间 half-open/stale 连接，不能只看枚举状态就完全不检查；
- 复用当前 `RealtimeClient` 的 connect/heartbeat/backoff，禁止 Shell 再维护独立常驻 reconnect loop；
- UI `connecting` 时提供明确 loading/旋转反馈，`connected` 恢复绿色，`disconnected` 不伪装在线；
- 恢复逻辑必须不破坏 `a6d33ba` 的 1:1 call shared realtime 恢复、`943de00` formal LiveKit token 和 Push resume。

## 4. 依赖与并行波次

### Wave 0：冻结与保护（总负责人）

- 冻结基线：`396e672339429100ae5288f3408e20f9d3858dcd`。
- 已确认 `master == origin/master`。
- 保护当前已 HUMAN-PASS 的基础公网 1:1 Calls 以及 `943de00` token 修复。
- 保护未跟踪 `DD-Windows.bat`、`实测需求与bug.md`。
- 并行 AI 一律独立 worktree。

### Wave 1：7 条低耦合/高优先级修复，可同时开工

1. **AI01 群通话生产配置**：B11。
2. **AI02 Android Push killed-state**：B15。
3. **AI03 iOS icon + chat footer**：B01/B02。
4. **AI04 会话滑动状态机 + 朋友圈评论颜色合同**：B09/B10。
5. **AI05 Telegram 贴纸包错误反馈**：B13。
6. **AI11 注册验证码 60 秒倒计时**：B16。
7. **AI12 锁屏/前后台 Realtime 恢复**：B17。

并行边界：

- AI02 明确禁止改 `main_shell_page.dart` / `messaging_coordinator.dart`，这两个文件的 resume/reconnect 所有权交 AI12。
- AI12 不碰 Push endpoint lifecycle、不改 Calls formal token/server 状态机。
- AI03 若必须改 `text_chat_page.dart`，只允许 footer 视觉最小改动，不碰 Voice/Mention/Clipboard/Live Photo。

Wave 1 全部提交后，由总负责人按固定顺序 review/cherry-pick 到 integration worktree，跑定向 + 全量门禁，再创建 `WAVE2_BASE_COMMIT`。

### Wave 2：5 条能力层并行，禁止抢热点 UI

基于 `WAVE2_BASE_COMMIT`：

8. **AI06 viewer-relative 备注显示名契约**：B03。
9. **AI07 durable mention 契约**：B12。
10. **AI08 Voice/STT 基础能力**：B04-B07/B05。
11. **AI09 Windows clipboard image adapter**：B14。
12. **AI10 Live Photo transport/media slice**：B08。

Wave 2 的目标是 server/model/controller/adapter；不要让 5 个 AI 同时把业务逻辑堆进 `text_chat_page.dart`。

### Wave 3：总负责人单写者集成

统一接线热点：

- `text_chat_page.dart`：Voice/STT/red dot/auto-play、长按头像 @、Windows 图片粘贴、Live Photo。
- `conversations_page.dart` / Shell：durable `【有人@你】` 与 messageId/sequence 精确定位。
- viewer-relative 显示名贯穿聊天标题、会话列表、搜索、转发、群成员、通话、朋友圈、通知。
- 合并时再次复核 Realtime resume 与 1:1 call recovery 不互相重复 connect/抢状态。

## 5. 关键架构决策（防返工）

### 5.1 备注显示名

- `remark` 是“当前用户给对方的私人备注”，不是公共 profile。
- viewer-relative preview：当前 principal 的非空 `contacts.remark` 优先，否则 fallback `users.display_name`。
- 群共享数据、消息持久内容、被推给其他人的 payload 不得写某一 viewer 的私人 remark。
- 优先统一 `effectiveDisplayName` 契约，禁止在几十个 Widget 中各写一遍 fallback。

### 5.2 @ 提醒

- 不仅依赖 last message、Push 或内存 event；重启、漏 WS、多设备后必须恢复。
- migration 建议从 `000034_message_mentions` 起，开工前再次确认 migration 号未占用。
- server-authoritative entities 与 mention index 同事务落库。
- `@all` 必须保留 OWNER/ADMIN 授权语义。
- 点击提醒复用现有消息定位/高亮能力，不造第二套搜索/滚动系统。

### 5.3 Voice / STT

- 点击 Voice 立即有 active/loading 反馈；下载与解码不能让 UI 像没点到。
- 连播定义为：用户主动播放第一条未听远端语音后，顺序播放后续符合条件的未听语音；禁止进聊天就自动外放。
- 通话中、离开会话、手动暂停/失败/切媒体必须终止队列。
- heard 只在真正开始播放后更新。
- STT 使用 provider interface；未配置明确 `UNAVAILABLE`，不能硬绑未知第三方。
- 若跨设备持久化，建议 migration `000035_voice_transcriptions`，开工前确认未占用。

### 5.4 Live Photo

- Live Photo 至少是 still + paired motion video；不能只当 JPEG。
- iOS picker 保持 path/stream，不把大视频 materialize 到 Dart/Swift 大块内存。
- 非 iOS 至少安全显示 still + 实况标识。
- 若必须新增 schema，建议后续号 `000036_live_photo`，开工前确认未占用。

### 5.5 Android Push

验收必须分清：前台、后台、recent-task swipe、系统回收进程、重启设备、Android Force Stop。Force Stop 是系统 stopped-package 语义，不能伪造“代码绕过”。

### 5.6 群通话

不重写群通话架构。修复重点是 `groups.Service` 不再绕过 `appconfig.ReadSecret()` 自己读 raw env；将已解析 LiveKit URL/key/secret显式注入 service，并补生产 secret-file 合同测试。

## 6. 固定 Merge 顺序

不要按谁先回来谁先合：

1. AI11 Auth countdown（最独立）。
2. AI01 Group Call prod config。
3. AI02 Android Push。
4. AI03 iOS visual。
5. AI04 swipe/Moments。
6. AI05 Telegram。
7. AI12 Realtime resume（最后合 Wave 1，便于专门复审 Shell/Coordinator 与 Calls/Push 生命周期）。
8. Wave 1 全量门禁，建立 `WAVE2_BASE_COMMIT`。
9. AI06 viewer-relative names。
10. AI07 durable mention。
11. AI08 Voice/STT。
12. AI09 Windows clipboard。
13. AI10 Live Photo。
14. Wave 3 总负责人热点 UI 接线。
15. 全量门禁、构建、人工验收清单。

## 7. 自动验证总门禁

至少执行：

```text
server: go test ./...
server: go vet ./...
clients/realtime_poc: dart test
clients/app: dart analyze --fatal-infos
clients/app: flutter test
```

此外：

- migration 分支：migration embed/contract/integration；
- iOS native：现有 iOS contract tests；
- Android Push：APK build + 真机 ADB/FCM 步骤；
- Realtime：必须覆盖 disconnect/reconnect + lifecycle resume，不接受只测手动 connect；
- Auth countdown：Widget fake-time/pump 证明 60 秒状态转换，不允许真实等待 60 秒。

## 8. 真人最终验收矩阵

- 注册：验证码成功提示正确；60→1 灰色倒计时；60 秒后可重发；失败不假倒计时。
- 锁屏恢复：在线 → 锁屏/后台 1/5/30 分钟 → 回 App，立即显示连接中，随后恢复绿色；消息补齐，不需要杀进程。
- iPhone：AppIcon 无非预期白边；不同聊天背景 footer 无色块；Live Photo 发送/查看。
- Android Push：前台、后台、划掉 recent tasks、系统回收后的通知；Force Stop 作为系统限制对照组。
- Windows：Ctrl+V 图片/纯文本/连续粘贴，不重复发送。
- 群聊：长按头像插入精确 @；群外/群内 `【有人@你】`；重启后仍存在；点击直达消息；已读后按语义消除。
- Voice：cache miss 首次点击立即反馈、红点、连续多条、通话打断、STT 手动/自动/失败/未配置。
- 群通话：生产不再误报 `GROUP_CALL_UNAVAILABLE`；2+ 设备 start/join/leave；公网 LiveKit/TURN 单独验收。
- Telegram：无 Token、错误链接、404、timeout、部分格式失败都有用户可见提示。
- Moments：评论作者/回复名/正文不使用 danger/red；点赞红心和错误提示仍可红。

## 9. 失败处理

- AI 发现需求会破坏已有安全/权限语义：报告证据并做最小兼容方案，不自行重构全仓。
- 测试无法运行：写明原因和替代证据，禁止“应该没问题”。
- 分支越界大改热点文件：总负责人可拒绝合并。
- 冲突处理以“当前 integration 已修复行为 + 新分支最小逻辑”为准，禁止整文件 `ours/theirs` 粗暴覆盖。
