# DD「bug与需求反馈」完整闭环开发 Todo

> 来源：`未实现的新增需求/bug与需求反馈.md`
>
> 强制关联需求：`未实现的新增需求/实现用户提及的开发方案.md`
>
> 生成日期：2026-08-10
>
> 目标：**把原始反馈 0～13 + 2026-08-10 最新追加的 Android 悬浮 Footer 需求全部做到真实可用、跨端一致、自动测试可证明、最终可人工验收。任何一项未闭环，本批次都不得宣称“全部完成”。**

## 2026-08-10 本轮执行状态（优先读这里）

> 下面原始细分 Todo 保留作为设计/回归合同；由于该文件生成时所有子项默认都是 `[ ]`，本轮没有为了“看起来完成”机械把 1000+ 行全部改成 `[x]`。**后续 AI 判断是否需要继续写代码，先看本矩阵 + `开发进度跟踪.md`；判断是否最终上线，必须再看 `人工测试.md`。**

### 代码 / 自动门禁状态

- [x] R00 Windows 现代化 UI：Desktop token、Rail/Sidebar/Chat Header/TitleBar 统一；原生边缘 resize/DPI/圆角能力保留；881×657 自动回归已加。
- [x] R01 Android 媒体消息不再提供无意义“复制媒体”；文字复制不受影响。
- [x] R02 头像裁剪重写为 `imageRect + cropRect`，8 锚点、1:1、拖动、缩放、旋转、还原、完成/取消与最终像素坐标统一。
- [x] R03 联系人“发消息”统一回消息模块原位打开 DIRECT，不再另起错误整窗聊天。
- [x] R04 Android 每条系统通知显式使用 `ic_stat_dd`，首次安装通知权限链保留。
- [x] R05 DD 自生成消息/通话音效；Windows 声音 backend 与语音条统一到 media_kit，规避已知 MediaEngine 后端故障。
- [x] R06 Windows 语音播放改 media_kit；真实文件头识别 WAV/AAC/MP3/M4A/OGG，不盲信历史 MIME。
- [x] R07 视频链根修：发送前本地 probe/poster、stream upload、真 abort cancel、受控 retry、grant refresh、后台完整缓存、二次打开本地优先、orphan media worker cleanup。
- [x] R08 图片/GIF/视频合并唯一“相册”入口；文件独立；旧“更多→表情文件”入口移除。
- [x] R09 详细资料按 Telegram 式层级重构，并补 CONTACT/NONE/PENDING/不可用关系语义与双尺寸回归。
- [x] R10 Emoji + ❤️自定义表情 + Telegram Sticker Pack：数据库、API、Relay、缓存、权限、多设备同步、管理页、动态 tabs、OpenAPI、真实 PostgreSQL 集成均已落地。
- [x] R11 AuthBootPage 启动 Gate：有效会话不闪登录页；401 清失效会话；网络临时错误保留 token 并可重试。
- [x] R12 `@username` 完整 Message Entity + stable userId + Suggestion + Overlay/IME/键盘 + 通知 + `@all` 权限链已落地。
- [x] R13 `开发进度跟踪.md` 已更新为当前权威快照；`人工测试.md` 已重新生成最终验收清单。
- [x] R14 Android Telegram 风格全圆角悬浮 Footer 已落地，IME/SafeArea/未读 badge/深色模式均有组件回归。
- [x] OpenAPI 合同已同步并执行 lint。
- [x] `000016_stickers` 已在真实 PostgreSQL 做 up → 幂等 up → down → 再 up roundtrip。
- [x] Sticker owner/多设备/cache/订阅与 STICKER 发送权限已跑真实 PostgreSQL 集成测试。
- [x] Windows / Android APK / Web Release 构建已执行；根目录发布物由 `scripts/publish-client-artifacts.ps1` 统一刷新。

### 仍然必须由真人最终验收的系统能力

- [ ] Windows 125% / 150% DPI、四边四角实际拖拽、连续 Hover、真实圆角视觉。
- [ ] Android 不同 ROM 状态栏 `ic_stat_dd` 的真实 small icon。
- [ ] Windows/Android 消息音、来电、回铃、接通、挂断的真实听感与停止时机。
- [ ] Android ↔ Windows 真实语音条双向播放。
- [ ] Android ↔ Windows 真实 MP4/MOV/WebM/MKV 双向发送、Poster、播放、缓存、保存；不能用 Flutter headless test 宿主冒充真机视频解码结果。
- [ ] 配置真实 `TELEGRAM_BOT_TOKEN` 后导入真实公开 Telegram Sticker Pack。
- [ ] Android 360×640～大屏真机悬浮 Footer / 键盘 / SafeArea 视觉。
- [ ] 音视频通话、短时断网恢复、30 分钟稳定性最终回归。

> **结论：代码与自动门禁已进入最终人工验收阶段；在上面真人项目全部通过前，不得把项目写成“最终上线验收完成”。**

---

# 0. 给下一位 AI 的最高优先级执行规则

## 0.1 本文件是“执行合同”，不是参考建议

- [ ] 本文件所有标记为必做的任务必须全部实现。
- [ ] `未实现的新增需求/bug与需求反馈.md` 中 0～13 每一条都必须有代码实现或明确的验收证据对应，不允许漏项。
- [ ] 第 12 条“用户提及”不是一句简单需求，必须完整执行 `未实现的新增需求/实现用户提及的开发方案.md` 的协议、服务端、Flutter、兼容、安全、性能、测试要求。
- [ ] 不能因为 `开发进度跟踪.md` 或旧 `归档需求/需求-todolist.md` 曾写过“✅完成”就跳过本轮真实失败项。
- [ ] **用户最新真人反馈优先级高于旧自动测试结论。** 例如旧文档声称头像裁剪、音效、VIDEO 已完成，但本轮用户已经实际发现它们仍然不可用或体验不合格，必须重新打开并根修。
- [ ] 不能把“代码里有这个函数/按钮/资源”当成“功能完成”。必须证明真实入口能走通。
- [ ] 不能用 Widget Test 冒充真实系统能力已经通过。音频、通知图标、系统媒体选择、视频解码、Windows 音效、Android 真机手势仍需最终人工验收。
- [ ] 每个已复现 Bug 必须尽量新增自动回归测试，防止修完后再次回归。
- [ ] 不允许只隐藏异常、吞异常、改错误文案来冒充根因修复。
- [ ] 不允许把失败路径改成静默失败。用户可恢复的问题必须给明确的重试、取消或错误说明。
- [ ] 不允许只修 Android 而让 Windows 退化，也不允许只修 Windows 而破坏 Android/Web。
- [ ] 未来 iOS 共用的 Flutter Domain/API/缓存/媒体/提及协议必须保持平台无关；平台特有能力通过 adapter/backend 隔离。

## 0.2 长时间连续开发规则

用户要求下一位 AI 尽可能长时间持续推进本批次，不要每做一个小功能就停止等待人工测试。

执行方式：

- [ ] 默认采用“批量开发 → 自动测试 → 自查 → 再开发 → 最后统一人工验收”的节奏。
- [ ] 除非遇到**确实无法绕过**的外部凭据、真机权限、账号验证码、第三方服务密钥等人类阻断，否则不要因为单个阶段完成就停下来。
- [ ] 不要为了“消耗上下文”制造无意义输出；上下文预算应全部用于读代码、实现、测试、审计、修回归和文档闭环。
- [ ] 如果一个会话上下文接近上限，先把真实完成状态、失败证据、下一步写回本文件与 `开发进度跟踪.md`，保证下一个会话能无损接力。
- [ ] **只有“本文件 Definition of Done 全部满足”或出现不可绕过的人类阻断时，才允许结束本批开发。**

## 0.3 工作树保护规则

当前项目已有大量未提交修改，下一位 AI 必须保护现状：

- [ ] 开工先执行 `git status --short` 并阅读现有改动。
- [ ] 禁止 `git reset --hard`。
- [ ] 禁止 `git checkout .` / `git restore .` 覆盖用户或前一位 AI 的修改。
- [ ] 禁止因为测试失败就删除数据库 volume、清 Android App 数据或清用户聊天数据，除非测试明确要求且有备份/隔离环境。
- [ ] 修改项目文件使用 DD 的编辑/写入能力，不用 shell 重定向破坏编码。
- [ ] 中文 Markdown、Dart、Go、PowerShell 统一按 UTF-8 处理。

---

# 1. 本批次全局 Definition of Done

本批次**只有同时满足以下全部条件才允许写“完成”**：

- [ ] R00 Windows 主界面完成现代化重设计，大黑侧栏问题关闭，881×657 默认窗口仍可用。
- [ ] R01 Android 图片/视频/GIF/Sticker 等媒体 UI 不再提供无意义“复制”按钮。
- [ ] R02 头像裁剪编辑器已按新交互模型推翻重写，长截图/横图/方图均正确，支持 8 锚点、旋转、还原、完成、取消。
- [ ] R03 联系人详情点击“发消息”会切换到“消息”模块并在消息主区域打开该 DIRECT 会话，不再另起一个错误的全窗口私聊。
- [ ] R04 Android 系统通知状态栏使用 DD 自己的通知小图标，不再出现默认 Android 机器人/错误图标。
- [ ] R05 Windows 与 Android 都有正常消息提示音、来电铃声、去电等待音、接通/挂断音；铃声已替换为更适合 IM 的原创/可商用声音。
- [ ] R06 Windows 可以稳定播放 Android/Windows 发来的真实语音条，不再全量“语音播放失败”。
- [ ] R07 视频发送主链重新审计并根修，Android ↔ Windows 至少使用多种真实样本全部可发送、同步、加载 poster、播放、保存/下载。
- [ ] R08 附件入口合并为“相册”，统一选择图片/视频/GIF；不再把图片/GIF/视频拆成三个割裂入口。
- [ ] R09 “详细资料”页面完成 Telegram 式信息层级与对齐重设计，桌面和移动端均无明显错位。
- [ ] R10 Emoji 面板扩展为“Emoji + 自定义表情 + Telegram 贴纸包”，支持管理、上传、整理、多选删除、服务端贴纸包中转和动态选项卡。
- [ ] R11 Android 启动有完整 DD Splash/Boot 第一屏；已有有效会话时不闪登录页，优先进入聊天主界面，只有确实无法恢复认证时才进入登录注册。
- [ ] R12 用户提及 `@username` 完整实现，采用服务端 Message Entity + 稳定 userId，不是前端正则假链接。
- [ ] R13 更新 `开发进度跟踪.md`，并重新生成根目录 `人工测试.md`。
- [ ] R14 Android 主界面底部 Footer/Tab Bar 改造成 Telegram 参考风格的**全圆角悬浮导航条**：脱离屏幕底边形成明确浮层、外轮廓完整圆角、选中项有 DD 品牌化胶囊态、阴影/边框克制、SafeArea 正确、不会遮住内容或键盘，360×640 到大屏手机均保持漂亮且稳定。
- [ ] 新增/修改代码全部 formatter 通过。
- [ ] `flutter analyze --fatal-infos` 0 issue。
- [ ] Flutter 自动测试全绿。
- [ ] `go test ./...` 全绿。
- [ ] OpenAPI lint/合同测试全绿。
- [ ] 真实 PostgreSQL 相关集成测试全绿。
- [ ] Realtime 自动测试全绿。
- [ ] Windows Release 构建通过。
- [ ] Android APK 构建通过。
- [ ] Web Release 构建通过。
- [ ] 根目录 `DD-Android.apk`、`DD-Windows.lnk`、`DD-Web.lnk` 仍可正确产出/更新。
- [ ] 最终 `人工测试.md` 覆盖本文件每一个真人可见需求，并提供 `[ ] / ✅ / ❌ / 测试反馈` 记录位。
- [ ] 不存在已知 P0/P1 阻断 Bug 被“暂时忽略”。

---

# 2. 开工基线与复现阶段（必须先做）

## B00｜阅读与对照

- [ ] 阅读 `AGENTS.md`。
- [ ] 阅读本文件。
- [ ] 完整阅读 `未实现的新增需求/bug与需求反馈.md`。
- [ ] 完整阅读 `未实现的新增需求/实现用户提及的开发方案.md`。
- [ ] 阅读 `开发进度跟踪.md`，只把它当历史证据，不能覆盖本轮真人反馈。
- [ ] 阅读 `docs/12-产品体验与UI功能基线.md`。
- [ ] 阅读 `docs/14-2026-08-09-登录联系人媒体缓存稳定性增量.md`。
- [ ] 涉及 API/数据模型时同步阅读 `docs/05-API与数据模型草案.md`。
- [ ] 涉及测试/发版时同步阅读 `docs/06-测试验收与发布标准.md`。

## B01｜当前代码热点确认

至少审计以下现有实现，避免重复造轮子或在错误层修补：

```text
clients/app/lib/app.dart
clients/app/lib/theme/app_theme.dart
clients/app/lib/core/window/desktop_window_frame.dart
clients/app/lib/core/media/avatar_crop_page.dart
clients/app/lib/core/media/avatar_image_processor.dart
clients/app/lib/core/media/chat_voice_recorder.dart
clients/app/lib/core/media/image_viewer_page.dart
clients/app/lib/core/media/media_export_service.dart
clients/app/lib/core/sound/app_sound_service.dart
clients/app/lib/core/notifications/app_notification_service.dart
clients/app/lib/features/auth/presentation/auth_page.dart
clients/app/lib/features/auth/data/auth_session_vault.dart
clients/app/lib/features/shell/presentation/main_shell_page.dart
clients/app/lib/features/contacts/presentation/contacts_page.dart
clients/app/lib/features/contacts/presentation/peer_profile_page.dart
clients/app/lib/features/messaging/application/messaging_coordinator.dart
clients/app/lib/features/messaging/data/media_api_client.dart
clients/app/lib/features/messaging/data/media_local_cache.dart
clients/app/lib/features/messaging/data/media_download_grant_cache.dart
clients/app/lib/features/messaging/data/voice_playback_source.dart
clients/app/lib/features/messaging/data/video_media_probe.dart
clients/app/lib/features/messaging/domain/messaging_models.dart
clients/app/lib/features/messaging/presentation/text_chat_page.dart
clients/app/lib/features/messaging/presentation/video_viewer_page.dart
server/internal/media/
server/internal/messaging/
server/internal/contacts/
server/internal/httpapi/
server/openapi/openapi.json
```

- [ ] 确认当前 `TextChatPage` 已非常大，新功能优先拆组件/服务，不能继续无边界堆进单文件。
- [ ] 确认当前 `app.dart` 直接 `home: AuthPage()` 会造成启动时登录页先参与构建，本轮启动流程需要重新设计 Boot Gate。
- [ ] 确认 Android notification 初始化当前使用 `ic_stat_dd`，进一步检查为什么真实通知仍出现错误小图标，不能因为资源文件“存在”就判定成功。
- [ ] 确认当前 VIDEO、VOICE、Sticker 代码虽存在，但以真实失败为准重新排查完整链路。

## B02｜复现与证据

- [ ] Windows 默认尺寸 881×657 截图/记录当前三栏结构、黑侧栏、标题栏、hover、选中态、联系人详情和资料页布局。
- [ ] Android 使用至少一张 9:16 长截图进入头像裁剪，记录初始 image transform、crop rect、最终输出错误。
- [ ] Windows 从联系人详情点击“发消息”，确认当前错误导航路径并定位具体调用链。
- [ ] Android 发一条真实系统通知，截图状态栏 small icon 与展开通知。
- [ ] Android → Windows 发真实语音条，记录下载授权、缓存路径、MIME、容器、播放器错误。
- [ ] Windows → Android 发真实语音条，确认反向链路。
- [ ] 使用真实 MP4、MOV、WebM、MKV 中至少项目宣称支持的格式逐个测试 VIDEO，记录失败发生在“选择、探测、reserve、upload、commit、message send、download、decode”的哪一层。
- [ ] 记录 Android 启动时登录页闪现/停留与 session restore 时间线。
- [ ] 所有可复现异常都留下日志或测试断言，不用“看起来可能是”代替根因。

---

# 3. R00｜Windows DD 现代化 UI 全面重设计

> 原反馈：左侧大黑条不符合现代审美；整个软件土；参考 Windows 微信和 Telegram，取其精华，做成未来三五年仍不过时的 UI。

## R00.1 设计原则先定稿

- [ ] 保留 DD 品牌识别，不直接复制微信/Telegram 专有图标、素材和声音。
- [ ] 桌面端采用清晰的“三层信息架构”：全局导航 / 会话或联系人列表 / 内容详情。
- [ ] 去掉“整块纯黑导航条压住视觉”的感觉。
- [ ] Light Mode 左侧导航与应用背景融为同一视觉体系，使用中性灰/半透明/弱层级表面，不再固定 `#2E2E2E` 大黑块。
- [ ] Dark Mode 使用统一深色 surface 层级，不把侧栏做成与其它区域完全割裂的黑洞。
- [ ] 颜色、圆角、间距、字号、hover、pressed、selected、focus、disabled 全部 token 化。
- [ ] 不用过量渐变、厚阴影、玻璃模糊制造廉价“AI UI”。
- [ ] 视觉优先级参考微信的克制与 Telegram Desktop 的轻快、清晰、快速响应。
- [ ] 所有动画都以低延迟、可取消、不会拖慢操作为原则。

## R00.2 Desktop Design Token 重构

建议在现有 `app_theme.dart` 基础上增加桌面语义 token，而不是散落魔法数字：

- [ ] `navigationSurface`
- [ ] `sidebarSurface`
- [ ] `contentSurface`
- [ ] `hoverSurface`
- [ ] `selectedSurface`
- [ ] `activeIndicator`
- [ ] `borderSubtle`
- [ ] `titleBarSurface`
- [ ] `desktopNavWidth`
- [ ] `conversationPaneWidth`
- [ ] `desktopTitleBarHeight`
- [ ] `desktopRowHeight`
- [ ] `desktopCompactControlHeight`

- [ ] 所有 token 同时提供 light/dark 值。
- [ ] 不再让 `DdColors.desktopRail = #2E2E2E` 成为整个桌面视觉唯一来源。
- [ ] 检查 Material3 默认色是否和 DD 自定义 token 冲突。

## R00.3 左侧全局导航重做

- [ ] 视觉上移除“大黑条”。
- [ ] 保留头像、消息、联系人、发现、我的/设置等全局入口，但重新设计 spacing 和 selected state。
- [ ] 导航 icon 使用统一线性风格，选中时才使用强调色/填充变化。
- [ ] hover 有轻量背景反馈，不造成卡顿。
- [ ] selected 使用局部高亮，不使用整列强色块。
- [ ] 未读 badge 与导航 icon 对齐，不溢出。
- [ ] 头像与底部设置区域有稳定 safe padding。
- [ ] 881×657 下所有入口仍完整可见。
- [ ] 更高 DPI/125%/150% Windows 缩放下不截断。

## R00.4 会话/联系人侧栏重做

- [ ] 标题、搜索框、新建动作处于统一 header 区。
- [ ] 搜索框高度和圆角更接近现代桌面 IM，不占用过多垂直空间。
- [ ] 会话 row 重新校准头像尺寸、名称、摘要、时间、未读数、免打扰、置顶状态。
- [ ] 选中会话背景明显但克制。
- [ ] hover 与 selected 不冲突。
- [ ] 置顶会话可使用非常轻的 surface 差异，不做强烈色块。
- [ ] 长昵称、长预览、超大未读数、Emoji 名称都不 overflow。
- [ ] 联系人页与消息页使用同一桌面视觉语言。

## R00.5 中央聊天区域重做

- [ ] 顶栏高度、头像、名称、状态、通话按钮、`...` 对齐统一。
- [ ] 聊天背景、消息气泡、时间分隔、系统状态的视觉层级统一。
- [ ] 输入区域与消息区域分界轻量化。
- [ ] 输入框、Emoji、语音、附件、发送按钮尺寸一致。
- [ ] hover/tooltip 不闪烁、不抢焦点。
- [ ] 输入焦点发送后保持。
- [ ] 881×657 下输入 footer 不溢出、不被标题栏挤压。

## R00.6 Windows 原生窗口壳

重点文件：

```text
clients/app/lib/core/window/desktop_window_frame.dart
clients/app/windows/runner/
```

- [ ] 保持自定义标题栏与窗口拖动逻辑稳定。
- [ ] 四边四角 resize 继续可用。
- [ ] 最大化/还原/最小化/关闭 hover 不再出现色块异常。
- [ ] 标题栏与左侧导航颜色融为一个产品壳，不出现“上面一条、左边一条”拼接感。
- [ ] 圆角窗口在 Windows 11 正常，Windows 不支持圆角时优雅退化。
- [ ] 不为了视觉效果引入高成本实时 blur 导致 hover/拖窗掉帧；任何 Mica/Acrylic 类效果先做性能验证。

## R00.7 响应与性能

- [ ] 高频 hover 不触发大面积 rebuild。
- [ ] 会话滚动 60fps 目标不因阴影/BackdropFilter 下降。
- [ ] 聊天长列表不因视觉重构破坏 lazy list。
- [ ] Windows 拖动窗口、resize、最大化时无明显卡死。
- [ ] 用 Flutter DevTools/性能日志确认没有明显 raster/build 峰值回归。

## R00.8 自动测试

- [ ] 881×657 Widget 几何测试更新为新布局。
- [ ] 导航 selected/hover/focus 状态 Widget Test。
- [ ] 会话 long text / badge overflow 测试。
- [ ] Windows 联系人 → 消息统一路由测试与 R03 联动。
- [ ] 亮/暗主题 smoke test。

## R00 完成判定

**禁止用“颜色改浅了”关闭 R00。** 必须完成桌面视觉系统、导航、列表、聊天、窗口壳、状态反馈的一致性重构，并在最终 `人工测试.md` 中单列 Windows 881×657 视觉验收。

---

# 4. R01｜Android 媒体“复制”按钮全部取消

> 原反馈：Android 图片/视频/GIF 等媒体根本不好复制，媒体类复制按钮全部取消。

## R01.1 范围

Android 下以下媒体都不应出现“复制”动作：

- [ ] IMAGE
- [ ] GIF
- [ ] STICKER
- [ ] VIDEO
- [ ] 头像/图片查看器中的媒体复制按钮
- [ ] 聊天媒体分类页中的媒体复制按钮
- [ ] 消息长按菜单中的媒体复制动作

## R01.2 保留行为

- [ ] Android 仍保留“保存到相册/下载/分享（若已有且真实可用）”等合理媒体动作。
- [ ] 文本消息“复制文字”不能被误删。
- [ ] Windows/Web 的媒体复制能力若真实可用，可以保留，不能因为 Android 需求全平台删掉。

## R01.3 实现原则

- [ ] UI capability 根据平台明确决定，不用点击后再弹“不支持”。
- [ ] `image_viewer_page.dart`、`video_viewer_page.dart`、`conversation_media_page.dart`、`text_chat_page.dart` 统一检查。
- [ ] 不留不可达 dead handler。

## R01.4 测试

- [ ] Android TargetPlatform Widget Test：媒体菜单不包含复制。
- [ ] Windows TargetPlatform Widget Test：原本支持的复制动作仍存在。
- [ ] 文本复制回归测试。

---

# 5. R02｜头像裁剪编辑器推翻重写

> 原反馈：长图/截图初始位置错误，当前编辑器整体逻辑不合格。不要继续在旧编辑器上死磕，直接重写。

## R02.1 不允许的做法

- [ ] 不允许只调一个 `BoxFit` 或 clamp 数值就宣称修好。
- [ ] 不允许继续沿用导致初始长图错位的旧 transform 模型。
- [ ] 不允许把原图强行拉成正方形。
- [ ] 不允许最终导出的 crop 与用户看到的裁剪框不一致。

## R02.2 新页面视觉结构

按用户给出的微信参考逻辑实现：

- [ ] 背景层全屏，使用深色/黑色编辑背景以突出图像。
- [ ] 图片层保持原图宽高比，禁止压扁/拉伸。
- [ ] 初始状态优先“等宽展示”：图片宽度与可编辑区域宽度对齐，长图自然超出上下区域。
- [ ] 图片初始居中，不能一打开就只看到错误局部或空白。
- [ ] 裁剪框始终为正方形。
- [ ] 裁剪框默认处于合理中央区域，不被系统状态栏/底部按钮遮挡。
- [ ] 裁剪框外区域有半透明遮罩。
- [ ] 裁剪框边界清晰，八个 resize anchor 清晰可点击。

## R02.3 八锚点裁剪框

必须提供：

- [ ] 左上角
- [ ] 上中
- [ ] 右上角
- [ ] 右中
- [ ] 右下角
- [ ] 下中
- [ ] 左下角
- [ ] 左中

交互：

- [ ] 拖动任一锚点都可缩放裁剪框。
- [ ] 无论拖哪个锚点，裁剪框最终保持 1:1 正方形。
- [ ] 角锚点以对角/相对锚点为主要固定参考缩放。
- [ ] 边锚点缩放时同步调整另一维，保持正方形并避免跳变。
- [ ] 设置合理最小裁剪尺寸，防止缩成几像素。
- [ ] 最大尺寸不能越出实际可裁图片区域。
- [ ] resize hit target 大于视觉锚点，移动端容易点中。

## R02.4 图片平移/缩放

- [ ] 用户可以拖动图片调整裁剪位置。
- [ ] 双指缩放图片时保持比例。
- [ ] 缩放下限保证裁剪框内不会出现无图空白。
- [ ] 缩放上限避免 GPU/内存异常，可结合源图分辨率设置。
- [ ] 拖动 clamp 以裁剪框为约束，而不是以整个屏幕错误约束。
- [ ] 裁剪框 resize 后重新计算图片允许移动范围。
- [ ] 手势冲突需要明确：拖图片与拖锚点不能互相抢 pointer。

## R02.5 底部四个按钮

用户明确要求：

- [ ] 完成
- [ ] 取消
- [ ] 图片旋转
- [ ] 还原

具体行为：

- [ ] “旋转”每次 90°，旋转后重新计算图像尺寸、transform、裁剪有效范围。
- [ ] 支持连续 90/180/270/360°，360°回到一致状态。
- [ ] “还原”恢复页面刚打开时的图片方向、缩放、平移和默认裁剪框。
- [ ] “取消”无副作用返回，不上传、不覆盖头像。
- [ ] “完成”只在合法 crop 时可用，防重复点击。

## R02.6 EXIF / 像素坐标 / 最终导出

- [ ] 解码时统一处理 EXIF orientation，显示坐标与导出像素坐标使用同一方向基准。
- [ ] UI viewport 坐标 → 原图像素 crop rect 通过明确矩阵/比例转换。
- [ ] 旋转后 crop rect 映射正确。
- [ ] 长截图不得被压缩成畸形比例。
- [ ] 横图、竖图、方图、超高长图、超宽图都必须覆盖。
- [ ] 输出头像仍遵守现有大小/压缩/格式策略，并保证最终上传结果与预览一致。

## R02.7 内存与性能

- [ ] 超大照片不能在 UI 线程反复做全尺寸重采样。
- [ ] 继续使用 isolate/后台处理现有 `avatar_image_processor.dart` 能力，必要时重构接口。
- [ ] 编辑预览使用适当 decode target，完成时再生成最终头像。
- [ ] 连续缩放/拖动保持流畅。

## R02.8 测试

单元/Widget Test 至少覆盖：

- [ ] 1080×2400 长截图初始变换正确。
- [ ] 2400×1080 横图初始变换正确。
- [ ] 1080×1080 方图初始变换正确。
- [ ] 八个锚点均能改变 crop size 且保持 1:1。
- [ ] crop 不越界。
- [ ] 旋转 90/180/270/360 正确。
- [ ] 还原恢复初始状态。
- [ ] 取消无输出。
- [ ] 完成输出与 UI crop 对应。
- [ ] 手势不会产生 NaN/Infinity/负尺寸。

## R02 完成判定

必须在 Android 真机用一张真实长截图、一张竖拍照片、一张横图完成头像裁剪，并在 `人工测试.md` 中让用户验证“打开第一帧就是对的、拖动/缩放/八锚点/旋转/还原都符合直觉”。

---

# 6. R03｜联系人“发消息”必须回到消息模块内打开私聊

> 原反馈：联系人 → 选择联系人 → 发消息，现在会另开满窗口私聊。正确逻辑是切换到“消息”，然后在消息区域打开该私聊。

## R03.1 目标导航语义

- [ ] 从联系人详情点击“发消息”先 `ensureDirectConversation(userId)`。
- [ ] 获取/复用唯一 DIRECT conversation。
- [ ] 切换 MainShell 当前一级导航到“消息”。
- [ ] 会话列表自动选中该 conversation。
- [ ] 右侧聊天内容区显示该会话。
- [ ] 不额外 push 一个覆盖整个桌面窗口的 `TextChatPage`。
- [ ] 已存在会话直接复用，不创建重复 DIRECT。

## R03.2 路由/状态架构

- [ ] 在 `MainShellPage` 建立可复用的“从任意模块打开会话”入口，例如语义等价的 `openConversation(conversationId)`。
- [ ] Contacts 不自己管理另一套聊天 Navigator。
- [ ] Mention、通知点击、搜索结果、资料页“发消息”以后也优先复用同一入口，减少路由分叉。
- [ ] 桌面端切换后联系人详情残留状态不覆盖消息内容。
- [ ] 移动端可保留符合手机习惯的页面 push，但一级 tab 状态必须正确；不能为满足桌面逻辑破坏 Android 返回栈。

## R03.3 测试

- [ ] Windows Widget Test：Contacts → Peer → 发消息 → shell selected section == messages。
- [ ] 对话列表 selected conversation 正确。
- [ ] 同一联系人连续点击 3 次只有一个逻辑 DIRECT。
- [ ] 从消息切回联系人再发消息仍正确。
- [ ] Android 导航回归测试。

---

# 7. R04｜Android 通知必须显示 DD 自己的小图标

> 原反馈：系统通知红框位置出现默认 Android 小图标，看起来像野鸡 App。

## R04.1 根因检查

当前存在：

```text
AndroidInitializationSettings('ic_stat_dd')
clients/app/android/app/src/main/res/drawable/ic_stat_dd.xml
```

但真实设备仍异常，因此必须继续检查：

- [ ] 通知实际 channel/notification 是否显式使用正确 small icon。
- [ ] `flutter_local_notifications` 当前 Android API 的 icon fallback 行为。
- [ ] 旧通知 channel/旧 APK 是否缓存旧配置。
- [ ] `ic_stat_dd.xml` 是否满足 Android notification small icon 的单色 alpha 规范。
- [ ] 是否错误使用 adaptive launcher icon 作为 small icon。
- [ ] Android 13/14/15 不同 ROM 是否退化成默认 app icon/机器人图标。

## R04.2 实现要求

- [ ] 设计一个 DD 品牌可辨识的单色通知 glyph。
- [ ] small icon 必须使用透明背景 + 单色轮廓/实心前景，符合 Android 状态栏规范。
- [ ] 在 `AndroidNotificationDetails` 明确绑定 DD small icon，不只依赖初始化默认值。
- [ ] sender avatar 继续作为 large icon / MessagingStyle Person icon，与 DD small icon 职责分离。
- [ ] manifest 的 launcher icon 继续使用 DD 正式图标。
- [ ] 新安装与覆盖安装都能看到正确 DD 图标。

## R04.3 测试

- [ ] Android 通知初始化自动测试确认资源名一致。
- [ ] 构建阶段校验 `ic_stat_dd` 资源存在。
- [ ] 真机锁屏/状态栏/展开通知截图验收。
- [ ] 深色/浅色状态栏都清晰。

---

# 8. R05｜Windows + Android 消息/通话音效完整恢复并重做铃声

> 原反馈：只有 Android 有通话音效；Windows 连消息通知音都没有；现有来电铃声难听，需要换。

## R05.1 先验证现状，不信旧“已完成”结论

- [ ] Windows 上直接调用 `AppSoundService` 每个 cue，确认 asset 是否能加载/播放。
- [ ] 检查 `pubspec.yaml` 音频 asset 是否被 Windows bundle 打包。
- [ ] 检查 `audioplayers` Windows backend 是否初始化正常。
- [ ] 检查路径大小写、asset URI、release 构建差异。
- [ ] 检查系统静音/应用 volume/audio device 切换。
- [ ] 检查自定义 Windows 通知 popup 是否绕过了系统音且 DD 自播又没有触发。

## R05.2 必须存在的 cue

Windows 和 Android 都要实际工作：

- [ ] 新消息提示音
- [ ] 来电铃声（循环）
- [ ] 去电等待/回铃音（循环）
- [ ] 接通提示音（一次）
- [ ] 挂断提示音（一次）

## R05.3 新铃声设计

- [ ] 替换当前用户认为难听的来电铃声。
- [ ] 使用 DD 自有生成/原创/明确可商用的声音，禁止直接复制 Telegram/微信/Apple 专有音频。
- [ ] 来电铃声要清晰但不过度尖锐，循环接缝无爆音。
- [ ] 消息音短、辨识度高、不会连续多消息变成噪音墙。
- [ ] 去电音与来电音明显不同。
- [ ] 接通/挂断音长度短且状态语义清晰。

## R05.4 状态机

- [ ] 来电开始 → incoming ringtone loop。
- [ ] 接听/拒绝/取消/超时 → 立即停止 incoming ringtone。
- [ ] 去电开始 → outgoing ringback loop。
- [ ] 对方接听 → 停止 ringback + 播接通音。
- [ ] 任一方挂断 → 停止所有 loop + 播挂断音一次。
- [ ] 快速状态变化不能产生两个 loop 叠加。
- [ ] 新消息免打扰时不播放消息音。
- [ ] 当前会话前台策略按产品逻辑执行，不能重复系统音 + DD 音双响。

## R05.5 Windows 音频设备/Audio Focus

- [ ] Windows 默认输出设备切换后下次播放可恢复。
- [ ] 蓝牙/耳机拔插不导致 sound service 永久失效。
- [ ] 通话媒体音频和 UI cue 不互相抢占导致通话无声。
- [ ] 资源释放正确，不长期占用播放器。

## R05.6 测试

- [ ] `AppSoundService` 状态机单元测试。
- [ ] Windows backend smoke test（能确认 API 调用成功，真实听感留人工）。
- [ ] Android backend smoke test。
- [ ] 快速接听/挂断不会残留 loop。
- [ ] 免打扰不播放消息音。
- [ ] 最终人工测试分别在 Android 与 Windows 真设备听全部 cue。

---

# 9. R06｜Windows 语音条播放失败根修

> 原反馈：Windows 语音条已经完全不可用，直接提示“语音播放失败，请稍后重试”。

## R06.1 必须定位到准确失败层

对一条 Android 发到 Windows 的真实语音，记录：

- [ ] message.content 的 `mediaId` / MIME / duration / size。
- [ ] 下载授权 grant 是否成功。
- [ ] 最终下载 URL/响应 status/content-type/content-length。
- [ ] `media_local_cache` 是否正确落盘。
- [ ] 本地缓存扩展名与真实容器是否一致。
- [ ] `voice_playback_source` 返回的是 URL、file path 还是 bytes source。
- [ ] 播放器 backend 返回的真实异常。
- [ ] 文件本身能否由独立播放器解码。

## R06.2 统一语音编码策略

- [ ] 明确 DD 正式语音消息首选容器 + codec。
- [ ] Android、Windows、未来 iOS/Web 的录制与播放能力必须在协议层有兼容矩阵。
- [ ] 如果当前 Android 录制格式 Windows backend 不稳定，优先统一到跨平台稳定格式或统一播放器 backend，而不是平台互相猜。
- [ ] MIME、文件扩展名、上传 metadata、实际文件头必须一致。
- [ ] 服务端媒体校验不能把合法语音误判。
- [ ] 旧语音消息需保留兼容播放策略，不能新格式上线后全部废掉。

## R06.3 播放器与缓存

- [ ] 语音消息点击后优先读本地 cache。
- [ ] 未缓存时只下载一次，完成后复用。
- [ ] 多次快速点同一条不发起重复网络下载。
- [ ] 下载失败与解码失败分开提示/日志。
- [ ] grant 过期自动刷新一次，不因旧签名 URL 永久失败。
- [ ] cache 文件损坏时自动丢弃并重下，而不是每次读坏文件。
- [ ] 播放切换消息时停止上一条。
- [ ] 1x / 1.5x / 2x 仍可用。
- [ ] duration/进度条与真实播放同步。

## R06.4 自动测试

- [ ] Voice content JSON 解析测试。
- [ ] MIME/扩展名映射测试。
- [ ] grant refresh 测试。
- [ ] cache hit/miss/corrupt 测试。
- [ ] 播放 source 生成测试。
- [ ] Windows/Android recorder metadata 一致性测试。
- [ ] 真实媒体集成测试：Android 录音样本服务端存储后 Windows 能完成下载链路。

## R06.5 完成判定

- [ ] Android → Windows 语音可播。
- [ ] Windows → Android 语音可播。
- [ ] Windows → Windows 语音可播。
- [ ] 重启后已缓存语音首次点击明显快于重新下载。
- [ ] 不再出现“所有语音一律失败”的系统性故障。

---

# 10. R07｜VIDEO 发送/播放整链重做与可靠性闭环

> 原反馈：发视频一个都测不了，全员报错；要求参考 Telegram 的可靠媒体体验重做。

## R07.1 不允许的修法

- [ ] 不允许仅改错误提示。
- [ ] 不允许仅放宽服务端 MIME 校验，把错误对象也存进去。
- [ ] 不允许把整个大视频一次性读进 Dart 内存。
- [ ] 不允许 timeline 中为每条视频初始化播放器。
- [ ] 不允许因为某一个 MP4 样本通过就宣称“视频完成”。

## R07.2 明确 VIDEO 状态机

统一为可观察的阶段：

```text
selected
→ probing
→ reserving
→ uploading
→ verifying/committing
→ sending_message
→ sent
```

失败状态至少区分：

```text
probe_failed
reserve_failed
upload_failed
verification_failed
message_failed
cancelled
```

- [ ] UI 能显示上传进度。
- [ ] 用户可取消。
- [ ] 网络失败可重试，不必重新选择文件。
- [ ] 重试不能重复发送两个逻辑 VIDEO 消息。

## R07.3 媒体选择输入统一

与 R08 联动：

- [ ] VIDEO 从统一“相册”入口选择。
- [ ] Android 正确处理 content URI，不假定存在普通文件路径。
- [ ] Windows 正确处理真实文件路径。
- [ ] Web 使用浏览器 file input 能力并有平台限制提示。
- [ ] 不通过扩展名单独相信 MIME，必要时 probe 文件头。

## R07.4 Probe / metadata

每个视频至少得到：

- [ ] 实际 MIME/容器
- [ ] sizeBytes
- [ ] durationMs
- [ ] width
- [ ] height
- [ ] 方向/rotation metadata
- [ ] poster/thumbnail

- [ ] probe 失败必须给可理解错误。
- [ ] 竖屏视频 poster 方向正确。
- [ ] 超短视频/无音轨视频也能处理。

## R07.5 Reserve / Upload / Verify 合同

重点排查历史“Uploaded object does not match the reserved media”类问题：

- [ ] reserve 时声明的 purpose/message media kind 与实际 commit 完全一致。
- [ ] reserve size 与实际上传对象 size 一致，不能上传前后又转码导致 reservation 失配。
- [ ] MIME/extension/role `PRIMARY` / `THUMBNAIL` 一致。
- [ ] poster 使用自己的 media reservation，不与主视频 reservation 混用。
- [ ] checksum/hash 如果协议存在，客户端和服务端算法一致。
- [ ] object key 不被错误复用。
- [ ] upload 成功后服务端 HEAD/metadata 验证通过再允许发消息。
- [ ] 失败 object 有 cleanup/过期策略。

## R07.6 流式上传

- [ ] Android/Windows 大视频走 stream/file upload，不 `readAsBytes()` 整体加载。
- [ ] 合理 connect/read/write timeout。
- [ ] 上传进度基于真实 bytes sent。
- [ ] cancel 能真正取消网络请求，不只隐藏 UI。
- [ ] retry 建立新的合法上传会话或遵循现有 reservation 重试契约。

## R07.7 Poster

- [ ] poster 在发送前生成或由服务端生成，策略必须唯一清晰。
- [ ] timeline 默认只加载 poster。
- [ ] poster 缓存到本地。
- [ ] poster 不应因为主视频 grant 过期而消失。
- [ ] poster 生成失败时有安全占位，但不阻塞一个本来可发的视频，除非协议明确要求。

## R07.8 播放

- [ ] 点击 poster 进入 `video_viewer_page.dart`。
- [ ] `media_kit` Player 生命周期正确创建/释放。
- [ ] 同一时间避免后台多个视频继续播放。
- [ ] 进入播放器时优先复用本地完整 cache；未缓存则按播放器能力选择 URL streaming/下载后播。
- [ ] grant 过期可刷新。
- [ ] 播放错误展示具体、可恢复状态。
- [ ] 竖屏/横屏视频按原比例显示，不拉伸。
- [ ] Android 聊天/通话不因普通视频播放器改变全 App orientation policy。

## R07.9 格式兼容策略

至少建立测试样本矩阵：

- [ ] MP4
- [ ] MOV
- [ ] WebM
- [ ] MKV

处理原则：

- [ ] 对“项目声明支持”的格式必须真实测试。
- [ ] 如果某格式在目标平台无法稳定硬/软解，产品必须明确采用客户端/服务端标准化转码策略，或在选择阶段给明确“不支持该编码”的提示；不能继续宣称支持然后发送后报错。
- [ ] 容器支持与内部 codec 支持分开检查，例如同为 MP4 也可能使用不同视频编码。
- [ ] 正式转码如引入 FFmpeg/系统 codec，必须评估 Windows/Android/iOS/Web 的许可、包体、性能、服务端成本，不允许偷偷塞入不可商用依赖。

## R07.10 服务端权限与转发

- [ ] 会话成员才能获取 VIDEO 主文件与 poster。
- [ ] 非成员返回明确无权限。
- [ ] 转发 VIDEO 后目标会话成员能访问转发副本关联媒体。
- [ ] 删除/撤回/本地删除的媒体生命周期遵循现有产品语义。
- [ ] 不泄漏永久公网对象 URL。

## R07.11 缓存

- [ ] poster 与完整视频分层缓存。
- [ ] 当前焦点附近的媒体优先加载。
- [ ] 离开视口停止不必要工作。
- [ ] 已下载完整视频再次打开不重复下载。
- [ ] cache 有 size/age eviction，不无限增长。

## R07.12 自动测试与真实样本

- [ ] Media reserve contract test。
- [ ] upload size/MIME/role mismatch 必须被测试捕获。
- [ ] poster 主/缩略关系真实 PostgreSQL 测试。
- [ ] 成员/非成员授权集成测试。
- [ ] 转发授权集成测试。
- [ ] Flutter VIDEO JSON model 测试。
- [ ] upload progress/cancel/retry 测试。
- [ ] poster-only timeline 测试。
- [ ] video viewer lifecycle test。
- [ ] 至少用 4 个真实媒体样本跑端到端。

## R07 完成判定

Android ↔ Windows 双向发送真实视频：选择 → 上传 → 对方实时收到 → poster 正确 → 点击可播 → 再打开利用缓存 → 保存/下载成功。所有声明支持格式都必须有证据，不能只测假 bytes。

---

# 11. R08｜附件面板合并为一个“相册”入口

> 原反馈：当前三个媒体入口不符合逻辑，合并成一个“相册”，同时支持图片、视频、GIF。

## R08.1 入口重构

- [ ] 删除附件面板中独立的“图片”入口。
- [ ] 删除附件面板中独立的“GIF”文件选择入口。
- [ ] 删除附件面板中独立的“视频”入口。
- [ ] 新增唯一“相册”入口。
- [ ] “文件”继续独立保留。
- [ ] 自定义表情/Sticker 以后主要从 Emoji/表情面板进入，不再与系统媒体选择混成一排同义按钮。

## R08.2 相册选择能力

- [ ] Android 使用系统 Photo Picker/Media picker 优先，支持图片 + 视频。
- [ ] GIF 作为图片媒体类型自然被相册选择器支持。
- [ ] Windows 文件选择器一次显示图片/GIF/视频合法扩展名。
- [ ] Web 使用浏览器 `accept=image/*,video/*` 等等价能力。
- [ ] 至少支持单选稳定发送；若现有 picker/API 易于支持，多选应一并实现为现代 IM 标准体验，并逐项显示发送状态。
- [ ] 选择完成后按 MIME/实际类型自动进入 IMAGE/GIF/VIDEO 对应发送链，不要求用户提前判断“这是 GIF 还是图片”。

## R08.3 UI

- [ ] 图标和文案只显示“相册”。
- [ ] 不出现“图片、GIF、视频”三个重复入口。
- [ ] 相册 picker 返回后输入框焦点/消息列表滚动位置不乱。
- [ ] 发送中的媒体有明确进度/占位。

## R08.4 测试

- [ ] JPG/PNG 走 IMAGE。
- [ ] GIF 走 GIF。
- [ ] MP4 走 VIDEO。
- [ ] 取消 picker 不产生 pending message。
- [ ] 不支持文件给明确错误。

---

# 12. R09｜“详细资料”页面按 Telegram 信息层级重设计

> 原反馈：详细资料 UI 明显没对齐，需要重新设计成 Telegram 同款层级/体验。

## R09.1 页面信息架构

`peer_profile_page.dart` 至少重构为：

### Header

- [ ] 大头像，圆形，位置稳定。
- [ ] 昵称主标题。
- [ ] `@DDID`/DDID 次级信息。
- [ ] 个性签名/状态存在时显示，不存在时不留巨大空白。

### 快捷动作

- [ ] 发消息
- [ ] 语音通话
- [ ] 视频通话

动作按钮：

- [ ] 大小一致。
- [ ] icon 对齐。
- [ ] label 对齐。
- [ ] hover/pressed 状态统一。
- [ ] 不把危险关系操作放在主动作旁边。

### 信息区

- [ ] DDID
- [ ] 昵称/备注（有产品语义时）
- [ ] 个性签名
- [ ] 联系人关系/标签等已有能力按分组展示

### 管理区

- [ ] 添加好友/通过好友/删除联系人按 relationship 状态显示。
- [ ] Block/解除 Block 使用危险/警告样式。
- [ ] 不重复显示不适用于当前关系的按钮。

## R09.2 对齐规范

- [ ] 头像视觉中心与 header 对齐。
- [ ] 左右 padding 统一。
- [ ] label/value baseline 对齐。
- [ ] section 间距一致。
- [ ] divider 不过度。
- [ ] 881×657 Windows 右侧详情不溢出。
- [ ] Android 小屏不出现 RenderFlex overflow。
- [ ] 长昵称/DDID/签名 ellipsis 或换行策略明确。

## R09.3 导航联动

- [ ] “发消息”复用 R03 统一会话打开方式。
- [ ] Mention 点击资料复用本页面，支持 stable userId 加载。
- [ ] 通知点击/搜索进入资料时不需要 handle 重新查找。

## R09.4 测试

- [ ] CONTACT / NONE / SELF / BLOCKED_BY_ME / BLOCKED_BY_PEER 状态 UI。
- [ ] 超长 displayName/handle/bio。
- [ ] Windows 881×657。
- [ ] Android 360×640。

---

# 13. R10｜Emoji + 微信式自定义表情 + Telegram 贴纸包系统

> 原反馈：当前只有 Emoji 不够。需要微信式自定义表情管理；需要支持 Telegram 贴纸包；国内客户端不能直接依赖 t.me，服务端必须中转；每新增一个贴纸包增加一个与自定义表情同级的选项卡。

## R10.1 表情面板顶层结构

至少包含：

- [ ] Emoji tab。
- [ ] ❤️/小爱心“自定义表情” tab。
- [ ] 每个已添加 Telegram 贴纸包一个独立 tab。
- [ ] tab 横向可滚动，贴纸包多时不挤爆。
- [ ] 当前 tab 状态切换流畅，不关闭键盘/输入焦点异常。
- [ ] Windows 支持鼠标 hover/滚轮；Android 支持触摸滚动。

## R10.2 自定义表情数据模型

必须明确持久化，而不是只存在一台机器内存：

- [ ] `custom_sticker_id`
- [ ] owner userId
- [ ] mediaId/object reference
- [ ] MIME/type
- [ ] width/height
- [ ] sizeBytes
- [ ] createdAt
- [ ] sortOrder（如果 UI 允许整理顺序）
- [ ] deletedAt 或明确删除语义

- [ ] 自定义表情与普通聊天消息媒体分开管理，但发送时最终可生成标准 `STICKER` message content。
- [ ] 多设备登录后自定义表情可以同步。
- [ ] 退出账号不能把 A 用户自定义表情展示给 B 用户。

## R10.3 自定义表情 tab

- [ ] 使用小爱心 icon。
- [ ] tab 内有“+”添加入口。
- [ ] 表情网格采用统一尺寸，不因原图尺寸乱跳。
- [ ] 静态图片透明背景正确。
- [ ] GIF/动画类如允许上传，播放策略不导致整个网格同时高负载。
- [ ] 点击表情直接发送 STICKER，不把文件名作为文字消息发送。

## R10.4 自定义表情管理页

用户明确要求：

- [ ] 顶部有“关闭”。
- [ ] 顶部有“整理”。
- [ ] 点击“整理”进入多选模式。
- [ ] 多选状态视觉清楚。
- [ ] 可批量删除。
- [ ] 删除有合理确认，防误删。
- [ ] 点击“+”上传自定义表情。
- [ ] 上传时本地校验格式/大小/尺寸。
- [ ] 上传成功后立即出现在当前账号表情库。
- [ ] 上传失败不产生空白格。

## R10.5 自定义表情 API

建议按现有 API 规范设计，具体命名可结合项目：

- [ ] List custom stickers。
- [ ] Reserve/upload custom sticker media。
- [ ] Create custom sticker item。
- [ ] Batch delete custom stickers。
- [ ] Optional reorder/sort update。
- [ ] 所有 API 鉴权并 owner-only。
- [ ] OpenAPI 完整更新。
- [ ] PostgreSQL migration 有 up/down 与 roundtrip 测试。

## R10.6 Telegram 贴纸包导入入口

必须支持用户给出的这类链接：

```text
https://t.me/addstickers/tmeaddsticss_yang2_yang2_by_fStikBot
```

- [ ] 客户端可粘贴 Telegram sticker pack 链接。
- [ ] 解析 `t.me/addstickers/<setName>`。
- [ ] 可兼容 Telegram 常用 sticker set deep link 形式时一并规范化为 setName。
- [ ] 客户端把 setName 交给 DD 服务端，不直接从 t.me 下载。

## R10.7 服务端 Telegram Sticker Relay

国内无法可靠访问 t.me，因此服务端作为中转：

- [ ] 服务端配置 Telegram Bot token/官方可用接口凭据，通过环境变量/Secret 注入，禁止写死仓库。
- [ ] 服务端用 Telegram 官方可用的 sticker set/file API 获取 pack metadata 和文件，不做脆弱 HTML scraping 作为正式方案。
- [ ] 如果服务端未配置 Telegram 凭据，返回明确 `TELEGRAM_STICKER_RELAY_NOT_CONFIGURED` 类错误，不假成功。
- [ ] 服务端拉取 pack 时设置 timeout、重试、限流。
- [ ] 所有客户端只访问 DD 服务端/对象存储，不需要直连 `t.me` 或 Telegram file CDN。

## R10.8 Sticker Pack 持久化与缓存

至少保存：

- [ ] pack setName
- [ ] pack title
- [ ] Telegram source identifier
- [ ] cover/thumb
- [ ] sticker item 列表
- [ ] 每个 sticker 的 source file unique id / hash
- [ ] DD 自己的 cached mediaId/object key
- [ ] media type/format
- [ ] width/height
- [ ] pack version/update timestamp

- [ ] 同一个 pack 多个用户添加时尽量复用服务端缓存，不重复下载相同资源。
- [ ] 用户“添加 pack”与全局 pack cache 分离：全局只缓存资源，用户拥有自己的订阅/排序关系。
- [ ] 用户移除 pack 不立即删除其他用户仍在使用的全局资源。
- [ ] 定期清理无人引用且过期的缓存资源。

## R10.9 格式兼容

- [ ] 以 Telegram 实际 pack metadata 为准处理静态、动画、视频 sticker 类型。
- [ ] 客户端对支持格式正常渲染。
- [ ] 对当前 Flutter 渲染栈确实不支持的格式，必须有服务端标准化转换或明确不支持提示，不能空白。
- [ ] 任何转换都要评估 CPU/内存/许可。
- [ ] 网格缩略图与发送后的聊天气泡使用合适分辨率，不下载超大原始资源来铺满列表。

## R10.10 动态选项卡

- [ ] 每新增一个 Telegram 贴纸包增加一个 tab。
- [ ] tab 与 ❤️自定义表情同级。
- [ ] tab icon 使用 pack cover/首个 sticker 的适配缩略图。
- [ ] pack 很多时横向滚动。
- [ ] 删除/移除 pack 后 tab 立即消失。
- [ ] 重启 App 后 pack tab 顺序和内容恢复。
- [ ] 多设备同步用户 pack 订阅。

## R10.11 发送

- [ ] 自定义表情与 Telegram sticker 统一发送为标准 `STICKER` message 类型。
- [ ] 发送消息保存稳定 DD mediaId，不把 Telegram 临时 URL 写进聊天历史。
- [ ] 对方不需要安装同一个 pack 也能看到已发送 sticker。
- [ ] 转发/收藏/同步 sticker 不依赖原 pack 仍被用户订阅。
- [ ] Android 不显示媒体“复制”动作，与 R01 一致。

## R10.12 安全

- [ ] Telegram pack URL 只解析预期 host/path，不允许用户提供任意 URL 让服务端 SSRF。
- [ ] setName 长度/字符集校验。
- [ ] relay 请求限流，防止被当成免费 Telegram 下载代理滥用。
- [ ] 下载文件大小上限。
- [ ] MIME 与实际文件类型校验。
- [ ] SVG/XML/压缩类格式若涉及解析要防实体/压缩炸弹等风险。
- [ ] 不记录 Telegram Bot token 到日志。
- [ ] 用户自定义表情上传继续走现有媒体权限和安全校验。

## R10.13 自动测试

- [ ] Custom sticker CRUD integration test。
- [ ] Owner/非 owner 权限测试。
- [ ] Batch delete 测试。
- [ ] 多设备同步测试。
- [ ] Telegram pack URL parser 单元测试。
- [ ] 非 Telegram host 拒绝。
- [ ] Relay provider 使用 mock official API 的 service test，不依赖测试时真实公网。
- [ ] Pack 去重/cache 测试。
- [ ] Sticker tab Widget Test。
- [ ] Add/remove pack 后 tab 更新测试。
- [ ] 表情网格大量 item 滚动性能 smoke test。

---

# 14. R11｜移动端启动第一屏 + 无登录页闪烁的自动会话恢复

> 原反馈：移动端需要一张开机第一屏遮挡连接过程；未来 iOS 也要用。Android 每次打开都先跳登录注册界面，应该有效会话直接进聊天，进不去再跳登录。

## R11.1 现有问题

当前 `app.dart`：

```text
home: AuthPage()
```

而 `AuthPage.initState()` 再异步 `_restoreSession()`，因此即使最终能自动恢复会话，登录 UI 也会先构建/闪现。

- [ ] 不允许继续靠把 `_restoreSession()` “再快一点”解决闪屏。
- [ ] 必须引入独立 boot/auth decision 状态机。

## R11.2 原生 Splash

Android：

- [ ] 使用 DD 正式品牌背景与 Logo。
- [ ] Android 12+ SplashScreen 行为与旧版本一致。
- [ ] 不出现 Flutter 默认图标/白屏/黑屏跳变。
- [ ] 资源适配 mdpi/hdpi/xhdpi/xxhdpi/xxxhdpi。
- [ ] 深色模式有可接受背景。

未来 iOS：

- [ ] 视觉规范写成可复用品牌 splash 资产/布局。
- [ ] Flutter Boot 页面不包含 Android 私有假设。

## R11.3 Flutter Boot Gate

建议新增独立组件：

```text
AppBootPage / SessionBootstrapPage / BootGate
```

状态至少：

```text
booting
restoring_session
authenticated
unauthenticated
offline_with_cached_identity
fatal_boot_error
```

- [ ] App 启动先显示 DD 品牌 boot screen。
- [ ] 读取 secure session vault。
- [ ] 有 refresh token 时尝试 refresh。
- [ ] refresh 成功直接构建 `MainShellPage`。
- [ ] vault 为空才进入 AuthPage。
- [ ] 服务端明确返回 refresh token 无效/撤销/过期，清理本地并进入 AuthPage。
- [ ] 单纯网络超时/服务不可达不能等价于“用户退出登录”。
- [ ] 如果本地已有足够的缓存身份/会话 UI 数据，网络暂时不可用时应优先进入主界面并显示离线/重连状态，而不是把用户踢到登录页。
- [ ] 如果当前数据结构无法安全 offline shell，至少 Boot 页面提供“正在连接/重试”状态，不直接闪登录注册。
- [ ] boot error 可重试。

## R11.4 认证职责拆分

- [ ] `AuthPage` 只负责真正未认证用户的登录/注册/找回密码/历史登录。
- [ ] session restore 从 AuthPage 移到 Boot/Auth Coordinator。
- [ ] `AuthSessionVault` 继续负责安全 refresh token 存储。
- [ ] session refresh timer 在 authenticated shell 生命周期正确启动。
- [ ] logout 后明确回 AuthPage，不回 Boot 无限循环。
- [ ] 被服务端远程 revoke 后能回 AuthPage 并说明原因。

## R11.5 启动性能

- [ ] Splash/Boot 第一帧无需等待网络即可渲染。
- [ ] Boot 过程中不要预加载全部聊天媒体。
- [ ] 先进入 shell，再渐进同步联系人/会话/头像。
- [ ] 网络慢时用户至少看到稳定 DD 启动画面和状态，不看到来回切页。

## R11.6 测试

- [ ] 有有效 vault + refresh 成功：从未构建 Auth 登录表单就进入 shell。
- [ ] vault 为空：进入 AuthPage。
- [ ] refresh 返回 401/invalid：清 vault 后进入 AuthPage。
- [ ] refresh 网络 timeout：不误清 vault。
- [ ] logout：进入 AuthPage。
- [ ] App restart：保持已登录。
- [ ] Android 冷启动真机录屏确认无登录页闪一下。

---

# 15. R12｜用户提及 `@username` 完整实现

> 此章节必须与 `未实现的新增需求/实现用户提及的开发方案.md` 一起执行。下面把必须落地的核心工作全部拆成可勾选项，禁止只做“文字变蓝”。

## R12.1 协议核心原则

- [ ] 采用“文本 + 服务端 Message Entity + 稳定 userId”。
- [ ] 服务端是 Mention Entity 唯一权威。
- [ ] 客户端发送正文时不能自行指定可信 `userId/entity offset`。
- [ ] 服务端从文本中解析 `@handle` 并绑定当时真实 userId。
- [ ] 历史消息显示原始 `@handle` 文本。
- [ ] 用户以后修改 handle，旧消息仍点击到原来的稳定 userId。
- [ ] 不存在的 `@xxx` 只是普通文字。
- [ ] 旧消息没有 entities 时不做危险的历史重绑定猜测。

## R12.2 Go 数据模型

在 Messaging model 增加语义等价结构：

```text
MessageEntity
- type
- offset
- length
- userId
- handle
```

- [ ] `TextContent.entities`。
- [ ] JSON `omitempty`/兼容策略正确。
- [ ] 未知 entity type 不破坏老客户端。
- [ ] OpenAPI 同步 Message Entity schema。

## R12.3 Offset 标准

- [ ] 协议固定 `offset` / `length` 为 UTF-16 code unit。
- [ ] Go 提供 UTF-8 byte position → UTF-16 offset/length 的测试函数。
- [ ] Dart `String.substring` 能直接按 entity 定位。
- [ ] JavaScript/Web 与 Dart 一致。
- [ ] Emoji 在 Mention 前时不偏移。
- [ ] 中文 + Emoji + Mention 混排测试通过。

## R12.4 Mention scanner

有效 handle 继续复用当前 normalize 规则：

```text
[a-z][a-z0-9_]{2,31}
```

必须覆盖：

- [ ] `@alice`
- [ ] `你好@alice`
- [ ] `(@alice)`
- [ ] `@alice，晚上好`
- [ ] `@alice/@bob`
- [ ] `@Alice` 解析到 normalized alice，但正文不改写

必须避免误判：

- [ ] `hello@example.com`
- [ ] `@@alice`
- [ ] `@a`
- [ ] token 边界非法情况

实现：

- [ ] 不依赖 Go regexp lookbehind。
- [ ] 使用 O(n) scanner 或等价确定性解析器。
- [ ] 单消息最多 64 Mention Entity。
- [ ] 单消息最多 32 个不同用户。
- [ ] 超限返回明确 `TOO_MANY_MENTIONS` 类错误，不静默截断。

## R12.5 批量解析 userId

- [ ] 收集唯一 normalized handles。
- [ ] 一次 SQL 批量查询 active users。
- [ ] 禁止 N+1 每个 @ 一次查询。
- [ ] 不存在的用户不生成 entity，但消息仍可正常发送。
- [ ] active/status/隐私策略遵循现有用户搜索规则。

## R12.6 SendMessage

- [ ] `normalizeSendInput` 后解析 Mention。
- [ ] 服务端生成 entities。
- [ ] 写入 `messages.content_json`。
- [ ] response/outbox/sync 都携带同一份 entities。
- [ ] 客户端伪造 entities 时服务端忽略/重建，不信任客户端目标 userId。

## R12.7 EditMessage

- [ ] TEXT 编辑后删除旧 Mention entities。
- [ ] 根据新正文重新解析并绑定。
- [ ] `@alice → @bob` 后只剩 Bob entity。
- [ ] 并发 editVersion 规则继续生效。

## R12.8 Forward / Saved / Reply / Sync

- [ ] 转发含 Mention 的历史消息时保留原 `text + entities`。
- [ ] **转发禁止重新按当前 handle 解析**，防 handle 改名后错绑。
- [ ] Saved Messages 保留 entities。
- [ ] 回复引用如展示原文，Mention 文本保持安全，不要求引用区域也可点击，具体 UI 统一。
- [ ] Realtime Sync 完整序列化 entities。
- [ ] Pending Queue 本地序列化不丢 entities。
- [ ] 重启客户端后从 local store 恢复不丢 entities。

## R12.9 Stable user profile API

新增语义等价接口：

```text
GET /api/v1/users/{userId}
```

- [ ] 鉴权。
- [ ] 只返回公开资料。
- [ ] 返回 relationship。
- [ ] 不返回邮箱/IP/设备/登录状态等敏感信息。
- [ ] deleted/BAN/inactive user 返回不可用语义。
- [ ] CONTACT/NONE/SELF/BLOCKED_BY_ME/BLOCKED_BY_PEER 全覆盖。
- [ ] `PeerProfilePage` 可以通过稳定 userId 加载，不再强依赖 handle。

## R12.10 Mention suggestion API

新增语义等价接口：

```text
GET /api/v1/users/mention-suggestions?q=ali&conversationId=<uuid>&limit=8
```

- [ ] 鉴权。
- [ ] q 最少 2～3 个有效字符，具体规则固定并写 OpenAPI。
- [ ] limit 最大 8 或 10。
- [ ] 当前私聊优先当前会话对方。
- [ ] 其次联系人。
- [ ] 再次是允许公开搜索的 handle prefix 用户。
- [ ] `conversationId` 为未来群聊排序保留。
- [ ] 服务端限流。
- [ ] 防用户枚举。
- [ ] Prefix index 是否增加必须以 PostgreSQL `EXPLAIN`/实测为依据，不盲加。

## R12.11 Flutter Domain Model

- [ ] Dart `MessageEntity` model。
- [ ] `TextMessageContent.entities`。
- [ ] 旧 JSON 无 entities → `[]`。
- [ ] 非法/未知 entity 不导致整条消息反序列化失败。
- [ ] local store 同步支持。

## R12.12 MentionRichText

新增独立组件，不把全部逻辑塞回 `text_chat_page.dart`：

- [ ] 按 offset 排序。
- [ ] 普通文本区间普通 TextSpan。
- [ ] MENTION 区间可点击 TextSpan。
- [ ] offset < 0 忽略。
- [ ] length <= 0 忽略。
- [ ] offset + length 越界忽略。
- [ ] overlap entity 安全处理。
- [ ] Mention userId 空时忽略点击语义。
- [ ] substring 与 entity handle 明显不一致时不执行危险跳转。
- [ ] recognizer 生命周期正确 dispose，长聊天不泄漏。
- [ ] Windows mouse cursor 为 click。
- [ ] 自己气泡/对方气泡 Mention 颜色都保证可读性。

## R12.13 点击 Mention

- [ ] 点击 entity.userId。
- [ ] 立即进入资料页 skeleton/loading state。
- [ ] stable userId API 拉当前资料。
- [ ] handle 已修改仍打开同一个用户。
- [ ] 用户已删除/不可用时显示“该用户当前不可用”。
- [ ] 旧消息原 `@handle` 文本不被改写。
- [ ] 资料页“发消息”走 R03 统一会话路由。

## R12.14 Composer Mention trigger

- [ ] 监听 `TextEditingController` text + selection。
- [ ] 只分析光标附近 token，不每次对 4000 字做高成本全解析。
- [ ] 找到最近合法 `@`。
- [ ] email 场景不触发。
- [ ] 空格/非法字符结束 trigger。
- [ ] 中文 IME composing 时不强行替换 selection。
- [ ] 不导致光标乱跳。
- [ ] 不导致 Android 键盘关闭。
- [ ] 不导致拼音 composing 被清空。

## R12.15 Suggestion 请求

- [ ] debounce 约 200～250ms，推荐 220ms。
- [ ] request token/sequence 防乱序旧结果覆盖新结果。
- [ ] query 短期内存缓存。
- [ ] 关闭候选后过期 response 不重新弹出。
- [ ] 网络失败只关闭/显示轻量状态，不影响继续输入。

## R12.16 候选 UI

Desktop：

- [ ] Overlay 位于输入框上方。
- [ ] avatar + displayName + `@handle`。
- [ ] ↑ / ↓ 选择。
- [ ] Enter 确认当前候选。
- [ ] Esc 关闭。
- [ ] 候选打开时 Enter 不发送消息。
- [ ] 候选关闭后恢复正常 Enter 发送。

Android/iOS：

- [ ] Overlay/Stack，不通过插入 Column 反复改变聊天列表高度。
- [ ] 点击候选不抢走 TextField focus。
- [ ] 键盘保持开启。
- [ ] 候选列表不遮住当前输入行关键区域。

## R12.17 选择候选后的文本替换

例如：

```text
你好 @ali|
```

选择 Alice 后：

```text
你好 @alice |
```

- [ ] 只替换当前 trigger token。
- [ ] 光标放在尾随空格后。
- [ ] 其它正文不变。
- [ ] selection 不乱。
- [ ] IME composing 不被非法修改。

## R12.18 Mention 通知语义

当前私聊：

- [ ] 不因为 Mention 再制造第二条重复通知。

未来群聊准备：

- [ ] Message Entity 数据结构能提取 mentionedUserIds。
- [ ] 不在本阶段硬写还不存在的群聊通知状态机。

## R12.19 兼容性回归

Mention 上线后以下全部仍正常：

- [ ] 文本发送
- [ ] Pending Queue
- [ ] 重试
- [ ] 编辑
- [ ] 回复
- [ ] 转发
- [ ] 收藏
- [ ] 消息置顶
- [ ] 搜索
- [ ] 本地删除
- [ ] 撤回
- [ ] Realtime Sync
- [ ] Windows
- [ ] Android
- [ ] Web
- [ ] 未来 iOS 无需新协议

## R12.20 安全攻击用例

- [ ] 一条消息大量 `@` 不造成 N 次 SQL。
- [ ] 构造越界 offset 不让 Flutter crash。
- [ ] suggestion 不允许空 query + huge limit 枚举全用户库。
- [ ] 客户端伪造 `@alice → bob userId` 不生效。
- [ ] Alice 改 handle 后旧 `@alice` 不被后来注册的新 Alice 劫持。
- [ ] 转发旧 Mention 不重新解析导致错绑。
- [ ] Mention 点击不能绕过 Block/隐私。

## R12.21 服务端测试

Mention parser 至少：

- [ ] `@alice`
- [ ] `你好@alice`
- [ ] `(@alice)`
- [ ] `@alice，hello`
- [ ] `hello@example.com`
- [ ] `@@alice`
- [ ] `@a`
- [ ] `@alice_01`
- [ ] `@Alice`
- [ ] `Emoji😀在前 @alice`
- [ ] 两个不同 Mention
- [ ] 重复 Mention
- [ ] 不存在用户

Integration：

- [ ] SendMessage entity.userId 正确。
- [ ] client 假 entity 注入无效。
- [ ] DB reload 后 entities 一致。
- [ ] EditMessage 重算。
- [ ] Forward 保留原绑定。
- [ ] Stable profile relationship matrix。
- [ ] Suggestion 限制/限流。

## R12.22 Flutter 测试

- [ ] Domain model old/new JSON。
- [ ] RichText 正常/非法 entity。
- [ ] Emoji UTF-16 offset。
- [ ] Mention tap callback userId。
- [ ] Composer `@` / `@ali`。
- [ ] email 不触发。
- [ ] 中文 IME composing。
- [ ] Desktop Enter/Esc/箭头。
- [ ] Android 候选点击焦点保持。
- [ ] 用户改 handle 后旧 Mention 跳转正确。

## R12.23 性能目标

- [ ] Mention parser O(n)。
- [ ] 每条消息用户解析固定 1 次批量 SQL。
- [ ] suggestion 正常同区域数据库环境 P95 目标 <150ms。
- [ ] 输入 `@` 不产生明显掉帧。
- [ ] RichText 渲染不为每条消息发网络请求。
- [ ] 只有点击 Mention 才拉 profile。

## R12 完成判定

必须满足：服务端 entity、stable userId、UTF-16、输入候选、富文本点击、编辑/转发/收藏/同步、旧消息兼容、安全测试、三端构建全部通过。**只把 `@alice` 变蓝色属于未实现。**

---

# 16. R13｜开发进度文档 + 新人工测试文档

> 原反馈第 13 条明确要求更新 `开发进度跟踪.md` 并新增 `人工测试.md`。

## R13.1 开发进度跟踪

- [ ] 更新根目录 `开发进度跟踪.md`。
- [ ] 明确记录本批次 R00～R14 的真实状态，包含最新追加的 Android 全圆角悬浮 Footer。
- [ ] 把旧文档“头像裁剪/音效/VIDEO 已完成但真人失败”的情况写成回归/重新打开项，不得继续保留误导性的最终结论。
- [ ] 每个完成项写自动测试证据。
- [ ] 每个仍需真人判断项明确标记“开发完成待真人验收”，不能写“✅真人通过”。
- [ ] 记录构建产物路径。
- [ ] 记录是否启动过临时测试服务、端口、PID 清理结果。
- [ ] 记录外部凭据/真机权限造成的真实阻断。

## R13.2 新建根目录 `人工测试.md`

当前工作树中旧根目录 `人工测试.md` 已不存在，因此本批完成后必须重新创建。

文档格式要求：

- [ ] 每条测试编号。
- [ ] 每条都有 `[ ] 未测 / ✅ 通过 / ❌ 失败` 的可编辑位置。
- [ ] 每条都有“测试反馈：”空位。
- [ ] 写明前置条件。
- [ ] 写明操作步骤。
- [ ] 写明预期结果。
- [ ] 不要求用户看代码/log 才能测试 UI 功能。
- [ ] 测试顺序按依赖排序，避免前面失败导致后面全测不了。

至少覆盖：

### Windows UI

- [ ] 881×657 默认窗口。
- [ ] 左侧导航新视觉。
- [ ] hover/selected。
- [ ] resize/最大化/还原。
- [ ] 消息/联系人/资料整体对齐。

### Android 媒体复制

- [ ] 图片无复制。
- [ ] GIF 无复制。
- [ ] VIDEO 无复制。
- [ ] 文本仍可复制。

### 头像裁剪

- [ ] 长截图初始显示。
- [ ] 横图。
- [ ] 方图。
- [ ] 八锚点。
- [ ] 拖图。
- [ ] 缩放。
- [ ] 旋转。
- [ ] 还原。
- [ ] 完成结果。

### 联系人发消息

- [ ] Contacts → 发消息 → Messages 内打开。
- [ ] 不再单开错误满窗口。

### 通知

- [ ] DD small icon。
- [ ] sender avatar。
- [ ] 锁屏/状态栏/展开通知。

### 音效

- [ ] Android 消息音。
- [ ] Windows 消息音。
- [ ] Android 来电/去电/接通/挂断。
- [ ] Windows 来电/去电/接通/挂断。
- [ ] 新铃声听感。

### 语音条

- [ ] Android → Windows。
- [ ] Windows → Android。
- [ ] 重启后缓存播放。
- [ ] 倍速。

### VIDEO

- [ ] 相册选择视频。
- [ ] Android → Windows。
- [ ] Windows → Android。
- [ ] poster。
- [ ] 播放。
- [ ] 缓存。
- [ ] 保存。
- [ ] 取消/重试。

### 相册

- [ ] 图片。
- [ ] GIF。
- [ ] 视频。
- [ ] 不再有三个重复入口。

### 详细资料

- [ ] Windows 对齐。
- [ ] Android 对齐。
- [ ] 发消息/语音/视频按钮。
- [ ] relationship 管理。

### 自定义表情

- [ ] ❤️ tab。
- [ ] + 上传。
- [ ] 管理页关闭/整理。
- [ ] 多选删除。
- [ ] 重启后仍存在。
- [ ] 多端同步。

### Telegram 贴纸包

- [ ] 粘贴示例 pack URL。
- [ ] 服务端中转成功。
- [ ] 国内客户端不直连 t.me 也可显示。
- [ ] 新 pack 新 tab。
- [ ] 对方没装 pack 也能看已发送 sticker。

### 启动

- [ ] Android 冷启动不闪登录页。
- [ ] 已登录直进主界面。
- [ ] 网络断开不会误退出登录。
- [ ] 真正 session 失效才进登录。

### Mention

- [ ] `@alice` 候选。
- [ ] 点击 Mention。
- [ ] 用户改名后旧 Mention。
- [ ] email 不误识别。
- [ ] 中文/Emoji offset。
- [ ] 编辑/转发。

### Android 悬浮 Footer

- [ ] Footer 四周有留白，不再贴屏幕左右/底边。
- [ ] 外层完整全圆角，视觉接近 Telegram 参考图的悬浮层级。
- [ ] 选中项为 DD 绿色品牌化胶囊态。
- [ ] 四个 tab 对齐、点击区域充足、未读 badge 正常。
- [ ] 360×640 不 overflow。
- [ ] 大屏手机不被横向拉得松散。
- [ ] 深色模式无突兀白条。
- [ ] 手势导航/三键导航不重叠。
- [ ] 页面最后一项不被 Footer 遮挡。
- [ ] 键盘升降不会把 Footer 顶到错误位置。
- [ ] 快速切换 tab 无闪烁/掉帧。

---

# 17. R14｜Android 主界面底部 Footer 改为 Telegram 风格全圆角悬浮导航条

> 最新追加反馈（2026-08-10）：当前 DD Android 底部 Footer 是贴着屏幕底边的整块矩形导航栏，视觉笨重。参考用户提供的 Telegram Android 截图，改成**完整圆角、四周留白、悬浮在内容上方的 Footer/Tab Bar**，同时保持 DD 自己的绿色品牌识别，不照搬 Telegram 蓝色或品牌资产。
>
> 当前代码热点：`clients/app/lib/features/shell/presentation/main_shell_page.dart` 的移动端分支目前直接在 `SafeArea > Column` 底部放置 Material 3 `NavigationBar`；`clients/app/lib/theme/app_theme.dart` 里还有全局 `navigationBarTheme`。下一位 AI 必须从这两个真实入口重构，不能另做一个没有接入主壳的演示组件。

## R14.1 视觉目标

- [ ] Footer 不再与屏幕左右边缘、底边贴死，四周必须有可见留白，形成真正悬浮感。
- [ ] 外层容器为连续完整的大圆角/胶囊轮廓，不允许只圆上方两个角。
- [ ] 建议外层高度控制在约 `68～76dp`；不能因为追求“悬浮”做成巨大占屏卡片。
- [ ] 建议左右外边距约 `10～14dp`，底部视觉间距约 `6～10dp + system safe inset`；最终数值以 360px 宽真机不拥挤为准。
- [ ] 外层圆角建议约 `28～36dp` 或使用与实际高度匹配的 pill 半径，四角视觉必须连续顺滑。
- [ ] 浅色模式使用干净白色/接近白色 surface；深色模式使用 DD 深色 surface，不能强制白底。
- [ ] 可使用极轻的边框 + 柔和阴影制造层级；禁止厚重黑阴影、发光、渐变玻璃大特效，把 UI 做成廉价悬浮卡片。
- [ ] 如采用半透明/BackdropFilter，必须先验证 Android GPU 与键盘动画性能；一旦引入掉帧，宁可使用实体 surface + 克制阴影。
- [ ] Footer 与页面背景之间必须有明显但自然的层次，不允许像当前一样看成页面最下面的一条固定白板。

## R14.2 导航信息架构保持 DD 现有四项

保留：

```text
DD / 消息
联系人
发现
我的
```

- [ ] 不因为参考 Telegram 就把 DD 的“发现”改成“设置”等其它 IA。
- [ ] 第一个 tab 可继续显示 `DD`，也可在整体品牌文案统一时改成“消息”，但必须与项目其它文档/页面统一，不能局部乱改。
- [ ] 未读 badge 必须继续工作，不能因自定义 Footer 丢失 `_UnreadNavigationIcon` / 总未读数能力。
- [ ] tab 切换仍复用 `_selectMainSection()` 和现有 `IndexedStack`，不得重新创建四套页面状态导致滚动位置、输入状态或联系人页状态丢失。

## R14.3 选中态做成 DD 品牌化胶囊

参考 Telegram 截图的核心不是“蓝色”，而是：**当前 tab 在整个浮动导航条内部拥有一个更轻的圆角选中区域。**

- [ ] 选中项使用浅绿色/绿色低透明度背景的内层 pill，颜色来自 DD Theme Token，不直接复制 Telegram 蓝色。
- [ ] 选中 icon 使用 DD 主绿色，优先 filled icon；未选中 icon 使用中性灰。
- [ ] 选中文字使用 DD 主绿色/深绿色，并保持足够对比度。
- [ ] 未选中文字使用中性灰/深色模式浅灰。
- [ ] 选中 pill 的宽高变化不能挤压其它 tab 或造成导航项左右跳动。
- [ ] 点击切换动画建议 `160～220ms`，使用轻量 `AnimatedContainer` / `TweenAnimationBuilder` 等实现；禁止复杂动画导致掉帧。
- [ ] 切换过程不能出现 icon 抖动、文字 baseline 跳动、Footer 自身高度变化。

## R14.4 点击区域与可访问性

- [ ] 每个导航项有效点击区域至少 `48×48dp`。
- [ ] icon、文字和 badge 不得互相遮挡。
- [ ] 360×640 小屏下四项仍能完整显示，不允许“联系人”被压成省略号。
- [ ] 系统字体放大到合理范围时不出现明显 overflow；必要时为导航标签设置稳定的单行布局。
- [ ] 保留 `Semantics` / Tooltip 等基本可访问性，不要用纯 GestureDetector 把语义全部弄丢。

## R14.5 SafeArea / 系统导航栏处理

这是最容易“截图好看、真机难用”的部分，必须专项处理：

- [ ] 正确读取 Android 底部 `MediaQuery.viewPadding/viewInsets` 或 SafeArea，不把 Footer 压进手势导航区域。
- [ ] 三键导航手机上 Footer 也不能与系统导航键区域重叠。
- [ ] 手势导航手机上底部留白不能大到像 Footer 漂到半空。
- [ ] 系统导航栏颜色/图标明暗应与 DD 当前主题协调，底部不能突然出现一条不搭的纯黑/纯白系统色块。
- [ ] 横屏不是本功能目标；若 Android 主界面发生横屏，Footer 至少不能 overflow/crash。

## R14.6 与页面内容的叠放关系

- [ ] 推荐通过 `Scaffold.bottomNavigationBar` + 外边距，或 `Stack/Positioned` + 正确内容 padding 实现真实浮层；具体方案以不破坏现有 Shell 为准。
- [ ] 如果 Footer 覆盖在页面内容上方，消息列表/联系人列表/“我的”列表底部必须增加等效安全 padding，最后一行不能被 Footer 挡住。
- [ ] 页面滚动到最底部时，最后一个 item 必须完整出现在 Footer 上方。
- [ ] 根页面可以显示悬浮 Footer；进入聊天详情、资料编辑、裁剪器、视频播放器等二级/全屏页面时，不能错误把主 Footer 压在业务页面上方。
- [ ] 从联系人“发消息”切回消息模块后，Footer 选中态必须同步到“DD/消息”。

## R14.7 键盘与输入法联动

- [ ] Android IME 弹起时不得出现 Footer 被键盘顶到输入框中间、悬在键盘上方挡聊天内容的怪相。
- [ ] 如果当前产品逻辑在聊天输入状态隐藏主 Footer，则保持隐藏并保证动画无跳变；如果根页面搜索框触发键盘仍显示 Footer，则必须保证不会与键盘重叠。
- [ ] 键盘收起后 Footer 平滑回到正确 SafeArea 位置。
- [ ] 不允许为了 Footer 增加新的 `resizeToAvoidBottomInset` 抖动或 Android 键盘升降掉帧。

## R14.8 Theme Token 与组件化

- [ ] 不要把颜色、阴影、圆角、尺寸全部硬编码在 `main_shell_page.dart`。
- [ ] 在 `app_theme.dart` 或专用 DD navigation token 中定义浮动 Footer 的 surface、selected surface、shadow/border、icon/text colors。
- [ ] 如果自定义组件超过约百行，应提取为独立可测试 Widget（例如 `DdFloatingNavigationBar`），避免继续把 `main_shell_page.dart` 膨胀成不可维护大文件。
- [ ] Windows 桌面 `_DesktopRail` 不受 R14 影响；Android/mobile 分支改动不能误伤 Windows 现代化 R00。
- [ ] Web 窄屏如复用 mobile layout，应保持可用；如果产品明确只给 Android 开启该视觉，需要用清晰平台策略，而不是散落 `Platform.isAndroid`。

## R14.9 自动测试

至少新增/更新 Widget Test：

- [ ] 手机宽度下显示自定义 floating Footer，而不是旧的贴底矩形 `NavigationBar`。
- [ ] 默认选中消息 tab。
- [ ] 点击联系人/发现/我的可切换 selected index。
- [ ] 未读 badge 仍显示。
- [ ] Footer 外层具备左右/底部 inset 与完整圆角。
- [ ] 360×640 无 overflow。
- [ ] 典型大屏手机尺寸无异常拉伸。
- [ ] 深色 Theme 无白色硬编码泄漏。
- [ ] 字体缩放下无 RenderFlex overflow。
- [ ] 二级页面不错误叠加主 Footer。

## R14.10 真人视觉验收

最终 `人工测试.md` 必须增加独立章节，Android 真机逐项验收：

- [ ] 与用户提供的 Telegram 参考图并排看，DD Footer 已有明显的**完整圆角 + 四周留白 + 浮层**结构，不再是贴底矩形白条。
- [ ] 但颜色、icon、文案仍是 DD 自己的品牌，不出现 Telegram logo/蓝色品牌照搬。
- [ ] 选中项内部胶囊舒服，不肥、不挤、不廉价。
- [ ] 四个 tab 对齐、间距、文字 baseline 一致。
- [ ] 未读红点/数字位置自然。
- [ ] 360×640 真机不拥挤。
- [ ] 手势导航和三键导航至少各验证一种可获得设备/模拟配置。
- [ ] 页面滑到底，最后一个会话/联系人/设置项不被 Footer 遮挡。
- [ ] 连续快速切换四个 tab 动画稳定、无闪烁、无掉帧。
- [ ] 冷启动进入主界面时 Footer 不从矩形旧样式闪成新样式。

### R14 完成判定

**禁止用“把 `NavigationBar` 外面套一个 `ClipRRect`”就关闭 R14。**

必须同时满足：真实悬浮留白、完整 pill 外轮廓、DD 品牌化选中态、SafeArea/系统导航栏、内容防遮挡、键盘联动、深色模式、未读 badge、尺寸回归和 Android 真人视觉验收均有证据。最终目标是达到用户参考图那种现代、轻盈、精致的底部导航层级，同时不做成 Telegram 品牌复制品。

---

# 18. 跨功能一致性与性能专项

这些不是“可选优化”，本轮改动非常大，必须做防回归。

## C01｜输入框与键盘

- [ ] Android 键盘升起/收起不因 Mention/表情面板/相册重构重新掉帧。
- [ ] 点击候选、表情、附件后 TextField 焦点策略符合产品逻辑。
- [ ] Windows Enter 发送，Shift+Enter 换行继续正确。
- [ ] Mention 候选打开时 Enter 优先选择候选。

## C02｜消息可靠性

- [ ] TEXT/IMAGE/GIF/STICKER/VOICE/VIDEO/FILE 都经过消息 Outbox/Sync 正常到达。
- [ ] 网络断开后 pending 不丢。
- [ ] 重连后不重复发送。
- [ ] 媒体失败不会留下永远 loading 的假消息。

## C03｜本地缓存

- [ ] Avatar cache 不串账号。
- [ ] Voice cache 不串账号/会话权限。
- [ ] Video cache 不泄漏旧账号私有媒体。
- [ ] Sticker cache 与用户订阅关系分离。
- [ ] Logout 清理 token/敏感缓存索引，但不使用粗暴删全局共享资源导致别的账号异常。

## C04｜安全

- [ ] 所有新增 API 鉴权。
- [ ] 所有 owner-only resource 有 IDOR 测试。
- [ ] Sticker relay 防 SSRF/滥用。
- [ ] Mention suggestion 防枚举。
- [ ] 媒体下载仍使用授权 grant，不暴露永久 URL。
- [ ] 日志不输出 token、Authorization、Telegram Bot token。

## C05｜错误处理

- [ ] 不再出现 HTTP 2xx 空正文导致 `Unexpected end of input`。
- [ ] JSON 编码错误继续返回结构化 500。
- [ ] 失败消息给用户可理解信息，但日志保留技术 root cause。
- [ ] 网络、权限、解码、格式不支持分别有不同错误码/日志字段。

---

# 19. 自动验证门禁

## V01｜格式与静态检查

- [ ] Go `gofmt`。
- [ ] `go vet ./...`。
- [ ] `go test ./...`。
- [ ] Dart formatter 0 change。
- [ ] `flutter analyze --fatal-infos` 0 issue。

## V02｜Flutter tests

- [ ] 现有全部测试继续通过。
- [ ] R00 新 UI 测试。
- [ ] R01 平台媒体菜单测试。
- [ ] R02 crop geometry/widget 测试。
- [ ] R03 shell route 测试。
- [ ] R04 notification resource/config 测试。
- [ ] R05 sound state machine 测试。
- [ ] R06 voice cache/source 测试。
- [ ] R07 video upload/viewer 测试。
- [ ] R08 album routing 测试。
- [ ] R09 profile responsive 测试。
- [ ] R10 sticker/custom expression 测试。
- [ ] R11 boot gate 测试。
- [ ] R12 mention model/richtext/composer 测试。
- [ ] R14 floating footer layout/selection/badge/safe-area/theme/widget 测试。

## V03｜Server integration

- [ ] Media reservation/upload/authorization PostgreSQL tests。
- [ ] VIDEO primary + thumbnail tests。
- [ ] Custom sticker persistence tests。
- [ ] Telegram pack subscription/cache tests（外部 API mock）。
- [ ] Mention send/edit/forward/sync tests。
- [ ] Stable profile API tests。
- [ ] Mention suggestion rate/limit tests。

## V04｜Migration

如新增自定义表情/贴纸包/订阅等表：

- [ ] migration up。
- [ ] repeated up 幂等。
- [ ] down 1 step。
- [ ] re-up。
- [ ] 真实 PostgreSQL roundtrip。

## V05｜OpenAPI

- [ ] `server/openapi/openapi.json` 同步所有新 API/字段。
- [ ] OpenAPI lint 通过。
- [ ] 增加合同回归，避免实现支持但 OpenAPI 漏字段。

## V06｜统一客户端门禁

执行项目已有：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-client.ps1
```

- [ ] Go tests PASS。
- [ ] Realtime analyze/test PASS。
- [ ] Flutter analyze/test PASS。
- [ ] Live REST/WebSocket smoke PASS。
- [ ] 临时 smoke 服务端口被清理。
- [ ] 无残留后台进程。

## V07｜三端构建

执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1 -Target all
```

必须：

- [ ] Windows Release PASS。
- [ ] Web Release PASS。
- [ ] Android APK PASS。
- [ ] 根目录 `DD-Android.apk` 更新。
- [ ] `DD-Windows.lnk` 有效。
- [ ] `DD-Web.lnk` 有效。

---

# 20. 最终人工验收前的 AI 自查

下一位 AI 在交给用户之前必须自己逐项做一次“反证式检查”：

- [ ] 是否有任何 task 只是 UI 按钮存在，但后端实际没通？
- [ ] 是否有任何旧测试只验证 mock，而用户真实路径仍会失败？
- [ ] 是否有 Android 特判误伤 Windows/Web？
- [ ] 是否有 Windows UI 在 881×657 之外看着正常、默认尺寸却 overflow？
- [ ] 是否有头像裁剪只在方图测试，长图仍错？
- [ ] 是否有通知资源存在但系统实际 small icon 仍错误？
- [ ] 是否有声音单测通过但 Windows release 资产没打包？
- [ ] 是否有语音下载成功但 codec 仍无法播放？
- [ ] 是否有视频 reserve/upload mock 通过但真实文件 size/MIME 仍失配？
- [ ] 是否有“相册”按钮仍内部弹三个二级选择，违背合并目的？
- [ ] 是否有资料页只改颜色，实际 baseline/spacing 仍不齐？
- [ ] 是否有自定义表情只存本地，换设备就丢？
- [ ] 是否有 Telegram sticker 客户端仍偷偷请求 `t.me`？
- [ ] 是否有启动时 AuthPage 仍先构建一帧？
- [ ] 是否有 Mention 只靠前端 regex，没有稳定 userId？
- [ ] 是否有用户改 handle 后旧 Mention 跳错人？
- [ ] 是否有编辑/转发/Saved/Sync 丢 Mention entity？
- [ ] Android Footer 是否只是旧 `NavigationBar` 套了圆角，实际上仍贴底、无悬浮留白？
- [ ] Android Footer 是否在手势导航/三键导航/键盘弹起时位置异常？
- [ ] Android Footer 是否遮住消息列表或联系人列表最后一项？
- [ ] Android Footer 是否为了参考 Telegram 直接照搬蓝色/品牌图标，而没有保留 DD 视觉身份？
- [ ] 是否有新增 API 缺 OpenAPI？
- [ ] 是否有新增数据库表缺 down migration？
- [ ] 是否有未关闭临时 server/port？
- [ ] 是否已经生成新的根目录 `人工测试.md`？
- [ ] `开发进度跟踪.md` 是否与真实代码/测试状态一致？

只要任何一条答案是“是/不确定”，继续开发或验证，不要提前结束。

---

# 21. 推荐实施顺序（按依赖，不按原反馈编号硬做）

## Phase A｜稳定性与根因

1. [ ] B00～B02 基线阅读与复现。
2. [ ] R06 Windows 语音播放根修。
3. [ ] R07 VIDEO 上传/播放主链根修。
4. [ ] R04 Android notification small icon。
5. [ ] R05 Windows/Android sound assets + 状态机。

**Checkpoint A：**

- [ ] 语音和视频真实双向样本已能走通。
- [ ] 通知与音效至少代码/自动验证闭环。
- [ ] 没有新增消息可靠性回归。

## Phase B｜高优先级交互重构

6. [ ] R02 头像裁剪器整体重写。
7. [ ] R03 联系人 → 消息统一路由。
8. [ ] R08 “相册”合并。
9. [ ] R01 Android 媒体复制动作清理。
10. [ ] R09 详细资料 UI 重做。
11. [ ] R14 Android Telegram 参考风格全圆角悬浮 Footer。

**Checkpoint B：**

- [ ] 长图 crop 自动测试通过。
- [ ] 桌面消息导航不再另开错误窗口。
- [ ] 相册可自动分流 IMAGE/GIF/VIDEO。
- [ ] Android 360×640 下 Footer 完整悬浮、无遮挡、SafeArea 正确。

## Phase C｜账号启动体验 + Windows 大 UI

12. [ ] R11 Boot Gate / Splash / 自动登录。
13. [ ] R00 Windows 现代化视觉系统与主壳。

**Checkpoint C：**

- [ ] Android 冷启动不再闪 Auth。
- [ ] Windows 881×657 新主界面完整可用。

## Phase D｜表情平台能力

14. [ ] R10 自定义表情服务端数据模型/API。
15. [ ] R10 自定义表情管理 UI。
16. [ ] R10 Telegram Sticker Relay。
17. [ ] R10 动态 sticker tabs / send / sync。

**Checkpoint D：**

- [ ] 自定义表情跨重启/多端存在。
- [ ] Telegram pack 客户端无需访问 t.me。

## Phase E｜Mention 基础设施

18. [ ] R12.1～R12.10 服务端协议/解析/API。
19. [ ] R12.11～R12.17 Flutter 渲染/候选/跳转。
20. [ ] R12.18～R12.23 兼容、安全、性能、测试。

**Checkpoint E：**

- [ ] 用户改 handle 后旧 Mention 仍稳定。
- [ ] 编辑/转发/同步不丢 entity。

## Phase F｜全量回归与交付

21. [ ] C01～C05 跨功能专项。
22. [ ] V01～V07 自动门禁与三端构建。
23. [ ] R13 更新 `开发进度跟踪.md`。
24. [ ] R13 生成全新的根目录 `人工测试.md`，必须包含 R14 Footer 真人验收章节。
25. [ ] 执行第 20 章最终反证式自查。
26. [ ] 只有全部技术 DoD 满足后，才把最终人工验收交给用户统一测试。

---

# 22. 最终结束条件

满足下面逻辑之前，**禁止结束本批次并声称“全部完成”**：

```text
R00 = 完整实现
AND R01 = 完整实现
AND R02 = 完整实现
AND R03 = 完整实现
AND R04 = 完整实现
AND R05 = 完整实现
AND R06 = 完整实现
AND R07 = 完整实现
AND R08 = 完整实现
AND R09 = 完整实现
AND R10 = 完整实现
AND R11 = 完整实现
AND R12 = 完整实现
AND R13 = 文档完成
AND R14 = Android 全圆角悬浮 Footer 完整实现
AND 全量自动门禁 = PASS
AND Windows/Android/Web 构建 = PASS
AND 已生成最终人工测试清单
```

如果只剩真人才能判断的事项，则允许状态写成：

```text
开发实现完成 + 自动门禁通过 + 等待统一人工验收
```

但**绝对不能写成：**

```text
全部测试通过
```

除非用户本人已经把新的 `人工测试.md` 对应条目全部验收通过。

---

# 23. 本批需求映射表（防漏项）

| 原反馈编号 | 本 Todo | 必须结果 |
|---|---|---|
| 0 | R00 | Windows DD UI 现代化重设计，移除大黑侧栏的割裂感 |
| 1 | R01 | Android 媒体无复制按钮 |
| 2 | R02 | 头像裁剪器整体重写：全屏、等比、8 锚点、旋转/还原/完成/取消 |
| 3 | R03 | 联系人发消息切到消息模块并打开 DIRECT |
| 4 | R04 | Android 通知显示 DD small icon |
| 5 | R05 | Windows/Android 消息与通话音效完整，新铃声 |
| 6 | R06 | Windows 语音条恢复可靠播放 |
| 7 | R07 | VIDEO 发送/缓存/播放整链可靠化 |
| 8 | R08 | 图片/GIF/视频入口合并为“相册” |
| 9 | R09 | 详细资料 UI Telegram 式重设计 |
| 10 | R10 | 自定义表情 + 管理 + Telegram sticker relay + 动态 tab |
| 11 | R11 | DD Splash/Boot + 有效会话直接进入主界面 |
| 12 | R12 | 完整 Message Entity 用户提及系统 |
| 13 | R13 | 更新开发进度 + 新根目录人工测试 |
| 最新追加（2026-08-10） | R14 | Android 底部 Footer 改成 Telegram 参考风格的 DD 品牌化全圆角悬浮导航条 |

**原反馈 0～13 + 最新追加 R14 全部闭环，才代表本轮需求没有漏项。**
