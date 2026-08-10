# DD 人工测试 BUG 修复 TodoList

> 生成时间：2026-08-10
>
> 来源：根目录 `人工测试.md` 中用户本轮**明确打 ❌、明确写出失败现象、或在未勾选项旁直接写明异常**的内容。
>
> **重要：本文件不把普通 `[ ] 未测试` 当成 Bug。** 未测试项仍留在 `人工测试.md`，只有用户已经实际测出问题的内容才进入这里。
>
> 执行原则：**停止继续堆新功能，先把本文件清零。** 每个 Bug 必须做到“复现 → 定位根因 → 修复 → 自动回归 → 真人复测条件准备完成”，不允许只改提示文案或把异常吞掉。

---

# 0. 当前结论

> **2026-08-10 11:xx 修复轮状态：8 项均已完成代码修复与可自动化部分回归，进入短人工复测。**
>
> 不把“自动测试通过”冒充“真人设备已验收”。Windows 原生缩放/DPI、Android Heads-up、真实视频首帧、Telegram 真包导入与 Footer 肉眼闪烁仍必须按第 3 节做一次真机/真窗口复测。

| Bug | 代码状态 | 自动证据 | 仍需人工确认 |
|---|---|---|---|
| P0-01 Windows 原生窗口 | ✅ 已修 | 最新 Windows Release 构建通过 | 100/125/150% DPI 四边四角、标题栏、灰块 |
| P0-02 用户资料误判 unavailable | ✅ 已修 | contacts Go 全测 + `peer_profile_page_test` 通过 | Win/Android 各打开真实联系人 |
| P0-03 视频 Poster/发送前探针 | ✅ 已修 | fixture 经 ffprobe 确认真 MP4；Flutter 发送相关回归通过；Release 内含 libmpv | 真窗口/真机各发 1 个 MP4（headless `flutter_test` 无视频 surface，不能伪造截图绿灯） |
| P0-04 Sticker/Telegram Pack | ✅ 已修 | Go sticker/http + Flutter sticker tests 通过；旧 `.env` 自动补新可选键 | 重启服务端后上传自定义表情；配置 token 后导入 1 个真包 |
| P1-05 Android Heads-up/icon | ✅ 已修 | 新 `dd_messages_v2` MAX channel + icon 资源回归；Debug/Release APK 构建通过 | 真机后台收消息 |
| P1-06 媒体菜单“复制” | ✅ 已修 | `text_chat_page_test`：媒体 payload 不出现复制，全套 Flutter test 通过 | 长按 Sticker/视频快速确认 |
| P1-07 深色模式入口 | ✅ 已修 | 外观持久化 store + Settings widget tests；`flutter analyze` 0 issue | 浅色/深色/跟随系统肉眼确认 |
| P1-08 Footer 闪烁 | ✅ 已修 | 单一 `AnimatedPositioned` indicator；快速连续切换 widget test 通过 | Android 真机连续切换 20 次 |

### 本轮关键根因与修法

- **Windows 缩放**：Flutter child HWND 覆盖整个 client area，边缘 `WM_NCHITTEST` 落在子窗口，父 HWND 根本收不到。现通过 child subclass 把 8 个 resize hit-test 边缘透明回传给顶层，并按当前 DPI 计算边框/最小尺寸；同时处理 `WM_ERASEBKGND` 降低 resize 灰块。
- **联系人 unavailable**：稳定 userId 路由 404 被客户端一律解释成“用户不可用”。现仅对 404 做受约束 fallback：精确 DDID 或联系人列表必须证明是同一个 `user.id` 才恢复；真实不存在/blocked 仍保留 404 隐私语义。
- **视频 Poster**：旧逻辑把 `width/height/duration` 同时非零当硬前置，再固定等 160ms 截一次图。现 duration 独立等待，Poster 多时间点/多格式重试，成功 Poster 本身反推出显示宽高，不再因 libmpv 暂未暴露 geometry 就直接拒绝所有视频。
- **Sticker**：当前代码与开发环境版本可能错位；旧 `infra/dev/.env` 不会自动获得后续新增的可选键。现启动脚本非破坏式升级现有 `.env`（不轮换凭据），Sticker UI 保留 status/error code 并给出可执行错误信息。
- **Android 通知**：Notification Channel 创建后 importance 不可被同 id 覆盖。升级到 `dd_messages_v2` 并显式创建 `Importance.max / Priority.max` channel，避免旧测试安装污染。
- **媒体复制**：复制动作现只允许真正 `TEXT` 且有文本的消息，STICKER/VIDEO/IMAGE/GIF/AUDIO/FILE 不再因内部 payload text 误出现“复制”。
- **深色模式**：新增“设置 → 通用 → 外观”，支持跟随系统/浅色/深色，本地持久化并即时更新 `MaterialApp.themeMode`。
- **Footer**：从“每个 tab 各有一个 AnimatedContainer”改成“整条 bar 只有一个 AnimatedPositioned indicator”，快速切换不会叠多个选中动画。

### 自动门禁结果

- [x] `server: go test ./...` —— 通过。
- [x] `flutter analyze --no-pub` —— 0 issue（必须从 ASCII 短盘符执行；直接在中文路径下 Analysis Server 会发生 LSP `Unexpected end of input`，属于工具链路径问题）。
- [x] `flutter test` —— **189 passed / 5 skipped**；5 个均为真实视频 runtime probe：Windows `flutter_test` 无原生视频 surface，libmpv 永久 buffering，已明确保留人工真窗口验收而不是造假绿灯。
- [x] `flutter build windows --release --no-pub` —— 最新代码通过。
- [x] `flutter build apk --debug` —— 通过。
- [x] `flutter build apk --release --no-pub` —— 通过，产物约 135.5 MB。
- [x] `scripts/init-dev-env.ps1` / `scripts/run-auth-dev.ps1` PowerShell AST 语法解析 —— 通过。

### 构建工具链附带修复

项目位于中文目录时，Flutter Windows/Android Release/Analyzer 部分子进程会把路径转成乱码；但 Android Kotlin incremental cache 又不能在 `C:` Pub Cache 与短盘符项目之间计算相对路径。现 Android 明确 `kotlin.incremental=false`，以少量构建速度换取跨盘符 Release 稳定性。Windows/Analyzer 继续使用项目已有 `subst` ASCII 短路径策略。

---

# P0-01｜Windows 原生窗口系统完全异常

## 用户实测证据

`人工测试.md / B03`：

- ❌ 左边缘不可缩放。
- ❌ 右边缘不可缩放。
- ❌ 上边缘不可缩放。
- ❌ 下边缘不可缩放。
- ❌ 四个角均不可斜向缩放。
- 用户反馈：`所有的缩放均不可用`。
- ❌ 最小化 / 最大化 / 关闭按钮异常。
- ❌ Windows 11 圆角存在异常。
- ❌ 125% 显示缩放下边缘缩放异常。
- ❌ 150% 显示缩放下布局/文字存在验收失败。
- 用户反馈：`灰色斑块 标题栏完全异常`。

## 高度可疑位置

- `clients/app/windows/runner/win32_window.cpp`
- `clients/app/windows/runner/win32_window.h`
- `clients/app/windows/runner/flutter_window.cpp`
- `clients/app/lib/core/window/desktop_window_frame.dart`

当前工程已经自定义 Win32 非客户区，并自行处理 `WM_NCHITTEST`、DWM 圆角、标题栏拖动与 Flutter 子窗口布局。**四边和四角同时全部失效**，优先怀疑不是单个 Flutter Widget，而是顶层 HWND 的 window style / non-client hit-test / child content 覆盖 / DPI 坐标换算链存在问题。

## 修复任务

- [ ] 建立 Windows 原生窗口最小复现：881×657、100% DPI，验证 `WM_NCHITTEST` 是否实际收到边缘命中。
- [ ] 检查顶层窗口是否保留 `WS_THICKFRAME / WS_MAXIMIZEBOX / WS_MINIMIZEBOX / WS_SYSMENU` 等必要 style；自绘标题栏不能把系统缩放能力一起剥掉。
- [ ] 验证 Flutter child HWND 是否覆盖/吞掉了顶层窗口边缘 hit test。
- [ ] 对左/右/上/下/四角分别记录实际返回的 `HTLEFT / HTRIGHT / HTTOP / HTBOTTOM / HTTOPLEFT / ...`。
- [ ] DPI 计算必须基于当前窗口 DPI，不能把物理像素与逻辑像素混用。
- [ ] 修复最小化、最大化、关闭按钮真实调用，不允许按钮只变 hover 状态却不执行原生动作。
- [ ] 排查灰色斑块：重点检查 DWM frame、窗口背景擦除、透明/无边框窗口、Flutter child resize 时的未绘制区域。
- [ ] Windows 11 圆角必须由 DWM 与窗口形态一致控制，不能出现黑角/白边/灰块。
- [ ] 100% / 125% / 150% DPI 都进行真实窗口 resize 回归。

## 自动回归要求

- [ ] Windows runner 编译通过。
- [ ] Flutter Windows Release 构建通过。
- [ ] 已有标题栏/窗口相关 widget test 不回归。
- [ ] 如可行，给 native hit-test 逻辑拆出可测试函数，对 8 个边缘方向 + client area 做单元测试。

## 人工复测通过标准

- [ ] 四边可缩放。
- [ ] 四角可斜向缩放。
- [ ] 标题栏拖动、双击最大化正常。
- [ ] 最小化 / 最大化 / 关闭正常。
- [ ] 100% / 125% / 150% 下均无灰块、黑角、白边、文字截断。

---

# P0-02｜用户资料大量被误判为“用户不可用” / 关系状态异常

## 用户实测证据

`人工测试.md`：

- D03：`win端一堆用户不可用啊`
- E / Android：`安卓也是一堆用户`
- K03：`全部都是用户`

该问题同时出现在 Windows 与 Android，优先按**共享 API / 关系状态 / userId 数据链**排查，而不是分别修两个 UI。

## 高度可疑位置

客户端：

- `clients/app/lib/features/contacts/presentation/peer_profile_page.dart`
- `clients/app/lib/features/contacts/data/contacts_api_client.dart`
- `clients/app/lib/features/contacts/domain/contact_models.dart`
- 会话/联系人点击进入资料时传入的 `userId`

服务端：

- `server/internal/httpapi/contacts.go`
- `server/internal/contacts/service.go`

当前 `PeerProfilePage._load()` 会调用 `GET /api/v1/users/{userId}`，并把 **HTTP 404 直接解释成 `_unavailable = true`**。服务端 `relationshipForUser()` 又会把 blocked 关系刻意映射为 `ErrNotFound`。如果上游传错 userId、用户记录状态异常、旧会话里存了错误 ID、或关系查询返回了非预期 404，UI 就会大面积显示“用户不可用”。

## 修复任务

- [ ] 对以下入口逐个抓取并记录：点击联系人头像、聊天头像、联系人资料、好友申请资料、搜索结果资料时传入的 `userId`。
- [ ] 同时记录请求：`GET /api/v1/users/{userId}` 的 status、error code、relationship、返回 user.id。
- [ ] 验证**会话 peerUserId** 与**联系人 contact.user.id** 是否一致，排除把 conversationId / memberId / message sender 临时 ID 当 userId 的错误。
- [ ] 用两个真实已加好友账号验证服务端 `GetUserByID()` 必须稳定返回 `CONTACT`。
- [ ] 用 NONE / PENDING_OUTGOING / PENDING_INCOMING / SELF / BLOCKED 场景建立集成测试矩阵。
- [ ] 不允许把“网络失败 / 500 / JSON 解析失败 / token 问题”错误显示成“用户不可用”。只有明确业务语义的 404/账号不可见才可进入 unavailable UI。
- [ ] 如果 blocked 继续使用 404 隐私语义，客户端必须保证只有真实 blocked/不存在账号走这条链，不能扩大到正常联系人。
- [ ] 修复后联系人资料页的主操作必须按关系状态准确显示。

## 自动回归要求

- [ ] Go contacts service integration tests 覆盖 CONTACT/NONE/PENDING/SELF/BLOCKED。
- [ ] Flutter `peer_profile_page_test.dart` 增加正常 CONTACT 不可误判 unavailable 的测试。
- [ ] 增加“非 404 API 异常不得显示用户不可用”的测试。
- [ ] Windows / Android 共用逻辑只修一份，禁止平台分叉打补丁。

## 人工复测通过标准

- [ ] 正常联系人资料不再出现“该用户当前不可用”。
- [ ] Windows、Android 同一用户显示同一关系状态。
- [ ] NONE / PENDING / CONTACT / SELF / blocked 各自按钮与提示正确。

---

# P0-03｜视频发送主链失败：无法生成视频缩略图

## 用户实测证据

`人工测试.md`：

- C：`无法生成视频缩略图`
- I05：`视频报错 提示无法生成视频缩略图`
- I02 整条视频发送链均被打 ❌。

## 当前代码事实

`clients/app/lib/features/messaging/data/video_media_probe.dart` 当前使用 `media_kit Player`：

1. `player.open(..., play: true)`
2. 等待 width / height / duration
3. seek 到约 650ms
4. `player.screenshot(format: 'image/jpeg')`
5. screenshot 为 null/empty 就直接抛 `无法生成视频缩略图。`

`text_chat_page.dart::_sendVideo()` 在任何上传之前强依赖该 probe，因此 Poster 截图失败会让**整个视频发送直接中止**。

## 修复任务

- [ ] 用真实 MP4 在 Windows 和 Android 分别复现，确认失败发生在 metadata 阶段还是 `Player.screenshot()` 阶段。
- [ ] 记录 `media_kit` 当前 track、width、height、duration、screenshot 字节数，禁止 catch 后完全吞掉诊断信息。
- [ ] 验证 `MediaKit.ensureInitialized()` / 平台库初始化时机是否正确。
- [ ] 验证 Android 的本地文件 URI/path 传法是否正确，不能把 SAF/content URI 或不可读路径直接当普通文件路径。
- [ ] 如果 `media_kit screenshot` 在某平台不可靠，换成**明确支持 Windows + Android 的本地首帧/关键帧提取方案**，不要继续赌固定延时 160ms。
- [ ] Poster 失败不能让所有可播放视频无条件失去发送能力；应设计可靠 fallback：可重新取帧、取第一可解码帧，最终确实不支持时才明确报错。
- [ ] Poster 与主视频必须是两个独立 media reservation，目的类型与 MIME 正确。
- [ ] 视频 probe 必须在上传前完成，不能服务端回读整个视频生成元数据。
- [ ] 真正实现取消：取消后要中断主视频上传流；Poster 未开始则不得继续上传。
- [ ] 5xx/瞬时断网只做有上限、带退避的重试；4xx/权限/协议错误不重试。
- [ ] 上传进度只统计主视频真实已发送字节，不允许 UI 假进度。

## 自动回归要求

- [ ] 至少加入真实小 MP4 fixture，不能只 mock。
- [ ] Windows probe 测试可读取宽高、时长并生成非空 JPEG Poster。
- [ ] Android 能通过测试/集成验证的部分必须覆盖；不能验证的部分写入人工清单。
- [ ] media reservation：主视频与 poster 的 purpose/mime/sha/size 分别有测试。
- [ ] 取消/失败后 reservation 不残留到下一次发送并触发 `Uploaded object does not match the reserved media`。

## 人工复测通过标准

- [ ] MP4 至少双端互发成功。
- [ ] Poster 能立即显示。
- [ ] 不再出现“无法生成视频缩略图”。
- [ ] 再继续扩展 MOV/WebM/MKV 与大文件测试。

---

# P0-04｜表情库 / 自定义 Sticker / Telegram Pack 基本瘫痪

## 用户实测证据

`人工测试.md`：

- C：`表情库暂时加载失败`
- C：`添加telegram表情包无法加载`
- J：`表情包系统完全瘫痪`

这不是单个按钮样式问题，必须按“客户端 API → 服务端 StickerService → 数据库 migration → media grant → Telegram relay”整链排查。

## 高度可疑位置

客户端：

- `clients/app/lib/features/messaging/data/sticker_api_client.dart`
- `clients/app/lib/features/messaging/presentation/sticker_library_sheet.dart`
- `clients/app/lib/features/messaging/domain/sticker_models.dart`
- `clients/app/lib/features/messaging/domain/telegram_sticker_link.dart`

服务端：

- `server/internal/httpapi/stickers.go`
- `server/internal/stickers/`
- `server/migrations/000016_stickers.up.sql`
- `server/cmd/api/main.go`
- `infra/dev/.env` / `TELEGRAM_BOT_TOKEN`

## 修复任务

### A. 先恢复自定义表情库基础 API

- [ ] 登录后调用 `GET /api/v1/stickers/custom`，记录真实 HTTP status + body。
- [ ] 调用 `GET /api/v1/stickers/packs`，记录真实 HTTP status + body。
- [ ] 确认 migration `000016_stickers` 已实际执行到当前开发数据库。
- [ ] 确认 API 启动时 `stickersService != nil`；不得因为单个可选 Telegram token 缺失导致整个自定义表情服务不可用。
- [ ] `TELEGRAM_BOT_TOKEN` 为空时：自定义 Sticker 仍必须正常；只有 Telegram import 返回明确 `TELEGRAM_STICKER_RELAY_NOT_CONFIGURED`。
- [ ] 客户端不要把所有错误统一显示成“表情库暂时加载失败”；开发日志必须保留 status/error code。

### B. 自定义表情上传

- [ ] PNG / WebP / GIF 上传 → media READY → 创建 custom sticker → 立即刷新列表完整跑通。
- [ ] MIME、尺寸、10 MiB、4096×4096 限制必须在客户端与服务端双重校验。
- [ ] 上传失败不能留下空白格或无效数据库记录。

### C. Telegram Pack

- [ ] `https://t.me/addstickers/<setName>` 解析出纯 setName 后再发 API。
- [ ] `tg://addstickers?set=<setName>` 正常。
- [ ] 非 Telegram host、夹带任意外部 URL/query 的输入拒绝，不能形成 SSRF 代理。
- [ ] token 未配置必须给用户明确提示，而不是“加载失败”。
- [ ] token 已配置时使用真实 Telegram pack 做一次完整 import。
- [ ] 静态 WebP 可缓存/显示/发送。
- [ ] TGS/WebM 当前不支持时计入 unsupported 数量，不能显示空白格。
- [ ] 相同 pack 第二个账号订阅必须复用服务端缓存。

## 自动回归要求

- [ ] Go `server/internal/stickers/...` 全部测试通过。
- [ ] HTTP sticker handler 测试覆盖：未配置 token、非法链接、正常静态 pack、provider 失败。
- [ ] Flutter sticker API/client/library tests 全部通过。
- [ ] 增加“服务端无 Telegram token 时，自定义 Sticker 仍正常”的回归测试。

## 人工复测通过标准

- [ ] 打开表情库不报错。
- [ ] Emoji、自定义表情 tab 可正常切换。
- [ ] 上传 1 个 PNG/WebP/GIF 后立即可见并可发送。
- [ ] Telegram token 未配时提示明确；配置后 pack 可导入。

---

# P1-05｜Android 通知不 Heads-up，状态栏仍显示 Android 机器人图标

## 用户实测证据

`人工测试.md / F`：

- 权限申请出现。
- 通知必须手动下拉通知栏才能看到，没有预期弹窗/Heads-up。
- 用户反馈看到的仍是 Android 机器人图标，没有看到 DD 图标。

## 高度可疑位置

- `clients/app/lib/core/notifications/app_notification_service.dart`
- `clients/app/android/app/src/main/res/drawable/ic_stat_dd.xml`
- Android notification channel 已存在后的历史配置

当前代码已经声明 `Importance.high / Priority.high / icon: ic_stat_dd`，因此重点不能只看 Dart 参数。Android Notification Channel 一旦以较低 importance 创建过，后续改代码通常不会自动覆盖用户设备上的旧 channel 配置；同时需要验证打包 APK 内真正携带的 small icon 资源，以及系统实际收到的 icon resource id。

## 修复任务

- [ ] 在全新安装/清数据设备上验证 `dd_messages` channel 第一次创建时 importance。
- [ ] 如果历史 channel 已污染，升级 channel id（例如带版本号）或提供迁移策略，确保新安装/升级用户拿到正确 importance。
- [ ] 验证系统通知是否允许弹出横幅/Heads-up；如果系统设置层被关闭，要在设置页给出明确引导。
- [ ] 验证 `ic_stat_dd` 被打进 release APK，并且 `AndroidInitializationSettings` 与每条消息 `icon` 都引用它。
- [ ] 检查 small icon 必须为 Android monochrome 规范，不可用 launcher adaptive icon 代替。
- [ ] 连发多条通知验证不能偶发 fallback 到默认机器人图标。

## 人工复测通过标准

- [ ] 新消息在允许通知的情况下直接 Heads-up。
- [ ] 状态栏小图标是 DD 自己的 monochrome 图标。
- [ ] 展开通知仍显示正确 DD 身份与发送者头像。

---

# P1-06｜Android Sticker / 视频消息菜单仍出现无意义“复制”

## 用户实测证据

`人工测试.md / C`：

- 图片：通过。
- GIF：通过。
- ❌ Sticker 仍有无意义复制。
- ❌ 视频仍有无意义复制。

## 修复任务

- [ ] 查清消息 Action Sheet 的动作生成逻辑，不要只在图片/GIF case 特判。
- [ ] 把“复制”限定为真正存在可复制文本语义的消息类型。
- [ ] STICKER / VIDEO / IMAGE / GIF / AUDIO / FILE 等媒体消息不得出现“复制媒体”。
- [ ] 文字、含文字 caption（如果产品支持）分别处理，不要误删文字复制。
- [ ] Android 与 Windows 行为一致，但平台 UI 形式可以不同。

## 自动回归要求

- [ ] 对 TEXT / IMAGE / GIF / STICKER / VIDEO 类型逐一断言 action 列表。

---

# P1-07｜深色模式没有可发现入口，当前无法验收

## 用户实测证据

`人工测试.md / B04`：

- 三项深色模式验收被打 ❌。
- 用户明确反馈：`哪儿有深色模式开关？`

## 分析

这里至少包含一个确定的产品 Bug：**即使主题代码存在，只要用户找不到入口，就等于功能不可用。** 不应让人工测试人员通过隐藏开发开关或系统魔法才能完成测试。

## 修复任务

- [ ] 在“我的/设置/外观”提供明确可发现的主题入口。
- [ ] 至少支持：跟随系统 / 浅色 / 深色。
- [ ] 选择后立即生效并持久化，重启后保持。
- [ ] Windows Rail/Sidebar/Chat/TitleBar 必须统一主题层级。
- [ ] Android Footer、弹层、聊天页同步主题。
- [ ] 不允许某一栏纯黑、其它区域灰造成割裂。

## 人工复测通过标准

- [ ] 测试人员无需查文档即可找到主题设置。
- [ ] 浅色/深色/跟随系统都能实际切换。

---

# P1-08｜Android Telegram 风格悬浮 Footer 快速切换时闪烁

## 用户实测证据

`人工测试.md / O`：

- 其余 Footer 布局项大多通过。
- `[ ] 快速连续切换 4 个 tab 动画流畅。 动画会闪烁`

## 高度可疑位置

- `clients/app/lib/core/widgets/dd_floating_navigation_bar.dart`
- `clients/app/lib/features/shell/presentation/main_shell_page.dart`

## 修复任务

- [ ] 复现快速连续 4 tab 切换闪烁，确认是选中胶囊动画、页面切换、图标重建还是整个 Footer 重建。
- [ ] 检查是否存在 AnimatedSwitcher key 不稳定、每次切 tab 新建不同 subtree、透明度与背景同时交叉闪烁。
- [ ] Footer 容器本身应保持稳定，只动画选中 indicator/icon/text，不要整条 bar fade out/fade in。
- [ ] 页面内容切换与 Footer indicator 动画解耦，快速点击时取消/合并旧动画，不能叠加。
- [ ] 检查 RepaintBoundary 与不必要的大范围 setState，避免整个 Scaffold 重绘。
- [ ] 低端/60Hz Android 设备也要稳定，不以开发机高刷掩盖问题。

## 自动回归要求

- [ ] Widget test 连续快速切换 tab，不出现异常状态或多个 selected item。
- [ ] 如有 golden，保证中间帧不会出现 Footer 整体透明/空白。

---

# 1. 修复执行顺序

严格建议按以下顺序，不要乱并发改共享核心链：

1. [x] **P0-02 用户资料/关系状态异常** —— 代码修复 + 自动回归完成，待短人工复测。
2. [x] **P0-03 视频缩略图/发送链** —— 代码修复 + 真实 fixture 格式验证完成，待真窗口/真机发送复测。
3. [x] **P0-04 表情/Sticker/Telegram Pack** —— 代码修复 + 自动回归完成，待服务端重启后真包复测。
4. [x] **P0-01 Windows 原生窗口** —— native 修复 + 最新 Windows Release 构建完成，待 DPI 真人复测。
5. [x] **P1-05 Android 通知** —— channel v2/MAX + APK 构建完成，待真机 Heads-up 复测。
6. [x] **P1-06 媒体菜单复制项** —— 回归测试通过。
7. [x] **P1-07 深色模式入口与主题一致性** —— 入口/持久化/自动测试完成。
8. [x] **P1-08 Footer 闪烁** —— 单 indicator 动画 + 快速切换自动回归完成。

> Windows native 与 Flutter 业务 Bug 可以分支/分 Agent 并行，但不要两个 Agent 同时改 `main_shell_page.dart` / `text_chat_page.dart` 这类热点文件。

---

# 2. 每轮修复后的硬门禁

每完成 1～2 个 Bug，至少执行：

- [x] `go test ./...`（在 `server` 目录）。
- [x] Flutter `analyze`（ASCII 短路径下 0 issue）。
- [x] 受影响模块的 Flutter test。
- [x] Windows 相关修改：Windows Release build。
- [x] Android 相关修改：Android Debug + Release APK build。
- [x] 不允许为了“测试通过”删除/跳过原有测试（原有测试未跳过；仅新增的 headless 视频 runtime fixture 明确标注无法在无 surface 环境执行）。
- [x] 不允许 catch 后静默吞掉关键错误；Sticker/Profile 等关键异常已记录阶段/status/error code。

---

# 3. 下一次人工测试只测这些

在本文件未清零前，不需要重新从 `人工测试.md` A→Q 全部跑一遍。修完后先给用户一个**短回归清单**，只测：

- [ ] Windows 四边/四角缩放 + 标题栏 + 100/125/150% DPI。
- [ ] Windows/Android 各打开 3 个正常联系人资料，确认不再“用户不可用”。
- [ ] Android→Windows、Windows→Android 各发 1 个真实 MP4。
- [ ] 打开表情库、上传自定义表情、导入/验证一个 Telegram pack。
- [ ] Android 后台收一条消息，确认 Heads-up + DD small icon。
- [ ] Sticker/视频长按菜单无“复制”。
- [ ] 找到深色模式入口并切换一次。
- [ ] Android 快速连续切换 4 个 Footer tab 20 次，无闪烁。

以上短回归全部通过后，再恢复 `人工测试.md` 的剩余未测项目。

---

# 4. 完成定义

只有满足以下条件，本文件才允许标记完成：

- [x] 8 个 Bug 的代码修复全部落地。
- [x] 对应自动测试全部通过（视频 runtime fixture 的 5 项 headless 限制已明确标注，不把 skip 冒充真机通过）。
- [x] Windows / Android Release 构建成功。
- [x] 为本轮关键根因增加回归测试，防止下一轮再次出现同类问题。
- [x] 本文件第 3 节已提供短复测入口；`人工测试.md` 在进入本轮前已处于 Git 删除状态，因此没有擅自恢复/覆盖旧人工记录。
- [ ] **最后只差第 3 节 8 项真人短回归全部通过。** 通过后本 BUG 清单才允许彻底清零并继续新需求。
