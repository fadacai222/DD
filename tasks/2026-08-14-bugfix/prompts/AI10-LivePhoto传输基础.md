# AI10：Live Photo 传输基础

使用 @dd 开发 `C:\Users\admin\Desktop\复刻微信`。这是 Wave 2 独立 worktree 任务，基于总负责人提供的 `b601d98317fb3478d3c84227a4ee9dac76d0ae17`，不要直接修改 master，不 merge/rebase。

任务：补齐 iOS Live Photo 的选择、媒体模型与传输基础。最终聊天热点 UI 由总负责人统一接线。

## 用户需求与当前缺口

用户反馈“发照片功能缺少实况支持（Live Photo）”。Live Photo 至少包含静态图和配对动态视频，不能按普通图片处理。

当前 `clients/app/ios/Runner/Services/FilePickerService.swift` 使用 PHPicker，但每个选择结果只挑一个 image/movie representation 并复制单个文件，因此动态部分会丢失。

## 必须完成：iOS picker

1. 先用当前 iOS 15 target 的实际 API/测试确认 Live Photo 结果可得到哪些 representation，不靠记忆猜。
2. 区分普通照片、普通视频、Live Photo。
3. Live Photo 要返回静态 component + motion component 的成对信息。
4. 两个 component 都复制进 DD cache，不能继续引用系统 picker 的临时 URL。
5. 保持 path-based；禁止把大 MOV 整块读进 Dart/Swift 内存。
6. still/motion 分别做大小校验，并考虑组合总大小。
7. 任一 component 失败时清理已经复制的另一部分。
8. 普通 photo/video 旧行为不能回退。
9. 权限/representation 不足时返回明确 typed error，不能假成功后只静默发静态图。

建议扩展 `dd/file_picker` 的 result model，使 Live Photo 可以表达 media kind、still 文件、motion 文件及可选 asset identifier；字段名按现有项目风格决定。

## 必须完成：消息与媒体传输

优先做向后兼容：主消息继续沿用现有图片语义，让旧客户端至少显示静态图；在图片 content 中增加可选 paired motion media reference 和 Live Photo 标识。除非现有校验证明无法安全扩展，否则不要无必要新增全新 message type。

要求：

- still 和 motion 都走现有 media upload / ownership / confirm 生命周期。
- server 创建消息时验证两个 mediaId 都属于发送者且用途合法。
- 接收者读取 motion 仍受 conversation authorization 保护。
- foreign/malformed paired mediaId 必须拒绝，防 IDOR。
- recall/delete/data-rights 等生命周期覆盖 motion 对象。
- 转发、保存、旧客户端解析至少安全降级，不因额外字段崩溃。
- 同步 OpenAPI、server model、Flutter domain/data model。
- 如果 JSON content 足够表达，优先不新增 DB migration；如果确需 migration，开工前确认 `000036` 未占用再使用。

## 跨平台降级

- iOS/支持端能识别 still + motion。
- Android/Windows/Web 暂未实现实况播放时，也必须正常显示 still。
- 最终 UI 可在图片上显示“实况”标识并播放 paired motion；本分支要把字段和 helper 准备好。

## 热点文件限制

不要大改：

- `text_chat_page.dart`
- `conversations_page.dart`
- `main_shell_page.dart`

重点范围：

- `clients/app/ios/Runner/Services/FilePickerService.swift`
- `clients/app/lib/core/media/dd_file_picker.dart`
- media/message domain/data model
- server media/messaging validation
- OpenAPI/tests

## 测试

至少覆盖：

1. 普通 photo/video 回归。
2. Live Photo paired result。
3. component copy failure 后清理。
4. pair size limit。
5. 普通 IMAGE 无额外字段仍兼容。
6. paired media ownership/IDOR。
7. malformed content reject。
8. recall/delete/data-rights 相关生命周期。

运行：

```text
server: go test ./...
clients/app: dart analyze --fatal-infos
clients/app: flutter test <picker/media/message定向测试>
```

Windows 环境无法证明真实 iPhone Photos picker 时，必须留下 Xcode/iPhone 真人测试步骤，不能标 VERIFIED。

## 交付

新增 `tasks/2026-08-14-bugfix/reports/AI10.md`，写清 picker representation 证据、bridge payload、兼容设计、清理/授权、测试、Wave 3 接线字段、iPhone 真人步骤。状态 `FIXED-PENDING-RETEST`。

建议 commit：`feat(ios): preserve Live Photo paired media in messaging`
