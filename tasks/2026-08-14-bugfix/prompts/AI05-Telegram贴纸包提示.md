# AI05：修复 Telegram 贴纸包无法添加且无任何提示

使用 `@dd`：`C:\Users\admin\Desktop\复刻微信`

你是 **AI05 / Telegram sticker import reliability**。

## Git

- 基线 `396e672339429100ae5288f3408e20f9d3858dcd`
- 独立 worktree；不改 master；不 merge/rebase。
- 原子 commit。

## 唯一任务

修复：

> 无法添加 Telegram 贴纸包，没有任何提示。

现有 Telegram sticker relay / TGS / WebM / pack share 已经存在，**禁止重写贴纸系统**。

## 当前代码事实

客户端已有：

- `parseTelegramStickerSetName()`
- `StickerApiClient.importTelegramPack()`
- `sticker_library_sheet.dart::_importTelegramPack()`
- `_operationErrorText()` 映射：
  - `TELEGRAM_STICKER_RELAY_NOT_CONFIGURED`
  - `TELEGRAM_STICKER_RELAY_UNAVAILABLE`
  - `TELEGRAM_STICKER_FORMAT_UNSUPPORTED`
  - `TELEGRAM_STICKER_TOO_LARGE`
- `_showError()` 目前通过当前 context 的 `ScaffoldMessenger` 展示 SnackBar。

服务端生产配置通过 `TELEGRAM_BOT_TOKEN_FILE` → appconfig → stickers provider。

既然用户实测“没有任何提示”，说明**可见错误链仍不可靠**，不能以“代码里有 SnackBar”判定已完成。

## 必须分析

从 UI 到 Telegram API 全链核对：

1. 用户输入链接/pack name。
2. dialog pop 后 sheet 是否还 mounted。
3. API request 是否真正发出。
4. 服务端无 Bot Token 时返回哪个 HTTP status/code。
5. Telegram 404/401/429/5xx/timeout 如何映射。
6. pack 内 TGS/WebM/静态 WebP/不支持格式的处理。
7. error 到达 UI 时 context/ScaffoldMessenger 是否仍有效、SnackBar 是否被 sheet/overlay 遮挡或立即消失。
8. shared sticker pack card 的导入错误是否与 library import 使用一致的用户文案。

## 必须实现

1. 失败必须有**稳定可见**反馈；优先在当前 sticker sheet/dialog 内保留 operation error state，再辅以 SnackBar，而不是只依赖一次性 overlay。
2. 用户下一次重试/成功后合理清除旧错误。
3. 无 Bot Token 时明确告诉用户“服务端未配置 Telegram sticker relay”，生产文案不要只写 `infra/dev/.env`。
4. 网络 timeout/Telegram 限流/服务端 5xx 要有友好提示，同时保留可诊断错误码。
5. invalid link 在客户端本地直接提示。
6. pack 不存在要明确提示，不得无响应。
7. 部分贴纸不支持时：成功导入支持项，并显示成功数/失败数；不要整包静默失败。
8. 不回退动态 TGS/WebM 支持，不得重新引入“只支持静态 WebP”的旧限制文案。
9. 不记录 Telegram Bot Token。

## 测试场景

至少补：

- invalid URL/name。
- server 503 relay not configured。
- relay unavailable/timeout。
- Telegram pack not found。
- unsupported/too large。
- 部分成功。
- 成功后切换到新 pack。
- error widget/文案在 dialog 关闭后仍然可见。

## 主要文件

- `clients/app/lib/features/messaging/presentation/sticker_library_sheet.dart`
- `clients/app/lib/features/messaging/data/sticker_api_client.dart`
- sticker tests
- `server/internal/stickers/*`
- 对应 httpapi/error tests

## 禁止

- 不改 `text_chat_page.dart`，除非 shared-pack 导入存在同一明确 bug 且改动极小；若碰必须单独 commit。
- 不改 voice/calls/push。
- 不升级 sticker 依赖。

## 验证

```text
server: go test ./internal/stickers/... ./internal/httpapi/...
clients/app: dart analyze --fatal-infos
clients/app: flutter test <sticker相关测试>
```

## 交付

新增 `tasks/2026-08-14-bugfix/reports/AI05.md`，记录实际根因、错误矩阵、测试、生产 Token 配置复测方法，状态 `FIXED-PENDING-RETEST`。

建议 commit：

`fix(stickers): make Telegram import failures visible and actionable`
