# DD API 与数据模型｜当前实现合同

> 更新时间：2026-08-11 03:36（runtime/OpenAPI/migration 全量复核）
>
> **重要：本文以当前 runtime handler + migration 为事实源。** `server/openapi/openapi.json` 已由 `TestOpenAPIFormalRuntimeSurface` 锁定正式 path/method，新增正式 HTTP 路由必须同步合同；WebSocket/兼容实验面仍单独说明。

---

# 1. API 基础约定

正式业务前缀：

```text
/api/v1
```

正式 Calls 已使用：

```text
/api/v1/calls
```

旧 `/api/calls...` 只保留历史/兼容语义，不再作为新客户端合同。

Realtime：

```text
/api/v1/realtime     正式鉴权 WebSocket
/ws                  历史兼容 PoC WebSocket
```

默认开发 API 端口：

```text
18473
```

---

# 2. HTTP 通用约定

## 2.1 Content-Type

写操作 JSON：

```http
Content-Type: application/json
```

上传对象本体不经过普通 JSON API，而走 presigned object storage PUT。

## 2.2 鉴权

正式用户 API 使用 Access Token。

服务端从 Token 构造 Principal：

```text
userId
deviceId
```

客户端请求体中的 userId 不能替代 Principal。

## 2.3 错误

业务错误返回稳定 code + message。

隐私边界允许使用 404 隐藏“存在但不可见”的资源，例如 block 关系中的公开用户资料。

---

# 3. 当前 runtime 路由总表

以下来自当前 `server/internal/httpapi/server.go` 与对应 handler。

## 3.1 Discovery / Health

| Method | Path | 状态 | 说明 |
|---|---|---|---|
| GET | `/.well-known/openimx/client` | 正式基础 | 客户端发现 |
| GET | `/api/v1/instance` | 正式 | 实例元数据 |
| GET | `/api/v1/system/live` | 正式 | 进程存活 |
| GET | `/api/v1/system/ready` | 正式 | 依赖 readiness |
| GET | `/api/v1/system/version` | 正式 | 版本 |
| GET | `/health` `/live` `/ready` `/version` | 兼容 | 历史别名 |

## 3.2 Auth

| Method | Path | 说明 |
|---|---|---|
| POST | `/api/v1/auth/register/email/send-code` | 发送注册验证码 |
| POST | `/api/v1/auth/register` | 注册 |
| POST | `/api/v1/auth/login` | 登录 |
| POST | `/api/v1/auth/token/refresh` | Refresh rotation |
| POST | `/api/v1/auth/password/reset/send-code` | 密码重置验证码 |
| POST | `/api/v1/auth/password/reset` | 重置密码 |
| POST | `/api/v1/auth/logout-all` | 全部设备退出 |

## 3.3 Me / Device

| Method | Path | 说明 |
|---|---|---|
| GET | `/api/v1/me` | 当前账号资料 |
| PATCH | `/api/v1/me` | 修改资料 |
| POST | `/api/v1/me/email/send-code` | 新邮箱验证码 |
| PATCH | `/api/v1/me/email` | 邮箱改绑 |
| PUT | `/api/v1/me/avatar` | 上传/替换头像 |
| DELETE | `/api/v1/me/avatar` | 删除头像 |
| GET | `/api/v1/avatars/{userId}` | 读取可见头像 |
| GET | `/api/v1/devices` | 设备列表 |
| DELETE | `/api/v1/devices/{deviceId}` | 撤销设备 |

## 3.4 User / Contacts

| Method | Path | 说明 |
|---|---|---|
| GET | `/api/v1/users/by-handle/{handle}` | DDID 精确查询 |
| GET | `/api/v1/users/{userId}` | stable userId 公开资料 + relationship |
| GET | `/api/v1/users/mention-suggestions` | Mention 建议 |
| GET | `/api/v1/contact-requests` | 收/发好友申请分页 |
| POST | `/api/v1/contact-requests` | 发送好友申请 |
| POST | `/api/v1/contact-requests/{requestId}/accept` | 同意 |
| POST | `/api/v1/contact-requests/{requestId}/reject` | 拒绝 |
| DELETE | `/api/v1/contact-requests/{requestId}` | 取消自己的申请 |
| GET | `/api/v1/contacts` | 联系人分页 |
| PUT | `/api/v1/contacts/{userId}` | 直接添加联系人业务入口（受状态约束） |
| PATCH | `/api/v1/contacts/{userId}` | 备注/标签/星标 |
| DELETE | `/api/v1/contacts/{userId}` | 删除联系人 |
| GET | `/api/v1/blocks` | 黑名单 |
| POST | `/api/v1/blocks` | 拉黑 |
| DELETE | `/api/v1/blocks/{userId}` | 解除拉黑 |

## 3.4.1 Group

| Method | Path | 说明 |
|---|---|---|
| POST | `/api/v1/groups` | 创建群聊并邀请初始联系人 |
| GET | `/api/v1/groups/{groupId}` | 群资料 |
| PATCH | `/api/v1/groups/{groupId}` | 群名称/公告/入群策略 |
| DELETE | `/api/v1/groups/{groupId}` | 群主解散群聊 |
| GET | `/api/v1/groups/{groupId}/members` | 活跃成员列表 |
| POST | `/api/v1/groups/{groupId}/members` | Owner/Admin 邀请联系人 |
| PATCH | `/api/v1/groups/{groupId}/members/{userId}` | 管理员角色或本人群昵称 |
| DELETE | `/api/v1/groups/{groupId}/members/{userId}` | 移出成员 |
| POST | `/api/v1/groups/{groupId}/leave` | 非群主退出 |
| POST | `/api/v1/groups/{groupId}/transfer` | 群主转让 |
| GET/POST | `/api/v1/groups/{groupId}/join-requests` | 审批列表/申请入群 |
| POST | `/api/v1/groups/{groupId}/join-requests/{requestId}/approve` | 通过申请 |
| POST | `/api/v1/groups/{groupId}/join-requests/{requestId}/reject` | 拒绝申请 |

`groupId == conversationId`。群聊消息不另建平行协议，继续复用 Messaging/Outbox/Sync/read/unread/media/sticker/mention；成员 `status != ACTIVE` 后服务端消息读写授权立即失效。`Conversation` 的 `latestUnreadMentionMessageId` / `latestUnreadMentionSequence` 只描述当前 principal，二者无目标时为 `null`；判定继续依赖 `last_read_sequence`，不新增第二套 mention-read boolean。

## 3.5 Conversation / Messaging

| Method | Path | 说明 |
|---|---|---|
| GET | `/api/v1/conversations` | 会话列表；GROUP summary 对当前 principal 返回 durable 未读 @ 目标 |
| POST | `/api/v1/conversations/direct` | 确保 DIRECT 会话 |
| GET | `/api/v1/conversations/{conversationId}` | 会话详情；GROUP 同样返回当前 principal 的 durable 未读 @ 目标 |
| DELETE | `/api/v1/conversations/{conversationId}` | 当前用户本地隐藏会话 |
| GET | `/api/v1/conversations/{conversationId}/messages` | 历史消息 |
| POST | `/api/v1/conversations/{conversationId}/messages` | 发送消息 |
| POST | `/api/v1/conversations/{conversationId}/read` | 标记已读 |
| PATCH | `/api/v1/conversations/{conversationId}/preferences` | pin/mute/archive 等偏好 |
| GET | `/api/v1/conversations/{conversationId}/pinned-messages` | 会话置顶消息 |
| GET | `/api/v1/messages/{messageId}` | 单条消息 |
| PATCH | `/api/v1/messages/{messageId}` | 编辑 TEXT |
| POST | `/api/v1/messages/{messageId}/recall` | 撤回 |
| DELETE | `/api/v1/messages/{messageId}/local` | 仅本地删除 |
| PUT | `/api/v1/messages/{messageId}/save` | 收藏 |
| DELETE | `/api/v1/messages/{messageId}/save` | 取消收藏 |
| PUT | `/api/v1/messages/{messageId}/pin` | 置顶消息 |
| DELETE | `/api/v1/messages/{messageId}/pin` | 取消置顶 |
| POST | `/api/v1/messages/{messageId}/forward` | 转发 |
| GET | `/api/v1/messages/search` | 消息搜索 |
| GET | `/api/v1/link-preview?url=...` | 已认证的公共 HTTP/HTTPS 链接预览；服务端代抓取并阻断私网/回环/危险端口/不安全重定向 |
| PUT | `/api/v1/saved-messages/conversation` | 确保 SELF 会话 |
| GET | `/api/v1/saved-messages` | 传统收藏列表 |
| GET | `/api/v1/sync` | cursor sync |

## 3.6 Media

| Method | Path | 说明 |
|---|---|---|
| POST | `/api/v1/media/uploads` | reserve 上传 |
| DELETE | `/api/v1/media/uploads/{uploadId}/cancel` | 取消未完成上传并立即释放 reservation/对象存储残留 |
| POST | `/api/v1/media/uploads/{uploadId}/complete` | 完成确认 |
| GET | `/api/v1/media/{mediaId}` | 媒体 metadata |
| POST | `/api/v1/media/{mediaId}/download-url` | 授权并签短期下载 URL |

## 3.7 Sticker

| Method | Path | 说明 |
|---|---|---|
| GET | `/api/v1/stickers/custom` | 自定义 Sticker 列表 |
| POST | `/api/v1/stickers/custom` | 把 READY media 加入个人库 |
| DELETE | `/api/v1/stickers/custom` | 删除个人库项（请求体指定 IDs） |
| PUT | `/api/v1/stickers/custom/order` | 重排 |
| GET | `/api/v1/stickers/packs` | 已订阅 Telegram packs |
| POST | `/api/v1/stickers/packs/telegram` | import/subscribe setName |
| DELETE | `/api/v1/stickers/packs/{packId}` | unsubscribe |

## 3.8 Moments

| Method | Path | 说明 |
|---|---|---|
| GET | `/api/v1/moments` | 当前用户可见 Feed |
| POST | `/api/v1/moments` | 发布文字/最多 9 图/单视频 Moment |
| GET | `/api/v1/moments/{momentId}` | 读取当前仍可见的单条动态 |
| DELETE | `/api/v1/moments/{momentId}` | 作者删除动态 |
| PUT/DELETE | `/api/v1/moments/{momentId}/like` | 点赞/取消点赞 |
| POST | `/api/v1/moments/{momentId}/comments` | 评论/回复 |
| DELETE | `/api/v1/moments/{momentId}/comments/{commentId}` | 删除有权删除的评论 |
| GET | `/api/v1/moment-activity` | 读取当前用户持久化的朋友圈互动未读数 + 最近 30 条仍可见互动明细 |
| POST | `/api/v1/moment-activity/read` | 把当前已有朋友圈互动标记为已读，并返回最新未读数 + 最近互动明细 |
| GET | `/api/v1/moment-preferences` | 长期朋友圈关系隐私偏好 |
| PATCH | `/api/v1/moment-preferences/{userId}` | 设置/清除“不看他/不让他看” |

可见性由服务端重新计算好友关系、Block、relationship preference 与单条 `ALL_CONTACTS/PRIVATE/EXCLUDE`，客户端隐藏不构成安全边界。

## 3.9 QR

| Method | Path | 说明 |
|---|---|---|
| GET | `/api/v1/qr/me` | 当前账号实例绑定个人 QR payload |
| POST | `/api/v1/group-qr-invites` | Owner/Admin 创建群邀请二维码 |
| DELETE | `/api/v1/group-qr-invites/{inviteId}` | 撤销群邀请二维码 |
| POST | `/api/v1/group-qr/redeem` | 当前账号消费群邀请码 |
| POST | `/api/v1/qr-login` | PC/Web 创建短期登录 challenge |
| POST | `/api/v1/qr-login/status` | 按 nonce 查询 challenge 状态 |
| POST | `/api/v1/qr-login/scan` | 已登录移动设备扫描并绑定 scanner |
| POST | `/api/v1/qr-login/confirm` | scanner 设备确认/拒绝 |
| POST | `/api/v1/qr-login/consume` | 目标设备一次消费并获取新 Session |

QR secret 通过 POST body 传输；登录 nonce 数据库只存 SHA-256。群 invite redeem 与 `use_count` 更新同事务；登录 Session 创建与 challenge consume 同事务。

## 3.10 Realtime

| Method | Path | 说明 |
|---|---|---|
| GET Upgrade | `/api/v1/realtime` | 正式鉴权 WebSocket |
| GET Upgrade | `/ws` | 历史 PoC 兼容 |

## 3.11 Calls（正式）

| Method | Path | 说明 |
|---|---|---|
| POST | `/api/v1/calls` | Bearer Principal 发起一对一 audio/video call |
| GET | `/api/v1/calls/active` | 当前 authenticated device 恢复 active call |
| POST | `/api/v1/calls/{callId}/actions` | accept/reject/cancel/end 等状态动作 |
| POST | `/api/v1/calls/{callId}/token` | 胜出/有权控制设备获取 scoped LiveKit token |

正式语义：caller identity/device 由 Access Token Principal 决定；callee 必须是联系人且双方未 Block；状态持久化 PostgreSQL；callee 多设备第一台 accept 后独占媒体控制。发起对象不是联系人时返回 `403 / CALL_CONTACT_REQUIRED`；真正的当前用户/设备无权控制既有 call 仍返回 `403 / CALL_FORBIDDEN`，客户端不得把两者混成同一提示。旧 `/api/calls...` 只属于兼容/历史实验面。

---

# 4. OpenAPI 当前状态

R16 之后合同继续随 P6-P9 扩展：`TestOpenAPIFormalRuntimeSurface` 当前锁定 Groups、Moments、Formal Calls、Group QR 与 QR Login 等正式 path + method；Redocly `recommended-strict` 最近复核通过。

显式不纳入正式 OpenAPI 的主要是：

- 兼容 health alias；
- WebSocket upgrade 入口；
- 旧 `/api/calls...` 兼容/历史实验面。

P10 Push 目前没有正式 runtime API，因此 `000022_push.up.sql` 里的表不能被误写成“已有 Push API”。

---

# 5. 核心数据模型

以下按 migration 当前最终状态描述。

---

## 5.1 `users`

核心字段：

```text
id uuid PK
email_normalized
email_verified_at
handle_normalized
display_name
avatar_media_id
bio
status
created_at
updated_at
deleted_at
```

约束：

```text
handle_normalized ~ ^[a-z][a-z0-9_]{2,31}$
status IN ACTIVE/SUSPENDED/DELETING/DELETED
```

外部产品名称统一叫 DDID；底层字段仍可保留 `handle`。

---

## 5.2 `user_privacy_settings`

一用户一行。

未来承载：

- 通过 DDID 查找开关。
- 陌生人消息策略。
- 通知预览。
- 朋友圈可见策略等。

当前具体字段以 migration 为准。

---

## 5.3 `auth_passwords`

```text
user_id PK/FK
password_hash
updated_at
```

密码只存 Argon2id hash。

---

## 5.4 `devices`

平台：

```text
ANDROID
IOS
WINDOWS
MACOS
LINUX
WEB
```

记录：

- user owner。
- device name/platform。
- last seen。
- revoked state。
- future identity key columns。

---

## 5.5 `refresh_tokens`

核心：

```text
id
user_id
device_id
token_hash
parent_token_id
family_id
issued_at
expires_at
revoked_at
revocation_reason
```

支持 rotation 与 family replay response。

---

## 5.6 `email_codes`

purpose：

```text
REGISTER
PASSWORD_RESET
CHANGE_EMAIL
```

记录 hash、attempts、expires、consumed。

---

## 5.7 Auth security tables

```text
auth_login_attempts
auth_audit_events
```

用于登录限流与认证操作审计。

---

# 6. 联系人数据

## 6.1 `contact_requests`

```text
sender_user_id
receiver_user_id
status
message
created_at
expires_at
resolved_at
```

状态：

```text
PENDING
ACCEPTED
REJECTED
CANCELLED
EXPIRED
```

禁止 self request。

## 6.2 `contacts`

有方向记录：

```text
owner_user_id
contact_user_id
remark
starred
created_at
updated_at
```

好友建立时通常生成双方两行。

## 6.3 `contact_tags`

复合 FK 到 owner/contact pair。

## 6.4 `blocks`

```text
owner_user_id
blocked_user_id
created_at
```

禁止 self block。

## 6.5 `relationship_rate_events`

当前 scope 至少：

```text
HANDLE_SEARCH
CONTACT_REQUEST
```

Mention suggestion 当前也有服务层 rate limiting；如其持久化 scope 与 migration 不一致，后续应统一 migration/实现。

---

# 7. Conversation 数据

## 7.1 `conversations`

当前 type：

```text
DIRECT
GROUP
SELF
```

关键：

```text
id
type
direct_pair_key
last_sequence
last_message_id
created_at
updated_at
```

`GROUP` 已由 P6 正式实现：`groups` 元数据与 `conversation_members` 共同构成群生命周期；正式 Messaging 直接把 GROUP 当 conversation 授权和同步，不另造第二套消息系统。

## 7.2 `conversation_members`

关键：

```text
conversation_id
user_id
role
status
joined_at
left_at
last_read_sequence
muted_until
is_pinned
archived_at
hidden_through_sequence
```

角色：

```text
MEMBER
ADMIN
OWNER
```

状态：

```text
ACTIVE
LEFT
REMOVED
```

---

## 7.3 Group 元数据（migration `000017_groups`）

### `groups`

```text
conversation_id PK/FK -> conversations.id
name
announcement
join_mode = INVITE_ONLY | APPROVAL
created_by_user_id
status = ACTIVE | DISSOLVED
created_at / updated_at / dissolved_at
```

### `group_member_profiles`

```text
conversation_id + user_id PK/FK -> conversation_members
nickname
updated_at
```

群昵称只允许成员修改自己的值；角色继续以 `conversation_members.role` 为唯一权威来源。

### `group_join_requests`

```text
id
conversation_id
requester_user_id
message
status = PENDING | APPROVED | REJECTED | CANCELLED
created_at / resolved_at / resolved_by_user_id
```

每用户每群最多 1 个 PENDING；审批时重新验证 requester 仍 ACTIVE、容量未超限、与当前群主不存在 block，避免申请后状态变化产生 TOCTOU 绕过。

# 8. Message 数据

## 8.1 `messages`

最终 message type：

```text
TEXT
IMAGE
GIF
STICKER
STICKER_PACK
FILE
VOICE
VIDEO
SYSTEM
ENCRYPTED
```

核心字段：

```text
id
conversation_id
sequence
sender_user_id
sender_device_id
client_message_id
type
content_json
ciphertext
reply_to_message_id
forwarded_from_message_id
created_at
edited_at
edit_version
recalled_at
deleted_at
```

### `client_message_id`

按发送设备形成幂等键，不能随 retry 改变业务语义。

### `sequence`

每会话单调递增，已读、历史分页、Sync 都依赖它。

### `edited_at/edit_version`

`000014_message_editing` 新增。

---

## 8.2 `message_media`

```text
message_id
media_id
role
```

角色：

```text
PRIMARY
THUMBNAIL
```

---

## 8.3 `message_local_deletions`

```text
user_id
message_id
```

只影响单用户可见性。

## 8.4 `message_mentions`（migration `000034_message_mentions`）

```text
message_id
conversation_id
sequence
mentioned_user_id
mention_all
```

该表只承载 GROUP durable mention viewer 事实，不信任客户端传入 entities。TEXT 发送时基于服务端解析后的 `MENTION` / 已授权 `MENTION_ALL` 与 message 同事务写入；edit 先按最新 authoritative entities 重建，recall 删除对应 rows。查询使用 `(mentioned_user_id, conversation_id, sequence DESC, message_id)` 索引，并同时要求当前 principal 仍是 ACTIVE member、`sequence > last_read_sequence`、message 未 recalled/deleted，且该 viewer 未执行 local delete。sender 不会成为自己的 `MENTION_ALL` recipient；账号匿名化会删除该用户的 viewer rows。

---

# 9. Messaging Productivity

## 9.1 `saved_messages`

传统 bookmark 表：

```text
user_id
message_id
saved_at
migrated_message_id
```

`000013` 后增加 `migrated_message_id`，用于向 SELF Saved Messages 体验迁移。

## 9.2 SELF conversation

`000013` 增加 `SELF` conversation type。

SELF 是真正可写会话，不只是收藏索引。

## 9.3 `conversation_pinned_messages`

```text
conversation_id
message_id
pinned_by_user_id
pinned_at
```

## 9.4 `forwarded_from_message_id`

`messages` 上的自引用，源消息删除后 `SET NULL`。

---

# 10. Outbox 与 Sync

## 10.1 `outbox_events`

aggregate type 当前：

```text
MESSAGE
CONVERSATION
RELATIONSHIP
```

核心字段：

```text
aggregate_type
aggregate_id
conversation_id
target_user_id
sequence
payload
available_at
attempts
published_at
```

## 10.2 `sync_events`

每用户一份可按 cursor 增量读取的事件。

核心：

```text
cursor
user_id
source_outbox_id
conversation_id
sequence
event_type
payload
created_at
```

---

# 11. 媒体数据

## 11.1 `media_objects`

核心：

```text
id
owner_user_id (000016 后可 NULL，provider shared media 使用)
purpose
original_name
mime_type
size_bytes
sha256
storage_key
status
encryption_mode
created_at
ready_at
```

purpose 当前：

```text
CHAT_IMAGE
CHAT_FILE
CHAT_VOICE
CHAT_VIDEO
STICKER
GIF
```

status：

```text
UPLOADING
READY
QUARANTINED
FAILED
DELETED
```

encryption mode：

```text
NONE
E2EE
```

`E2EE` 只是媒体协议预留。

## 11.2 `media_uploads`

保存 reservation：

```text
media_id
owner_user_id
expected_size
expected_sha256
expires_at
completed_at
```

## 11.3 `media_variants`

为 thumbnail/transcode 等变体预留；当前视频 Poster 主链更多通过独立 media + `message_media.THUMBNAIL` 表达。

---

# 12. Sticker 数据

由 `000016_stickers` 引入。

## 12.1 `custom_stickers`

```text
id
owner_user_id
media_id
width
height
mime_type
size_bytes
sort_order
created_at
```

MIME：

```text
image/png
image/webp
image/gif
video/mp4
video/webm
application/x-tgsticker   # 从 Telegram Pack/消息保存到个人库时允许
```

## 12.2 `telegram_sticker_packs`

```text
id
set_name
title
cover_media_id
supported_sticker_count
unsupported_sticker_count
...
```

`set_name`：

```text
^[A-Za-z0-9_]{1,64}$
```

## 12.3 `telegram_sticker_items`

`000029_telegram_sticker_dynamic_video` 后正式缓存接受：

```text
image/webp
image/png
application/x-tgsticker
video/webm
```

`unsupported_sticker_count` 保留为兼容字段，但语义改为“源项目格式损坏/超限/无法导入数量”，不再表示合法动态/视频 Sticker 不受支持。

每 item 保存 provider source identity、DD mediaId、尺寸、size、sort。

## 12.4 `user_sticker_packs`

用户订阅与全局 pack metadata 分离。

## 12.5 `sticker_rate_events`

当前 scope：

```text
TELEGRAM_IMPORT
```

---

# 13. P7 Calls 数据（migrations `000018_calls` + `000020_calls_conversation`）

### `calls`

核心字段：

```text
id
caller_user_id
callee_user_id
caller_device_id
answered_device_id
conversation_id
room_name
kind = audio | video
status = ringing | accepted | rejected | ended
created_at
ring_expires_at
accepted_at
ended_at
end_reason
version
```

重要约束：

- caller/callee 不能相同；
- caller device 固定；
- accepted 必须有 `answered_device_id`；
- 终态必须有 `ended_at/end_reason`；
- `conversation_id` 在 `000020` 中回填并设为 NOT NULL；
- 历史没有 DIRECT conversation 的 Call pair 只补 conversation 容器，不凭空制造联系人关系。

---

# 14. P8 Moments 数据（migration `000019_moments` + `000028_moment_activity`）

正式表：

```text
moments
moment_media
moment_visibility_users
moment_likes
moment_comments
moment_relationship_preferences
moment_activity_notifications
```

`moments.visibility`：

```text
ALL_CONTACTS
PRIVATE
EXCLUDE
```

`moment_media.sort_order` 限 0..8，即一条 Moment 最多 9 个媒体引用；当前产品约束为最多 9 图或单视频。媒体 purpose 已扩展 `MOMENT_IMAGE/MOMENT_VIDEO`。

Feed/单条读取不能只按表存在返回，必须重新计算 contact、Block、长期 preference 和单条 audience。

`000028_moment_activity` 增加 `moment_activity_notifications` 作为朋友圈点赞/评论/回复的**持久互动事实**。它与 Push Job 分离：Push 失败或被系统吞掉不能导致角标丢失。LIKE 以 Moment+actor+recipient 去重；COMMENT/回复以 comment+recipient 去重；取消点赞、删除评论/动态会同步清理对应活动记录。`GET /api/v1/moment-activity` 除 `unreadCount` 外还返回最近 30 条仍可见的互动 `items`，每条包含 `kind / actor / momentId / commentId? / commentText? / createdAt / read`，用于朋友圈顶部“互动焦点”和互动消息面板；标记已读只更新 `read_at`，不会删除历史互动。未读汇总与最近互动列表都必须重新检查当前 Moment 可见性和 Block，避免不可见内容留下幽灵角标或历史泄漏。

---

# 15. P9 QR 数据（migration `000021_qr`）

### `qr_login_sessions`

```text
id
nonce_hash          bytea(32) unique
target_origin
requested_device_name
requested_platform
requested_app_version
status = PENDING | SCANNED | CONFIRMED | REJECTED | CONSUMED | EXPIRED
scanned_user_id
scanned_device_id
created_at/expires_at/scanned_at/confirmed_at/consumed_at
```

原始登录 nonce 不落库，只保存 SHA-256。确认用户/设备与扫码时绑定；消费后不可再次签发 Session。

### `group_qr_invites`

```text
id
group_id
created_by_user_id
nonce_hash          bytea(32) unique
created_at/expires_at/revoked_at
use_count
max_uses
```

群邀请码消费必须在事务内同时完成 invite 状态/次数检查、Group 成员写入、Group Outbox 和 `use_count`。

---

# 16. P10 Push 数据（IMPLEMENTED / AUTO-VERIFIED / HUMAN-PENDING）

`000022_push` 已从 schema 预留推进为正式 Push domain/API/Worker/provider 主链；后续 migration 又补充产品约束、索引和生命周期。核心事实表仍包括：

```text
user_notification_preferences
device_push_endpoints
push_jobs
```

### `user_notification_preferences`

```text
push_enabled
preview_mode = FULL | SENDER_ONLY | HIDDEN
```

### `device_push_endpoints`

```text
device_id
provider = FCM | APNS | UNIFIEDPUSH
endpoint
endpoint_hash
app_id
environment = PRODUCTION | SANDBOX
status = ACTIVE | INVALID | DISABLED
failure_count
last_success_at/last_failure_at/last_failure_code
```

### `push_jobs`

```text
recipient_user_id
event_type
resource_id
conversation_id
actor_user_id
dedupe_key
payload_json
status = PENDING | SENT | DROPPED
attempts
available_at
last_error
created_at/sent_at
```

当前 Push domain、`/api/v1/push/*` HTTP surface、durable Worker、FCM/APNs/UnifiedPush provider、endpoint retry/INVALID lifecycle 与 Flutter token/偏好接入均已落地；PostgreSQL lifecycle/worker integration 和 provider tests 已形成自动证据。真实 FCM/APNs 设备 delivery/click 与 credential rotation 仍属于真人/生产环境验收，Push 仍不作为消息业务真相源。

---

# 17. Avatar 数据

当前头像表：

```text
profile_avatars
```

当前仍保存头像 bytes 与 MIME/size 等到 PostgreSQL。

这是过渡实现；长期目标迁入统一媒体对象存储，避免 DB 大量 bytea。

迁移前必须保证：

- 旧头像 URL/API 兼容。
- 用户资料和通知头像不失效。
- 原子切换与回滚。

---

# 18. 典型 Message JSON

以下是概念级合同，字段以实际 models/OpenAPI 为准。

## 18.1 TEXT

```json
{
  "clientMessageId": "device-stable-idempotency-key",
  "type": "TEXT",
  "content": {
    "text": "hello @alice"
  },
  "replyToMessageId": null
}
```

服务端保存时可扩展 authoritative entities：

```json
{
  "text": "hello @alice",
  "entities": [
    {
      "type": "MENTION_USER",
      "offset": 6,
      "length": 6,
      "userId": "stable-uuid"
    }
  ]
}
```

## 18.2 IMAGE

```json
{
  "type": "IMAGE",
  "content": {
    "mediaId": "uuid",
    "width": 1080,
    "height": 1440
  }
}
```

## 18.3 VOICE

```json
{
  "type": "VOICE",
  "content": {
    "mediaId": "uuid",
    "durationMs": 14220
  }
}
```

## 18.4 VIDEO

```json
{
  "type": "VIDEO",
  "content": {
    "mediaId": "video-uuid",
    "posterMediaId": "poster-uuid",
    "width": 1920,
    "height": 1080,
    "durationMs": 42000
  }
}
```

主视频和 Poster 不允许使用同一个 mediaId。

## 18.5 STICKER

```json
{
  "type": "STICKER",
  "content": {
    "mediaId": "dd-stable-media-uuid"
  }
}
```

服务端发送时必须验证当前用户拥有发送权限。

## 18.6 STICKER_PACK

```json
{
  "type": "STICKER_PACK",
  "content": {
    "mediaId": "first-sticker-media-uuid",
    "width": 512,
    "height": 512
  }
}
```

客户端分享 Telegram Pack 时提交排序第一项作为预览媒体；服务端必须再次验证该媒体确实属于当前用户已订阅 Pack 且确实为该 Pack 首项，然后把它作为 `message_media.PRIMARY` 挂入消息，并在返回内容中补入服务端生成的 `dd://stickers/telegram/<setName>?title=...`。这样接收方在未订阅 Pack 前仍可通过消息媒体授权读取缩略图。转发 `STICKER_PACK` 时复用原消息的可信导入 URI 与 PRIMARY 媒体授权，不依赖 Pack 缓存仍然存在。

---

# 19. Mention Suggestion 合同

```http
GET /api/v1/users/mention-suggestions?q=al&conversationId=<uuid>&limit=8
```

当前约束：

- `q` 2～32。
- 首字符 a-z。
- 后续 a-z/0-9/_。
- limit 最大 8。
- 双向 block filter。
- 当前 DIRECT peer 优先。
- contacts 其次。
- public matches 最后。

---

# 20. Sync 合同原则

```http
GET /api/v1/sync?cursor=<lastCursor>&limit=<bounded>
```

响应应包含：

- event items。
- 新 cursor/下一页语义。

客户端不能因为 WebSocket 收到一条消息就跳过 cursor 持久化。

---

# 21. Media Reservation 合同原则

创建：

```json
{
  "purpose": "CHAT_VIDEO",
  "fileName": "clip.mp4",
  "mimeType": "video/mp4",
  "sizeBytes": 12345678,
  "sha256": "64-char-hex"
}
```

服务端返回概念上：

```json
{
  "uploadId": "uuid",
  "mediaId": "uuid",
  "uploadUrl": "short-lived-presigned-url",
  "expiresAt": "..."
}
```

Complete 后才成为 READY。

---

# 22. Search 当前边界

服务端当前存在文本消息搜索。

因此：

- 当前非 E2EE 消息可以服务端搜索。
- 未来 E2EE 正式开启后不能默认继续服务端全文索引密文。
- E2EE 搜索应转向客户端本地索引或明确可选服务端模型。

---

# 23. 下一轮 API/Data 必做

1. P9 QR HTTP/Data/Flutter 主链已自动验证，下一步只在真人扫码/跨设备验收暴露真实合同问题时做 Stop-the-line 修复；不要重新规划 QR 主体。
2. P10 Push domain、endpoint API、durable Job、Worker、FCM/APNs/UnifiedPush provider 与客户端 token 注册已经实现；下一步补生产 provider 运维/监控证据，并保持 Push PostgreSQL lifecycle + worker CI 门禁。
3. CI 需要显式增加 Moments / QR PostgreSQL integration step，避免开发机缺少 `DD_MOMENTS_TEST_DATABASE_URL` 等变量时把 SKIP 当成真实数据库验证。
4. P11 Production E2EE 已移出 V1；未来若重新立项，必须新建 identity/prekey/session/device/backup 等独立模型，不能污染当前明文 message schema 后假装加密完成。
5. Admin 新建独立管理员 identity/RBAC/audit/report/data-rights schema，不能复用普通用户 token 当管理员权限。
6. 头像迁移统一媒体存储前写 migration/兼容 ADR。
7. P13 生产化前补 migration compatibility、backup/restore 与 schema upgrade 演练。
