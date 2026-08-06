# 开发 Todolist

> 规则：按依赖顺序执行。每个任务完成时必须同时满足 Acceptance 与 Verify。任何任务如果预计改动超过 5 个主要文件，应继续拆分。

## P0：决策与技术验证

- [ ] **P0-001 确定正式项目名和品牌边界**
  - Acceptance：名称不含微信/WeChat 近似混淆表达；有原创 Logo 方向和免责声明。
  - Verify：完成商标初步检索；更新 README 和 ADR-006。

- [ ] **P0-002 确定开源许可证**
  - Acceptance：明确服务端、客户端、SDK、文档各自许可证。
  - Verify：生成 `LICENSE`；完成依赖许可证扫描，无已知冲突。

- [ ] **P0-003 决定 1.0 E2EE 范围**
  - Acceptance：明确私聊、群聊、附件、通话、朋友圈各自加密等级。
  - Verify：更新 PRD、ADR-004 和 Release Gate。

- [ ] **P0-004 决定默认注册策略**
  - Acceptance：公开、邀请、审批、关闭注册的默认值和切换规则明确。
  - Verify：更新 PRD 和配置规范。

- [ ] **P0-005 决定 iOS 推送方案**
  - Acceptance：明确官方中继、部署者自行凭据或自签客户端的路线。
  - Verify：写 ADR；列出隐私、成本、App Store 和运维影响。

- [ ] **P0-006 Flutter 多平台构建 PoC**
  - Progress：Windows Release、Web Release、Android Debug APK 已构建；iOS/macOS 仍需 macOS 构建机，Linux 仍需 Linux CI 或开发机。
  - Acceptance：同一最小应用能构建 Android、iOS、Web、Windows、macOS、Linux；无法在当前 CI 构建的平台有正式矩阵方案。
  - Verify：CI 构建日志和产物清单。

- [x] **P0-007 Flutter 与 Go REST/WSS PoC**
  - Result：正式 Flutter 调试 App 已接入 Go REST/WSS；真实握手、事件展示、Ping/Pong、服务重启断线检测和自动重连均通过。
  - Acceptance：客户端完成 REST 请求、WSS 连接、断线重连和事件展示。
  - Verify：自动化集成测试通过；详见 `docs/07-P0实时通信PoC.md`。

- [ ] **P0-008 LiveKit 一对一通话 PoC**
  - Acceptance：Flutter 至少 Android、Web、Windows 三端互通；验证摄像头、麦克风和网络切换。
  - Verify：跨公网测试记录；UDP 禁止时 TURN 回退测试。

- [ ] **P0-009 E2EE 候选库评估**
  - Acceptance：列出平台覆盖、维护状态、许可证、FFI 风险、测试向量和审计情况。
  - Verify：形成独立评估文档并给出 Go/No-Go 结论。

### Checkpoint P0

- [ ] 所有 ADR 状态从 Proposed 调整为 Accepted 或有明确替代方案。
- [ ] 没有未验证的关键技术阻断项。

## P1：仓库与工程基础

- [ ] **P1-001 创建 Monorepo 目录结构**
  - Acceptance：clients、server、packages、infra、scripts、docs、tasks 目录职责明确。
  - Verify：目录树与 `docs/02-技术架构与模块设计.md` 一致。

- [ ] **P1-002 初始化 Go Module**
  - Acceptance：包含 api、worker、migrate 三个入口和内部模块骨架。
  - Verify：`go test ./...`、`go vet ./...` 通过。

- [ ] **P1-003 初始化 Flutter App**
  - Acceptance：功能目录、设计系统、网络、本地存储和平台适配层存在。
  - Verify：`flutter analyze`、`flutter test` 通过。

- [ ] **P1-004 初始化 Admin Web**
  - Acceptance：React + TypeScript 工程包含路由、认证壳、API Client 和测试框架。
  - Verify：Lint、Typecheck、Test、Build 通过。

- [ ] **P1-005 建立 OpenAPI 合同**
  - Acceptance：实例发现、健康检查和示例 API 有完整 Schema 和统一错误。
  - Verify：OpenAPI lint 通过；生成客户端无差异。

- [ ] **P1-006 建立 WebSocket Event Schema**
  - Acceptance：HELLO、PING/PONG、EVENT_AVAILABLE 和错误帧版本化。
  - Verify：Go 与 Dart 的编码/解码契约测试通过。

- [ ] **P1-007 建立配置加载和校验**
  - Acceptance：支持环境变量/Secret 文件；危险默认值拒绝启动。
  - Verify：缺失 Secret、通配 CORS、弱 Secret 的负向测试通过。

- [ ] **P1-008 建立结构化日志与 requestId**
  - Acceptance：HTTP、WSS、Worker 日志均含服务名、版本、requestId 和错误码，不含敏感信息。
  - Verify：日志脱敏测试通过。

- [ ] **P1-009 建立健康检查**
  - Acceptance：live、ready、version 三类端点语义明确。
  - Verify：依赖断开时 readiness 失败，liveness 仍符合预期。

- [ ] **P1-010 建立本地 Docker Compose**
  - Acceptance：PostgreSQL、Redis、MinIO、Mailpit、LiveKit 可启动且有健康检查。
  - Verify：干净环境执行一次性命令后集成测试通过。

- [ ] **P1-011 建立数据库迁移框架**
  - Acceptance：迁移可排序、可检测状态、失败可停止启动。
  - Verify：空库迁移、重复迁移、失败迁移测试通过。

- [ ] **P1-012 建立 CI**
  - Acceptance：Go、Flutter、Admin、OpenAPI、Docker、Secret、依赖和许可证检查进入 CI。
  - Verify：故意引入格式错误和 Secret 时 CI 能阻断。

### Checkpoint P1

- [ ] CI 全绿。
- [ ] 示例 API 在 Flutter 和 Admin 中可调用。
- [ ] 本地依赖可重复启动和清理。

## P2：Auth、User、Device

- [ ] **P2-001 创建用户与认证数据表**
  - Acceptance：users、privacy、passwords、devices、refresh_tokens、email_codes 完整，唯一约束正确。
  - Verify：迁移测试和约束并发测试通过。

- [ ] **P2-002 实现邮箱归一化和 Handle 规则**
  - Acceptance：大小写、空白、Unicode 和保留词策略明确。
  - Verify：表驱动单元测试覆盖冲突和边界值。

- [ ] **P2-003 实现邮箱验证码发送**
  - Acceptance：验证码哈希存储、短时效、频率和尝试次数限制。
  - Verify：过期、重用、轰炸、SMTP 失败测试通过。

- [ ] **P2-004 实现注册事务**
  - Acceptance：验证码消费、用户、密码、首设备创建原子完成。
  - Verify：并发同邮箱/Handle 仅一个成功；失败无半成品数据。

- [ ] **P2-005 实现 Argon2id 密码服务**
  - Acceptance：参数可基准测试和升级；无明文日志。
  - Verify：正确/错误密码、参数重哈希测试通过。

- [ ] **P2-006 实现登录与统一错误**
  - Acceptance：不存在账号和密码错误对外响应一致；有限流和审计事件。
  - Verify：账号枚举测试和爆破限流测试通过。

- [ ] **P2-007 实现 Access/Refresh Token**
  - Acceptance：Access 短时效；Refresh 哈希存储、轮换、撤销和 Family 重放检测。
  - Verify：旧 Refresh 重放触发整族撤销测试通过。

- [ ] **P2-008 实现 Web Cookie 会话**
  - Acceptance：HttpOnly、Secure、SameSite 和 CSRF 策略正确。
  - Verify：浏览器集成测试检查 Cookie 属性和 CSRF。

- [ ] **P2-009 实现密码找回**
  - Acceptance：短期一次性凭据；成功后按策略撤销旧会话。
  - Verify：过期、重放、邮箱枚举测试通过。

- [ ] **P2-010 实现用户资料和隐私设置 API**
  - Acceptance：字段长度、头像归属和隐私默认值正确。
  - Verify：授权和输入验证测试通过。

- [ ] **P2-011 实现设备列表与远程退出**
  - Acceptance：用户能查看和撤销设备；不能撤销他人设备。
  - Verify：IDOR 测试和实时下线测试通过。

- [ ] **P2-012 Flutter 注册 UI**
  - Acceptance：邮箱、验证码、密码、Handle、昵称流程完整，错误可恢复。
  - Verify：Widget Test 与端到端注册测试通过。

- [ ] **P2-013 Flutter 登录和安全存储**
  - Acceptance：原生 Refresh Token 只进入系统安全存储；Web 使用 Cookie。
  - Verify：代码扫描和平台集成测试。

- [ ] **P2-014 Flutter 资料与设备管理 UI**
  - Acceptance：修改资料、查看设备、远程退出可用。
  - Verify：跨两台设备端到端测试。

- [ ] **P2-015 Admin 用户只读列表**
  - Acceptance：仅管理员访问，支持游标/分页和状态筛选，不显示密码/Token。
  - Verify：RBAC 和字段泄露测试。

### Checkpoint P2

- [ ] 新用户可完成注册、登录、资料修改和设备退出。
- [ ] Auth 安全测试全部通过。

## P3：好友与关系链

- [ ] **P3-001 创建好友相关数据表**
  - Acceptance：contact_requests、contacts、blocks、contact_tags 及唯一约束完成。
  - Verify：迁移和并发约束测试。

- [ ] **P3-002 实现 Handle 精确搜索**
  - Acceptance：遵守隐私、封禁和限流，不暴露邮箱。
  - Verify：枚举、大小写和未登录访问测试。

- [ ] **P3-003 实现好友申请状态机**
  - Acceptance：发送、接受、拒绝、撤销、过期状态明确。
  - Verify：重复提交和双方并发申请测试。

- [ ] **P3-004 实现接受好友事务**
  - Acceptance：双向 contacts 和私聊会话创建/复用原子完成。
  - Verify：故障注入无单边好友关系。

- [ ] **P3-005 实现备注、标签和星标**
  - Acceptance：仅 owner 可修改自己的联系人元数据。
  - Verify：授权测试。

- [ ] **P3-006 实现删除好友**
  - Acceptance：关系移除与历史消息保留语义符合 PRD。
  - Verify：重新添加和多设备同步测试。

- [ ] **P3-007 实现拉黑**
  - Acceptance：即时阻断好友申请、陌生消息、朋友圈和通话；旧会话读取策略明确。
  - Verify：跨模块权限集成测试。

- [ ] **P3-008 Flutter 联系人列表与搜索**
  - Acceptance：搜索、申请、备注、标签、删除、拉黑 UI 完整。
  - Verify：Widget 和 E2E 测试。

- [ ] **P3-009 Admin 风控配置基础**
  - Acceptance：可配置搜索和申请频率；修改有审计。
  - Verify：配置生效和审计测试。

### Checkpoint P3

- [ ] 两个用户可从搜索到建立好友关系。
- [ ] 拉黑权限联动全部通过。

## P4：会话、文字消息和同步

- [ ] **P4-001 创建会话和消息数据表**
  - Acceptance：conversations、members、messages、outbox、sync_events 索引和约束完成。
  - Verify：迁移、唯一性和查询计划测试。

- [ ] **P4-002 实现私聊会话幂等创建**
  - Acceptance：同一用户对只产生一个逻辑私聊。
  - Verify：100 个并发创建请求仅一个会话。

- [ ] **P4-003 实现会话成员授权服务**
  - Acceptance：读、写、管理动作统一授权，不由各 Handler 随意判断。
  - Verify：权限矩阵单元测试。

- [ ] **P4-004 实现消息发送事务**
  - Acceptance：分配 sequence、写消息、更新会话、写 Outbox 同一事务。
  - Verify：故障注入后无“已响应但没消息”或“有消息没事件”。

- [ ] **P4-005 实现消息幂等**
  - Acceptance：`senderDeviceId + clientMessageId` 唯一，重复请求返回原结果。
  - Verify：重复 100 次只一条记录。

- [ ] **P4-006 实现消息历史游标分页**
  - Acceptance：按 sequence 前后拉取，无页码漂移。
  - Verify：并发插入时分页无重复无漏项。

- [ ] **P4-007 实现已读序号与未读数**
  - Acceptance：每成员最后已读序号单调递增；不能倒退。
  - Verify：多设备并发已读测试。

- [ ] **P4-008 实现 Outbox Dispatcher**
  - Acceptance：至少一次投递、指数退避、幂等消费、失败可观测。
  - Verify：崩溃重启和重复消费测试。

- [ ] **P4-009 实现 WebSocket 鉴权与心跳**
  - Acceptance：Origin、Token、版本、帧大小、连接上限和心跳正确。
  - Verify：未认证、过期、超大帧和慢客户端测试。

- [ ] **P4-010 实现在线设备事件路由**
  - Acceptance：事件投递到用户全部有效设备；节点状态可重建。
  - Verify：Redis 重启后连接恢复测试。

- [ ] **P4-011 实现 Sync API**
  - Acceptance：用户按 cursor 获取增量事件；重复拉取幂等。
  - Verify：事件丢失、乱序、断线重连测试。

- [ ] **P4-012 Flutter 本地数据库模型**
  - Acceptance：会话、消息、联系人、游标和发送队列有迁移策略。
  - Verify：本地库升级测试。

- [ ] **P4-013 Flutter 同步引擎**
  - Acceptance：WSS 仅触发同步；断线后按 cursor 补齐；状态可恢复。
  - Verify：杀进程、断网、重启端到端测试。

- [ ] **P4-014 Flutter 离线发送队列**
  - Acceptance：本地乐观消息、重试、失败、取消和幂等映射正确。
  - Verify：飞行模式发送后恢复测试。

- [ ] **P4-015 Flutter 会话列表**
  - Acceptance：最后消息、未读、时间、置顶、免打扰和草稿正确。
  - Verify：多设备最终一致测试。

- [ ] **P4-016 Flutter 聊天页面**
  - Acceptance：文字发送、失败重试、回复、复制、撤回和历史加载可用。
  - Verify：Widget、Golden 和 E2E 测试。

- [ ] **P4-017 实现消息撤回事件**
  - Acceptance：撤回产生可同步系统事件；权限和时限可配置。
  - Verify：多设备、超时、他人消息撤回测试。

- [ ] **P4-018 消息可靠性压测**
  - Acceptance：200 在线连接、100 msg/s 基线下无重复和永久丢失。
  - Verify：提交压测脚本、硬件配置和报告。

### Checkpoint P4：MVP 核心门

- [ ] 断网、重连、服务重启后消息完整。
- [ ] 消息重复率为 0。
- [ ] 未通过本检查点前，不开始朋友圈等非核心功能。

## P5：媒体、文件、图片与语音条

- [ ] **P5-001 创建媒体表和对象命名规则**
  - Acceptance：随机 Key、归属、状态、哈希、派生文件和软删除完整。
  - Verify：迁移和对象 Key 不可猜测测试。

- [ ] **P5-002 实现上传申请与配额预占**
  - Acceptance：大小、类型、用户和实例配额校验；并发不超卖。
  - Verify：并发配额测试。

- [ ] **P5-003 实现预签名上传和完成确认**
  - Acceptance：短时效、限定对象和大小；未确认对象不可发消息。
  - Verify：跨用户、过期和篡改请求测试。

- [ ] **P5-004 实现图片处理 Worker**
  - Acceptance：缩略图、方向纠正、EXIF 清理、像素上限。
  - Verify：超大像素和畸形图片样本测试。

- [ ] **P5-005 实现文件扫描 Worker**
  - Acceptance：恶意或未知高风险文件进入隔离状态。
  - Verify：EICAR 和类型伪装测试。

- [ ] **P5-006 实现临时对象清理**
  - Acceptance：超时未确认对象、孤儿派生文件可安全清理。
  - Verify：清理任务幂等测试。

- [ ] **P5-007 实现受控下载**
  - Acceptance：下载前验证资源权限；签名 URL 短时有效。
  - Verify：IDOR 和 URL 转发测试。

- [ ] **P5-008 Flutter 图片消息**
  - Acceptance：选择、压缩、上传进度、预览、发送和失败恢复。
  - Verify：大图、断网和取消测试。

- [ ] **P5-009 Flutter 文件消息和桌面拖拽**
  - Acceptance：大小提示、进度、取消、重试和打开策略安全。
  - Verify：Windows/Web/Android 测试。

- [ ] **P5-010 Flutter 语音录制**
  - Acceptance：按住说话、上滑取消、最大时长、权限拒绝恢复。
  - Verify：Android/iOS/Windows 平台测试。

- [ ] **P5-011 Flutter 语音播放**
  - Acceptance：波形、进度、已听、倍速、听筒/扬声器策略。
  - Verify：多条连续播放和音频焦点测试。

### Checkpoint P5

- [ ] 图片、文件、语音在外网和多端可用。
- [ ] 对象存储无公开 Bucket 和越权下载。

## P6：群聊

- [ ] **P6-001 创建群与成员数据模型**
  - Acceptance：群、成员、角色、邀请、公告和审批模型完整。
  - Verify：迁移和角色约束测试。

- [ ] **P6-002 实现创建群事务**
  - Acceptance：群、会话、群主成员一次完成。
  - Verify：故障注入无孤儿群/会话。

- [ ] **P6-003 实现成员邀请和审批**
  - Acceptance：权限、人数上限、重复邀请和拉黑规则正确。
  - Verify：并发入群和上限测试。

- [ ] **P6-004 实现群角色和管理动作**
  - Acceptance：群主、管理员、成员权限矩阵固定。
  - Verify：越权测试。

- [ ] **P6-005 实现退出、踢出、解散和转让**
  - Acceptance：状态事件同步；权限即时失效。
  - Verify：多设备和并发操作测试。

- [ ] **P6-006 实现群公告和群资料**
  - Acceptance：修改权限、长度和审计正确。
  - Verify：授权测试。

- [ ] **P6-007 实现 @成员**
  - Acceptance：mention 使用用户 ID，不依赖昵称解析；通知可控。
  - Verify：昵称重复和已退群成员测试。

- [ ] **P6-008 Flutter 群创建与详情 UI**
  - Acceptance：成员选择、资料、公告、管理和退出流程完整。
  - Verify：E2E 测试。

- [ ] **P6-009 群消息与大群基线测试**
  - Acceptance：成员校验、扇出、未读序号无明显写放大。
  - Verify：目标群规模压测报告。

### Checkpoint P6

- [ ] 群权限、成员变化和消息同步全部通过。

## P7：一对一语音与视频通话

- [ ] **P7-001 定义呼叫状态机**
  - Acceptance：所有状态、事件、超时和非法转移有表格与测试。
  - Verify：状态机分支覆盖率 ≥ 90%。

- [ ] **P7-002 创建通话数据模型**
  - Acceptance：calls、participants、状态时间和结束原因完整。
  - Verify：迁移测试。

- [ ] **P7-003 实现创建呼叫和权限检查**
  - Acceptance：好友/会话/拉黑/忙线规则正确。
  - Verify：权限矩阵测试。

- [ ] **P7-004 实现 LiveKit Token 签发**
  - Acceptance：短时效、限定房间、身份和权限。
  - Verify：篡改房间和过期 Token 测试。

- [ ] **P7-005 实现多设备来电仲裁**
  - Acceptance：全部设备响铃；一个接听后其他设备停止；重复接听被拒。
  - Verify：三设备并发测试。

- [ ] **P7-006 Flutter 语音通话 UI**
  - Acceptance：呼叫、响铃、接听、拒绝、静音、扬声器和挂断。
  - Verify：Android/iOS/Web/Windows 测试矩阵。

- [ ] **P7-007 Flutter 视频通话 UI**
  - Acceptance：摄像头开关、前后切换、本地/远端画面、弱网提示。
  - Verify：目标平台测试。

- [ ] **P7-008 实现网络切换和重连策略**
  - Acceptance：Wi-Fi/蜂窝切换后可恢复或明确失败。
  - Verify：真实设备网络切换测试。

- [ ] **P7-009 完成 TURN/TLS 部署模板**
  - Acceptance：域名、证书、公网 IP、UDP/TCP 和中继端口完整。
  - Verify：外部网络连通检测脚本通过。

- [ ] **P7-010 音视频弱网与 NAT 测试**
  - Acceptance：不同运营商、UDP 禁止、丢包、抖动测试有结果和限制说明。
  - Verify：测试报告归档。

### Checkpoint P7

- [ ] 通话不只在开发者局域网可用。
- [ ] 不默认录音录像。

## P8：朋友圈

- [ ] **P8-001 创建朋友圈数据模型**
  - Acceptance：帖子、媒体、可见范围、点赞、评论和屏蔽关系完整。
  - Verify：迁移测试。

- [ ] **P8-002 实现发布和删除**
  - Acceptance：媒体归属、数量、类型、大小和可见范围校验。
  - Verify：非法媒体和越权删除测试。

- [ ] **P8-003 实现 Feed 查询**
  - Acceptance：服务端应用好友、拉黑、屏蔽和受众规则；游标分页。
  - Verify：权限组合测试和分页测试。

- [ ] **P8-004 实现点赞和评论**
  - Acceptance：仅可见用户能互动；重复点赞幂等。
  - Verify：越权和并发测试。

- [ ] **P8-005 实现不看谁/不让谁看**
  - Acceptance：设置即时作用于 Feed 和详情。
  - Verify：缓存失效测试。

- [ ] **P8-006 实现举报与后台处置**
  - Acceptance：举报可追踪、处置有审计、权限分离。
  - Verify：RBAC 测试。

- [ ] **P8-007 Flutter 发布朋友圈 UI**
  - Acceptance：文字、图片、短视频、可见范围和失败恢复。
  - Verify：E2E 测试。

- [ ] **P8-008 Flutter 时间线和详情 UI**
  - Acceptance：分页、点赞、评论、媒体预览和屏蔽操作完整。
  - Verify：Widget 和 E2E 测试。

### Checkpoint P8

- [ ] 所有朋友圈可见性组合通过服务端授权测试。

## P9：二维码和扫码登录

- [ ] **P9-001 定义版本化 QR Payload**
  - Acceptance：类型、版本、实例标识、短期 token 格式明确。
  - Verify：非法类型、超长内容和未知版本测试。

- [ ] **P9-002 实现个人二维码**
  - Acceptance：不包含邮箱和内部主键；可安全解析。
  - Verify：二维码内容审查和扫描测试。

- [ ] **P9-003 实现群邀请二维码**
  - Acceptance：有效期、次数、审批和撤销正确。
  - Verify：过期、次数耗尽和撤销测试。

- [ ] **P9-004 实现扫码登录状态机**
  - Acceptance：CREATED、SCANNED、CONFIRMED、CANCELLED、EXPIRED、CONSUMED 转移明确。
  - Verify：分支覆盖率 ≥ 90%。

- [ ] **P9-005 实现手机确认和风险信息**
  - Acceptance：展示请求设备、浏览器、时间和 IP 粗略信息。
  - Verify：请求信息绑定和篡改测试。

- [ ] **P9-006 实现一次性登录凭据交换**
  - Acceptance：二维码 token 不直接成为正式会话；消费一次即失效。
  - Verify：复制、重放和并发消费测试。

- [ ] **P9-007 Flutter 扫码和 Deep Link**
  - Acceptance：安全解析、用户确认、未知类型不执行动作。
  - Verify：各平台相机权限和恶意二维码测试。

- [ ] **P9-008 Web/PC 扫码登录 UI**
  - Acceptance：过期刷新、扫描状态、取消和登录完成可视化。
  - Verify：E2E 测试。

### Checkpoint P9

- [ ] 所有二维码均无敏感明文和重放风险。

## P10：通知与后台

- [ ] **P10-001 设计统一通知事件**
  - Acceptance：消息、好友、群、通话、朋友圈通知字段和隐私等级明确。
  - Verify：Schema 契约测试。

- [ ] **P10-002 实现 Push Worker**
  - Acceptance：异步、重试、退避、失效 token 清理，不阻塞消息事务。
  - Verify：供应商超时和重复投递测试。

- [ ] **P10-003 实现 Web 通知**
  - Acceptance：前台 WSS、后台浏览器通知、权限拒绝路径完整。
  - Verify：Chrome/Edge/Firefox/Safari 支持矩阵测试。

- [ ] **P10-004 实现 Android FCM**
  - Acceptance：token 注册、轮换、点击路由和隐私预览。
  - Verify：前台、后台、杀进程测试。

- [ ] **P10-005 评估并实现 UnifiedPush 适配器**
  - Acceptance：作为可选插件，不影响 FCM 和核心消息。
  - Verify：至少一个兼容分发器测试；不支持时文档说明。

- [ ] **P10-006 实现 iOS APNs 路线**
  - Acceptance：按 P0 决策完成凭据、推送和隐私模型。
  - Verify：TestFlight/真实设备后台测试。

- [ ] **P10-007 实现桌面系统通知**
  - Acceptance：Windows/macOS/Linux 点击通知进入正确会话。
  - Verify：目标平台测试。

- [ ] **P10-008 实现通知隐私设置**
  - Acceptance：关闭预览后所有平台均不显示正文。
  - Verify：自动化/人工矩阵测试。

### Checkpoint P10

- [ ] Push 丢失不会导致消息丢失。
- [ ] 通知不泄露用户关闭预览后的内容。

## P11：私聊端到端加密

- [ ] **P11-001 选定 E2EE 库和许可证**
  - Acceptance：平台、维护、安全审计和许可证通过评审。
  - Verify：ADR-004 更新为具体实现。

- [ ] **P11-002 实现设备身份密钥生成和安全存储**
  - Acceptance：私钥仅在客户端系统安全存储；服务端只保存公钥。
  - Verify：代码审查和设备提取测试。

- [ ] **P11-003 实现预密钥上传与补充**
  - Acceptance：签名预密钥、一次性预密钥数量和轮换策略正确。
  - Verify：耗尽、重复和签名错误测试。

- [ ] **P11-004 实现设备间会话建立**
  - Acceptance：离线接收者可建立初始会话；身份变化被检测。
  - Verify：官方测试向量。

- [ ] **P11-005 实现 Double Ratchet 消息加解密**
  - Acceptance：每条消息独立密钥，支持乱序和跳号限制。
  - Verify：官方测试向量和重放测试。

- [ ] **P11-006 实现多设备密文信封**
  - Acceptance：发送到接收者所有有效设备和发送者其他设备。
  - Verify：新增、撤销、离线设备测试。

- [ ] **P11-007 实现设备验证与安全码**
  - Acceptance：二维码/数字码验证，身份密钥变化有醒目提示。
  - Verify：中间人替换公钥模拟测试。

- [ ] **P11-008 实现附件客户端加密**
  - Acceptance：原图、缩略图、语音和文件上传前加密；密钥只在 E2EE 消息中。
  - Verify：服务端对象抽查无明文。

- [ ] **P11-009 实现本地搜索**
  - Acceptance：E2EE 消息不依赖服务端全文搜索。
  - Verify：离线搜索测试和索引清理测试。

- [ ] **P11-010 设计密钥备份/迁移**
  - Acceptance：明确不备份、密码加密备份或设备迁移方案及风险。
  - Verify：丢钥和恢复场景测试。

- [ ] **P11-011 跨平台互操作测试**
  - Acceptance：Android、iOS、Web、Windows、macOS、Linux 密文互通。
  - Verify：自动化矩阵结果。

- [ ] **P11-012 独立安全评审**
  - Acceptance：高危问题清零，中危有明确处置。
  - Verify：评审报告和修复回归测试。

### Checkpoint P11

- [ ] 未通过测试向量和安全评审前，产品不得显示“端到端加密已保障”。

## P12：管理后台、风控和数据权利

- [ ] **P12-001 实现管理员 RBAC**
  - Acceptance：超级管理员、用户管理员、内容管理员、审计员权限分离。
  - Verify：权限矩阵测试。

- [ ] **P12-002 强制管理员 MFA**
  - Acceptance：高权限账号无 MFA 不能进入管理后台。
  - Verify：登录 E2E 测试。

- [ ] **P12-003 实现用户封禁与解封**
  - Acceptance：会话撤销、实时连接断开、原因和期限可配置。
  - Verify：封禁即时生效测试。

- [ ] **P12-004 实现举报工单**
  - Acceptance：创建、分配、处置、备注、关闭和审计完整。
  - Verify：RBAC 和状态机测试。

- [ ] **P12-005 实现不可修改审计日志**
  - Acceptance：普通管理员不可编辑/删除；高风险操作全覆盖。
  - Verify：篡改测试和审计完整性抽查。

- [ ] **P12-006 实现注册和风控配置**
  - Acceptance：邀请、审批、关闭注册、限流和新号冷却可配置。
  - Verify：动态配置和审计测试。

- [ ] **P12-007 实现系统概览和容量指标**
  - Acceptance：用户、在线、消息、错误、队列、数据库、存储和通话指标可见。
  - Verify：指标与真实数据抽查一致。

- [ ] **P12-008 实现数据导出**
  - Acceptance：异步生成、加密下载、短时链接、审计和自动清理。
  - Verify：越权和大数据量测试。

- [ ] **P12-009 实现账号注销**
  - Acceptance：冷静期、撤销、会话终止、删除/匿名化和备份保留说明完整。
  - Verify：全流程和恢复边界测试。

### Checkpoint P12

- [ ] 管理员无法读取 E2EE 正文。
- [ ] 所有高风险操作均可审计。

## P13：部署、运维、升级与恢复

- [ ] **P13-001 编写生产 Dockerfile**
  - Acceptance：多阶段、非 root、只读优先、固定基础版本、Healthcheck。
  - Verify：镜像扫描和容器权限检查。

- [ ] **P13-002 编写生产 Docker Compose**
  - Acceptance：持久卷、网络、资源、日志、健康依赖和固定版本完整。
  - Verify：干净 Linux 主机启动测试。

- [ ] **P13-003 编写 `.env.example`**
  - Acceptance：所有配置有说明、安全默认值和必填标记，无真实 Secret。
  - Verify：配置 Schema 自动校验。

- [ ] **P13-004 编写安装脚本**
  - Acceptance：检查 OS、架构、Docker、磁盘、端口、域名并生成 Secret。
  - Verify：全新主机安装测试；重复执行不破坏数据。

- [ ] **P13-005 编写网络/TURN 检测脚本**
  - Acceptance：检测 HTTPS、WSS、UDP、TURN/TLS、公网 IP 和端口范围。
  - Verify：故意阻断端口时输出明确修复提示。

- [ ] **P13-006 编写健康检查脚本**
  - Acceptance：检查 API、数据库、Redis、对象存储、SMTP、LiveKit 和版本。
  - Verify：每个依赖故障均能准确定位。

- [ ] **P13-007 编写备份脚本**
  - Acceptance：数据库、对象、配置、版本、加密、哈希和保留策略完整。
  - Verify：备份产物校验。

- [ ] **P13-008 编写恢复脚本**
  - Acceptance：版本检查、停止写入、恢复、迁移和验证完整。
  - Verify：恢复到另一台干净主机。

- [ ] **P13-009 编写更新脚本**
  - Acceptance：固定版本、预检查、备份、迁移、健康检查和失败处置。
  - Verify：上一稳定版升级到当前版。

- [ ] **P13-010 定义数据库回滚策略**
  - Acceptance：每个迁移标注可逆/不可逆；不可逆有恢复备份路径。
  - Verify：发布流程自动检查迁移元数据。

- [ ] **P13-011 构建 amd64/arm64 镜像**
  - Acceptance：所有服务双架构镜像可启动。
  - Verify：两种架构 CI/真实机验证。

- [ ] **P13-012 建立监控与告警模板**
  - Acceptance：Prometheus/Grafana/Loki 可选安装；关键告警有默认阈值。
  - Verify：故障注入触发告警。

- [ ] **P13-013 编写运维文档**
  - Acceptance：安装、配置、端口、邮件、存储、推送、备份、恢复、升级、排错完整。
  - Verify：由未参与开发的人按文档完成部署。

### Checkpoint P13

- [ ] 不依赖作者私有服务完成安装。
- [ ] 备份恢复和升级实测通过。

## P14：安全、稳定、发布

- [ ] **P14-001 完成全量授权审计**
  - Acceptance：用户、会话、消息、媒体、群、朋友圈、QR、管理 API 全覆盖。
  - Verify：IDOR/BOLA 自动化测试无高危。

- [ ] **P14-002 完成 Web 安全测试**
  - Acceptance：XSS、CSRF、CORS、CSP、SSRF、上传和 WebSocket 安全通过。
  - Verify：ZAP/自定义报告。

- [ ] **P14-003 完成依赖、镜像、Secret 和许可证扫描**
  - Acceptance：无未接受高危漏洞和许可证阻断。
  - Verify：CI Release Gate。

- [ ] **P14-004 完成消息与同步压力测试**
  - Acceptance：达到 PRD 基线，无永久丢失和重复。
  - Verify：报告包含硬件、数据、配置、P50/P95/P99。

- [ ] **P14-005 完成音视频容量与弱网测试**
  - Acceptance：给出真实容量区间和限制，不做空泛承诺。
  - Verify：跨网络测试报告。

- [ ] **P14-006 完成故障注入**
  - Acceptance：数据库、Redis、MinIO、SMTP、Push、LiveKit、磁盘故障行为符合设计。
  - Verify：演练记录和回归测试。

- [ ] **P14-007 完成多端兼容与无障碍测试**
  - Acceptance：目标平台核心流程、键盘、屏幕阅读器、200% 文本缩放通过。
  - Verify：测试矩阵。

- [ ] **P14-008 完成第三方安全审计/渗透测试**
  - Acceptance：高危清零，中危有明确接受或修复。
  - Verify：报告和修复记录。

- [ ] **P14-009 完成开源治理文件**
  - Acceptance：README、LICENSE、CONTRIBUTING、CODE_OF_CONDUCT、SECURITY、CHANGELOG 完整。
  - Verify：链接和流程实测。

- [ ] **P14-010 生成 SBOM 和签名产物**
  - Acceptance：镜像、安装包、校验和和 Commit 可追溯。
  - Verify：签名验证命令通过。

- [ ] **P14-011 完成 RC 自建测试**
  - Acceptance：至少一名未参与开发者在干净公网服务器独立安装并使用核心功能。
  - Verify：问题清单全部关闭或列入已知限制。

- [ ] **P14-012 发布 1.0**
  - Acceptance：`docs/06-测试验收与发布标准.md` 无阻断项。
  - Verify：Tag、镜像、安装包、Changelog、迁移和文档一致。

## P15：1.0 后候选

- [ ] 群聊端到端加密。
- [ ] 群语音和群视频。
- [ ] 机器人与 Webhook API。
- [ ] 插件沙箱和权限模型。
- [ ] 跨实例联邦协议与威胁模型。
- [ ] 多地域部署。
- [ ] 消息保留和合规策略插件。
- [ ] 可选语音转文字。
- [ ] F-Droid 和更多应用商店发布。

## 全局 Definition of Done

每个任务合并前：

- [ ] 需求/ADR/API 合同已更新。
- [ ] 输入验证和授权完成。
- [ ] 单元、集成或 E2E 测试覆盖对应风险。
- [ ] 日志不含敏感数据。
- [ ] 不引入未经审查的依赖和许可证冲突。
- [ ] 构建、Lint、测试、扫描全绿。
- [ ] 用户可见行为和运维变化有文档。
- [ ] 没有遗留后台测试服务或端口占用。
