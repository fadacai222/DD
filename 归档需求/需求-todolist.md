# DD 2026-08-10 需求执行清单（T01～T15）

> 来源：根目录 `需求.md`
> 最终更新：2026-08-10
> 状态：**T01～T15 开发实现全部完成；自动门禁/真实 PostgreSQL/OpenAPI/三端构建全部通过；真人体验验收待 `人工测试.md`。**

## 勾选规则

- `[x]`：代码/协议/数据库/自动测试/构建已有实际证据支持。
- `[ ]`：只能真人在真设备上判断，AI 不代替用户勾选。
- “本批需求完成”指 T01～T15 技术实现完成，不表示整个 DD 商业化 1.0 已全部开发完。

---

# 0. 开工基线与收口

- [x] 阅读并对照 `需求.md`。
- [x] 阅读并对照 `docs/12-产品体验与UI功能基线.md`。
- [x] 阅读并同步 `docs/05-API与数据模型草案.md`。
- [x] 阅读并同步 `docs/06-测试验收与发布标准.md`。
- [x] 检查当前 Git 工作树，不 reset/checkout 覆盖既有修改。
- [x] 所有新增代码通过 formatter / analyzer / vet。
- [x] 所有新增协议有 OpenAPI/合同回归。
- [x] 本批功能完成后生成统一 `人工测试.md`。
- [x] 更新 `开发进度跟踪.md`。

---

# T01｜个人资料编辑权只保留在“我的 → 个人信息” ✅

## 实现

- [x] Android/通用 `账号、隐私与设备` 删除昵称编辑入口。
- [x] 删除 DDID 编辑入口。
- [x] 删除邮箱编辑入口。
- [x] 删除个性签名编辑入口。
- [x] `我的 → 个人信息` 提供昵称编辑。
- [x] `我的 → 个人信息` 提供 DDID 编辑。
- [x] `我的 → 个人信息` 提供个性签名编辑。
- [x] 邮箱改绑通过验证码确认。
- [x] 修改后刷新当前 Session / 用户展示数据。
- [x] 历史登录信息同步最新头像/名称。
- [x] Widget Test 防止设置页重新暴露资料编辑字段。

## 真人验收

- [ ] Android 真机确认入口没有重复/绕路编辑器。

---

# T02｜头像查看 + 下载 ✅

- [x] 头像点击进入统一图片查看器。
- [x] 查看器提供保存/下载动作。
- [x] Android 图片保存接 MediaStore。
- [x] Windows/Web 走平台保存/下载能力。
- [x] 自动测试覆盖图片导出调用。

## 真人验收

- [ ] Android 系统相册真实可见。
- [ ] Windows 保存路径/文件真实可用。

---

# T03｜头像裁剪重做 ✅

- [x] 手势区域大于裁剪框，不再被正方形边界锁死。
- [x] 竖长图可双指放大到只截脸。
- [x] 横长图可拖动/缩放。
- [x] 支持拖动。
- [x] 支持双指缩放。
- [x] 支持双击复位。
- [x] offset clamp，不能拖出无图空白。
- [x] 裁剪几何与最终上传结果一致。
- [x] 宽/高/方图自动测试覆盖。

## 真人验收

- [ ] 竖长真照片裁脸手感。

---

# T04｜聊天右上角 `...` → 真正聊天详情 ✅

- [x] 移除 `...` 上的调试 `_sync` 行为。
- [x] 打开正式“聊天详情”。
- [x] 显示对方头像、名称、DDID。
- [x] 可进入对方资料/关系管理。
- [x] 当前会话搜索使用 `conversationId` 真过滤。
- [x] 搜索结果可定位原消息。
- [x] 提供免打扰开关。
- [x] 提供置顶开关。
- [x] 提供当前聊天背景入口。
- [x] 提供仅本地删除会话，并使用危险操作样式。
- [x] 新增真实“聊天图片、视频与文件”分类入口。
- [x] 图片/GIF/Sticker 分类页。
- [x] VIDEO 分类页，poster 展示，点击可播放。
- [x] 文件分类页，点击可定位原消息。
- [x] 可继续加载更早媒体历史。
- [x] Widget Test 覆盖 `... → 详情 → 媒体分类 → 文件 → 原消息定位`。

## 真人验收

- [ ] 大量真实媒体历史下分类/定位体验。

---

# T05｜Android 视频通话 PiP ✅

- [x] 默认远端主画面、本地右下角小窗。
- [x] 点击小窗交换主/副画面。
- [x] 再次点击可交换回来。
- [x] 小窗支持拖动。
- [x] 安全区域 clamp。
- [x] 左右吸边。
- [x] 避免核心控制按钮区域。
- [x] 摄像头关闭占位保持可操作。
- [x] 修复小尺寸小窗 overflow。

## 真人验收

- [ ] Android Platform Texture 真机点击/拖动命中。
- [ ] 真实视频通话中无横屏/遮挡问题。

---

# T06｜Telegram 式全局高圆角体系 ✅

统一 Design Token：

```text
DdRadii.pill
DdRadii.messageBubble
DdRadii.media
DdRadii.surface
DdRadii.sheet
DdRadii.control
```

- [x] 头像统一真圆。
- [x] 消息气泡高圆角。
- [x] 媒体缩略图高圆角。
- [x] 搜索/输入/适合 pill 的控件统一。
- [x] 会话菜单/Action Sheet/设置卡片统一。
- [x] 联系人/资料页统一。
- [x] Saved Messages/通话/Realtime 辅助 UI 扫描迁移。
- [x] 全项目显式小圆角扫描完成。
- [x] 仅保留波形条、进度线、拖拽手柄、程序化背景等 2～4px 微型几何，不把这些错误放大成 20px。

## 真人验收

- [ ] Android 360×640 视觉一致性。
- [ ] Windows 881×657 视觉一致性。

---

# T07｜聊天日期显示 ✅

- [x] 今天。
- [x] 昨天。
- [x] 同年更早月/日。
- [x] 跨年完整日期。
- [x] SYSTEM 与普通消息统一参与日期分组。
- [x] 自动测试覆盖按本地自然日分隔。

---

# T08｜PC 联系人详情增加“发消息” ✅

- [x] Windows 联系人详情有明确发消息主按钮。
- [x] 点击直接进入 DIRECT 私聊。
- [x] 复用已有会话，防止重复 DIRECT。

## 真人验收

- [ ] Windows 实际点一次确认交互位置/视觉顺手。

---

# T09｜撤回后任何用户 UI 不显示撤回提示 ✅

- [x] 服务端保留 `recalled_at` tombstone。
- [x] Sync 仍同步撤回状态。
- [x] 时间线直接隐藏撤回消息。
- [x] 不显示“你撤回了一条消息”。
- [x] 不显示“对方撤回了一条消息”。
- [x] 不显示“消息已撤回”。
- [x] 会话预览过滤撤回消息。
- [x] Pin/回复引用/搜索同步过滤。
- [x] 已独立转发/收藏副本不被源撤回污染。
- [x] Widget Test 覆盖无撤回占位。

## 真人验收

- [ ] Android ↔ Windows 跨端撤回视觉确认。

---

# T10｜编辑文字消息 + “已更新” ✅

## 数据库 / 协议

- [x] migration `000014_message_editing`。
- [x] `messages.edited_at`。
- [x] `messages.edit_version`。
- [x] `PATCH /api/v1/messages/{messageId}`。
- [x] 请求体 `text + expectedEditVersion`。
- [x] 只有发送者可以编辑。
- [x] 仅 TEXT 可以编辑。
- [x] 已撤回消息禁止编辑。
- [x] 默认不限编辑时间。
- [x] 相同正文幂等。
- [x] stale editVersion 冲突，禁止静默覆盖。
- [x] 同一事务更新正文/版本并写 Outbox。
- [x] Sync 事件 `MESSAGE_EDITED`。
- [x] OpenAPI 完整描述编辑请求/响应字段。

## 客户端

- [x] 长按/右键自己 TEXT 出现“编辑”。
- [x] 输入框进入编辑态。
- [x] 提供取消编辑。
- [x] 原消息原地更新，不生成第二条消息。
- [x] 显示“已更新”。
- [x] 新正文参与搜索，会话预览读取最新内容。
- [x] Flutter DTO 保留 `editedAt/editVersion`。

## 自动证据

- [x] 真实 PostgreSQL owner-only/幂等/冲突/搜索 PASS。
- [x] Alice/Bob 双端 `MESSAGE_EDITED` Sync PASS。
- [x] Widget Test 编辑 UI PASS。

## 真人验收

- [ ] Android ↔ Windows 多设备实时编辑体验。
- [ ] 两设备同时编辑冲突提示体验。

---

# T11｜PC 输入框固定置底 ✅

- [x] 881×657 几何回归测试。
- [x] 输入 footer 固定聊天区底部。
- [x] 移除常驻占高的 Enter/Shift+Enter 提示。
- [x] Enter 发送。
- [x] Shift+Enter 换行。
- [x] 回复/编辑条属于 footer。
- [x] 连续发送保持输入焦点已有回归覆盖。

## 真人验收

- [ ] Windows 881×657 真窗口视觉确认。

---

# T12｜聊天背景 ✅

- [x] DD 原创程序化默认背景。
- [x] 不使用微信/Telegram 专有壁纸。
- [x] 全局背景。
- [x] 单聊天覆盖。
- [x] 恢复跟随全局。
- [x] 纯色。
- [x] 自定义图片。
- [x] 自定义图片本地压缩。
- [x] 复制到 App 私有目录，不依赖原始文件继续存在。
- [x] 按账号隔离。
- [x] 自动测试覆盖状态持久化/资产清理。

## 真人验收

- [ ] 长历史滚动时背景性能。
- [ ] 多账号实际切换不串背景。

---

# T13｜通话等待音 / 来电铃声 / 通知音等 ✅

- [x] `AppSoundService` 统一管理。
- [x] 去电等待音。
- [x] 来电铃声。
- [x] 接通音。
- [x] 挂断音。
- [x] 新消息提示音。
- [x] 全部使用 DD 程序生成 PCM WAV，无第三方音效授权坑。
- [x] 通话状态变化停止上一个循环声音。
- [x] 消息提示 debounce。
- [x] 会话免打扰不播放 DD 消息音。
- [x] 系统通知静音，避免本地 DD 音效 + 系统默认音双响。
- [x] 单元测试验证 WAV/状态机/debounce。

## 真人验收

- [ ] Android/Windows 真扬声器、耳机、Audio Focus、听感。

---

# T14｜图片/GIF/视频查看、保存/复制 + VIDEO 主链 ✅

## VIDEO 数据/协议

- [x] migration `000015_video_messages`。
- [x] 正式消息类型 `VIDEO`。
- [x] 媒体 purpose `CHAT_VIDEO`。
- [x] `posterMediaId`。
- [x] 主视频 `PRIMARY` + poster `THUMBNAIL`。
- [x] VIDEO 发送校验宽高/时长/poster。
- [x] 主视频/poster 所有权与 READY 授权。
- [x] 转发保持 VIDEO + poster 语义。
- [x] OpenAPI `Message.type` 包含 VIDEO。
- [x] OpenAPI `SendMessageRequest.type` 包含 VIDEO。
- [x] OpenAPI `MessageContent.posterMediaId`。
- [x] OpenAPI media purpose 包含 CHAT_VIDEO。
- [x] 新增 Go OpenAPI 合同测试，避免“实现已支持但合同漏字段”再次发生。

## Flutter

- [x] 本地选择 MP4/WebM/MOV/MKV。
- [x] 流式上传主视频。
- [x] 读取时长/宽高。
- [x] 抓 poster JPEG。
- [x] poster 上传。
- [x] pending VIDEO 显示“视频发送中/失败”，不显示空文本气泡。
- [x] 消息流只加载 poster。
- [x] 点击视频进入 `media_kit` 播放页。
- [x] 图片/GIF 查看器支持保存/复制。
- [x] VIDEO 查看器支持保存/复制。
- [x] Android 大视频保存使用流式 MediaStore。
- [x] Android 视频复制使用 FileProvider/content URI。
- [x] 当前会话媒体分类页可浏览图片/视频/文件。
- [x] Flutter DTO 测试覆盖 VIDEO/poster/pending persistence。

## 真 PostgreSQL 安全验证

- [x] conversation member 主视频/poster 可访问。
- [x] non-member 主视频/poster forbidden。
- [x] 转发后目标会话成员获得合法媒体访问。
- [x] `message_media` PRIMARY/THUMBNAIL 角色正确。

## 真人验收

- [ ] Android 相册实际保存。
- [ ] Windows Save As/复制。
- [ ] MP4/WebM/MOV/MKV 真设备解码兼容性。
- [ ] Android FileProvider 视频复制到目标 App。

---

# T15｜图片/媒体消息不套绿色背景 ✅

- [x] IMAGE 不套绿色正文气泡。
- [x] GIF 不套绿色正文气泡。
- [x] Sticker 不套绿色正文气泡。
- [x] VIDEO 不套绿色正文气泡。
- [x] 缩略图高圆角。
- [x] 时间/状态独立显示。
- [x] 收发结构一致，仅左右位置不同。
- [x] Widget Test 覆盖自己的视觉媒体无绿色外层气泡。

## 真人验收

- [ ] 极宽/极高图片、GIF、竖屏视频视觉检查。

---

# 16. 自动化 DoD ✅

## Migration / PostgreSQL

- [x] `000014` / `000015` 真实 PostgreSQL up。
- [x] 重复 up 幂等。
- [x] down 一步。
- [x] 再 up。
- [x] `MIGRATION_ROUNDTRIP_TEST_PASSED=true`。
- [x] T10 真 PostgreSQL 集成 PASS。
- [x] T14 真 PostgreSQL 授权/转发集成 PASS。

## 全量代码门禁

最终一次 `scripts/test-client.ps1`：

- [x] Go `gofmt`。
- [x] Go `vet ./...`。
- [x] Go `test ./...`。
- [x] Realtime analyze。
- [x] Realtime test 4/4。
- [x] Flutter format 135 files / 0 changed。
- [x] Flutter analyze `--fatal-infos` / 0 issue。
- [x] Flutter test 127/127。
- [x] Live REST/WebSocket smoke PASS。
- [x] 最终临时 smoke 端口 `18846`。
- [x] residual process/port check PASS。

## OpenAPI

- [x] recommended-strict lint PASS。
- [x] `OPENAPI_LINT_PASSED=true`。
- [x] 编辑合同代码级回归。
- [x] VIDEO/poster/CHAT_VIDEO 合同代码级回归。

## 三端构建

- [x] Windows Release build PASS。
- [x] Web Release build PASS。
- [x] Android Debug APK build PASS。
- [x] 根目录 `DD-Windows.lnk` 已刷新。
- [x] 根目录 `DD-Web.lnk` 已刷新。
- [x] 根目录 `DD-Android.apk` 已刷新。

> 最后一轮客户端构建发生在最后一次客户端 Dart 改动之后。随后只补了服务端 OpenAPI JSON 与 Go 合同测试，不影响客户端二进制。

---

# 17. 文档 DoD ✅

- [x] `需求-todolist.md` 更新到真实完成状态。
- [x] `开发进度跟踪.md` 更新。
- [x] `人工测试.md` 重建为最新唯一真人验收入口。
- [x] `docs/05-API与数据模型草案.md` 补编辑/VIDEO 合同与数据模型。
- [x] `docs/06-测试验收与发布标准.md` 补编辑/VIDEO/高圆角/PiP/音效验收标准。
- [x] `docs/12-产品体验与UI功能基线.md` 修正早期圆角冲突并加入 2026-08-10 最新硬基线。
- [x] `需求.md` 保留用户原始需求，不改写原文。

---

# 18. 最终人工验收 DoD

以下项目只能由真人完成，所以此处故意不打勾：

- [ ] Android/Windows/Web 最新产物按 `人工测试.md` 完整验收。
- [ ] 真机 PiP 点击/拖动手感通过。
- [ ] 真机/Windows 音效状态机与听感通过。
- [ ] Android 相册保存/视频复制通过。
- [ ] Windows 保存/剪贴板通过。
- [ ] 真实视频格式兼容通过。
- [ ] 360×640 / 881×657 最终视觉通过。
- [ ] 用户在 `人工测试.md` 勾选“全部通过”。

---

# 19. 当前最终状态

```text
T01  [x]
T02  [x]
T03  [x]
T04  [x]
T05  [x] 代码/自动；真人触摸待验
T06  [x]
T07  [x]
T08  [x]
T09  [x]
T10  [x]
T11  [x]
T12  [x]
T13  [x] 代码/自动；真人听感待验
T14  [x] 代码/协议/真库；真设备媒体能力待验
T15  [x]

自动门禁    [x]
真实 PostgreSQL [x]
OpenAPI      [x]
三端构建      [x]
文档同步      [x]
真人最终验收  [ ]
```

**开发侧本批需求已经关闭。下一步不要继续盲改代码，先按 `人工测试.md` 做一轮真实设备体验验收；发现问题再按反馈进入下一轮。**
