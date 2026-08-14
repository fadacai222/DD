# AI12：锁屏/前后台恢复 Realtime 主链

使用 `@dd` 开发：

`C:\Users\admin\Desktop\复刻微信`

你是 **AI12 / Realtime Resume Recovery**。

## Git 约束

- 冻结基线：`396e672339429100ae5288f3408e20f9d3858dcd`
- 必须独立 Git worktree。
- 不直接改 master，不 merge/rebase master。
- 不碰主工作区未跟踪文件。
- 当前基线已包含：
  - `a6d33ba fix(calls): recover incoming calls from shared realtime`
  - `943de00 fix calls formal livekit token`
  - 基础公网 1:1 Calls HUMAN-PASS
- 这些现有行为不得回退。

## 唯一任务

修复新增真人问题：

> 锁屏以后重开软件，左上角绿点变灰色，没有自动重连，必须大退杀后台重启；希望像微信一样连接恢复时有“连接中”反馈。

本 AI 负责 **Realtime resume/recovery 核心与测试**。

为了避免与 AI04 同时修改 `conversations_page.dart`，本 AI **不要改会话列表滑动页面的 UI 实现**。你只需确保连接状态会可靠进入 `connecting → connected/disconnected`；最终“旋转 loading”视觉由总负责人 Wave 3 在 `conversations_page.dart` 做最小接线。

## 已确认当前代码事实

### RealtimeClient 已有自动机制

`clients/realtime_poc/lib/src/realtime_client.dart` 已有：

- heartbeat interval 5s；
- heartbeat timeout 5s；
- disconnect 后指数退避 reconnect：1/2/4/8/16/30s；
- `disconnected / connecting / connected` 状态流。

因此**禁止再造第二套常驻 reconnect Timer**。

### 当前 Shell resume 缺口

`clients/app/lib/features/shell/presentation/main_shell_page.dart::didChangeAppLifecycleState()` 当前 resumed 只做：

- Moment activity refresh；
- Push `onAppResumed()`；
- Call external signal recovery；
- badge sync。

它没有主动调用 Messaging/Realtime recover。

`MessagingCoordinator.recover()` 当前只有在 `_realtime.state == disconnected` 时才调用 `_realtime.connect()`；如果锁屏后 socket 已 half-open/stale、客户端枚举仍暂时为 connected，就可能没有及时恢复。

## 必须先证明问题

新增自动测试，至少覆盖一种等价场景：

1. 首次 realtime connected；
2. App 进入 paused/inactive/hidden 或模拟锁屏导致底层连接失效/过期；
3. App resumed；
4. 不依赖用户杀进程，Messaging 主链主动执行恢复；
5. 状态明确经过 connecting，并最终 connected 或保留 disconnected 可诊断状态；
6. cursor sync/pending flush 不丢。

不要只写“手动调用 connect() 能成功”的测试，那不能证明 lifecycle Bug 被修。

## 必须实现

1. 给 Messaging/Realtime 增加明确的 **resume recovery 入口**，命名清楚，例如 `onAppResumed()` / `recoverAfterResume()`；不要让 Shell 拼装一堆私有细节。
2. resume recovery 必须幂等、可串行化：
   - 连续多次 resumed 不得创建重复 websocket；
   - 不得重复订阅 realtime streams；
   - 不得和正在进行的 initialize/recover 互相踩状态。
3. 恢复至少包含：
   - cursor sync；
   - pending message flush；
   - conversation state refresh（按现有 coordinator 语义选择最小必要调用）；
   - realtime connection revalidation/reconnect。
4. 对 stale/half-open 连接不要只看 `state == connected` 就永远跳过。可以选择**resume 时主动安全重连**或增加明确的 revalidate/reconnect primitive，但要有测试证明不会双连。
5. 复用 `RealtimeClient` 已有 heartbeat/backoff，不要在 Shell 新增永不停止的 retry loop。
6. Shell `AppLifecycleState.resumed` 必须调用该恢复入口。
7. 保留现有：
   - `_pushRegistrationService.onAppResumed()`；
   - `_recoverCallFromExternalSignal(...)`；
   - Moment refresh；
   - notification badge sync。
8. 恢复动作不能回退 1:1 Call shared realtime：
   - 不删 `CALL_RINGING → call-created` 转换；
   - 不破坏 `_callController.handleRealtimeReason(...)`；
   - 不改 formal Call token API/state machine。
9. 如果主动 reconnect 会短暂把状态切成 `connecting`，这是期望行为；最终总负责人会把该状态接成旋转 loading。
10. 错误必须可诊断，但不要因为暂时 websocket 失败阻断 REST/cursor sync 正常使用。

## 推荐修改边界

允许重点修改：

- `clients/app/lib/features/messaging/application/messaging_coordinator.dart`
- `clients/app/lib/features/shell/presentation/main_shell_page.dart`
- `clients/realtime_poc/lib/src/realtime_client.dart`（仅当确实需要一个可测试、单一职责的 immediate reconnect/revalidate primitive）
- 对应 tests

禁止修改：

- `clients/app/lib/features/messaging/presentation/conversations_page.dart`（AI04 同波次；loading 视觉留给 Wave 3）
- Push endpoint lifecycle / Auth lease
- Server Calls state machine / formal token API
- `two_party_call_controller.dart`，除非测试暴露真实兼容问题且改动极小；默认不要碰
- 无关 UI

## 测试要求

### realtime_poc

加强/新增：

`clients/realtime_poc/test/realtime_client_reconnect_test.dart`

至少覆盖：

- connected 后 immediate revalidation/reconnect 不产生双 channel；
- reconnect 期间状态序列合理；
- dispose/stop 后不残留 reconnect timer；
- stale channel 被替换后旧 channel 的 onDone/onError 不把新连接打掉。

### Flutter App

新增/强化 Messaging/Shell 生命周期测试：

- resumed 主动触发 coordinator recovery；
- pending/sync 继续执行；
- Push resume 与 Call recovery 仍被调用；
- 多次 resumed 不发生重复并发 connect；
- current 1:1 Call realtime tests 保持全绿。

运行：

```text
clients/realtime_poc: dart test
clients/app: dart analyze --fatal-infos
clients/app: flutter test test/messaging_coordinator_test.dart
clients/app: flutter test <新增/相关 shell lifecycle tests>
clients/app: flutter test test/features/calls/two_party_call_controller_test.dart
```

如定向测试通过，再跑 App 全量 `flutter test`。

## 真人验收步骤必须写入 report

至少覆盖：

1. App 在线，确认绿点。
2. 锁屏/后台 1 分钟 → 回 App。
3. 锁屏/后台 5 分钟 → 回 App。
4. 锁屏/后台 30 分钟 → 回 App。
5. 回 App 时应出现短暂“连接中”状态，随后恢复绿色；不需要杀进程。
6. 锁屏期间让另一设备发送多条消息；恢复后消息通过 cursor sync 补齐。
7. 恢复后继续实时收消息，不是只补一次历史然后仍离线。
8. 同时回归 1:1 来电：锁屏/恢复后对端呼叫仍能收到。

## 交付

新增：

`tasks/2026-08-14-bugfix/reports/AI12.md`

写清：

- 真正根因；
- 是 timer suspend、half-open socket、Shell resume 缺口还是组合问题；
- 采用的 recovery/reconnect primitive；
- 并发/幂等保护；
- 自动测试；
- 留给 Wave 3 的 loading UI 最小接线说明；
- 真人验收步骤；
- 状态 `FIXED-PENDING-RETEST`（UI loading 接线前不要宣称整项完成）。

建议 commit：

`fix(realtime): recover messaging after app resume`
