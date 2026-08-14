# 总负责人最终合并 / 复审 Checklist

## 1. 集成基线与保护

- integration worktree 基线固定：`396e672339429100ae5288f3408e20f9d3858dcd`。
- 当前 `master == origin/master`。
- 保护未跟踪 `DD-Windows.bat`、`实测需求与bug.md`。
- 每个 AI 必须有 commit hash、report、测试结果后才进入队列。
- 真人反馈项复测前只能标 `FIXED-PENDING-RETEST`。
- 拒绝无关依赖升级、大范围格式化、secret/token、越界热点改动。

## 2. 必须保护的当前主线行为

基线已经包含：

- `a6d33ba fix(calls): recover incoming calls from shared realtime`
- `943de00 fix calls formal livekit token`
- `396e672` 文档记录基础公网 1:1 来电/接听/语音/视频 HUMAN-PASS

凡合并涉及 `messaging_coordinator.dart` / `main_shell_page.dart` / Calls 相关代码，必须验证：

- shared realtime availability reason 仍能进入 call controller；
- durable Sync `CALL_RINGING` 仍能触发 formal incoming recovery；
- formal `/api/v1/calls/{id}/token` 仍使用当前已修复的正式授权链；
- caller cancel/terminal state 不回退；
- Realtime resume 不制造重复 Call signaling/重复 connect。

## 3. Wave 1 固定合并顺序

1. AI11 Registration code cooldown。
2. AI01 Group Call production config。
3. AI02 Android Push killed-state。
4. AI03 iOS icon/footer。
5. AI04 swipe/Moments。
6. AI05 Telegram sticker import。
7. AI12 Realtime resume recovery。

每个 commit：review diff → 跑定向测试 → 再进入下一个。

AI12 最后合，是为了在 Wave 1 已稳定后单独复审 Shell / Messaging / Push / Calls lifecycle。

Wave 1 完成后：

- `go test ./...`
- `go vet ./...`
- `clients/realtime_poc: dart test`
- `clients/app: dart analyze --fatal-infos`
- `clients/app: flutter test`
- 建立 `WAVE2_BASE_COMMIT`

## 4. Wave 1 所有权检查

- AI02 不得修改 `main_shell_page.dart` / `messaging_coordinator.dart`。
- AI12 不得修改 `conversations_page.dart`，避免与 AI04 同波次冲突。
- AI03 对 `text_chat_page.dart` 仅保留 footer 视觉最小修改。
- AI11 原则上仅改 Auth UI/tests。

若分支违反上述边界，先拆 commit，不直接硬合。

## 5. Wave 2 合并顺序

1. AI06 viewer-relative display name contract。
2. AI07 durable mention contract。
3. AI08 Voice/STT foundation。
4. AI09 Windows clipboard adapter。
5. AI10 Live Photo core。

## 6. 热点冲突原则

热点：

- `text_chat_page.dart`
- `messaging_coordinator.dart`
- `main_shell_page.dart`
- `conversations_page.dart`
- `messaging_models.dart`
- `server/internal/messaging/*`

规则：

- 禁止整文件 `ours/theirs`。
- 逐 hunk 对照行为目标和测试。
- 保留 integration 已通过 regression tests。
- 新行为保留自己的 contract tests。
- 冲突后同时重跑双方测试。

## 7. Wave 3 单写者接线顺序

1. AI12 暴露的 `connecting` 状态 → 会话列表旋转 loading；不改其 recovery 逻辑。
2. 全平台 effective display name。
3. durable mention：头像 long-press @、红色 `【有人@你】`、message 精确定位。
4. Voice：loading/playing、红点、连续播放、手动/自动 STT。
5. Windows clipboard image。
6. Live Photo paired send/view/fallback。

同一时刻只允许一个写者改 `text_chat_page.dart`。

## 8. 新增 B16/B17 专门验收

### B16 Auth countdown

- 成功后 button disabled。
- 60→59→...→1→恢复。
- 文案：`验证码发送成功，收不到就去邮箱垃圾箱看看`。
- 失败不启动 cooldown。
- timer dispose 无异常。
- server 60s cooldown 仍为权威。

### B17 Realtime resume

- App online → lock/background → resume 自动恢复，不杀进程。
- 1/5/30 分钟场景。
- 锁屏期间消息通过 cursor sync 补齐。
- 恢复后继续实时收新消息。
- `connecting → connected` 状态可见。
- Push resume 仍工作。
- 1:1 incoming Call 仍工作。
- 不残留重复 websocket/reconnect timer。

## 9. 最终自动门禁

- server：`go test ./...`
- server：`go vet ./...`
- migration embed/contract/integration
- realtime_poc：`dart test`
- clients/app：`dart analyze --fatal-infos`
- clients/app：`flutter test`
- Android APK build
- Windows build/package
- iOS unsigned/cloud 可执行合同门禁
- repo hygiene：无 build/cache/temp/log 垃圾、无 secret、无无意义整文件格式化

## 10. 真人验收失败处理

- 不整波回退。
- 失败条目退回 `IN-PROGRESS`。
- 用真人复现补 regression test 后做 follow-up commit。
- 先判断是否同根因，禁止继续堆无证据补丁。

## 11. 最终文档同步

统一更新：

- `docs/README.md`
- `docs/15-当前实现状态与开发路线.md`
- `开发进度跟踪.md`
- `CHANGELOG.md`
- 必要时 `未开发任务.md`

只有真人通过项改 `VERIFIED/HUMAN-PASS`；其余保持 `FIXED-PENDING-RETEST`。
