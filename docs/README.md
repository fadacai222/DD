# DD 文档中心｜开发唯一入口

> 更新时间：2026-08-11 03:52（000022 Push migration 配对修复）
>
> 适用仓库：`C:\Users\admin\Desktop\复刻微信`
>
> 本目录是 **DD 后续开发的主规格、状态与架构入口**。任何新功能、Bug 修复、接口、migration、客户端能力或发布门禁变化，都必须在同一轮开发中同步这里。

---

## 1. 事实优先级

遇到“文档、旧 Todo、历史对话、测试结果与代码冲突”时，按以下顺序判断：

1. **当前工作区源代码、runtime route、数据库 migration、当前自动测试/构建结果**。
2. **本文件 + `15-当前实现状态与开发路线.md`**。
3. `01-产品需求规格书-PRD.md` 与对应专题规格。
4. `decisions/` ADR。
5. 根目录开发进度、人工测试、Bug 清单。
6. `tasks/*.md`、归档需求与旧对话，只作为历史输入。

如果代码已经改变而 docs 没变，**代码是事实，docs 必须立即追平**；如果代码存在但当前门禁失败，禁止继续沿用上一轮 `AUTO-VERIFIED` 状态。

---

## 2. 统一状态模型

| 状态 | 含义 |
|---|---|
| `IMPLEMENTED` | 当前代码已经存在对应实现。 |
| `AUTO-VERIFIED` | 当前代码已有可重复自动测试/build/contract gate 证明主要路径。 |
| `HUMAN-PASS` | 目标真实平台已人工验收通过。 |
| `FIXED-PENDING-RETEST` | 真人曾报失败，代码已有针对性修复，但真人未复测。 |
| `KNOWN-FAILURE` | 当前代码、测试、构建或真实客户端仍存在已知失败。 |
| `IN-PROGRESS` | 已开始实现，但还没有形成可验收闭环。 |
| `PLANNED` | 规格已定义，当前代码尚未实现。 |
| `OUT-OF-SCOPE` | 当前阶段明确不做。 |

**硬规则：** `IMPLEMENTED` ≠ `AUTO-VERIFIED` ≠ `HUMAN-PASS`。

---

## 3. 2026-08-11 当前一句话状态

DD 已从基础 IM 进入大功能扩展后的收敛阶段：

- P0/P2/P3/P4/P5 主链已经形成账号、联系人、DIRECT/SELF 消息、媒体、Sticker、可靠同步和多端客户端；
- **P6 Group** 已有正式 PostgreSQL domain、HTTP/OpenAPI、Flutter 创建/聊天/群详情和自动测试；
- **P7 Calls** 已从实验内存 CallStore 正式化为 `server/internal/calls` + PostgreSQL 状态机 + `/api/v1/calls` + Bearer Principal + 多设备接听仲裁；
- **P8 Moments** 已有朋友圈 Feed、最多 9 图/单视频、点赞评论、单条可见范围、长期隐私偏好和私有媒体授权；
- **P9 QR** 服务端与 Flutter 主链已完成本轮收口：`dart analyze --fatal-infos` 0 issue，4 个 QR 定向测试文件 10/10 通过，Windows/Web/Android 当前源码均已重新构建成功；仍待真人扫码与多端设备验收；
- **P10 Push** 已开始，`000022_push.up.sql` / `000022_push.down.sql` 已形成可加载的 migration 对；正式 Service/API/Worker/provider/client token registration 仍未实现；
- P11 E2EE、P12 Admin/Data Rights、P13 Production Self-host、P14 iOS/macOS 正式交付仍未完成。

当前不能宣称 Stable 1.0，也不能把“今晚能运行开发环境”写成“商业上线完成”。

---

## 4. 当前数据库与正式模块快照

当前 migration 已出现：

```text
000001_instance_settings
...
000016_stickers
000017_groups
000018_calls
000019_moments
000020_calls_conversation
000021_qr
000022_push           ← P10 开发中，up/down 已配对
```

当前 Go 正式业务模块包括：

```text
auth
contacts
groups
calls
messaging
moments
media
stickers
qrcode
realtimebus
realtimev1
```

P10 Push 尚未形成对应正式 domain package。

---

## 5. 当前 API 合同快照

正式 `/api/v1` 已覆盖原有 Auth/Contacts/Messaging/Media/Stickers，并新增：

```text
Groups
Moments
Moment Preferences
Formal Calls
Group QR Invite/Redeem
QR Login create/status/scan/confirm/consume
```

Calls 正式入口已经是：

```text
POST /api/v1/calls
GET  /api/v1/calls/active
POST /api/v1/calls/{callId}/actions
POST /api/v1/calls/{callId}/token
```

旧 `/api/calls...` 只属于兼容/历史实验面，**不得再作为新客户端开发导向**。

QR 正式入口包括：

```text
POST   /api/v1/group-qr-invites
DELETE /api/v1/group-qr-invites/{inviteId}
POST   /api/v1/group-qr/redeem
POST   /api/v1/qr-login
POST   /api/v1/qr-login/status
POST   /api/v1/qr-login/scan
POST   /api/v1/qr-login/confirm
POST   /api/v1/qr-login/consume
```

`TestOpenAPIFormalRuntimeSurface` 继续作为 runtime route ↔ OpenAPI 的防漂移门禁。

---

## 6. 2026-08-11 自动门禁事实

### Server

最近完整 `go test ./...` 已通过，Groups/Calls/Moments/QR 都存在真实 PostgreSQL integration coverage；P9 QR migration `000021` 已完成 `up → idempotent up → down → up` 验证。

### P6 Group

`IMPLEMENTED + AUTO-VERIFIED / HUMAN-PENDING`。

### P7 Calls

`IMPLEMENTED + AUTO-VERIFIED / HUMAN-PENDING`。

自动证据包含正式 Bearer API、多设备仲裁、Block/非联系人拒绝、错误设备不能取 LiveKit token/控制 Call、终态通话记录服务端事务化等。公网 TURN/TLS 和跨端长时通话仍需真人环境。

### P8 Moments

`IMPLEMENTED + AUTO-VERIFIED / HUMAN-PENDING`。

真实 PostgreSQL 已覆盖单条可见范围、长期隐私偏好、Block、删除好友后旧动态失权、互动身份可见性、媒体授权和 Outbox；Flutter Moments API/Feed/Publish 定向回归曾 9/9 通过。

### P9 QR

当前状态：

```text
SERVER: IMPLEMENTED + AUTO-VERIFIED
FLUTTER: IMPLEMENTED + AUTO-VERIFIED
OVERALL: AUTO-VERIFIED / HUMAN-PENDING
```

2026-08-11 04:42 本轮已重新验证：

- `dart analyze --fatal-infos`：0 issue；
- `dd_qr_payload_test.dart`、`qr_api_client_test.dart`、`qr_login_page_test.dart`、`qr_scanner_page_test.dart`：10/10 通过；
- Windows Release：构建成功；
- Web Release：构建成功；
- Android Debug APK：构建成功并发布到根目录 `DD-Android.apk`；
- Windows 单实例恢复逻辑修复：残留无窗口进程不再导致后续双击静默退出。

当前只保留真人扫码、相机权限、跨设备登录确认等真实设备验收债务，不能因此直接标 `HUMAN-PASS`。

### P10 Push

`IN-PROGRESS`。

当前 `000022_push.up.sql` / `000022_push.down.sql` 已配对；up migration 包含：

```text
user_notification_preferences
device_push_endpoints
push_jobs
```

并预留：

```text
FCM
APNS
UNIFIEDPUSH
FULL / SENDER_ONLY / HIDDEN preview mode
endpoint hash 去重
失败计数/状态
push job dedupe/retry 时间
```

当前尚缺：

- Push domain/service；
- device endpoint API；
- durable Job producer；
- Worker consumer；
- FCM/APNs/UnifiedPush provider adapter；
- 失败退避与失效 token 清理；
- Flutter/Android/iOS token 注册；
- provider 真凭据 integration test。

所以 P10 不能标 `IMPLEMENTED`。

---

## 7. 文档地图

| 文档 | 用途 |
|---|---|
| `00-需求完善总览.md` | 产品范围与当前完成度总览。 |
| `01-产品需求规格书-PRD.md` | 最终产品行为与功能要求。 |
| `02-技术架构与模块设计.md` | 当前真实架构、模块边界和数据流。 |
| `03-安全隐私与威胁模型.md` | Auth/Group/Calls/Moments/QR/Push/E2EE 安全边界。 |
| `04-部署运维与开源交付规范.md` | 开发/生产部署、构建、Worker、migration、发布。 |
| `05-API与数据模型草案.md` | 当前正式 API、migration 和数据实体。 |
| `06-测试验收与发布标准.md` | 自动门禁、真人验收和发布阻断条件。 |
| `07-P0实时通信PoC.md` | Realtime PoC 历史结论与正式主链关系。 |
| `08-P0音视频通话PoC.md` | LiveKit/TURN PoC 与已正式化 P7 Calls 的演进。 |
| `09-P0-E2EE候选库评估.md` | E2EE PoC 与 P11 正式实现边界。 |
| `10-P2账号认证垂直切片.md` | Auth/User/Device 与 QR trusted-session 关系。 |
| `11-P3好友关系链.md` | DDID、好友、Block 与 Group/Moments/QR 联动。 |
| `12-产品体验与UI功能基线.md` | Windows/Android/Web、朋友圈、二维码等 UI/体验基线。 |
| `13-2026-08-09-1(1)-体验与能力增量需求.md` | 历史体验增量吸收与回归索引。 |
| `14-2026-08-09-登录联系人媒体缓存稳定性增量.md` | 登录、联系人、媒体缓存回归索引。 |
| `15-当前实现状态与开发路线.md` | **每轮开发必读：真实状态、阻断、下一步。** |
| `16-2026-08-11-全量文档同步记录.md` | 本次从 P5/R16 旧视角追平到 P6-P10 的事实变更记录。 |
| `decisions/*.md` | 已接受/废弃架构决策；P9/P10 新增 ADR-010/ADR-011。 |

---

## 8. 后续开发唯一顺序

当前不再从 P6 重新开始。开发主线是：

```text
完成 P9 真人扫码/跨设备验收
→ 完成 P10 Push
→ P11 Production E2EE
→ P12 Admin / Abuse / Data Rights
→ P13 Production Self-host / Backup / Upgrade / Observability
→ P14 iOS/macOS 产品交付
```

P6/P7/P8 同时保留真人多端/弱网/规模验收债务，但不能把已实现模块重新写回 `PLANNED`。

---

## 9. 后续 AI / 开发者开工流程

1. 读本文件。
2. 读 `15-当前实现状态与开发路线.md`。
3. 根据当前阶段读一到两个对应专题文档。
4. 再读 runtime route、migration、测试和当前 worktree。
5. 先修 `KNOWN-FAILURE`，再开发下一大模块。
6. 修改代码后重新跑受影响门禁。
7. 同一轮同步 docs。
8. 真人未测的用户体验只能写 `HUMAN-PENDING` / `FIXED-PENDING-RETEST`，禁止冒充 `HUMAN-PASS`。

---

## 10. 文档维护 Definition of Done

一次文档更新至少需要做到：

- 当前 route 与 API 文档一致；
- 当前 migration 序列一致；
- 实现状态和最新测试结果一致；
- 已知失败没有被旧“完成”描述覆盖；
- ADR 与代码现实不冲突；
- 所有内部 Markdown 引用可解析；
- `15-当前实现状态与开发路线.md` 的下一任务与真实 worktree 一致。
