# DD 产品需求规格书（PRD）

> 版本：2026-08-11 Current（P6-P9 实现状态同步，P10 开发中）
>
> 本文描述 **产品最终应有行为**。实现状态不要从本文标题猜测，统一查看 `15-当前实现状态与开发路线.md`。

---

## 1. 产品愿景

DD 是一个可自托管、多端、面向真实日常使用的即时通讯产品。

用户感知目标：

- 打开就能回到上次会话，不反复登录。
- 消息发送、切页、输入、媒体打开要“立即响应”。
- 断网和服务重启不能造成消息静默丢失。
- UI 信息层级克制、直观；功能开放度不被微信式限制束缚。
- 服务器部署者能够掌控账号策略、数据、对象存储、RTC 与备份。
- 隐私功能必须真实可验证，不能用营销文案替代协议和安全评审。

---

## 2. 用户角色

### 普通用户

注册、登录、维护资料、添加联系人、聊天、发媒体、通话、群聊、朋友圈与二维码；后续增加完整后台 Push 与 E2EE。

### 群主/管理员

管理群资料、成员、Owner/Admin/Member 权限、公告、邀请、审批和群二维码。当前 P6/P9 已有对应正式服务端能力。

### 实例管理员

未来维护注册策略、用户状态、举报、审计、容量、邮件、对象存储、RTC 等实例配置。

### 部署者

通过 Docker Compose 等方式部署、升级、备份和恢复 DD。

---

## 3. 核心用户旅程

### 3.1 首次注册

```text
输入邮箱
→ 获取验证码
→ 设置 DDID / 昵称 / 密码
→ 注册成功
→ 建立设备会话
→ 进入主界面
```

要求：

- DDID 唯一、可用于精确搜索与 `@username`。
- 邮箱不作为公开检索标识。
- 验证码、密码、Token 错误信息不能形成账号枚举漏洞。

### 3.2 再次打开客户端

```text
启动页
→ 读取安全会话 Vault
→ Refresh
→ 成功则直接进入主壳
```

要求：

- 无有效会话才展示登录页。
- 临时网络失败不能误删除 Refresh Token。
- Refresh 明确失效后才清会话。
- 历史账号可展示头像/昵称以快速切换。

### 3.3 添加好友并聊天

```text
搜索 DDID
→ 资料页
→ 发申请/直接私聊（依关系策略）
→ 对方在“新的朋友”收到
→ 同意
→ 双方关系实时更新
→ 自动存在 DIRECT 会话
→ 进入聊天
```

### 3.4 多设备

- 同一账号允许多个设备会话。
- 消息、已读、联系人关系、Sticker 库等应通过服务端同步。
- 用户可以查看并撤销设备。
- 密码重置/全部退出必须使旧会话失效。

---

# 4. 功能需求

## 4.1 Auth / Account

### FR-AUTH-001 邮箱注册

- 仅邮箱即可注册，不强制手机号。
- 邮箱验证码一次性、短 TTL、有尝试次数与发送限流。
- 注册事务必须原子创建用户、密码、隐私设置、设备和初始会话。

### FR-AUTH-002 登录

- 邮箱 + 密码。
- 失败统一错误并限流。
- 记录必要安全审计，日志不得记录明文密码或 Token。

### FR-AUTH-003 Token

- 短期 Access Token。
- 长期 Refresh Token。
- Refresh Token 只存哈希。
- Rotation + Family replay detection。
- Web 与 Native 会话边界可不同，但授权语义一致。

### FR-AUTH-004 找回密码

- 邮箱验证码重置。
- 重置后撤销旧会话/旧 Refresh family。

### FR-AUTH-005 历史登录与 Boot

- 本地保存非敏感历史账号卡片。
- Native secret 放安全存储。
- 自动 Refresh 成功前不闪登录页。

---

## 4.2 用户资料

### FR-USER-001 资料

至少包含：

- stable userId；
- DDID；
- 昵称；
- 个性签名；
- 头像；
- 邮箱（仅本人可见/管理）。

### FR-USER-002 唯一编辑入口

“我的 → 个人信息”作为昵称、DDID、邮箱、签名、头像的主要编辑入口。

设置页不得重复出现容易产生冲突的资料编辑表单。

### FR-USER-003 邮箱改绑

- 新邮箱必须验证码验证。
- 成功后同步当前 session / profile。

### FR-USER-004 头像

- 点击头像进入查看器。
- 修改头像支持自由 1:1 裁剪、拖动、缩放、旋转。
- 客户端可压缩普通手机大图，不要求用户手工缩图。
- 服务端仍必须限制最终载荷和像素，防内存 DoS。

### FR-USER-005 数据权利

未来支持：数据导出、注销、删除窗口和状态可见。

---

## 4.3 联系人和关系链

### FR-CONTACT-001 DDID 精确搜索

- 公开搜索主入口使用 DDID。
- 不开放无约束邮箱或全库模糊枚举。
- 需要限流。

### FR-CONTACT-002 好友申请

状态：

```text
PENDING → ACCEPTED | REJECTED | CANCELLED | EXPIRED
```

要求：

- 重复申请幂等/冲突可解释。
- 反向同时申请正确收敛。
- 被拉黑关系不能绕过。
- 同意后实时刷新“新的朋友”和联系人。
- 同意后聊天内出现系统提示：`我刚刚同意了你的好友请求`。

### FR-CONTACT-003 联系人

- 备注。
- 标签。
- 星标。
- 删除联系人。
- 删除联系人不删除历史聊天。

### FR-CONTACT-004 拉黑

- 阻止新的聊天写入和好友申请。
- 移除联系人关系。
- 取消相关 pending request。
- 公开 API 不应直接泄露“对方把你拉黑”的隐私事实。

### FR-CONTACT-005 资料页

资料页必须准确区分 SELF/NONE/PENDING/CONTACT/不可用。

网络错误、500、JSON 错误不得伪装成“用户不可用”。

---

## 4.4 会话

### FR-CONV-001 DIRECT

- 两个 user 的直接会话唯一且幂等。
- 会话生命周期与 contacts 解耦。

### FR-CONV-002 SELF

- 每个用户拥有可写的 Saved Messages SELF 会话。
- 可用于收藏、跨设备传文件、自发消息。

### FR-CONV-003 会话偏好

- 置顶。
- 免打扰。
- 归档。
- 本地隐藏/清空可见历史。

### FR-CONV-004 会话列表

展示：

- 头像/标题；
- 最后一条消息摘要；
- 时间；
- 未读角标；
- 置顶；
- 免打扰；
- 发送状态。

---

## 4.5 消息

### FR-CHAT-001 消息类型

```text
TEXT
IMAGE
GIF
STICKER
FILE
VOICE
VIDEO
SYSTEM
ENCRYPTED（未来 E2EE 协议载荷预留）
```

### FR-CHAT-002 发送可靠性

- 客户端生成稳定 `clientMessageId`。
- 服务端幂等。
- 会话 sequence 单调。
- Pending Queue 可恢复。
- WebSocket 仅承担低延迟提示，Cursor Sync 负责最终补账。

### FR-CHAT-003 已读

- 进入真实可见会话后才标为已读。
- 仅切换到联系人页等其它 UI 不能误判为已读。
- 未读会话支持“标为已读”。

### FR-CHAT-004 回复

- 保存稳定 reply target。
- 点击回复引用可加载较早分页并定位高亮原消息。

### FR-CHAT-005 编辑

- 当前产品支持自己发送的 TEXT 编辑。
- 服务端用 `expectedEditVersion` 防并发覆盖。
- 编辑后重建 Mention entity。

### FR-CHAT-006 撤回

- 自己消息默认不采用 2 分钟硬限制。
- 撤回通过服务端状态同步所有设备。

### FR-CHAT-007 仅本地删除

- 只对当前用户隐藏。
- Android/移动端危险操作为红色。

### FR-CHAT-008 转发

- 目标会话独立生成新消息。
- `forwardedFromMessageId` 只用于内部关联/产品能力，不泄露不必要隐私。

### FR-CHAT-009 收藏

- 支持传统收藏索引。
- 支持 Saved Messages SELF 自聊。

### FR-CHAT-010 消息置顶

- 会话成员内可查看置顶消息。
- 当前 DIRECT 基线允许置顶/取消置顶并同步。

### FR-CHAT-011 搜索

- 全局消息搜索。
- 会话内搜索。
- 搜索结果可定位原消息。
- 未来 E2EE 开启后，服务端搜索策略必须重新评估。

### FR-CHAT-012 `@username`

- 用户输入 `@handle`。
- 自动提示联系人/当前会话对方/公开匹配。
- 服务端重新扫描正文并生成 authoritative entity，不能相信客户端伪造 userId。
- entity 绑定 stable userId；用户以后改 DDID，旧 Mention 仍指向原用户。
- offset/length 统一按 UTF-16 code unit。
- `@all` 已在 P6 GROUP 实现，仅 OWNER/ADMIN 有权限生成群体 Mention；DIRECT 或普通成员输入时不获得群体权限。

---

## 4.6 输入区与键盘

- Windows：Enter 发送，Shift+Enter 换行。
- Android 外接键盘/scrcpy：Enter 应可发送。
- 点击空白处可合理收键盘。
- 发送后焦点不丢失。
- IME composing 阶段不能被 Mention 自动补全破坏。
- Emoji/Sticker 面板与系统键盘切换不能大幅跳帧。

---

## 4.7 媒体

### FR-MEDIA-001 上传协议

```text
reserve
→ client PUT private object
→ complete
→ business message references READY mediaId
```

### FR-MEDIA-002 授权

- Bucket 不公开。
- 下载前服务端按消息/Sticker 所有权授权。
- 下载 URL 短期有效。
- 过期 Grant 可刷新。

### FR-MEDIA-003 取消与重试

- Cancel 关闭真实上传 transport。
- 超时、408、429、5xx 可有限重试。
- 新 PUT retry 使用新 reservation，避免对象与 reservation 不一致。
- 4xx 合同错误不盲目重试。

### FR-MEDIA-004 缓存

- 已看过媒体优先本地缓存。
- 失败缓存不污染最终文件。
- Web 不做无限本地磁盘缓存。

### FR-MEDIA-005 图片/GIF

- 相册统一入口选择图片/GIF/视频。
- 图片支持查看和保存。
- GIF 可正常显示，不把所有列表项同时无限解码。

### FR-MEDIA-006 文件

- 文件发送、接收、保存。
- Windows 支持拖拽发送是目标能力。

### FR-MEDIA-007 视频

本地视频发送前：

```text
本地 probe
→ 宽高/时长
→ 提取 Poster
→ 主视频上传
→ Poster 上传
→ VIDEO message
```

禁止上传后再从远端完整下载回来只为生成 Poster。

### FR-MEDIA-008 视频播放

- 对方画面/媒体尽快开始播放。
- 首播可 streaming，后台持久化完整缓存。
- 二次打开优先本地文件。

---

## 4.8 语音条

### FR-VOICE-001 录制交互

- 点击语音按钮切换成“按住说话”。
- 长按录音。
- 松开发送。
- 滑向取消区后显示“松手取消”。
- 录制过程有明确动画/时长反馈。

### FR-VOICE-002 音频质量

- 使用移动端与桌面端可稳定解码的合理高质量编码。
- MIME/扩展名不能只相信历史消息字段，应能通过文件头识别常见格式。

### FR-VOICE-003 播放

- 点击播放/暂停。
- 离开消息焦点后状态可合理持久。
- Windows native 播放链不得因 MediaEngine 错误整体不可用。

---

## 4.9 Emoji / Sticker

### FR-STICKER-001 Emoji

- 常用 Emoji 面板。
- 选择后插入输入光标处。

### FR-STICKER-002 自定义 Sticker

- 支持 PNG/WebP/GIF/MP4/WebM；动图与短视频表情统一作为 Sticker 能力处理，而不是要求用户理解“GIF”和“视频表情”两套入口。
- 自定义 Sticker 源文件单项上限为 64 MiB；16 MiB 级 GIF/MP4 必须能正常加入个人库，不得因失败上传残留的 reservation 被误判为配额耗尽。
- GIF 保留动画；MP4/WebM 在聊天中默认静音、循环播放，离开可视区域后暂停以控制 CPU/GPU 与流量。
- 加入个人库、排序、删除。
- 已发送消息不能因从个人库删除而失效。

### FR-STICKER-003 Telegram Relay

- 接受 `t.me/addstickers/<setName>` 或可验证 deep link。
- 客户端解析后只提交 setName。
- 服务端使用 Bot Token 拉取并缓存到 DD 对象存储。
- 不把 Telegram 文件 URL 当长期产品资源。
- 不把 Bot Token 暴露客户端。
- 必须完整支持 Telegram 官方 Sticker 三类主格式：静态 WebP/PNG、动态 TGS（gzip Lottie）、视频 WebM；合法 TGS/WebM 不允许再被标记为“不支持”。
- TGS 在表情面板和聊天气泡中循环播放；WebM 复用静音循环视频 Sticker 链并在离开可视区域后暂停。
- 已由旧版本只导入静态子集的 Pack 必须自动失效旧缓存并在再次导入时补齐动态/视频项。

---

## 4.10 通知与声音

### FR-NOTIFY-001 前台

- App 前台且用户不在该会话：显示 DD 风格应用内顶部通知，包含发送者头像。
- 当前正在阅读该会话：不重复打扰。
- 免打扰会话不弹。

### FR-NOTIFY-002 后台

- Windows/Android 使用系统通知。
- Android 首次安装主动请求通知权限。
- Android 消息 Channel 应具备 Heads-up 所需优先级。
- Small icon 使用符合 Android monochrome 规范的 DD 图标。

### FR-NOTIFY-003 真正离线 Push

当前本地通知只在进程仍能收到实时事件时有效。P10 已进入实现阶段：`000022_push.up.sql` 已定义用户通知偏好、设备 Push endpoint 与 durable push job，但 Service/API/Worker/provider/client token 注册尚未形成闭环。

最终必须实现：

- Android FCM；
- 可选 UnifiedPush；
- iOS APNs；
- Web Push（如产品需要）；
- provider token 失效清理、退避重试、Job 去重；
- Push 只做提醒/唤醒，消息事实由 Sync 获取。

### FR-SOUND-001

DD 使用自有消息音/来电/回铃/接通/挂断声音，不复制微信/Telegram 音频。

---

## 4.11 一对一通话（IMPLEMENTED + AUTO-VERIFIED / HUMAN-PENDING）

### FR-CALL-001 状态机

至少覆盖：

```text
RINGING
ACCEPTED / ACTIVE
REJECTED
CANCELLED
ENDED
TIMEOUT
```

### FR-CALL-002 体验

- 来电、去电。
- 通话计时。
- 结束后约 1 秒自动退出。
- 聊天中写入语音/视频通话结果和时长。
- Android 通话强制竖屏产品布局，不因视频横向内容自动旋转整页。
- 视频通话以对方画面为主，己方画面小窗。
- 摄像头关闭有明确占位。

### FR-CALL-003 网络

- 外网 NAT/TURN 可用。
- 网络切换可恢复或明确失败。
- 不能只验证同局域网。

---

## 4.12 群聊（IMPLEMENTED + AUTO-VERIFIED / HUMAN-PENDING）

- 创建群。
- 邀请/审批。
- Owner/Admin/Member。
- 退出、踢人、转让、解散。
- 群公告。
- 群头像：Owner/Admin 可上传、替换或移除；仅修改头像时也必须作为合法的群资料 PATCH 处理。
- 群昵称。
- `@成员` / `@all`。
- 群消息可靠同步。
- 群权限服务端强制校验。

---

## 4.13 朋友圈（IMPLEMENTED + AUTO-VERIFIED / HUMAN-PENDING）

- 发布文字/图片/视频。
- Feed。
- 点赞/评论/回复。
- 别人对我的朋友圈点赞、评论，或回复我的朋友圈评论时，必须形成**服务端持久互动未读状态**，不能只依赖一次性 Push；“发现”主导航与“朋友圈”入口同时显示红色数字角标，`1..99` 显示真实数字，超过 99 显示 `99+`。
- 自己的朋友圈 Feed 顶部（封面下方）必须有“互动焦点”：有新互动时显示新互动数、最近互动头像与摘要；点开“互动消息”展示最近点赞/评论/回复的人、评论正文与时间。清掉未读角标后，最近互动历史仍应可回看，不能因为“已读”把是谁点赞/评论的信息一起丢掉。
- 进入自己的朋友圈 Feed 即视为查看现有互动并清除当时未读；清除状态需写回服务端，重启、换设备、漏掉 Realtime/Push 后仍能恢复正确数字。取消点赞、删除评论/动态以及 Block/可见性变化不能留下幽灵角标。
- 删除。
- 不看谁/不让谁看。
- 黑名单联动。
- 举报和后台处置。

---

## 4.14 二维码（SERVER-AUTO-VERIFIED / FLUTTER-AUTO-EVIDENCE / HUMAN-PENDING）

- 个人二维码与实例绑定 stable user payload。
- 扫码进入用户资料/添加好友主链。
- 相机识别与桌面手动 payload 兜底。
- 群邀请二维码：随机 nonce、过期、撤销、次数限制、Block/容量校验。
- PC/Web 扫码登录：随机 nonce、短 TTL、扫码设备绑定、手机二次确认、一次消费、目标设备信息展示、抗重放。
- 登录/群 invite 原始 secret 不直接作为数据库可检索明文事实，登录 nonce 当前只存 SHA-256。

当前服务端 PostgreSQL/HTTP/OpenAPI 已自动验证；Flutter 页面与入口代码存在，2026-08-12 全局 analyzer 与 Flutter 全量测试已恢复通过；仍需真实相机扫码、跨设备登录与异常路径真人验收后才能发布。

---

## 4.15 管理后台（PLANNED）

- 管理员认证 + 强制 MFA。
- RBAC。
- 用户状态管理。
- 举报处理。
- 审计日志。
- 注册策略。
- SMTP/S3/LiveKit 健康诊断。
- 容量与系统指标。
- 数据导出/注销状态。

当前 `admin/` 只有 React/Vite 工程壳与基础实例页，不能当作上述能力已完成。

---

## 4.16 E2EE（PLANNED）

- 不自研加密协议。
- 设备级身份密钥。
- 私聊 Double Ratchet 类成熟协议。
- 附件客户端加密。
- 多设备信封。
- 安全码/设备验证。
- E2EE 开启后重新设计搜索、举报、备份、通知预览边界。

未经互操作测试、安全向量与独立评审，UI 不得显示“端到端加密已保障”。

---

# 5. UI / UX 要求

## 5.0 全局控件视觉

DD 的绿色只承担品牌强调、主操作和选中态，不允许把“聚焦”处理成整圈高饱和绿色描边。

- 普通输入框采用中性灰底 + 轻量中性描边，圆角克制，不使用超大 pill 圆角。
- 多行输入框与评论/回复输入框沿用同一套中性输入 token；聚焦时只轻微加深灰色边界，不改变几何形状。
- 朋友圈发表正文属于内容编辑区，保持无框、无填充的编辑纸面感，不允许因全局主题继承出绿色胶囊边框。
- AlertDialog / 确认弹窗使用中性白/深灰表面、无绿色 Material seed tint，圆角保持克制；标题、正文、操作区层级清楚。
- 主按钮可以继续使用 DD 绿色，但按钮本身采用常规小圆角，不把所有操作按钮做成胶囊。
- 搜索框可保留搜索语义需要的更柔和圆角，但聚焦不得出现绿色描边。
- 浅色/深色主题必须共用相同的几何规则，只改变中性色阶与对比度。

## 5.1 移动端

主导航：

```text
DD（消息） / 联系人 / 发现 / 我的
```

Android Footer 当前采用全圆角悬浮 pill 风格，但应保持 DD 自有视觉，不做 Telegram 品牌复制。

### 联系人

默认进入联系人列表，不把“添加朋友”当默认内容。

### 资料

居中大头像 + 昵称 + DDID + 关系状态 + 操作入口。

### 聊天

- 输入框聚焦顺滑。
- 键盘升降不明显掉帧。
- 媒体懒加载。
- 长按菜单移动端使用整洁 Action Sheet。

## 5.2 Windows

默认设计验证尺寸：`881 × 657`。

要求：

- 自定义标题栏视觉稳定。
- 四边与四角可缩放。
- 100%/125%/150% DPI 正常。
- 标题栏拖动、双击最大化、最小化/最大化/关闭正常。
- 不出现灰块、色块覆盖、黑角、白边。
- 会话/联系人侧栏和聊天内容使用统一 token。
- Hover 不能引发卡死。

## 5.3 主题

- 跟随系统。
- 浅色。
- 深色。
- “我的/设置”存在可发现的外观入口。
- 即时生效并持久化。

---

# 6. 性能目标

首要用户感知目标：

- 文本输入不因网络操作阻塞主线程。
- 页面切换无整屏闪烁。
- 消息发送先有本地即时反馈。
- 媒体打开避免每次完整重新下载。
- 长列表按需构建。
- Sticker/GIF 大列表避免同时解码全部动画。
- Android 键盘和 Footer 动画在 60 Hz 设备上也应稳定。
- WebSocket 重连采用有限退避；Sync 负责补账。

具体压力门槛见 `06-测试验收与发布标准.md`。

---

# 7. 产品安全与隐私硬规则

- 不记录密码、验证码、Access Token、Refresh Token、Telegram Bot Token。
- 任何 IDOR 都由服务端授权阻止，不能信任客户端隐藏按钮。
- Block 关系不提供可枚举侧信道。
- 媒体 Bucket 不公开。
- Telegram Sticker Relay 不允许 arbitrary URL，防 SSRF。
- Mention userId 不信任客户端。
- 上传 MIME、大小、哈希与业务 purpose 需要服务端确认。
- Production secret 支持 `_FILE` 注入，不要求写进 `.env` 明文。

---

# 8. 发布成功标准

1. 核心 P0/P2/P3/P4/P5 真人主链通过。
2. Windows/Android/Web 关键流程不存在 P0/P1 阻断 Bug。
3. `go test ./...`、Flutter analyze/test、Admin build、OpenAPI contract 均有可重复通过的门禁。
4. 真机消息/媒体/通话弱网和恢复测试完成。
5. 生产 Docker Compose、备份恢复、升级回滚演练通过。
6. 安全边界完成专项测试。
7. 文档与代码同步。

在这些条件满足前，只能称 Alpha/Beta/RC，不能宣称 Stable 1.0。
