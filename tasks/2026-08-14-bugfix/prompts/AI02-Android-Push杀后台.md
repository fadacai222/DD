# AI02：修复 Android 杀后台后 Push 不到达

使用 `@dd`：

`C:\Users\admin\Desktop\复刻微信`

你是 **AI02 / Android Push killed-state**。

## Git 约束

- 基线：`396e672339429100ae5288f3408e20f9d3858dcd`
- 独立 worktree。
- 不改 master，不 merge/rebase master。
- 完成后原子 commit，返回 hash。
- 不碰主工作区未跟踪文件。

## 唯一任务

修复：

> 安卓端的 push 也没了，大退杀后台以后没 push 了。

不要同时开发 iOS Push，不要回退 Auth/Push lease lifecycle。

## 当前事实

现有 server FCM 已经：

- HTTP v1 OAuth
- Android data-only
- Android priority `HIGH`
- endpoint lifecycle / invalid token / retry

客户端已经：

- `main.dart` 调 `PushRegistrationService.prepareBackgroundMessaging()`
- `FirebaseMessaging.onBackgroundMessage(ddFirebaseMessagingBackgroundHandler)`
- background handler 初始化 Firebase、解析 data、调用本地通知
- Android Manifest 有 `POST_NOTIFICATIONS`、default channel/icon

但当前 background handler 最后：

```dart
} catch (_) {
  // Background Push failure must never crash...
}
```

即所有 killed/background 失败都不可诊断。

## 必须先澄清 Android 状态语义

测试/报告必须明确区分：

1. App 前台。
2. App 在后台。
3. 从最近任务列表划掉 / Dart 进程死亡。
4. 系统回收进程。
5. 设备重启后。
6. Android Settings 或 `adb shell am force-stop <package>` 的 **Force Stop**。

第 6 种属于 Android stopped-package 语义，系统可以阻断 FCM/广播直到用户再次手动打开 App。**不要声称 App 代码可以绕过系统 Force Stop。**

用户反馈的“杀后台”优先按 3/4 去修。

## 必须分析整条链

按顺序证明：

1. 当前 device FCM token 是否注册到 DD server endpoint。
2. endpoint 是否 ACTIVE，appId/environment 是否正确。
3. message/outbox 是否生成 push job。
4. worker 是否调用 FCM 且得到成功 message name。
5. payload 在 Android 是 data-only + HIGH。
6. killed/background isolate 是否真正启动 handler。
7. handler 是否能初始化 Firebase。
8. `AppNotificationService` 在 background isolate 是否能初始化 channel/plugin 并显示通知。
9. Android 13+ notification permission 是否已授权。
10. 通知 channel 是否被用户关闭。

不要只改一处然后猜。

## 必须实现

1. 保持 data-only 设计，不能为了“看起来能推”直接加 `android.notification` 导致系统自动渲染与 DD MessagingStyle/avatar 双路径冲突，除非有非常明确的架构证据并同步重做整个契约。
2. background handler 的失败必须留下**可诊断但不泄漏 token/message 私密内容**的本地日志/错误分类；不能继续全吞。
3. handler 必须是 top-level + `@pragma('vm:entry-point')`，并在 killed isolate 下依赖最少。
4. 检查 Firebase initialize 与 background handler 注册顺序是否满足当前 firebase_messaging 版本要求。
5. `AppNotificationService` 如有 main-isolate-only 假设，拆出 background-safe 的初始化/显示路径。
6. 权限/频道关闭时前台设置页应能明确显示状态，不要误判成 server Push 坏了。
7. token refresh、logout、切账号 endpoint ownership 不得被回退。
8. 如果需要 Android native service/receiver，优先使用 Firebase 官方 plugin 机制，不要重复注册产生双通知。

## 测试

至少新增/强化：

- background payload parser 无 UI context 也可运行。
- malformed data 不崩溃且有可诊断结果。
- killed/background notification content 保留 conversationId/navigation data。
- Android foreground path不双通知。
- endpoint lifecycle 原测试继续绿。
- server FCM payload test继续断言 Android `HIGH` + data-only。

运行：

```text
server: go test ./internal/push/... && go test ./...
clients/app: dart analyze --fatal-infos
clients/app: flutter test <push相关定向测试>
clients/app: flutter test
Android: flutter build apk（使用项目既有构建参数/脚本）
```

不要启动长驻服务。

## 真机验收脚本/步骤

report 里必须给出 ADB 可复制命令，至少包括：

- 查看 package / process 状态；
- 普通划掉最近任务后测试；
- `adb shell am force-stop` 作为“系统限制对照组”；
- 重新打开 App 后 token/Push 恢复；
- `adb logcat` 过滤 DD/Firebase/notification 关键日志；
- Android 通知权限/channel 检查。

不要把真实 FCM token 写进 report/Git。

## 禁止碰

- iOS APNs/Auth lease 逻辑，除非跨平台抽象测试强制需要且改动最小。
- `two_party_call_controller.dart`
- `messaging_coordinator.dart`
- `main_shell_page.dart` / `messaging_coordinator.dart`（本轮前后台恢复由 AI12 单写；不要抢 ownership）
- 当前已 HUMAN-PASS 的 1:1 Call shared realtime / formal LiveKit token 修复
- 无关 UI

## 交付

新增：

`tasks/2026-08-14-bugfix/reports/AI02.md`

写清：根因是否最终确认、代码修复、测试、Android Force Stop 边界、真机步骤、状态 `FIXED-PENDING-RETEST`。

建议 commit：

`fix(push): harden Android killed-process notifications`
