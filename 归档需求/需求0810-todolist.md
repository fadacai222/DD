# DD「需求0810」完整开发 / Bug 修复 Todo

> 来源：`需求0810.md`
>
> 生成日期：2026-08-11
>
> 适用仓库：`C:\Users\admin\Desktop\复刻微信`
>
> 目标：把 `需求0810.md` 中所有真人反馈拆成可直接执行、可测试、可验收、可跨会话接力的开发任务。**任何原始需求没有代码闭环、自动验证或明确真人复测项，本批次都不得宣称“全部完成”。**

---

# 0. 给下一位 AI 的强制执行规则

## 0.1 事实优先级

开工顺序必须是：

1. 阅读 `AGENTS.md`。
2. 阅读 `docs/README.md`。
3. 阅读 `docs/15-当前实现状态与开发路线.md`。
4. 完整阅读 `需求0810.md` 和本文件。
5. 再按任务读取相关专题 docs 与当前源代码。

判断“当前到底做没做”的优先级：

```text
当前代码 / migration / 当前自动测试 / 当前构建结果
> docs 当前状态
> 本 Todo
> 旧 Todo / 旧对话 / 旧截图结论
```

但有一条例外：**本文件对应的是用户最新真人体验反馈。只要真人明确说某入口不可用、UI 不合格、功能失败，就必须重新打开问题，不能拿旧的 AUTO-VERIFIED 结论压掉真人反馈。**

## 0.2 本批次禁止事项

- [ ] 禁止只改按钮文案、隐藏入口、吞异常来冒充修复。
- [ ] 禁止只做 Windows 或只做 Android，除非任务本身明确是单平台能力。
- [ ] 禁止把 Flutter Widget Test 当成相机、文件系统、系统分享、硬件解码、PiP、通知真实平台验收。
- [ ] 禁止新增第二套重复 QR、Sticker、Moments、Group 业务模型；优先接通现有正式模块。
- [ ] 禁止继续把大量逻辑无边界塞进已经很大的 `text_chat_page.dart`；新增复杂能力应拆 widget / controller / service。
- [ ] 禁止为了“无限文件大小”直接把全部文件一次性读进内存。必须流式、分块、可取消。
- [ ] 禁止为了“复刻 Telegram 硬件加速”复制或假装拥有 Telegram 私有图形引擎。目标是**实现同等级体验目标：硬件解码优先、合理渲染后端、低 CPU/GPU 占用、平滑播放、失败回退**。
- [ ] 禁止破坏现有用户数据和 migration 历史；已发布 migration 只允许 forward-only 新增。
- [ ] 禁止 `git reset --hard`、`git restore .`、`git checkout .` 覆盖当前未提交开发成果。

## 0.3 开发节奏

默认执行：

```text
批量读取/复现
→ 修阻断 Bug
→ 补缺失功能
→ 做 UI/交互统一
→ 自动门禁
→ Windows / Android / Web 构建
→ 更新 docs / 开发进度 / 人工测试
→ 最后一次性交真人复测
```

除真实设备、第三方凭据、系统权限、真机相机、真实硬件解码等无法自动完成的事项外，不要每做一个小点就停下问用户。

---

# 1. 本批次总 Definition of Done

以下全部满足，本批次才允许标记“完成”：

- [ ] `需求0810.md` 每一条原始需求都能映射到本文件一个或多个任务。
- [ ] 已归档入口尺寸/位置正确，我的收藏头像统一圆形。
- [ ] Android 文件消息支持打开、保存到系统、系统分享。
- [ ] 图片/视频/文件上传和下载均有可取消圆形进度 UI，展示已传/已下与总大小。
- [ ] 自动下载/手动下载设置真实生效，并有缓存管理页。
- [ ] 收藏消息不再出现“收藏原消息/收藏自原消息”二层视觉气泡。
- [ ] 视频消息拥有 Telegram 级别的缩略图播放、进度、静音、播放器、倍速、全屏、桌面悬浮/PiP 等体验。
- [ ] 桌面端详情页统一使用侧边扩展栏，不把移动端全屏页面原样搬到 PC。
- [ ] 登录设备管理支持一键清理已退出设备记录。
- [ ] 应用内通知/黑色提示不贴边、不贴底，头像全部圆形。
- [ ] Emoji 不再使用手写少量列表，覆盖平台支持的完整标准 Emoji 集，并记住最近一次表情面板 Tab。
- [ ] `@用户` mention 视觉足够明显，同时不破坏文本可读性和深色模式。
- [ ] 添加自定义表情后立即可见、可同步、可发送。
- [ ] 群头像可编辑并多端同步。
- [ ] 群语音通话与群视频通话实现正式主链，不是占位按钮。
- [ ] 自定义表情支持 GIF 输入，并通过客户端处理生成适合 Sticker 使用的体积/尺寸资产；发送时按 STICKER 语义展示，而不是普通图片消息。
- [ ] 联系人中的“群聊”入口能展示已有群；Windows 通讯录也能展示群聊。
- [ ] 朋友圈背景图可更改并持久化。
- [ ] “不看他 / 不让他看”等朋友圈联系人级权限移动到联系人资料/聊天详情的合理位置。
- [ ] 联系人详情页按用户参考方向重新设计。
- [ ] Windows / Android 的资料编辑 UI 按用户参考方向统一重做。
- [ ] 发现→扫一扫、主页 `+`→扫一扫、个人信息→我的二维码全部接入当前正式 QR 能力。
- [ ] 个人资料/联系人资料的个性签名显示正确。
- [ ] 联系人资料可直接进入对方朋友圈。
- [ ] 朋友圈点赞/评论等互动不再藏在不合理二级菜单。
- [ ] 朋友圈视觉移除用户明确不喜欢的厚重/全圆框；评论不使用错误红色正文。
- [ ] 发表朋友圈页移除不必要全圆容器。
- [ ] 朋友圈视频发布错误修复；单条发布失败不能污染全局媒体状态导致其他人的图片也不可见。
- [ ] 聊天附件“拍摄”入口真实可用，并处理相机权限/取消/失败。
- [ ] 所有二级菜单、ActionSheet、弹层点击空白遮罩均可取消（危险确认框除外）。
- [ ] `dart format` / analyzer / Flutter tests 通过。
- [ ] `go test ./...` 通过。
- [ ] OpenAPI / contract gate 通过（如本批新增 API）。
- [ ] PostgreSQL integration tests 通过（如本批新增 schema / service）。
- [ ] Windows Release 构建通过。
- [ ] Android APK 构建通过。
- [ ] Web Release 构建通过，或对不支持的系统能力有明确降级而非编译失败。
- [ ] 相关 `docs/`、`开发进度跟踪.md` 和最终人工测试清单同步更新。

---

# 2. 开工基线与代码热点确认

## B00｜先确认当前实现，不重复造轮子

优先检查：

```text
clients/app/lib/features/messaging/presentation/conversations_page.dart
clients/app/lib/features/messaging/presentation/text_chat_page.dart
clients/app/lib/features/messaging/presentation/saved_messages_page.dart
clients/app/lib/features/messaging/presentation/sticker_library_sheet.dart
clients/app/lib/features/messaging/presentation/video_viewer_page.dart
clients/app/lib/features/messaging/presentation/chat_details_page.dart
clients/app/lib/features/messaging/application/messaging_coordinator.dart
clients/app/lib/features/messaging/data/media_api_client.dart
clients/app/lib/features/messaging/data/media_local_cache.dart
clients/app/lib/features/messaging/data/video_file_cache.dart
clients/app/lib/features/contacts/presentation/contacts_page.dart
clients/app/lib/features/contacts/presentation/peer_profile_page.dart
clients/app/lib/features/groups/presentation/group_details_page.dart
clients/app/lib/features/groups/data/groups_api_client.dart
clients/app/lib/features/moments/presentation/moments_feed_page.dart
clients/app/lib/features/moments/presentation/moment_publish_page.dart
clients/app/lib/features/moments/presentation/moment_privacy_page.dart
clients/app/lib/features/qrcode/presentation/qr_scanner_page.dart
clients/app/lib/features/qrcode/presentation/my_qr_page.dart
clients/app/lib/features/shell/presentation/main_shell_page.dart
clients/app/lib/features/auth/presentation/account_management_page.dart
clients/app/lib/features/auth/presentation/personal_profile_page.dart
clients/app/lib/core/notifications/app_notification_service.dart
```

当前已知代码事实（仅作为定位提示，开工时必须重新确认）：

- `contacts_page.dart` 的“群聊”入口目前存在占位逻辑。
- `conversations_page.dart` 的主页 `+ → 扫一扫` 当前存在“功能正在接入”占位提示。
- QR 正式模块已经存在，不应另做一套扫码业务。
- `main_shell_page.dart` / `personal_profile_page.dart` 已有“我的二维码/个性签名”视觉入口，但需要核对真实点击链路与数据绑定。
- `sticker_library_sheet.dart` 已有 Emoji、自定义表情、Sticker pack 能力，本轮重点是“完整 Emoji、Tab 记忆、添加即显示、GIF/压缩/语义展示”。
- P7 当前正式 Calls 主链是一对一通话；**群通话是新增大功能，不得把 1:1 Calls 按钮复制一下就算完成。**

## B01｜建立复现矩阵

每个真人失败项至少记录：

- [ ] 平台：Windows / Android / Web。
- [ ] 操作路径。
- [ ] 当前实际表现。
- [ ] 预期表现。
- [ ] 控制台/网络/服务端日志（如有）。
- [ ] 根因层：UI / 状态管理 / 平台 adapter / API / 数据库 / 媒体管线 / 权限。
- [ ] 修复后的自动回归测试位置。

---

# 3. P0 阻断类 Bug：先修这些再做大 UI

## R01｜朋友圈视频发布失败 + 失败污染全局媒体状态

### 原始需求

- 朋友圈发视频报错。
- 报错以后，别人的照片也看不到。

### 执行细则

- [ ] 用至少 3 个真实视频样本复现：短 MP4、较大 MP4、设备实拍视频。
- [ ] 分阶段记录：pick → probe → reserve → upload → commit → create moment → media grant → feed render。
- [ ] 明确错误发生在客户端、媒体服务、Moments API 还是对象存储。
- [ ] 检查 `moment_publish_page.dart` 是否共用一个全局 `_error` / loading / media state，导致单次发布失败后影响 Feed 图片解析。
- [ ] 检查媒体授权缓存是否把一次失败写成全局 negative cache。
- [ ] 检查图片/视频 MIME、media kind、grant scope 是否串用。
- [ ] 发布失败必须只回滚本次草稿/本次上传状态，不允许清空/污染 Feed 中其他媒体的可见状态。
- [ ] 若已上传孤儿媒体，交给服务端清理策略，不要让客户端随意删除可能被引用的资源。
- [ ] 失败后用户可以直接重试，不需要重启 App。
- [ ] 失败后的 Feed 立即刷新，其他联系人的图片仍正常。

### 验收标准

- [ ] 视频朋友圈可正常发布并播放。
- [ ] 故意制造一次上传失败后，旧 Feed 图片仍正常。
- [ ] 网络恢复后可重试成功。
- [ ] 错误信息明确，不出现全局白屏/所有媒体失效。

### 自动验证

- [ ] Moment publish controller/service 增加失败隔离测试。
- [ ] Media grant/cache 增加“video failure does not poison image cache”回归。
- [ ] 服务端 Moments + Media integration 覆盖失败事务边界。

---

## R02｜主页 `+ → 扫一扫` 未接入正式 QR

### 执行细则

- [ ] 移除 `conversations_page.dart` 中“扫一扫功能正在接入”的占位 SnackBar。
- [ ] 复用现有 `QrScannerPage` / 当前 QR route/controller。
- [ ] 与“发现 → 扫一扫”使用**同一入口函数/同一结果处理器**，避免两个扫码入口行为漂移。
- [ ] 扫到个人码：打开个人资料。
- [ ] 扫到群码：进入群邀请确认/加入流程。
- [ ] 扫到登录码：进入目标设备确认流程。
- [ ] 无效码：给出可恢复错误，不崩溃。
- [ ] Android 相机权限拒绝时提供重新授权路径。
- [ ] Windows/Web 如果当前不具备摄像头扫码能力，应支持文件/剪贴板/系统可行降级，至少不能是死按钮。

### 验收标准

- [ ] 发现扫一扫和主页加号扫一扫结果完全一致。
- [ ] 个人码/群码/登录码三种 payload 均正确分流。
- [ ] 点击返回/取消不会破坏主页面状态。

---

## R03｜聊天“拍摄”入口不可用

### 执行细则

- [ ] 检查 `text_chat_page.dart` 中“拍摄”动作是否只是 UI 占位。
- [ ] 抽象 `CameraCaptureService` / platform adapter，不把权限和相机逻辑塞进聊天页。
- [ ] Android 支持拍照；若产品已有视频拍摄入口，一并支持短视频，否则明确只做拍照并保持文案一致。
- [ ] 相机权限首次请求、拒绝、永久拒绝、系统无相机都必须可处理。
- [ ] 拍摄完成后进入与“相册选择”相同的媒体压缩/上传/发送管线。
- [ ] 用户取消拍摄不生成空消息、不报错。
- [ ] Android 横竖屏行为与项目既定策略一致。

### 验收标准

- [ ] Android 真机可直接拍照并发送。
- [ ] 取消相机后返回聊天，输入框状态不丢。
- [ ] 权限拒绝时有明确提示和设置入口。

---

# 4. 会话列表 / 收藏体验

## R04｜已归档入口高度降低，并始终位于搜索框下方

### 执行细则

- [ ] 定位 `conversations_page.dart::_archiveEntry`。
- [ ] 已归档入口固定在搜索框下方、普通会话列表上方，不被“我的收藏”或其他特殊会话插队。
- [ ] 参考 Telegram 采用紧凑行高，不按普通会话 row 高度展示。
- [ ] 保留归档数量，但视觉弱于普通会话。
- [ ] 移动端与桌面端分别校准，不用同一死高度造成 DPI / 字体缩放截断。
- [ ] 搜索状态下按产品逻辑隐藏或固定，但不能跳到列表随机位置。
- [ ] 进入归档列表/返回后位置稳定。

### 验收标准

- [ ] 归档入口肉眼明显更矮。
- [ ] 永远紧贴搜索框下方。
- [ ] 881×657 / Android 小屏无 overflow。

---

## R05｜“我的收藏”头像全部圆形

### 执行细则

- [ ] 审计会话列表、收藏页头部、转发目标、自发消息视图中的“我的收藏”头像。
- [ ] 统一使用项目 Avatar 组件，`ClipOval` / 全圆语义。
- [ ] 禁止某处圆角矩形、某处圆形。
- [ ] 默认占位图同样圆形裁剪。

### 验收标准

- [ ] Windows / Android / Web 所有“我的收藏”头像均为正圆。

---

## R06｜收藏气泡去掉“收藏原消息/收藏自原消息”二层提示

### 执行细则

- [ ] 定位 `text_chat_page.dart` 里 `收藏自原消息` 相关 UI。
- [ ] 收藏消息只展示一层消息气泡/内容，不再套“收藏原消息”提示块。
- [ ] 原始消息来源元数据可保留在 model 中用于“定位原消息”等功能，但默认视觉不额外占一层。
- [ ] 原消息已删除时，收藏本身仍应按服务端保存语义可查看；不能因去掉提示破坏数据。

### 验收标准

- [ ] 收藏文字、图片、视频、文件、语音、Sticker 都只有单一内容气泡。
- [ ] 取消收藏、转发、长按操作不受影响。

---

# 5. 文件 / 媒体上传下载体系

## R07｜Android 文件消息支持打开、保存、系统分享

### 执行细则

- [ ] 增加/补齐文件动作菜单：`打开`、`保存`、`分享`。
- [ ] 打开文件必须基于 MIME + 文件扩展名交给 Android 系统 Intent / 合适插件，不在 App 内乱解析未知格式。
- [ ] 保存使用 Android 合规的 SAF / MediaStore / Document API 路径，兼容 scoped storage。
- [ ] 分享使用系统 Share Sheet，提供本地可读 URI，不暴露 `file://`。
- [ ] 未下载完成时，打开/分享应先走下载流程，并显示进度。
- [ ] 文件已缓存时优先本地打开，不重复下载。
- [ ] 文件不存在/缓存损坏时重新下载。
- [ ] 无可处理该 MIME 的 App 时给出友好提示。
- [ ] Web/Windows 不因 Android adapter 引入而编译失败。

### 验收标准

- [ ] Android 可打开 PDF、TXT、ZIP、常见 Office 文件（由系统已安装 App 决定）。
- [ ] 可另存到用户选择目录。
- [ ] 可系统分享给 Telegram/邮箱/网盘等目标 App。

---

## R08｜上传圆形进度 + 中央取消按钮

### 原始需求

发送文件、图片、视频等时：圆形转圈进度，中间有叉叉，可随时停止。

### 执行细则

- [ ] 为媒体上传建立统一 `MediaTransferState`：queued / preparing / uploading / committing / done / failed / canceled。
- [ ] 上传进度必须来自真实字节数，不做假动画。
- [ ] 图片/视频/文件消息预览上叠加圆形进度环。
- [ ] 圆环中央显示取消 `×`。
- [ ] 点击取消必须真正 abort HTTP upload / stream，不只是隐藏 UI。
- [ ] 取消后不发送残缺消息；服务端 reservation/临时对象按现有 orphan cleanup 清理。
- [ ] preparation 阶段（压缩/probe）也可取消。
- [ ] commit 已完成后取消按钮自动消失。
- [ ] 失败状态允许重试。
- [ ] 多媒体并发发送时每条传输状态独立。

### 验收标准

- [ ] 发送 100MB 以上视频时可观察真实进度变化。
- [ ] 中途取消网络层确实停止。
- [ ] 取消一条不会影响同时上传的其他媒体。

---

## R09｜下载圆形进度 + `9.1 / 47.9 MB`

### 执行细则

- [ ] 下载状态与上传状态分离，但复用统一 Transfer UI。
- [ ] 显示 `已下载 / 总大小`，自动选择 KB/MB/GB。
- [ ] 总大小未知时显示已下载大小 + indeterminate 环，不伪造总量。
- [ ] 下载中可取消。
- [ ] 取消保留还是删除 partial 文件必须有明确策略；默认安全做法：partial 放临时文件，取消后删除。
- [ ] 下载完成后原位置变为可打开/播放状态。
- [ ] 缓存命中时不闪下载进度。
- [ ] 弱网重试不要从 UI 上突然跳回 0，除非协议确实不支持断点续传。
- [ ] 若服务端支持 Range，则实现断点续传；若不支持，在 docs 明确记录。

---

## R10｜自动下载 / 手动下载设置

### 执行细则

设置页新增“媒体与缓存”或同级合理入口，不散落在聊天页。

建议策略至少包含：

- [ ] 图片自动下载开关。
- [ ] GIF / Sticker 自动下载开关。
- [ ] 视频自动下载开关。
- [ ] 文件自动下载开关。
- [ ] 可选 Wi-Fi / 移动网络策略；如果当前项目尚无网络类型感知，先实现总开关并预留 domain，不伪装已经支持。
- [ ] 自动下载只下载到 App 缓存，不等于自动保存到系统相册/下载目录。
- [ ] 关闭自动下载后只加载 poster/占位，用户点击后手动下载。
- [ ] 设置本地持久化；若产品定义需要多设备同步，再增加服务端偏好，不要默认混在聊天消息数据里。

### 验收标准

- [ ] 关闭视频自动下载后，新视频不自动拉取完整文件。
- [ ] 点击后可以手动下载并展示进度。
- [ ] 重启 App 设置仍保留。

---

## R11｜缓存管理页

### 执行细则

- [ ] 设置新增“存储与缓存/缓存管理”。
- [ ] 展示缓存总大小。
- [ ] 至少分类：图片、视频、文件、语音、Sticker/GIF、临时文件。
- [ ] 支持一键清理全部缓存。
- [ ] 支持按类型清理。
- [ ] 清理缓存不能删除聊天记录、收藏记录、服务端媒体。
- [ ] 正在播放/上传/下载的文件不能被并发删除导致 crash；需要 transfer lock / reference protection。
- [ ] 清理后 UI 立即刷新缓存大小。
- [ ] 缓存清除后再次打开媒体可以重新从服务器下载。
- [ ] 对本地用户主动保存到系统目录的文件绝不纳入 App 缓存删除。

### 自动验证

- [ ] Cache index / size calculation 单测。
- [ ] clear-by-kind 测试。
- [ ] active transfer protection 测试。

---

# 6. 视频消息与播放器重做

## R12｜聊天内视频缩略图完整播放

### 执行细则

- [ ] 视频消息默认显示真实 poster/thumbnail，不显示空黑框。
- [ ] poster 上可直接播放/暂停。
- [ ] 显示播放进度。
- [ ] 左上角按用户参考显示剩余时长/倒计时；格式如 `0:27`。
- [ ] 提供静音切换按钮。
- [ ] 自动播放策略必须克制：默认不允许多个聊天内视频同时有声播放。
- [ ] 滚出可视区域时暂停或降资源占用，避免长列表同时解码。
- [ ] 预览播放失败可点击进入完整播放器重试。
- [ ] 已缓存视频本地优先。

### 性能要求

- [ ] 列表滚动不能因多个 VideoPlayer 实例明显掉帧。
- [ ] 只给可视/即将可视媒体创建重型播放器资源。
- [ ] 离屏及时 dispose / suspend。

---

## R13｜完整视频播放器能力

点开视频进入播放器后必须有：

- [ ] 播放 / 暂停。
- [ ] 可拖动进度条。
- [ ] 当前时间 / 总时长。
- [ ] 静音。
- [ ] 音量调节（桌面端必须；Android 以系统音量语义为主，不强行做无意义独立音量滑块）。
- [ ] 全屏。
- [ ] 退出全屏/缩小。
- [ ] 倍速：至少 0.5× / 1× / 1.25× / 1.5× / 2×，可按实际播放器能力调整。
- [ ] 保存 / 分享可复用媒体导出能力。
- [ ] 键盘快捷键（Windows）：空格播放暂停、左右方向 seek、Esc 退出全屏，且不抢聊天输入焦点。
- [ ] 播放控制几秒无操作自动淡出，移动鼠标/点击后出现。

---

## R14｜Windows 无边框悬浮小窗 / PiP + 恢复

### 执行细则

- [ ] Windows 支持把视频切到独立悬浮播放窗口或可靠的应用内 always-on-top 浮窗。
- [ ] 悬浮窗无厚重系统边框，保留必要拖动区域。
- [ ] 可拖动位置。
- [ ] 有“恢复到主窗口”按钮。
- [ ] 关闭浮窗不应杀掉整个 DD。
- [ ] 主窗口切换会话时，浮窗播放状态不异常重建。
- [ ] 单实例、窗口管理、DPI 与最小尺寸需要回归。
- [ ] Android 若系统支持 PiP，可接入系统 PiP；不支持的平台优雅隐藏该按钮。

### 验收标准

- [ ] Windows 浮窗播放 10 分钟无明显资源泄漏。
- [ ] 恢复后进度连续。

---

## R15｜硬件加速 / 图形后端性能目标

### 说明

用户要求“复刻 Telegram 的硬件加速与图形引擎”。实现目标应解释为**体验与性能对标**，不是复制 Telegram 私有实现。

### 执行细则

- [ ] 审计当前 Windows/Android 视频 backend 是否使用硬件解码路径。
- [ ] 优先使用底层播放器支持的硬件解码；不支持/驱动异常时可回退软件解码。
- [ ] 不强制单一 GPU API，避免部分显卡黑屏。
- [ ] 记录播放 1080p H.264 的 CPU 占用、掉帧、首帧时间。
- [ ] 4K / HEVC 是否支持以实际平台解码器为准；不支持必须给可理解错误。
- [ ] poster、聊天内预览、完整播放器不能重复同时解码同一文件。
- [ ] Windows GPU context/device lost 后播放器可恢复或干净报错。
- [ ] Android 后台/前台切换后播放器状态正确。

### 验收标准

- [ ] 主流 H.264 MP4 播放流畅。
- [ ] 无持续 100% 单核 CPU 的异常软件解码。
- [ ] 不出现“为了硬件加速导致部分机器完全打不开视频”的退化。

---

# 7. 桌面端信息架构：禁止手机页面全屏照搬

## R16｜PC 统一右侧详情扩展栏

### 原始需求

PC 端聊天详情、群聊信息、个人信息等不能像手机一样单独占满整个 App；参考 Telegram Desktop，在主内容右侧增加详情栏。

### 执行细则

- [ ] 定义 Desktop `DetailPaneHost` / `RightInspectorPane` 统一容器。
- [ ] 聊天详情打开在右侧栏。
- [ ] 联系人资料打开在右侧栏。
- [ ] 群聊详情打开在右侧栏。
- [ ] 媒体/共享文件等二级详情可在 inspector 内继续切换，但要有返回栈。
- [ ] 保留中间聊天，不因打开详情把聊天整个替换掉。
- [ ] 窄窗口达到断点时可退化为 overlay/drawer/full page；不要在 881×657 强行挤成 4 列。
- [ ] inspector 宽度设最小/理想/最大约束，不写死到某个 DPI。
- [ ] Android 保持移动端 push page / sheet 交互，不强行三栏。
- [ ] Web 桌面宽度采用与 Windows 一致架构。

### 验收标准

- [ ] Windows 聊天中打开联系人资料，聊天仍可见。
- [ ] 群信息打开后不跳出聊天主框架。
- [ ] resize 到窄宽度自动退化且不 overflow。

---

# 8. 设备管理

## R17｜一键清空“已退出设备”

### 执行细则

- [ ] 在 `account_management_page.dart` 登录设备区域增加“清理已退出设备”动作。
- [ ] 当前设备、仍有效远程设备绝不能被删除。
- [ ] 若服务端目前只返回 revoked device record 且无删除 API，新增正式 API/service 清理当前用户自己的 revoked device history。
- [ ] 只能清理自己的设备记录，服务端按 Bearer principal 限权。
- [ ] 设计幂等：重复清理返回成功/0 条，不报错。
- [ ] 清理前可轻确认，但不要使用高危到吓人的流程。
- [ ] 完成后列表即时刷新。

### 验收标准

- [ ] 有 5 条已退出设备时，一键清理后只保留有效设备。
- [ ] 当前设备不会被误删。
- [ ] 多设备并发 revoke/cleanup 不造成认证异常。

---

# 9. 通知 / 提示层视觉统一

## R18｜应用内通知不贴边、不贴底

### 执行细则

- [ ] 审计 `main_shell_page.dart` 的 Overlay message banner 与 SnackBar。
- [ ] 顶部消息通知与窗口四周留稳定 safe margin。
- [ ] Android 处理 SafeArea / 状态栏。
- [ ] Windows 处理自定义标题栏高度。
- [ ] 黑色 Toast/SnackBar 使用 floating 行为，不允许贴屏幕最底边。
- [ ] 底部提示与悬浮 Footer / 键盘之间留间距。
- [ ] 连续通知需要替换/排队策略，不能无限叠加。
- [ ] 宽度不超过合理最大值，桌面不要横跨整屏。

---

## R19｜所有通知/消息头像统一正圆

### 执行细则

- [ ] 应用内 Banner 头像正圆。
- [ ] Windows 自定义通知头像正圆。
- [ ] 头像加载失败 fallback 仍正圆。
- [ ] 群头像如果产品最终使用群组合头像，外轮廓仍正圆；内部组合可按设计实现。

---

# 10. Emoji / Sticker / Mention

## R20｜完整标准 Emoji 数据源

### 原始问题

当前 `text_chat_page.dart` 存在手写少量 `_emoji` 列表，用户认为严重不全。

### 执行细则

- [ ] 移除把几十个 Emoji 写死在聊天页的做法。
- [ ] 使用维护良好的 Emoji 数据集/依赖或项目内生成数据，覆盖当前平台可显示的 Unicode Emoji 序列。
- [ ] 支持分类：最近、表情与人物、动物、食物、活动、旅行、物品、符号、旗帜等。
- [ ] 支持肤色/变体时不要把 ZWJ 序列拆坏。
- [ ] 不对单个 Unicode code point 做错误截断。
- [ ] 搜索可以后续增强，但本批至少分类完整可浏览。
- [ ] 平台字体不支持的 Emoji 应有合理 fallback；不要打包巨大版权不明 Emoji 图片集。

### 验收标准

- [ ] 面板数量远高于当前手写列表，常用旗帜、家庭、职业、肤色等可找到。
- [ ] 发送后消息文本保持完整 Unicode 序列。

---

## R21｜记住上次打开的表情 Tab

### 执行细则

- [ ] 记录用户上次选择：Emoji / 自定义表情 / 某 Sticker Pack。
- [ ] 关闭面板再打开时恢复该 Tab。
- [ ] 重启 App 是否恢复：建议本地持久化；至少同一会话生命周期必须恢复。
- [ ] 若上次 Sticker Pack 已被移除，fallback 到自定义表情或 Emoji，不崩溃。
- [ ] 不同登录用户的本地偏好隔离。

---

## R22｜`@用户` 提及蓝色增强

### 执行细则

- [ ] 调整 `mention_rich_text.dart` / 相关 style token。
- [ ] Light 模式使用更清晰品牌蓝/链接蓝。
- [ ] Dark 模式使用提高亮度后的可读蓝，确保对比度。
- [ ] mention 与普通文本、链接有区别但不要荧光过度。
- [ ] hover/click（桌面）可以进一步高亮。
- [ ] 群里的 `@all` 可使用相同 mention 语义样式。

---

## R23｜添加自定义表情后立即显示

### 执行细则

- [ ] 复现“添加成功但面板无内容”。
- [ ] 检查 create API 返回后是否更新 `_custom` 本地列表。
- [ ] 检查 cache invalidation / pagination / owner filtering。
- [ ] 添加完成后无需关闭整个 App，面板立即出现新表情。
- [ ] 重新登录/另一设备同步后仍可看到。
- [ ] 添加失败不可插入幽灵本地记录。

---

## R24｜自定义表情支持 GIF，取消不合理固定文件大小限制

### 执行原则

“不限制文件大小”的产品目标实现为：**用户不因为一个很小的人为前端上限而直接被拒绝；客户端尽量本地处理到产品允许的 Sticker 规格。仍必须保留防 OOM、防磁盘打满、防 DoS 的安全上限和服务端实例配置。**

### 执行细则

- [ ] 文件选择支持 GIF。
- [ ] 静态图片输入统一处理为适合 Sticker 的 WebP。
- [ ] GIF 保留动画语义；不要粗暴转第一帧 WebP。
- [ ] 若底层 Sticker 协议支持 animated WebP / WebM，则选择项目兼容性最佳格式；必须由当前客户端播放器能力决定。
- [ ] 本地处理使用流式/文件管线，禁止超大文件一次性 `readAsBytes`。
- [ ] 分辨率过高时等比缩放。
- [ ] 透明通道保留。
- [ ] 根据质量目标压缩到合理体积，而不是直接报“文件太大”。
- [ ] 处理过程显示进度/可取消。
- [ ] 服务端仍保留可配置绝对安全上限并返回明确错误。

### 验收标准

- [ ] 普通 JPG/PNG 可转 Sticker。
- [ ] GIF 可作为动态自定义表情使用。
- [ ] 大分辨率图片不会 OOM。

---

## R25｜自定义表情按 STICKER 语义发送，不显示成普通图片

### 执行细则

- [ ] 自定义表情发送必须产生 `STICKER` 消息类型/正式 sticker asset 引用。
- [ ] 不复用 IMAGE 消息的大图气泡样式。
- [ ] 聊天内默认显示较小 Sticker 尺寸。
- [ ] 缩略图尺寸/缓存文件尺寸明显小于普通聊天图片。
- [ ] 长按菜单按 Sticker 语义：收藏/转发/删除等；不出现普通图片不适用动作。
- [ ] 保存到系统相册是否提供按产品定义处理，不默认把 Sticker 当普通照片。
- [ ] 自定义 Sticker 多设备同步保持原动画/透明度。

---

# 11. 群聊能力补齐

## R26｜群头像编辑

### 执行细则

- [ ] 群详情页提供群头像点击/编辑入口。
- [ ] Owner/Admin 权限按产品规则决定；建议 Owner/Admin 可改，普通成员只读。
- [ ] 支持相册选择、拍摄（平台支持时）、裁剪。
- [ ] 本地压缩后上传到正式 media domain。
- [ ] 群表增加 avatar media 引用；如已有字段则复用，不重复。
- [ ] 修改后通过 Group Outbox/Realtime 同步给其他成员。
- [ ] 会话列表、聊天头部、联系人群列表同时更新。
- [ ] 旧缓存需要 cache bust/version key。

### 验收标准

- [ ] Android 改群头像后 Windows 自动刷新。
- [ ] 无权限成员看不到编辑动作。

---

## R27｜联系人 → 群聊必须展示已有群

### 执行细则

- [ ] 移除 `contacts_page.dart` “群聊功能正在接入”占位。
- [ ] 调用正式 Groups list API / 当前 coordinator 数据。
- [ ] 展示当前用户 active member 的群聊。
- [ ] 支持搜索群名。
- [ ] 点击群进入对应 GROUP 会话；会话不存在时按正式流程 ensure/sync，而不是提示“稍后刷新”。
- [ ] Android / Windows / Web 行为一致。
- [ ] PC 通讯录左侧列表增加群聊分类/入口。

### 验收标准

- [ ] 已创建 3 个群时，联系人→群聊能立即看到 3 个。
- [ ] 点击后直接打开对应群聊天。

---

## R28｜正式群语音通话 / 群视频通话

### 重要说明

这是本批次最大新增功能之一。P7 当前正式能力是一对一通话，不能把群通话伪装成已存在。

### 服务端设计

- [ ] 先定义 Group Call domain 与状态机。
- [ ] Call 必须绑定 `groupId`。
- [ ] 校验发起者是 active group member。
- [ ] Participant 只允许 active member 加入。
- [ ] 被移出群/退群后不能新加入群通话。
- [ ] 定义 voice/video 两种模式。
- [ ] 定义 participant joined/left/muted/camera state 所需实时事件。
- [ ] LiveKit room/token 使用服务端签发，不允许客户端自报任意 group/user identity。
- [ ] 加入 token 绑定 userId + deviceId + group membership。
- [ ] 定义最大参与人数和实例可配置上限。
- [ ] 群通话结束生成群 SYSTEM message / 通话记录。
- [ ] Block / 免打扰 / Push 的语义单独明确，不能简单照搬 1:1。

### Flutter

- [ ] 群聊天头部/菜单增加语音群通话、视频群通话入口。
- [ ] 发起前展示参与者/通知策略。
- [ ] 群语音页面支持多人头像网格、静音、扬声器、成员列表。
- [ ] 群视频支持动态网格/主讲者布局，小屏不 overflow。
- [ ] Windows 桌面充分利用大屏，不照搬手机 2×2 布局。
- [ ] 成员加入/退出实时更新。
- [ ] 网络恢复、后台、设备切换按现有 Calls 基线处理。

### 测试

- [ ] PostgreSQL Group Call membership integration。
- [ ] 非成员 token 拒绝。
- [ ] 被踢成员再次 join 拒绝。
- [ ] 3+ 参与者状态机测试。
- [ ] 真人至少 Windows + 2 Android / Web 三设备测试。

---

# 12. 朋友圈功能与视觉

## R29｜朋友圈背景图可更改

### 执行细则

- [ ] 朋友圈顶部封面增加编辑入口，仅当前用户自己的 Feed 显示。
- [ ] 支持从相册选择；移动端可选拍摄。
- [ ] 提供裁剪/定位，适配桌面宽屏与手机窄屏。
- [ ] 服务端保存用户级 Moments cover media 引用。
- [ ] 私有媒体授权：封面应该只对允许查看该用户朋友圈/资料的人暴露，具体范围按产品规则定义。
- [ ] 更新后多端刷新。
- [ ] 默认封面保留品牌中性 fallback。

---

## R30｜朋友圈长期权限移动到联系人资料 / 聊天详情

### 原始需求

“不看他 / 不让他看”放在朋友圈 Feed 顶部不符合逻辑，应在聊天详情和联系人里面。

### 执行细则

- [ ] `moments_feed_page.dart` 顶部移除不合理的“朋友圈权限”全局按钮，或只保留真正的全局朋友圈设置。
- [ ] 联系人资料增加：
  - [ ] 不看他的朋友圈。
  - [ ] 不让他看我的朋友圈。
- [ ] DIRECT 聊天详情增加同样入口。
- [ ] 两处共用同一 service/state，不允许一个开关改了另一个不刷新。
- [ ] 群聊详情不显示联系人级朋友圈权限。
- [ ] 非好友/自己账号时按规则隐藏。

### 验收标准

- [ ] 在联系人页修改后，聊天详情状态即时一致。
- [ ] Feed 过滤立即生效。

---

## R31｜联系人资料可进入对方朋友圈

### 执行细则

- [ ] 联系人详情新增明显的“朋友圈”行/缩略入口。
- [ ] 点击打开该联系人的个人朋友圈 Feed，而不是全量朋友圈。
- [ ] 受 Block、删除好友、对方隐私设置约束。
- [ ] 没有动态时显示正常空状态。
- [ ] 无权限时显示“暂无可见内容/不可见”，不要泄露是否真实存在隐藏内容。

---

## R32｜朋友圈互动一级化

### 原始需求

朋友圈点赞/评论不应藏在二级菜单。

### 执行细则

- [ ] 每条动态直接提供点赞和评论入口。
- [ ] 不要求先点 `...` 再选择点赞/评论。
- [ ] `...` 只保留低频动作：删除（本人）、权限/举报（未来）等。
- [ ] 点赞状态一键切换，乐观更新失败后正确回滚。
- [ ] 评论按钮直接聚焦评论输入区。
- [ ] 回复某条评论仍可用点击评论的二级上下文动作，但不能影响主互动入口。

---

## R33｜朋友圈视觉去除不喜欢的框体

### 执行细则

- [ ] 对照原需求截图检查 Feed 当前外层卡片/边框。
- [ ] 移除厚重全包围卡片感，向微信式平铺信息流靠拢。
- [ ] 用户头像、昵称、正文、媒体、时间、互动区依赖 spacing/分隔线建立层级，不靠大圆角卡片套卡片。
- [ ] 评论区背景可使用很浅的 surface，但不要整条红色/高饱和边框。
- [ ] Light / Dark 都需重新校准。

---

## R34｜评论文字颜色修正

- [ ] 评论正文不允许使用红色。
- [ ] 联系人名字/回复对象使用品牌链接色或主文字强调。
- [ ] 删除/危险操作才使用红色。
- [ ] 深色模式保证可读性。

---

## R35｜发表朋友圈页面移除全圆框

### 执行细则

- [ ] `moment_publish_page.dart` 去掉用户明确不喜欢的外层全圆大框。
- [ ] 编辑区采用页面本身的布局层级：文本输入 + 媒体 grid + 权限/位置等行项。
- [ ] “发表”按钮不必因全局组件习惯做成夸张胶囊；按当前 DD 顶栏动作风格处理。
- [ ] Android / Windows 桌面布局分别适配。

---

# 13. 联系人资料 / 编辑 UI

## R36｜联系人详情页按参考方向重做

### 设计目标

用户明确不喜欢当前联系人详情，希望更接近所给参考图的简洁资料页。

### 执行细则

- [ ] 顶部头像、昵称、DDID、个性签名形成清晰身份区。
- [ ] 主动作“发消息 / 语音通话 / 视频通话”放在容易触达位置。
- [ ] 朋友圈入口直接可见。
- [ ] 朋友圈隐私项按 R30 放在合理设置区。
- [ ] 备注、标签、共同群聊等信息按实际已有能力展示，没数据不做假占位。
- [ ] 拉黑/删除联系人等危险动作放底部，红色仅用于危险操作。
- [ ] Desktop 使用 R16 右侧详情栏；Android 使用移动页面。
- [ ] 头像正圆。
- [ ] 长昵称/长签名不 overflow。
- [ ] PENDING / NONE / CONTACT / blocked 等关系状态显示正确。

---

## R37｜资料编辑框 UI 重做（Windows + Android）

### 执行细则

用户不喜欢当前大量默认 Material TextField 式编辑框，参考图更偏简洁底线/列表式编辑。

- [ ] 统一建立 `DdProfileEditField` / 语义组件。
- [ ] 标签与输入值层级清晰。
- [ ] 减少厚重 OutlineInputBorder / 大圆角输入框。
- [ ] 聚焦状态使用轻量品牌色底线/边框。
- [ ] 错误状态清楚但不整框刺眼红。
- [ ] Android 键盘弹出时字段不被遮挡。
- [ ] Windows Enter / Esc / Tab 键盘行为合理。
- [ ] 昵称、备注、签名、邮箱等可编辑字段统一视觉语言。
- [ ] 密码等安全字段可保留专门控件，不强行统一。

---

## R38｜个性签名展示接通真实数据

### 执行细则

- [ ] 核对 `personal_profile_page.dart` 已有 bio 编辑能力与 API 字段。
- [ ] `main_shell_page.dart` 当前“个性签名 未设置”不能继续写死。
- [ ] 自己资料显示当前 session/user 的真实 bio。
- [ ] 联系人资料显示 peer bio。
- [ ] 修改后当前界面即时刷新，不要求重新登录。
- [ ] 空签名才显示“未设置”。

---

# 14. QR 入口完整接线

## R39｜发现 → 扫一扫确保正式接线

虽然用户反馈此入口当前可用，本轮仍加入回归：

- [ ] 确认调用正式 `QrScannerPage`。
- [ ] 个人码、群码、登录码都可分流。
- [ ] 与 R02 共享 handler。

---

## R40｜个人信息 → 我的二维码接线

### 执行细则

- [ ] `personal_profile_page.dart` 的“二维码 / 我的二维码”行可点击。
- [ ] `main_shell_page.dart` 我的页面二维码图标/行可点击。
- [ ] 全部进入现有 `MyQrPage`。
- [ ] 二维码内容来自正式实例绑定 payload，不在客户端自己拼危险 URL。
- [ ] 支持保存/分享二维码（若现有能力已具备则回归）。
- [ ] 无网络时对已有静态个人码是否可展示按现有 QR domain 设计执行，不造假数据。

---

# 15. 二级菜单 / 弹层统一可取消

## R41｜点击空白遮罩关闭菜单

### 范围

- [ ] 聊天 `+` 二级菜单。
- [ ] Emoji/Sticker 面板（按产品需要；输入型面板可用下滑/空白关闭）。
- [ ] 消息长按/右键菜单。
- [ ] 联系人更多菜单。
- [ ] 群聊更多菜单。
- [ ] 朋友圈低频 `...` 菜单。
- [ ] 其他 `showModalBottomSheet` / `OverlayEntry` / 自定义 popup。

### 执行细则

- [ ] popup 外必须存在可点击 barrier。
- [ ] barrier 点击关闭。
- [ ] Esc（Windows）关闭当前最上层 popup。
- [ ] Android 返回键关闭 popup，不直接退出页面。
- [ ] 危险确认 Dialog 不因误触外部区域直接确认；可按产品规则允许取消，但绝不能把 barrier tap 当确认。
- [ ] popup 关闭后焦点合理恢复到原控件/聊天输入框。

---

# 16. 跨任务架构要求

## A01｜统一 Media Transfer Controller

R07～R15 不允许各做一套 upload/download 状态。

建议形成：

```text
MediaTransferController
├── upload task
├── download task
├── progress(bytesDone, bytesTotal)
├── cancel
├── retry
├── cache target
└── observable state
```

- [ ] UI 层只订阅 transfer state。
- [ ] 网络层暴露 cancel handle。
- [ ] cache 层负责 atomic temp → final rename。
- [ ] 同一 mediaId 避免重复下载。

---

## A02｜统一 Desktop Inspector

R16、R30、R36、R40 等桌面二级详情优先走统一 inspector host，不要每个页面自己判断 `isDesktop` 然后复制一套 scaffold。

---

## A03｜统一 Avatar 组件

R05、R18、R19、R26、R36 统一复用一个 Avatar widget / avatar image provider：

- 正圆裁剪；
- fallback；
- 缓存；
- 错误态；
- 可选 presence/badge overlay。

---

## A04｜统一 Popup / ActionSheet 行为

R41 不要靠每个页面手工包 `GestureDetector`。建立或收敛统一 DD popup/action sheet 组件，保证 barrier/返回键/Esc 行为一致。

---

# 17. 测试与质量门禁

## T00｜Flutter 自动测试

至少补以下定向回归：

- [ ] 归档入口顺序与紧凑高度。
- [ ] 收藏头像圆形。
- [ ] 收藏消息无“收藏自原消息”标签。
- [ ] Transfer progress 格式化与 cancel state。
- [ ] 自动下载偏好持久化。
- [ ] Cache manager 分类清理。
- [ ] 视频控制层 play/pause/mute/speed/progress。
- [ ] Desktop inspector 几何/断点。
- [ ] Emoji Tab 恢复。
- [ ] Sticker 添加后列表刷新。
- [ ] mention style token。
- [ ] Contacts group list 不再占位。
- [ ] 群头像权限 UI。
- [ ] Moments privacy 入口从 Feed 移出并出现在联系人/聊天详情。
- [ ] Moments interaction 一级按钮。
- [ ] Profile bio 真实绑定。
- [ ] `+ → 扫一扫` 路由到 QrScannerPage。
- [ ] 个人资料 → 我的二维码路由。
- [ ] popup barrier dismiss。

## T01｜Go / PostgreSQL

如果新增下列能力，必须有服务端测试：

- [ ] revoke device history cleanup API。
- [ ] group avatar persistence/authorization。
- [ ] group call domain / participant membership / token authorization。
- [ ] moments cover persistence/authorization。
- [ ] custom sticker animated asset metadata（如需 schema/API 变化）。

## T02｜真实平台测试，不能用 Widget Test 冒充

### Android

- [ ] 打开文件。
- [ ] SAF/系统保存。
- [ ] 系统分享。
- [ ] 相机拍摄。
- [ ] 相机权限拒绝/永久拒绝。
- [ ] 大文件上传取消。
- [ ] 大文件下载取消。
- [ ] 视频硬件解码。
- [ ] GIF Sticker 动画。
- [ ] 朋友圈视频发布。

### Windows

- [ ] 视频播放器全屏。
- [ ] 浮窗/PiP。
- [ ] 恢复主窗口。
- [ ] Desktop inspector。
- [ ] 125% / 150% DPI。
- [ ] 文件打开/保存/分享等已有能力回归。

### 多端

- [ ] 群头像 Android 修改 → Windows/Web 刷新。
- [ ] 自定义表情设备 A 添加 → 设备 B 出现。
- [ ] 群通话 3+ 设备。
- [ ] 朋友圈背景图跨设备。

---

# 18. 推荐执行顺序

严格建议按以下顺序推进，避免先做皮肤后被底层重构推翻：

## Phase 1｜阻断真人继续测试的问题

- [ ] R01 朋友圈视频发布与媒体污染。
- [ ] R02 主页加号扫一扫。
- [ ] R03 拍摄。
- [ ] R23 自定义表情添加后不显示。
- [ ] R27 联系人群聊入口。
- [ ] R38 个性签名真实绑定。
- [ ] R40 我的二维码。

### Checkpoint 1

- [ ] 上述功能入口全部不是占位按钮。
- [ ] Flutter 定向测试通过。
- [ ] `go test ./...` 通过。

## Phase 2｜媒体传输与缓存底座

- [ ] A01 Transfer controller。
- [ ] R07 Android 文件打开/保存/分享。
- [ ] R08 上传进度/取消。
- [ ] R09 下载进度/取消。
- [ ] R10 自动下载设置。
- [ ] R11 缓存管理。

### Checkpoint 2

- [ ] 大文件真实上传/下载取消不会留脏 UI。
- [ ] 缓存清理后能重新下载。

## Phase 3｜视频体验

- [ ] R12 聊天内视频播放。
- [ ] R13 完整播放器。
- [ ] R14 Windows 浮窗/PiP。
- [ ] R15 硬件加速/性能。

### Checkpoint 3

- [ ] 真实 MP4 在 Android/Windows 连续播放通过。
- [ ] Windows 浮窗恢复通过。

## Phase 4｜Emoji / Sticker / Mention

- [ ] R20 完整 Emoji。
- [ ] R21 Tab 记忆。
- [ ] R22 Mention 视觉。
- [ ] R24 GIF/大图 Sticker 处理。
- [ ] R25 Sticker 语义展示。

### Checkpoint 4

- [ ] 自定义 Sticker 静态 + 动态均能多端发送。

## Phase 5｜群聊扩展

- [ ] R26 群头像。
- [ ] R28 群语音/视频通话。

### Checkpoint 5

- [ ] 群头像同步通过。
- [ ] 3+ 设备群通话主链通过。

## Phase 6｜桌面信息架构 + 联系人资料

- [ ] A02 Desktop Inspector。
- [ ] R16 PC 右侧详情栏。
- [ ] R36 联系人详情重做。
- [ ] R37 编辑框 UI。
- [ ] R30 朋友圈权限迁移。
- [ ] R31 对方朋友圈入口。

## Phase 7｜朋友圈视觉与背景

- [ ] R29 朋友圈背景图。
- [ ] R32 互动一级化。
- [ ] R33 去卡片化。
- [ ] R34 评论颜色。
- [ ] R35 发表页去全圆框。

## Phase 8｜会话 / 通知 / 弹层 polish

- [ ] R04 归档入口。
- [ ] R05 收藏头像。
- [ ] R06 收藏气泡。
- [ ] R17 已退出设备清理。
- [ ] R18 通知 margin。
- [ ] R19 通知头像圆形。
- [ ] A03 Avatar 统一。
- [ ] A04 Popup 统一。
- [ ] R41 空白关闭菜单。

---

# 19. 最终自动门禁

下一位 AI 在宣称代码阶段完成前至少执行当前仓库已有的对应门禁；具体命令以 `docs/06-测试验收与发布标准.md` 和项目脚本为准，不要凭旧对话猜命令。

必须确认：

- [ ] Dart format 无漂移。
- [ ] Flutter analyzer 0 issue。
- [ ] Flutter 全量/关键定向测试通过。
- [ ] Go test 全绿。
- [ ] OpenAPI lint/contract 全绿。
- [ ] 新 migration 有 up/down，且真实 PostgreSQL roundtrip。
- [ ] Windows Release build 通过。
- [ ] Android APK build 通过。
- [ ] Web Release build 通过或平台特有代码正确隔离。
- [ ] 不存在测试服务/浏览器后台残留进程。

---

# 20. 文档同步要求

同一开发批次结束前：

- [ ] 更新 `docs/12-产品体验与UI功能基线.md`。
- [ ] 更新 `docs/15-当前实现状态与开发路线.md`。
- [ ] 涉及 API/数据模型时更新 `docs/05-API与数据模型草案.md`。
- [ ] 涉及权限/媒体/群通话时更新安全与架构相关 docs。
- [ ] 更新 `开发进度跟踪.md`。
- [ ] 生成/更新最终真人测试清单，覆盖本文件 R01～R41。
- [ ] 真人没有复测的历史失败只能标 `FIXED-PENDING-RETEST`，不能写 `HUMAN-PASS`。

---

# 21. 给下一位 AI 的最终自检

在结束本批会话前逐条回答：

- [ ] 是否还有任何 `功能正在接入` / `暂不可用` 占位入口与本需求冲突？
- [ ] 是否有按钮看得到但点击后没有真实业务链？
- [ ] 是否只修了 Android，却让 Windows/Web 编译或体验退化？
- [ ] 是否只修了 UI，没有真正 abort upload/download？
- [ ] 是否用“文件太大”偷懒拒绝，而没有尝试流式压缩/处理？
- [ ] 是否把 GIF 自定义表情错误转成静态第一帧？
- [ ] 是否把 Sticker 仍作为 IMAGE 消息发送？
- [ ] 是否把移动端全屏资料页原样搬到了 Windows？
- [ ] 是否把朋友圈长期联系人权限继续放在 Feed 顶部？
- [ ] 是否把群通话误当成 P7 1:1 Calls 已完成？
- [ ] 是否单次朋友圈视频失败仍能影响其他 Feed 媒体？
- [ ] 是否所有 popup 都能通过空白/Esc/返回键自然取消？
- [ ] 是否相关自动回归和 docs 已同步？

只要任意答案为“是（存在问题）”，继续开发，不得宣布本文件已完成。
