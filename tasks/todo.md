# 开发 Todolist

> 状态同步：2026-08-08 12:14（UTC+8）。当前 P4 修复批次代码与三端构建已收口，先做真人复测，不因“自动测试通过”提前勾掉仍要求真实设备/跨端 Verify 的任务。
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
  - Progress：Windows Release、Web Release、Android Debug APK 均已通过；Windows 中文路径使用临时 `subst` 英文盘符构建。iOS/macOS 仍需 macOS 构建机，Linux 仍需 Linux CI 或开发机。
  - Acceptance：同一最小应用能构建 Android、iOS、Web、Windows、macOS、Linux；无法在当前 CI 构建的平台有正式矩阵方案。
  - Verify：CI 构建日志和产物清单。

- [x] **P0-007 Flutter 与 Go REST/WSS PoC**
  - Result：正式 Flutter 调试 App 已接入 Go REST/WSS；真实握手、事件展示、Ping/Pong、服务重启断线检测和自动重连均通过。
  - Acceptance：客户端完成 REST 请求、WSS 连接、断线重连和事件展示。
  - Verify：自动化集成测试通过；详见 `docs/07-P0实时通信PoC.md`。

- [ ] **P0-008 LiveKit 一对一通话 PoC**
  - Progress：Windows / Web / Android 三端本轮人工清单于 2026-08-08 全部通过，包括 Web ↔ Android、三端 relay-only TURN、通话状态同步、Android 后台/锁屏/短时断网恢复、媒体控制和窄屏适配。TURN/UDP 已固定 `3478 + 30000-30019/udp`，并处理 LiveKit 1.12+ 私网 peer 限制。当前仅因 Verify 仍要求“跨公网测试记录 + 公网/NAT TURN/TLS 回退”而保持未完成；详见 `docs/08-P0音视频通话PoC.md`。
  - Acceptance：Flutter 至少 Android、Web、Windows 三端互通；验证摄像头、麦克风和网络切换。
  - Verify：跨公网测试记录；UDP 禁止时 TURN 回退测试；详见 `docs/08-P0音视频通话PoC.md`。

- [x] **P0-009 E2EE 候选库评估**
  - Acceptance：列出平台覆盖、维护状态、许可证、FFI 风险、测试向量和审计情况。
  - Verify：形成独立评估文档并给出 Go/No-Go 结论。

### Checkpoint P0

- [ ] 所有 ADR 状态从 Proposed 调整为 Accepted 或有明确替代方案。
- [ ] 没有未验证的关键技术阻断项。

## P1：仓库与工程基础

- [x] **P1-001 创建 Monorepo 目录结构**
  - Acceptance：clients、server、packages、infra、scripts、docs、tasks 目录职责明确。
  - Verify：目录树与 `docs/02-技术架构与模块设计.md` 一致。

- [x] **P1-002 初始化 Go Module**
  - Acceptance：包含 api、worker、migrate 三个入口和内部模块骨架。
  - Verify：`go test ./...`、`go vet ./...` 通过。

- [ ] **P1-003 初始化 Flutter App**
  - Acceptance：功能目录、设计系统、网络、本地存储和平台适配层存在。
  - Verify：`flutter analyze`、`flutter test` 通过。

- [ ] **P1-004 初始化 Admin Web**
  - Progress：React + TypeScript、API Client、Foundation 页面、Typecheck 和 Production Build 已通过；测试框架/Lint 质量门仍需补齐。
  - Acceptance：React + TypeScript 工程包含路由、认证壳、API Client 和测试框架。
  - Verify：Lint、Typecheck、Test、Build 通过。

- [ ] **P1-005 建立 OpenAPI 合同**
  - Progress：实例发现、System、P2 Auth 已纳入正式 `/api/v1` 并通过 Redocly recommended-strict；生成客户端无差异尚未建立。
  - Acceptance：实例发现、健康检查和示例 API 有完整 Schema 和统一错误。
  - Verify：OpenAPI lint 通过；生成客户端无差异。

- [x] **P1-006 建立 WebSocket Event Schema**
  - Acceptance：HELLO、PING/PONG、EVENT_AVAILABLE 和错误帧版本化。
  - Verify：Go 与 Dart 的编码/解码契约测试通过。

- [x] **P1-007 建立配置加载和校验**
  - Acceptance：支持环境变量/Secret 文件；危险默认值拒绝启动。
  - Verify：缺失 Secret、通配 CORS、弱 Secret 的负向测试通过。

- [ ] **P1-008 建立结构化日志与 requestId**
  - Acceptance：HTTP、WSS、Worker 日志均含服务名、版本、requestId 和错误码，不含敏感信息。
  - Verify：日志脱敏测试通过。

- [x] **P1-009 建立健康检查**
  - Acceptance：live、ready、version 三类端点语义明确。
  - Verify：依赖断开时 readiness 失败，liveness 仍符合预期。

- [x] **P1-010 建立本地 Docker Compose**
  - Acceptance：PostgreSQL、Redis、MinIO、Mailpit、LiveKit 可启动且有健康检查。
  - Verify：干净环境执行一次性命令后集成测试通过。

- [x] **P1-011 建立数据库迁移框架**
  - Acceptance：迁移可排序、可检测状态、失败可停止启动。
  - Verify：空库迁移、重复迁移、失败迁移测试通过。

- [ ] **P1-012 建立 CI**
  - Progress：Go、Flutter、Admin、OpenAPI、Compose、E2EE PoC、PostgreSQL + Mailpit Auth 真实集成已经进入 CI；Secret、依赖和许可证检查仍需补齐。
  - Acceptance：Go、Flutter、Admin、OpenAPI、Docker、Secret、依赖和许可证检查进入 CI。
  - Verify：故意引入格式错误和 Secret 时 CI 能阻断。

### Checkpoint P1

- [ ] CI 全绿。
- [ ] 示例 API 在 Flutter 和 Admin 中可调用。
- [ ] 本地依赖可重复启动和清理。

## P2：Auth、User、Device

- [x] **P2-001 创建用户与认证数据表**
  - Progress：`000002_auth_user_device` + `000003_auth_security_profile` 已覆盖 users、privacy、passwords、devices、refresh_tokens、email_codes、密码重置和 Auth 审计相关表。
  - Acceptance：users、privacy、passwords、devices、refresh_tokens、email_codes 完整，唯一约束正确。
  - Verify：Migration 与真实 PostgreSQL Auth 生命周期已通过。

- [x] **P2-002 实现邮箱归一化和 Handle 规则**
  - Acceptance：大小写、空白、Unicode 和保留词策略明确。
  - Verify：表驱动单元测试覆盖冲突和边界值。

- [ ] **P2-003 实现邮箱验证码发送**
  - Progress：HMAC 哈希、10 分钟有效期、60 秒冷却、15 分钟 5 次频率、尝试次数、枚举保护和 Mailpit 真 SMTP 已实现；完整轰炸/SMTP 失败负向矩阵仍需补齐后再勾完成。
  - Acceptance：验证码哈希存储、短时效、频率和尝试次数限制。
  - Verify：过期、重用、轰炸、SMTP 失败测试通过。

- [ ] **P2-004 实现注册事务**
  - Progress：验证码、用户、隐私、Argon2id 密码、首设备、Refresh Family 已在 Serializable 事务内完成并通过真实 PostgreSQL 集成；并发同邮箱/Handle 专项仍需补齐。
  - Acceptance：验证码消费、用户、密码、首设备创建原子完成。
  - Verify：并发同邮箱/Handle 仅一个成功；失败无半成品数据。

- [x] **P2-005 实现 Argon2id 密码服务**
  - Acceptance：参数可基准测试和升级；无明文日志。
  - Verify：正确/错误密码、参数重哈希测试通过。

- [x] **P2-006 实现登录与统一错误**
  - Progress：未知账号/错误密码统一 `INVALID_CREDENTIALS`，dummy Argon2 时序缓解、15 分钟累计 10 次失败限流和 Auth 安全审计事件均已实现。
  - Acceptance：不存在账号和密码错误对外响应一致；有限流和审计事件。
  - Verify：真实 Auth 集成已覆盖爆破限流，HTTP 测试覆盖统一错误。

- [x] **P2-007 实现 Access/Refresh Token**
  - Acceptance：Access 短时效；Refresh 哈希存储、轮换、撤销和 Family 重放检测。
  - Verify：旧 Refresh 重放触发整族撤销测试通过。

- [ ] **P2-008 实现 Web Cookie 会话**
  - Progress：Web Refresh Token 已从 JSON 移除，使用 `HttpOnly + SameSite=Lax + /api/v1/auth` Cookie；HTTPS 启用 Secure，Flutter Web 使用 credentials，CORS 白名单支持凭据。真实浏览器 Cookie/CSRF 人工验收待 `人工测试.md`。
  - Acceptance：HttpOnly、Secure、SameSite 和 CSRF 策略正确。
  - Verify：浏览器集成测试检查 Cookie 属性和 CSRF。

- [x] **P2-009 实现密码找回**
  - Progress：密码找回验证码、重置、成功后撤销全部旧设备/Refresh Token 已实现。
  - Acceptance：短期一次性凭据；成功后按策略撤销旧会话。
  - Verify：真实 PostgreSQL + Mailpit 集成覆盖重置后旧密码/旧会话失效和新密码成功。

- [x] **P2-010 实现用户资料和隐私设置 API**
  - Progress：`GET/PATCH /api/v1/me`、资料字段和隐私设置已实现；2026-08-08 新增头像可用链：`PUT/DELETE /api/v1/me/avatar`、`GET /api/v1/avatars/{userId}` 和 `000006_profile_avatars`。服务端最终载荷仍限制 2 MiB、JPEG/PNG/WebP、最大 2048×2048 / 约 4MP；客户端现允许选择更大的手机原图，原生端通过 `compute` 后台处理 EXIF 方向、最长边缩至 1536 并压缩为 JPEG 后再上传，避免大图压缩阻塞 UI；为防客户端内存 DoS，源文件保留 64 MiB、解码画布约 70MP 的宽松安全上限。聊天中点击对方头像可进入资料页读取昵称、Handle、简介和关系。这是 P5 对象存储媒体管线前的可用过渡，不冒充最终媒体架构。
  - Acceptance：资料字段长度和隐私默认值正确；头像具备授权、类型/大小限制和稳定读取；P5 接入对象存储时迁移头像资源但保持 API 兼容。
  - Verify：头像魔数单测、Auth API Client 二进制上传测试、CORS PUT 门禁和 OpenAPI strict 已覆盖；真实多端头像刷新留 `人工测试.md`。

- [x] **P2-011 实现设备列表与远程退出**
  - Progress：设备列表、指定设备撤销、全部退出已实现；Access Token 每次同时检查用户/设备是否仍有效。
  - Acceptance：用户能查看和撤销设备；不能撤销他人设备。
  - Verify：IDOR 自动测试和“被撤销设备下一次请求立即失效”真实集成通过；真人多端 UI 留 `人工测试.md`。

- [ ] **P2-012 Flutter 注册 UI**
  - Progress：Windows/Web/Android 共用注册表单、验证码、错误恢复和 360×640 防 overflow Widget Test 已实现；真实 UI 注册端到端待 `人工测试.md`。
  - Acceptance：邮箱、验证码、密码、Handle、昵称流程完整，错误可恢复。
  - Verify：Widget Test 与端到端注册测试通过。

- [x] **P2-013 Flutter 登录和安全存储**
  - Progress：Native 已接 `flutter_secure_storage`，启动自动 Refresh 恢复；Web 继续只用 HttpOnly Cookie，Refresh Token 不进入 JS 存储。
  - Acceptance：原生 Refresh Token 只进入系统安全存储；Web 使用 Cookie。
  - Verify：Auth 自动测试通过；Windows 当前机器 clean Release 仍受 Visual Studio ATL 环境依赖阻塞，真实安全存储恢复留人工跨端批次。

- [ ] **P2-014 Flutter 资料与设备管理 UI**
  - Progress：资料、隐私、头像更换/移除、设备列表、远程退出、全部退出 UI 已实现；Windows/Web 设置页改为微信式“左侧分类 + 右侧内容”，含账号与存储/通用/快捷键/通知/插件/关于 DD；移动端继续保持单栏。头像在主导航、会话、聊天、联系人和“我的”中统一显示。自动测试通过，跨 Windows/Android/Web 真人 E2E 尚未执行。
  - Acceptance：修改资料/头像、查看设备、远程退出可用；桌面设置页不再是 Material Card 堆叠。
  - Verify：跨两台设备端到端测试留 `人工测试.md`。

- [ ] **P2-015 Admin 用户只读列表**
  - Acceptance：仅管理员访问，支持游标/分页和状态筛选，不显示密码/Token。
  - Verify：RBAC 和字段泄露测试。

### Checkpoint P2

- [ ] 新用户可完成注册、登录、资料修改和设备退出。（代码与自动化已具备，等待本轮真人三端验收）
- [ ] Auth 安全测试全部通过。（核心自动化已通过；完整 SMTP 故障/注册并发强化矩阵仍保留）

## P3：好友与关系链

- [x] **P3-001 创建好友相关数据表**
  - Progress：`000004_contacts` 已新增 contact_requests、contacts、contact_tags、blocks、relationship_rate_events，并为接受好友事务提前建立 conversations / conversation_members。
  - Acceptance：contact_requests、contacts、blocks、contact_tags 及唯一约束完成。
  - Verify：PostgreSQL 18.4 真库 Migration + 并发关系链测试通过。

- [x] **P3-002 实现 Handle 精确搜索**
  - Progress：`GET /api/v1/users/by-handle/{handle}` 已实现；只返回公开资料，不返回邮箱；任一方向 block 时统一 404；10 分钟 60 次持久化限流。
  - Acceptance：遵守隐私、封禁和限流，不暴露邮箱。
  - Verify：未登录 401、被拉黑 404、无 email、限流第 61 次阻断均已有自动测试。

- [x] **P3-003 实现好友申请状态机**
  - Progress：PENDING/ACCEPTED/REJECTED/CANCELLED/EXPIRED 已实现；同向重复幂等，反向申请自动接受，默认 30 天过期，每用户每天 30 次新申请。
  - Acceptance：发送、接受、拒绝、撤销、过期状态明确。
  - Verify：真实 PostgreSQL 覆盖重复提交、双方并发申请，并修复 `SERIALIZABLE` 40001 自动重试。

- [x] **P3-004 实现接受好友事务**
  - Progress：双向 contacts、DIRECT conversation、conversation_members、申请 ACCEPTED 在同一 Serializable 事务完成；同一用户对复用唯一私聊。
  - Acceptance：双向 contacts 和私聊会话创建/复用原子完成。
  - Verify：真库集成和并发互相申请测试未出现单边好友或重复逻辑会话。

- [x] **P3-005 实现备注、标签和星标**
  - Progress：备注、星标、最多 20 标签已实现；标签 NFKC + 大小写归一化去重，数据按 owner 隔离。
  - Acceptance：仅 owner 可修改自己的联系人元数据。
  - Verify：真库集成验证 Alice 的联系人元数据不会泄漏到 Bob 视角。

- [x] **P3-006 实现删除好友**
  - Progress：删除好友会删除双方 contacts，但保留 DIRECT conversation，重新建立好友时可复用逻辑会话。
  - Acceptance：关系移除与历史消息保留语义符合 PRD。
  - Verify：服务层语义和会话唯一键已有自动覆盖；正式历史消息/多设备同步随 P4 继续验证。

- [ ] **P3-007 实现拉黑**
  - Progress：block、解除 block、拉黑时删除双方好友、取消 PENDING、搜索隐藏、好友申请阻断已实现；**P4 正式消息已完成拉黑联动：拉黑后禁止新消息但保留旧历史读取**。P7 正式通话 / P8 朋友圈尚未全部接入，因此跨模块总验收保持未完成。
  - Acceptance：即时阻断好友申请、陌生消息、朋友圈和通话；旧会话读取策略明确。
  - Verify：P3 范围真库测试已通过；P4/P7/P8 各自接入后再完成跨模块权限集成。

- [ ] **P3-008 Flutter 联系人列表与搜索**
  - Progress：移动端四 Tab 继续覆盖搜索、申请、接受/拒绝/撤销、备注/标签/星标、删除、拉黑、黑名单解除；Windows/Web 已重构为约 248px 左侧通讯录目录 + 右侧详情/申请/黑名单处理区，加入通讯录搜索、添加朋友菜单、星标分组和真实头像，交互结构对齐微信桌面通讯录。360×640 原回归继续 PASS。
  - Acceptance：搜索、申请、备注、标签、删除、拉黑 UI 完整；桌面端使用通讯录信息架构而不是移动 Tab 横向放大。
  - Verify：Widget 已通过；Windows/Web/Android 双账号 E2E 留 `人工测试.md`。

- [ ] **P3-009 Admin 风控配置基础**
  - Acceptance：可配置搜索和申请频率；修改有审计。
  - Verify：配置生效和审计测试。

### Checkpoint P3

- [x] 两个用户可从搜索到建立好友关系。（真实 PostgreSQL 自动集成已覆盖）
- [ ] 拉黑权限联动全部通过。（P3 + P4 正式消息已通过，等待 P7 正式通话 / P8 朋友圈接入）

## P4：会话、文字消息和同步

### 当前执行优先级（2026-08-08 冻结）

```text
1. Web 置顶 / 免打扰根因已修，当前进入跨端真人回归
2. 微信式 UI 主体第一轮已落地，继续做细节收口和截图验收
3. 紧接着做 Telegram 级丝滑度和响应性能专项
4. 已读 UI、Enter 发送、不限时撤回已落代码，补跨端真人验收与“已送达”状态
5. Unicode Emoji 已有基础选择器，继续补最近使用 / Sticker / GIF
6. 再进入图片消息、语音条等 P5 媒体能力
7. 最后继续群聊、朋友圈等外围大功能
```

> UI 阶段优先级高于继续堆新功能。目标不是“做得像一个 Flutter Demo”，而是先形成稳定、微信式、低干扰的完整客户端骨架，并把滚动、点击、输入、页面切换做到接近 Telegram 的即时响应感。

- [x] **P4-001 创建会话和消息数据表**
  - Progress：`000005_messaging` 已落地 messages、outbox_events、sync_events、message_local_deletions，并补齐 sequence / 幂等 / 查询索引和 last_message 外键；真实 PostgreSQL Migration 已执行通过。
  - Acceptance：conversations、members、messages、outbox、sync_events 索引和约束完成。
  - Verify：真实 Migration + 消息生命周期集成测试 PASS；大数据量 EXPLAIN 仍归 P4-018 压测收口。

- [x] **P4-002 实现私聊会话幂等创建**
  - Progress：同一无序用户对使用数据库 advisory transaction lock + `direct_pair_key` 唯一键双保险，不依赖脆弱的有限次数 Serializable 重试。
  - Acceptance：同一用户对只产生一个逻辑私聊。
  - Verify：真实 PostgreSQL 100 个并发创建请求仅一个会话，PASS。

- [x] **P4-003 实现会话成员授权服务**
  - Progress：消息读写授权集中在 messaging service；私聊新消息统一检查 active membership、好友/陌生消息策略和双方拉黑关系，Handler 不信任客户端 sender 身份。
  - Acceptance：读、写、管理动作统一授权，不由各 Handler 随意判断。
  - Verify：HTTP forged sender、block 后禁止新写但保留历史等自动测试 PASS。

- [x] **P4-004 实现消息发送事务**
  - Progress：sequence 分配、messages 插入、conversation last_message/updated_at、Durable Outbox 写入同一 PostgreSQL 事务。
  - Acceptance：分配 sequence、写消息、更新会话、写 Outbox 同一事务。
  - Verify：真实 PostgreSQL 生命周期测试 PASS；事务中任一步错误会整体回滚。

- [x] **P4-005 实现消息幂等**
  - Progress：`sender_device_id + client_message_id` 唯一索引，并对同一幂等键使用 advisory transaction lock；重复请求返回原逻辑消息。
  - Acceptance：`senderDeviceId + clientMessageId` 唯一，重复请求返回原结果。
  - Verify：真实 PostgreSQL 100 个并发相同 clientMessageId 只一条记录且返回同一 messageId，PASS。

- [x] **P4-006 实现消息历史游标分页**
  - Progress：历史按 conversation sequence 游标向前翻页，使用 `beforeSequence` / `nextBeforeSequence`，本地删除不会污染对方历史。
  - Acceptance：按 sequence 前后拉取，无页码漂移。
  - Verify：多页顺序、无重复基础集成 PASS；大规模并发插入压测留 P4-018。

- [x] **P4-007 实现已读序号与未读数**
  - Progress：`last_read_sequence=GREATEST(...)` 单调推进，禁止读到 conversation last_sequence 之后，会话列表按 sequence 计算未读。
  - Acceptance：每成员最后已读序号单调递增；不能倒退。
  - Verify：2 -> 1 不倒退、越界 3 拒绝等真库测试 PASS；真实多端最终一致留本轮人工验收。

- [x] **P4-008 实现 Outbox Dispatcher**
  - Progress：Worker 500ms 批处理 `FOR UPDATE SKIP LOCKED`，sync_events 以 `(source_outbox_id,user_id)` 幂等，失败指数退避；写消费失败时用 SAVEPOINT 回滚失败语句后再记录重试状态。
  - Acceptance：至少一次投递、指数退避、幂等消费、失败可观测。
  - Verify：真实 Outbox -> Sync 集成 PASS；`run-auth-dev.ps1` 现在会同时启动 API + Worker。

- [x] **P4-009 实现 WebSocket 鉴权与心跳**
  - Progress：正式 `/api/v1/realtime` 要求 hello Access Token + protocolVersion，继承 Origin 白名单、16KB 帧限制、心跳，并限制每账号 16 条本机连接；旧 `/ws` 继续留给 P0 PoC，不破坏旧通话测试。
  - Acceptance：Origin、Token、版本、帧大小、连接上限和心跳正确。
  - Verify：无 Token、错误协议版本、正式 Dart hello token/version、半开连接重连、Live Smoke PASS；16 连接上限压力仍可在 P4-018 加测。

- [x] **P4-010 实现在线设备事件路由**
  - Progress：已实现 Redis Pub/Sub 跨 API 节点 `event_available` fan-out；每个节点只把提示投递给本机该 userId 的全部 WebSocket。设计不依赖 Redis Presence 持久状态，Redis 只负责“唤醒 Sync”，消息事实仍由 PostgreSQL + `/sync` 保证。
  - Acceptance：事件投递到用户全部有效设备；节点状态可重建。
  - Verify：双 RedisBus 节点真集成 PASS；自动 `CLIENT KILL TYPE pubsub` 强杀订阅连接后后续事件可恢复投递；API readiness 已加入 Redis 检查。

- [x] **P4-011 实现 Sync API**
  - Progress：`GET /api/v1/sync?cursor=` 按用户全局 cursor 增量恢复；WebSocket 只发 `event_available` 提示，客户端始终以 Sync 为事实来源。Sync 请求会 best-effort 预派发 Outbox，Worker 仍作为可靠后台派发主路径。
  - Acceptance：用户按 cursor 获取增量事件；重复拉取幂等。
  - Verify：cursor 前进、重复 cursor 空增量、Outbox -> 双方 Sync 真库测试 PASS。

- [ ] **P4-012 Flutter 本地数据库模型**
  - Progress：已完成 versioned `flutter_secure_storage` 持久化 sync cursor + pending send queue，按 userId/deviceId 隔离；**完整会话/消息/联系人 SQLite 本地库与迁移还没做**。
  - Acceptance：会话、消息、联系人、游标和发送队列有迁移策略。
  - Verify：当前 schemaVersion/损坏状态恢复已在代码中处理；完整本地库升级测试待后续。

- [ ] **P4-013 Flutter 同步引擎**
  - Progress：协调器已实现启动恢复 cursor、WSS `event_available` 唤醒 Sync、分页追赶、cursor 禁止回退、连接恢复自动 flush + sync；自动单测通过，真实杀进程/断网 E2E 留新的 `人工测试.md`。
  - Acceptance：WSS 仅触发同步；断线后按 cursor 补齐；状态可恢复。
  - Verify：自动 cursor 持久化 PASS；杀进程、断网、重启端到端测试待人工批次。

- [ ] **P4-014 Flutter 离线发送队列**
  - Progress：消息先持久化 pending，再尝试发送；网络/5xx/429 保留队列，恢复后用**原 clientMessageId**重试，服务端确认后才删除；不可重试业务错误保留失败状态；待发送气泡现支持单条“立即重试 / 取消发送”，回复消息离线重试也保留原 replyToMessageId。
  - Acceptance：本地乐观消息、重试、失败、取消和幂等映射正确。
  - Verify：模拟首次断网、第二次恢复重试使用完全相同 clientMessageId 且成功后清队列，自动测试 PASS；飞行模式真机待人工。

- [ ] **P4-015 Flutter 会话列表**
  - Progress：最后消息、未读、时间、草稿、实时状态、待发送数和手动同步已存在；Web 置顶/免打扰根因为 CORS 预检漏放行 `PATCH`，现已补 `PUT/PATCH/DELETE` 并增加回归测试；偏好更新成功后客户端直接 upsert 会话并立即重排。Windows 默认宽度 881px 下固定采用约 `60px 导航 + 248px 会话栏 + 聊天区`，会话栏顶部改为“搜索 + 加号菜单”，不再显示手机式大标题；长按/右键菜单采用 Telegram 式紧凑图标菜单。主消息入口和会话行已保留红色未读角标；Android 未读会话长按提供真实“标为已读”，自动 Widget 回归 PASS。
  - Acceptance：最后消息、未读、时间、置顶、免打扰和草稿正确；置顶必须真实改变排序，免打扰必须保存并跨端同步。
  - Verify：Web 设置 → UI 立即变化 → 刷新仍保存 → Windows/Android 读取一致 → 另一端修改后 Sync 更新，全部通过后才能关闭。

- [ ] **P4-016 Flutter 聊天页面**
  - Progress：聊天页已完成微信式灰底、真实头像、白色/浅绿气泡、紧凑输入区、Telegram 式右键/长按菜单、发送中/已发送/已读/失败展示、回复/复制/撤回/本地删除、历史加载、Unicode Emoji 选择器；Android 长按菜单统一为紧凑圆角 Action Sheet，危险操作红色，会话未读时提供“标为已读”。已读推进现要求聊天页真正可见 + App resumed + 当前路由，修复 `IndexedStack` 隐藏聊天在联系人页仍自动已读的问题。PC/Web 已实现 `Enter=发送`、`Shift+Enter=换行` 并防输入法组合态误发送；发送后保持 FocusNode。Access Token 新增到期前自动轮换，401 发送失败保留 pending 并触发刷新，不再笼统标为“服务端拒绝”。聊天标题栏语音/视频继续复用 P0 Call/LiveKit；主开发启动脚本现正式启动并配置 LAN LiveKit。**仍缺独立“已送达”确认、Sticker/GIF、图片和语音条。**
  - Acceptance：文字发送、失败重试、回复、复制、历史加载可用；聊天区显示发送中/已发送/已送达/已读/失败；PC/Web `Enter=发送`、`Shift+Enter=换行`。
  - Verify：Windows/Web/Android 真人 E2E + 键盘交互 + 已读状态 UI 验收。

- [ ] **P4-017 实现消息撤回事件**
  - Progress：服务端 2 分钟硬限制及 `RECALL_WINDOW_EXPIRED` 分支已移除，OpenAPI 同步改为自己的消息不限时撤回；集成测试改为消息超过 24 小时仍可由发送者撤回，同时继续验证他人不可撤回。客户端菜单不再显示“2 分钟内”。剩余多端真人最终一致验收后关闭。
  - Acceptance：自己的消息默认**不限时撤回**；不得硬编码 2 分钟；撤回继续产生可同步事件并校验发送者权限。
  - Verify：超过 2 分钟、超过 24 小时的自己消息仍可撤回；他人消息仍不可撤回；多端最终一致。

- [x] **P4-018 消息可靠性压测**
  - Acceptance：200 在线连接、100 msg/s 基线下无重复和永久丢失。
  - Verify：提交压测脚本、硬件配置和报告。

- [ ] **P4-019 微信式客户端 UI 主体重构（高优先级）**
  - Progress：第二轮主体已落地；本轮继续修 Windows 原生层：自绘标题栏缩至约 28px，顶层窗口恢复 `WS_OVERLAPPEDWINDOW` 能力但通过 `WM_NCCALCSIZE` 隐藏系统 caption，Win11 DWM 请求圆角并关闭原生 accent border，减少标题栏色块覆盖；Flutter 额外提供四边四角 8 方向 resize handle，直接映射 Win32 `HT*`，不再依赖脆弱的非客户区命中。默认窗口仍为 `881×657`，桌面主壳约 60px 导航 + 248px 会话栏 + 聊天区；联系人/设置已左栏右详情。移动端继续“消息 / 联系人 / 发现 / 我的”。**仍需真实 Windows 圆角/缩放/色块人工验收、登录页、发现页/我的细节、Golden。**
  - Acceptance：不仅重做聊天页，还要统一 Windows / Web / Android 的导航、会话列表、联系人、发现、我的、聊天主区、输入区、消息气泡、菜单、弹层、空状态、加载状态、桌面多栏与移动导航；布局、信息密度和交互心智高保真参考微信，但品牌、图标、素材保持 DD 原创。
  - Verify：Windows/Web/Android 全套核心页面截图人工验收 + Golden 基准；不得再呈现明显 WhatsApp / Material Demo 风格。
  - Maintainability：第二轮 UI 后 `ContactsPage` / `TextChatPage` 已超过 1000 行；下一轮继续堆功能前拆出桌面目录、详情面板、消息行、输入区、上下文菜单等独立组件，避免单文件继续膨胀。

- [ ] **P4-024 Telegram 级丝滑度与交互性能优化（高优先级）**
  - Progress：聊天消息列表按 index 真懒构建并增加 `RepaintBoundary`；发送期间不切换 TextField enabled；草稿 700ms debounce + `notify=false`；Material `InkSparkle` 改 `InkRipple`。Android IME 第二轮改为 Activity `adjustNothing` + Flutter 监听 `viewInsets`，使用合成层 `Transform.translate` 把已完成布局的聊天表面移到键盘上方，避免键盘升降每一帧对长历史消息重新 layout；聊天消息区点击空白可主动 `unfocus` 收键盘。主壳继续持久 `IndexedStack`，但已读状态不再等同于“Widget 仍挂在树上”。尚未完成真机 Profile 帧耗时量化和 50 条快速发送 / 500+ 历史压力验收。
  - Acceptance：60Hz 参考设备正常滚动/页面切换/菜单/输入保持稳定 60fps；关键点击 P95 < 100ms 出现视觉反馈；消息发送本地乐观更新；消息/会话列表局部更新；长历史懒构建；弱网不冻结 UI；高刷设备不人为锁低帧率。
  - Verify：Windows/Web/Android Profile 模式 + 实机滚动/快速发送/长列表测试；连续快速发送 50 条不冻结、不重复、不乱序；500+ 历史消息滚动无持续性掉帧；慢帧比例目标 < 1%。

- [ ] **P4-020 Emoji / Sticker / GIF 基础交互**
  - Progress：Unicode Emoji 选择器已接入聊天输入区并可插入当前光标位置；“+”面板已为图片/GIF/文件保留真实入口但明确标记开发中，不伪装成已可发送。最近使用、图片表情/Sticker、GIF 数据源与发送协议仍待开发。
  - Acceptance：Unicode Emoji 选择器、最近使用、图片表情/Sticker 入口、GIF 入口存在；第三方 GIF 搜索必须可选，自托管环境仍可发送本地 GIF。
  - Verify：Windows/Web/Android 发送与展示一致；无第三方 Provider 时核心功能仍可用。

- [ ] **P4-021 消息已读状态 UI**
  - Progress：Conversation API 新增 `peerLastReadSequence`；仅当对端 `read_receipts_enabled=true` 时返回，对端关闭回执则返回 `null`。客户端自己的消息已按该游标显示“已读”，pending 显示“发送中/失败”，服务端已确认但未读显示“已发送”。**独立“已送达”需要后续设备投递确认机制，当前不伪造。**
  - Acceptance：自己的私聊消息在聊天区域显示发送中、已发送、已送达、已读、失败；用户关闭已读回执后遵守隐私设置。
  - Verify：双端在线/离线/重连/关闭回执场景。

- [ ] **P4-022 PC/Web 键盘发送**
  - Progress：PC/Web 输入框已接 `Enter=发送`，`Shift+Enter` 保留 TextField 换行行为；检测 composing range，中文输入法组合态不触发发送。Windows Widget Test 已覆盖 Enter 发送和 Shift+Enter 不误发送；Web/真实中文输入法仍留人工验收。
  - Acceptance：默认 `Enter=发送`、`Shift+Enter=换行`；输入法组合态不得误发送；后续可配置快捷键策略。
  - Verify：中文输入法、英文、多行文本、Web/Windows 自动与人工测试。

- [ ] **P4-023 Telegram 式消息操作扩展预留**
  - Acceptance：消息菜单和协议为编辑消息、Reaction、为双方删除、收藏、转发等能力保留清晰扩展点，不把当前 P4 数据模型锁死。
  - Verify：接口/模型设计审查，不要求本阶段一次实现全部功能。

### Checkpoint P4：MVP 核心门

- [ ] 断网、重连、服务重启后消息完整。
- [ ] 消息重复率为 0。
- [ ] 未通过本检查点前，不开始朋友圈等非核心功能。

## P5：媒体、文件、图片与语音条

- [x] **P5-001 创建媒体表和对象命名规则**
  - Progress：`000007_media` 已落地 media_objects / media_uploads / media_variants；对象 Key 使用用途前缀 + 年月 + 24-byte CSPRNG 随机值，不暴露用户 ID/文件名。
  - Acceptance：随机 Key、归属、状态、哈希、派生文件和软删除完整。
  - Verify：迁移和对象 Key 不可猜测测试。

- [x] **P5-002 实现上传申请与配额预占**
  - Progress：上传申请按用户 advisory transaction lock 原子预占；限制 32 个活动上传和 512 MiB 活动预留，按 IMAGE/GIF/STICKER/VOICE/FILE 校验 MIME 与大小。
  - Acceptance：大小、类型、用户和实例配额校验；并发不超卖。
  - Verify：并发配额测试。

- [x] **P5-003 实现预签名上传和完成确认**
  - Progress：S3/MinIO 预签名 PUT、SHA-256/Content-Type/Size 完成校验、READY 状态和幂等 complete 已接；消息发送只接受发送者本人 READY 且 purpose 匹配的 mediaId。
  - Acceptance：短时效、限定对象和大小；未确认对象不可发消息。
  - Verify：跨用户、过期和篡改请求测试。

- [ ] **P5-004 实现图片处理 Worker**
  - Acceptance：缩略图、方向纠正、EXIF 清理、像素上限。
  - Verify：超大像素和畸形图片样本测试。

- [ ] **P5-005 实现文件扫描 Worker**
  - Acceptance：恶意或未知高风险文件进入隔离状态。
  - Verify：EICAR 和类型伪装测试。

- [ ] **P5-006 实现临时对象清理**
  - Progress：Worker 已每分钟扫描过期且仍为 `UPLOADING` 的 media_uploads；逐条行锁复核后先删对象存储，再删除数据库 reservation，READY 资源不会进入清理条件。孤儿派生文件和 FAILED/DELETED 长期回收策略仍待补。
  - Acceptance：超时未确认对象、孤儿派生文件可安全清理。
  - Verify：Go test/vet 已通过；后续补真实 MinIO + PostgreSQL 幂等/并发清理集成。

- [x] **P5-007 实现受控下载**
  - Progress：owner 或仍可见该消息的 ACTIVE conversation member 才能取得短时下载 URL；本地删除/撤回后不再通过消息关系授权。
  - Acceptance：下载前验证资源权限；签名 URL 短时有效。
  - Verify：IDOR 和 URL 转发测试。

- [ ] **P5-008 Flutter 图片消息**
  - Progress：跨端图片多选（单批最多 30 张）、逐张后台解码/EXIF 方向处理/JPEG 压缩、预签名上传、每张真实上传进度、顺序可靠发送、缩略显示、点击大图和授权下载已接；多选按张串行处理避免同时解码多张大图造成内存尖峰。剪贴板粘贴、桌面拖拽、图片上传取消/原图策略仍待补。
  - Acceptance：移动端相册/文件选择、Windows/Web 文件选择、剪贴板粘贴、桌面拖拽、压缩、上传进度、缩略图、点击大图预览、发送失败重试/取消。
  - Verify：大图、断网、取消、粘贴、拖拽、跨端显示测试。

- [ ] **P5-009 Flutter 文件消息和桌面拖拽**
  - Progress：普通文件选择/私有上传/FILE 可靠消息/文件名与大小气泡/短时授权下载地址已接；2026-08-08 已改成双遍流式读取：第一遍流式 SHA-256，第二遍 StreamedRequest 上传，不再把整个文件读入内存，支持实时进度与上传中取消，客户端恢复使用服务端 2 GiB 上限。剩桌面拖拽、断点续传、保存/直接打开与下载进度。
  - Acceptance：大小提示、进度、取消、重试和打开策略安全。
  - Verify：Windows/Web/Android 测试。

- [ ] **P5-010 Flutter 语音录制**
  - Progress：`record` 已接 WAV 录制；Android 长按/上滑取消、桌面/Web 点击开始结束、10 分钟上限、私有上传并进入 durable pending 已实现，真实权限/设备行为留晚间人工验收。
  - Acceptance：Android/iOS 支持按住说话、上滑取消、录制计时、最大时长、权限拒绝恢复；Windows/Web 支持点击开始/结束录音；录音完成进入可靠发送队列。
  - Verify：Android/iOS/Windows/Web 权限、取消、断网、重试测试。

- [ ] **P5-011 Flutter 语音播放**
  - Progress：授权 URL + audioplayers 播放/暂停、进度、已听标记、1x/1.5x/2x 倍速已接；真实波形、移动端听筒/扬声器切换和音频焦点专项仍待补。
  - Acceptance：波形、进度、已听、倍速、听筒/扬声器策略。
  - Verify：多条连续播放和音频焦点测试。

- [ ] **P5-012 Sticker / GIF 媒体管线**
  - Progress：本地 GIF 与 PNG/WebP/GIF 图片表情已经走对象存储、可靠消息和授权下载；自定义贴纸收藏/贴纸包、最近表情管理和可选第三方 GIF 搜索仍待开发。
  - Acceptance：本地 GIF 可上传/发送/播放；静态 Sticker 可收藏并组成自定义贴纸包；资源走对象存储和权限校验。第三方 GIF 搜索 Provider 为可选插件，不得成为核心依赖。
  - Verify：无第三方网络时本地 GIF/Sticker 仍可发送；跨用户越权、超大文件和畸形媒体测试。

### Checkpoint P5

- [ ] 图片、文件、语音、Sticker、GIF 在外网和多端可用。
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
  - Progress：PoC 已实现 `ringing -> accepted/rejected/ended`，覆盖接听、拒绝、呼叫前取消、通话中挂断、45 秒无人接听超时和非法转移；正式版仍缺数据库持久化、独立 BUSY/FAILED 等完整状态表和多设备仲裁。
  - Acceptance：所有状态、事件、超时和非法转移有表格与测试。
  - Verify：状态机分支覆盖率 ≥ 90%。

- [ ] **P7-002 创建通话数据模型**
  - Acceptance：calls、participants、状态时间和结束原因完整。
  - Verify：迁移测试。

- [ ] **P7-003 实现创建呼叫和权限检查**
  - Progress：PoC 已完成双方身份校验、参与者操作限制和忙线冲突；正式登录鉴权、好友/会话和拉黑联动尚未接入。
  - Acceptance：好友/会话/拉黑/忙线规则正确。
  - Verify：权限矩阵测试。

- [ ] **P7-004 实现 LiveKit Token 签发**
  - Progress：PoC 已限制为接听后的通话参与者领取指定房间短期 Token；本轮修复主开发环境未接媒体服务的问题：`run-auth-dev.ps1` 现在与 PostgreSQL/Redis 一起启动 LiveKit，并按自动检测 LAN IP 配置 `ws://<LAN>:17880`、RTC TCP 17881、RTC UDP 17882、TURN UDP 13478 及 LocalSubnet 防火墙。Call accept/reject/hangup 的同状态重复动作改为幂等，客户端收到 INVALID_CALL_STATE 会自动恢复/清理最新状态，媒体 join 失败显示 LiveKit 真实错误。正式版仍需登录会话绑定和持久化授权。
  - Acceptance：短时效、限定房间、身份和权限。
  - Verify：篡改房间和过期 Token 测试。

- [ ] **P7-005 实现多设备来电仲裁**
  - Acceptance：全部设备响铃；一个接听后其他设备停止；重复接听被拒。
  - Verify：三设备并发测试。

- [ ] **P7-006 Flutter 语音通话 UI**
  - Progress：PoC 已完成前台呼叫、来电、接听、拒绝、静音和挂断；扬声器切换、系统铃声、后台与锁屏来电尚未完成。
  - Acceptance：呼叫、响铃、接听、拒绝、静音、扬声器和挂断。
  - Verify：Android/iOS/Web/Windows 测试矩阵。

- [ ] **P7-007 Flutter 视频通话 UI**
  - Progress：PoC 已完成自动入房、摄像头开关、前后切换、本地/远端画面和挂断；弱网提示尚未完成。
  - Acceptance：摄像头开关、前后切换、本地/远端画面、弱网提示。
  - Verify：目标平台测试。

- [ ] **P7-008 实现网络切换和重连策略**
  - Progress：信令重连后可查询活动通话并恢复状态；真实 Wi-Fi/蜂窝切换和媒体重连仍未验收。
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
  - Progress：当前仅完成**进程仍存活时**的 Android 本地系统通知和 Android 13+ `POST_NOTIFICATIONS` 权限申请；尚未接 FCM token、Push Worker、杀进程唤醒和通知点击路由，不能把本地通知误记为 FCM 完成。
  - Acceptance：token 注册、轮换、点击路由和隐私预览。
  - Verify：前台、后台、杀进程测试。

- [ ] **P10-005 评估并实现 UnifiedPush 适配器**
  - Acceptance：作为可选插件，不影响 FCM 和核心消息。
  - Verify：至少一个兼容分发器测试；不支持时文档说明。

- [ ] **P10-006 实现 iOS APNs 路线**
  - Acceptance：按 P0 决策完成凭据、推送和隐私模型。
  - Verify：TestFlight/真实设备后台测试。

- [ ] **P10-007 实现桌面系统通知**
  - Progress：Windows 已接 `flutter_local_notifications` 本地系统通知；前台但不在当前聊天时使用软件内 SnackBar，后台/最小化且进程仍存活时使用 Windows Toast。Android 同时接本地高优先级消息通知并请求 Android 13+ 通知权限；免打扰会话不通知。**杀进程可靠通知仍未完成，必须依赖后续 Push Worker / FCM；Windows 通知点击路由也待接。**
  - Acceptance：Windows/macOS/Linux 点击通知进入正确会话。
  - Verify：Windows/Android 进程存活前后台真人测试；杀进程场景留 P10-002/P10-004。

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
