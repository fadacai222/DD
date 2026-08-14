# AI09：补齐 Windows Ctrl+V 剪贴板图片能力

使用 `@dd`：`C:\Users\admin\Desktop\复刻微信`

你是 **AI09 / Windows Clipboard Image Adapter**。

## 依赖 / Git

- Wave 2 任务，只能基于总负责人提供的 `b601d98317fb3478d3c84227a4ee9dac76d0ae17` 创建独立 worktree。
- 不 merge/rebase master。
- 原子 commit。

## 用户需求

> Windows 端目前 Ctrl+V 只能粘贴文字，剪贴板里的截图/图片粘贴不了。

## 当前事实

项目已经依赖：

`pasteboard: ^0.5.0`

并且 `media_export_service.dart` / `remote_media_action_service_io.dart` 已经使用 pasteboard。

因此优先复用现有依赖，不要再引入第二套 clipboard plugin。

## 本分支职责

建立**可测试的 Windows clipboard image adapter + shortcut decision contract**，最终 `text_chat_page.dart` 的热点接线由总负责人做。

## 必须实现

### 1. Clipboard adapter

新增独立 service/interface，能力至少包括：

- 判断剪贴板是否有可读取图片。
- 读取 bitmap/image bytes。
- 如 pasteboard 能返回图片文件列表，也要能识别图片 file path。
- 返回统一结构：bytes/path、mime、建议文件名、size。
- 空剪贴板/坏数据返回明确 no-image 或 typed error，不抛未处理异常。

### 2. Ctrl+V 决策语义

为总集成提供 helper：

- Windows + clipboard 有图片 → 本次 Ctrl+V 由 DD 消费为“粘贴图片”。
- clipboard 只有文字 → **不要消费快捷键**，让 TextField 保持原生文本粘贴。
- clipboard 同时提供 bitmap + 文本 representation 时，优先图片，避免截图被当文字。
- 非 Windows 平台不改变现有粘贴行为。

### 3. 图片发送复用

不要新造上传协议。最终必须复用现有聊天图片链：

- size validation
- image processing/metadata cleanup
- media upload/confirm
- pending/retry
- preview/发送失败提示

你的 adapter 应输出足够信息让总负责人直接接到现有 send-image 方法。

### 4. 临时文件

如果底层发送链必须拿 path：

- 写入 App cache/temp 专用目录。
- 文件名不要信任 clipboard 外部输入。
- 发送完成/失败后按现有 cache policy 清理。
- 不在桌面/当前工作目录留下临时图片。

### 5. 边界

- 超大 clipboard image 走现有媒体大小限制，不能 OOM。
- malformed bitmap 不崩 App。
- Ctrl+V key repeat 不重复创建多条发送任务。
- 连续复制两张不同图片再粘贴应读取最新内容。
- 不能因为拦截 Ctrl+V 破坏 Ctrl+C / Ctrl+X / 中文输入法。

## 热点文件限制

本分支**不要大改**：

- `text_chat_page.dart`
- `main_shell_page.dart`

允许做一个最小 demo/test harness 或极小接口接线，但最终快捷键挂接由总负责人 Wave 3 做。

主要新代码建议放在：

- `clients/app/lib/core/media/` 或 `core/platform/`
- 对应 test

## 必须测试

通过 injectable fake clipboard adapter 覆盖：

1. image bytes → decision=consume image。
2. image path → 识别。
3. only text → decision=pass through。
4. image + text → image 优先。
5. empty → pass through。
6. malformed/exception → 不崩溃，回退文本或返回可见错误策略。
7. non-Windows → 不启用 image shortcut interception。
8. key repeat/dedup helper（如设计中存在）。

不要让 widget test 依赖真实 Windows 系统剪贴板，否则 CI 不稳定。

## 验证

```text
clients/app: dart analyze --fatal-infos
clients/app: flutter test <clipboard/core media tests>
```

如能在 Windows 本机做一次真实 clipboard smoke test，可以执行一次性命令/测试，不启动长驻服务。

## 交付

新增 `tasks/2026-08-14-bugfix/reports/AI09.md`：

- pasteboard 实际 API/格式
- adapter 契约
- text-vs-image precedence
- tests
- Wave 3 需要在 chat composer 接哪一个方法
- 真人测试清单
- 状态 `FIXED-PENDING-RETEST`

建议 commit：

`feat(windows): add clipboard image paste adapter`
