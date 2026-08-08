# API 与数据模型草案

## 1. 设计原则

- REST API 统一使用 `/api/v1`。
- 请求和响应字段使用 `camelCase`。
- 数据库字段使用 `snake_case`。
- ID 使用 UUIDv7 或等价有序高熵 ID，不使用可枚举自增 ID 暴露给客户端。
- 所有写接口支持幂等、乐观锁或明确冲突语义。
- 列表接口使用游标分页，消息历史不使用易漂移的页码分页。
- 错误响应统一格式。
- API 合同以 OpenAPI 为准，客户端代码从合同生成或严格校验。
- WebSocket 事件只用于实时通知，权威状态仍由同步 API 提供。

## 2. 通用响应

### 成功

```json
{
  "data": {},
  "requestId": "req_01..."
}
```

### 错误

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "请求参数无效",
    "details": {
      "field": "email"
    },
    "requestId": "req_01..."
  }
}
```

### 游标分页

```json
{
  "data": [],
  "pagination": {
    "nextCursor": "cursor_xxx",
    "hasMore": true
  },
  "requestId": "req_01..."
}
```

## 3. 核心 API 草案

## 3.1 实例发现

```text
GET  /.well-known/openimx/client
GET  /api/v1/instance
GET  /api/v1/instance/registration-policy
```

用途：客户端输入实例域名后读取 API、WebSocket、媒体、LiveKit 和功能开关。

## 3.2 Auth

```text
POST /api/v1/auth/register/email/send-code
POST /api/v1/auth/register
POST /api/v1/auth/login
POST /api/v1/auth/token/refresh
POST /api/v1/auth/logout
POST /api/v1/auth/logout-all
POST /api/v1/auth/password/forgot
POST /api/v1/auth/password/reset
POST /api/v1/auth/totp/setup
POST /api/v1/auth/totp/verify
DELETE /api/v1/auth/totp
```

注册请求：

```json
{
  "email": "user@example.com",
  "code": "123456",
  "password": "strong-password",
  "handle": "liang",
  "displayName": "良",
  "inviteCode": null,
  "device": {
    "name": "DD Windows",
    "platform": "WINDOWS",
    "appVersion": "0.5.0"
  }
}
```

登录响应：

```json
{
  "data": {
    "user": {},
    "device": {},
    "tokens": {
      "accessToken": "short-lived-token",
      "accessExpiresAt": "2026-08-08T02:00:00Z",
      "refreshToken": "native-client-only",
      "refreshExpiresAt": "2026-09-07T02:00:00Z"
    }
  },
  "requestId": "req_01..."
}
```

Web 客户端 Refresh Token 不返回 JSON，使用 `HttpOnly + SameSite=Lax` Cookie；正式 HTTPS 部署同时启用 `Secure`。浏览器客户端请求使用 credentials，CORS 只对实例白名单 Origin 返回 `Access-Control-Allow-Credentials: true`。

> 2026-08-08 实现状态：`register/email/send-code`、`register`、`login`、`token/refresh`、密码找回、设备管理、`logout-all`、资料/隐私和头像链均已进入正式 `/api/v1` 合同；注册事务、Argon2id、Access Token、Refresh Token 轮换与 Token Family 重放撤销已落地。TOTP / 2FA 仍属于后续 P2。

## 3.3 Devices

```text
GET    /api/v1/devices
GET    /api/v1/devices/{deviceId}
PATCH  /api/v1/devices/{deviceId}
DELETE /api/v1/devices/{deviceId}
POST   /api/v1/devices/{deviceId}/verify
POST   /api/v1/devices/push-token
POST   /api/v1/devices/keys/prekeys
GET    /api/v1/users/{userId}/devices/keys
```

## 3.4 Users

```text
GET    /api/v1/me
PATCH  /api/v1/me
PUT    /api/v1/me/avatar
DELETE /api/v1/me/avatar
GET    /api/v1/avatars/{userId}
GET    /api/v1/users/by-handle/{handle}
POST   /api/v1/me/export
POST  /api/v1/me/deletion-request
DELETE /api/v1/me/deletion-request
```

搜索不提供无上限 `GET /users?q=`，避免账号枚举。模糊搜索需单独权限、限流和最小查询长度。

头像当前阶段采用 `000006_profile_avatars`：原图直接存 PostgreSQL `bytea`，单文件最大 2 MiB，仅允许 JPEG / PNG / WebP，并同时检查 `Content-Type`、文件格式与画布尺寸；最大 2048×2048 且约 4MP，SVG、伪造 MIME 和超大像素图片拒绝。`GET /api/v1/avatars/{userId}` 需要登录并返回私有缓存 ETag。该实现用于在 P5 对象存储/缩略图/EXIF 清理正式管线完成前提供可用头像能力；P5 落地后应迁移存量头像资源，但保持客户端头像读取接口兼容。

## 3.5 Contacts

```text
GET    /api/v1/users/by-handle/{handle}
GET    /api/v1/contacts?page=1&pageSize=50
GET    /api/v1/contact-requests?direction=incoming|outgoing&page=1&pageSize=50
POST   /api/v1/contact-requests
POST   /api/v1/contact-requests/{requestId}/accept
POST   /api/v1/contact-requests/{requestId}/reject
DELETE /api/v1/contact-requests/{requestId}
PATCH  /api/v1/contacts/{userId}
DELETE /api/v1/contacts/{userId}
POST   /api/v1/blocks
DELETE /api/v1/blocks/{userId}
GET    /api/v1/blocks?page=1&pageSize=50
```

当前正式实现规则：

- Handle 只做精确搜索；不返回邮箱。
- 任一方向存在 block 时，Handle 搜索统一按 `404 NOT_FOUND` 处理，避免泄露“被谁拉黑”。
- 搜索默认每用户 10 分钟最多 60 次；发送新好友申请默认每用户 24 小时最多 30 次。
- 同方向重复 PENDING 申请幂等返回原记录。
- 反方向存在 PENDING 时，新申请会原子接受已有申请并建立好友关系。
- 接受申请时双向 contacts 与 DIRECT conversation 创建/复用在同一事务完成。
- 删除好友删除双方 contacts，但保留逻辑私聊会话和后续历史消息语义。
- 拉黑会删除双方 contacts 并取消双方 PENDING 申请。

## 3.6 Conversations

```text
GET   /api/v1/conversations
POST  /api/v1/conversations/direct
GET   /api/v1/conversations/{conversationId}
PATCH /api/v1/conversations/{conversationId}/preferences
POST  /api/v1/conversations/{conversationId}/read
```

创建私聊必须幂等；同一对用户返回同一逻辑私聊会话。

## 3.7 Messages

```text
GET    /api/v1/conversations/{conversationId}/messages?beforeSequence=1000&limit=50
POST   /api/v1/conversations/{conversationId}/messages
POST   /api/v1/messages/{messageId}/recall
DELETE /api/v1/messages/{messageId}/local
POST   /api/v1/messages/{messageId}/forward
GET    /api/v1/messages/{messageId}
```

发送明文消息示例：

```json
{
  "clientMessageId": "01H...",
  "type": "TEXT",
  "content": {
    "text": "你好"
  },
  "replyToMessageId": null
}
```

发送 E2EE 消息示例：

```json
{
  "clientMessageId": "01H...",
  "type": "ENCRYPTED",
  "encryptedEnvelopes": [
    {
      "recipientDeviceId": "dev_...",
      "ciphertext": "base64...",
      "protocolVersion": 1
    }
  ],
  "metadata": {
    "contentClass": "MESSAGE"
  }
}
```

服务端不得信任客户端传入的 senderUserId、senderDeviceId 或 sequence。

## 3.8 Groups

```text
POST   /api/v1/groups
GET    /api/v1/groups/{groupId}
PATCH  /api/v1/groups/{groupId}
DELETE /api/v1/groups/{groupId}
GET    /api/v1/groups/{groupId}/members
POST   /api/v1/groups/{groupId}/members
PATCH  /api/v1/groups/{groupId}/members/{userId}
DELETE /api/v1/groups/{groupId}/members/{userId}
POST   /api/v1/groups/{groupId}/leave
POST   /api/v1/groups/{groupId}/transfer-owner
POST   /api/v1/groups/{groupId}/announcements
```

## 3.9 Media

```text
POST /api/v1/media/uploads
POST /api/v1/media/uploads/{uploadId}/complete
GET  /api/v1/media/{mediaId}
POST /api/v1/media/{mediaId}/download-url
DELETE /api/v1/media/{mediaId}
```

申请上传：

```json
{
  "fileName": "photo.jpg",
  "size": 123456,
  "mimeType": "image/jpeg",
  "sha256": "...",
  "purpose": "CHAT_IMAGE"
}
```

返回：

```json
{
  "data": {
    "uploadId": "upl_...",
    "uploadUrl": "short-lived-signed-url",
    "expiresAt": "2026-08-07T03:00:00Z",
    "requiredHeaders": {}
  }
}
```

## 3.10 Calls

```text
POST /api/v1/calls
GET  /api/v1/calls/{callId}
POST /api/v1/calls/{callId}/accept
POST /api/v1/calls/{callId}/reject
POST /api/v1/calls/{callId}/end
POST /api/v1/calls/{callId}/livekit-token
GET  /api/v1/calls/history
```

服务端签发的 LiveKit Token：

- 短时有效。
- 限定房间。
- 限定身份。
- 限定发布/订阅权限。

## 3.11 Moments

```text
GET    /api/v1/moments/feed
POST   /api/v1/moments
GET    /api/v1/moments/{momentId}
DELETE /api/v1/moments/{momentId}
POST   /api/v1/moments/{momentId}/likes
DELETE /api/v1/moments/{momentId}/likes/me
POST   /api/v1/moments/{momentId}/comments
DELETE /api/v1/moment-comments/{commentId}
POST   /api/v1/moments/{momentId}/report
```

## 3.12 QR

```text
POST /api/v1/qr/profile
POST /api/v1/qr/group-invite
POST /api/v1/qr/login/sessions
GET  /api/v1/qr/login/sessions/{sessionId}
POST /api/v1/qr/login/sessions/{sessionId}/scan
POST /api/v1/qr/login/sessions/{sessionId}/confirm
POST /api/v1/qr/login/sessions/{sessionId}/cancel
POST /api/v1/qr/resolve
```

## 3.13 Sync

```text
GET /api/v1/sync?cursor=<cursor>&limit=500
GET /api/v1/conversations/{conversationId}/sync?afterSequence=100
```

同步事件示例：

```json
{
  "eventId": "evt_...",
  "cursor": "cur_...",
  "type": "MESSAGE_CREATED",
  "resourceId": "msg_...",
  "conversationId": "conv_...",
  "sequence": 101,
  "occurredAt": "2026-08-07T02:00:00Z"
}
```

## 3.14 Admin

```text
GET   /api/v1/admin/overview
GET   /api/v1/admin/users
GET   /api/v1/admin/users/{userId}
POST  /api/v1/admin/users/{userId}/suspend
POST  /api/v1/admin/users/{userId}/unsuspend
POST  /api/v1/admin/users/{userId}/revoke-sessions
GET   /api/v1/admin/reports
POST  /api/v1/admin/reports/{reportId}/resolve
GET   /api/v1/admin/audit-logs
GET   /api/v1/admin/config
PATCH /api/v1/admin/config
POST  /api/v1/admin/test/smtp
POST  /api/v1/admin/test/object-storage
POST  /api/v1/admin/test/livekit
```

## 4. WebSocket 协议

连接：

```text
wss://api.example.com/api/v1/realtime
```

客户端首帧：

```json
{
  "type": "HELLO",
  "protocolVersion": 1,
  "deviceId": "dev_...",
  "lastCursor": "cur_..."
}
```

服务端事件：

```json
{
  "type": "EVENT_AVAILABLE",
  "eventId": "evt_...",
  "cursor": "cur_..."
}
```

心跳：

```json
{"type":"PING","timestamp":1234567890}
{"type":"PONG","timestamp":1234567890}
```

呼叫信令：

- `CALL_INVITED`
- `CALL_RINGING`
- `CALL_ACCEPTED`
- `CALL_REJECTED`
- `CALL_ENDED`
- `CALL_STATE_CHANGED`

限制：

- 单帧最大大小。
- 每秒命令数。
- 未认证连接超时。
- Origin 白名单。
- 协议版本不兼容明确断开码。

## 5. 数据表草案

## 5.1 身份与用户

### users

- `id`
- `email_normalized`
- `email_verified_at`
- `handle_normalized`
- `display_name`
- `avatar_media_id`
- `bio`
- `status`
- `created_at`
- `updated_at`
- `deleted_at`

唯一约束：

- `email_normalized`
- `handle_normalized`

### user_privacy_settings

- `user_id`
- `allow_email_search`
- `allow_stranger_messages`
- `show_online_status`
- `read_receipts_enabled`
- `notification_preview_enabled`

### auth_passwords

- `user_id`
- `password_hash`
- `password_changed_at`

### devices

- `id`
- `user_id`
- `name`
- `platform`
- `app_version`
- `identity_public_key`
- `is_verified`
- `last_seen_at`
- `revoked_at`

### refresh_tokens

- `id`
- `user_id`
- `device_id`
- `token_hash`
- `family_id`
- `expires_at`
- `used_at`
- `revoked_at`

## 5.2 好友

### contact_requests

- `id`
- `sender_user_id`
- `receiver_user_id`
- `message`
- `status`：`PENDING/ACCEPTED/REJECTED/CANCELLED/EXPIRED`
- `created_at`
- `expires_at`
- `resolved_at`

当前正式约束不是只防“同方向”重复，而是对排序后的用户对建立 PENDING 唯一索引：

```text
LEAST(sender_user_id, receiver_user_id)
GREATEST(sender_user_id, receiver_user_id)
```

这样双方同时互发申请也不会长期留下两条 PENDING。

### contacts

每个方向各一行，用于保存 owner 私有元数据：

- `owner_user_id`
- `contact_user_id`
- `remark`
- `is_starred`
- `created_at`
- `updated_at`

### contact_tags

- `owner_user_id`
- `contact_user_id`
- `tag_normalized`
- `tag_name`
- `created_at`

当前每联系人最多 20 个标签；标签 NFKC 归一化并按大小写去重。

### blocks

- `owner_user_id`
- `blocked_user_id`
- `created_at`

### relationship_rate_events

- `user_id`
- `scope`：`HANDLE_SEARCH/CONTACT_REQUEST`
- `created_at`

用于 P3 当前跨进程可持续的数据库限流；后续如迁移到 Redis 分布式限流，仍保留服务层语义和审计能力。

## 5.3 会话与消息

### conversations

- `id`
- `type`：`DIRECT`/`GROUP`
- `direct_pair_key`：私聊唯一对键
- `last_sequence`
- `last_message_id`
- `created_at`
- `updated_at`

### conversation_members

- `conversation_id`
- `user_id`
- `role`
- `status`
- `joined_at`
- `left_at`
- `last_read_sequence`
- `muted_until`
- `is_pinned`

### messages

- `id`
- `conversation_id`
- `sequence`
- `sender_user_id`
- `sender_device_id`
- `client_message_id`
- `type`
- `content_json`：仅非 E2EE 模式
- `ciphertext_json`：E2EE 信封
- `reply_to_message_id`
- `created_at`
- `recalled_at`
- `deleted_at`

唯一约束：

- `(conversation_id, sequence)`
- `(sender_device_id, client_message_id)`

### message_receipts

仅对需要精细送达的场景保存；群聊已读优先使用成员的 `last_read_sequence`。

- `message_id`
- `user_id`
- `device_id`
- `status`
- `occurred_at`

### outbox_events

- `id`
- `aggregate_type`
- `aggregate_id`
- `event_type`
- `payload_json`
- `created_at`
- `published_at`
- `attempts`
- `last_error`

## 5.4 群聊

### groups

- `id`
- `conversation_id`
- `owner_user_id`
- `name`
- `avatar_media_id`
- `announcement`
- `join_policy`
- `member_limit`
- `created_at`

### group_invites

- `id`
- `group_id`
- `token_hash`
- `created_by`
- `expires_at`
- `max_uses`
- `used_count`
- `revoked_at`

## 5.5 媒体

### media_objects

- `id`
- `owner_user_id`
- `storage_key`
- `original_name`
- `mime_type`
- `size_bytes`
- `sha256`
- `purpose`
- `status`
- `encryption_mode`
- `created_at`
- `deleted_at`

### media_variants

- `id`
- `media_id`
- `variant_type`
- `storage_key`
- `mime_type`
- `size_bytes`
- `width`
- `height`
- `duration_ms`

## 5.6 通话

### calls

- `id`
- `conversation_id`
- `initiator_user_id`
- `type`
- `status`
- `livekit_room_name`
- `started_at`
- `answered_at`
- `ended_at`
- `end_reason`

### call_participants

- `call_id`
- `user_id`
- `device_id`
- `status`
- `joined_at`
- `left_at`

## 5.7 朋友圈

### moments

- `id`
- `author_user_id`
- `text`
- `visibility_type`
- `visibility_rule_json`
- `created_at`
- `deleted_at`

### moment_media

- `moment_id`
- `media_id`
- `sort_order`

### moment_likes

- `moment_id`
- `user_id`
- `created_at`

### moment_comments

- `id`
- `moment_id`
- `author_user_id`
- `reply_to_comment_id`
- `reply_to_user_id`
- `content`
- `created_at`
- `deleted_at`

## 5.8 QR 与登录

### qr_login_sessions

- `id`
- `token_hash`
- `status`
- `requesting_device_info_json`
- `scanned_by_user_id`
- `scanned_by_device_id`
- `expires_at`
- `confirmed_at`
- `consumed_at`

## 5.9 风控与审计

### reports

- `id`
- `reporter_user_id`
- `target_type`
- `target_id`
- `reason`
- `status`
- `assigned_admin_id`
- `resolved_at`

### audit_logs

- `id`
- `actor_type`
- `actor_id`
- `action`
- `target_type`
- `target_id`
- `reason`
- `request_id`
- `source_ip`
- `result`
- `created_at`

## 6. 索引建议

- `messages(conversation_id, sequence desc)`。
- `conversations(updated_at desc)`。
- `conversation_members(user_id, status)`。
- `contact_requests(receiver_user_id, status, created_at desc)`。
- `contacts(owner_user_id, created_at)`。
- `moments(author_user_id, created_at desc)`。
- `moment_comments(moment_id, created_at)`。
- `outbox_events(published_at, created_at)` 部分索引。
- `media_objects(owner_user_id, status, created_at)`。
- `audit_logs(created_at desc, actor_id)`。

消息表达到较大规模后按时间或会话哈希分区，但首版不提前分库分表。

## 7. 数据一致性

必须使用事务：

- 接受好友申请 + 建立双向联系人 + 建立/复用私聊。
- 创建消息 + 增加会话序号 + 更新最后消息 + 写 Outbox。
- 创建群 + 创建会话 + 添加群主成员。
- 删除用户的状态切换 + 撤销会话 + 写审计。

不允许跨数据库事务依赖 Redis 成功。Redis 更新失败应可重试和重建。

## 8. 数据保留

可配置：

- 验证码：分钟级。
- 扫码会话：分钟级。
- 未完成上传：小时级。
- 普通日志：天/周级。
- 审计日志：月/年级。
- 已删除媒体：宽限期后清理。
- 已注销用户：按法律和实例策略清理。

E2EE 消息的服务端密文保留策略与普通消息相同，但服务端无法恢复丢失的客户端密钥。

## 9. P4 当前实现快照（2026-08-08）

本节记录已经落地的正式实现，避免后续只看早期草案误判当前接口。

### 9.1 已落地表

Migration `000005_messaging` 已增加：

```text
messages
outbox_events
sync_events
message_local_deletions
```

关键约束：

- `messages(conversation_id, sequence)` 唯一，sequence 从会话原子递增得到。
- `messages(sender_device_id, client_message_id)` 唯一。
- 同一 `senderDeviceId + clientMessageId` 使用 PostgreSQL advisory transaction lock 串行化竞争窗口，重复请求返回原 message。
- 同一 DIRECT user pair 使用 advisory transaction lock + `direct_pair_key` 唯一键双保险。
- Message、conversation `last_sequence/last_message_id` 与 Durable Outbox 在同一事务提交。
- `sync_events(source_outbox_id, user_id)` 唯一，使 Dispatcher 重放不制造重复 Sync 事件。

### 9.2 正式 Messaging API

当前 OpenAPI 已正式包含：

```text
GET  /api/v1/conversations
POST /api/v1/conversations/direct
GET  /api/v1/conversations/{conversationId}
GET  /api/v1/conversations/{conversationId}/messages
POST /api/v1/conversations/{conversationId}/messages
POST /api/v1/conversations/{conversationId}/read
PATCH /api/v1/conversations/{conversationId}/preferences
GET  /api/v1/messages/{messageId}
POST /api/v1/messages/{messageId}/recall
DELETE /api/v1/messages/{messageId}/local
GET  /api/v1/sync?cursor=...
```

发送接口不接受客户端伪造 `senderUserId / senderDeviceId`；身份只来自 Access Token 对应的 `Principal`。

### 9.3 正式 Realtime 语义

```text
/ws                 = P0 PoC 兼容入口
/api/v1/realtime    = P4 正式鉴权入口
```

P4 hello 必须携带：

```json
{
  "type": "hello",
  "payload": {
    "clientId": "<device-id>",
    "accessToken": "<access-token>",
    "protocolVersion": "1",
    "lastEventId": 0
  }
}
```

服务端的 `event_available` **只表示“有增量可同步”**。客户端收到后调用 `/api/v1/sync?cursor=`；即使 WebSocket 提示丢失或断线，重连后的 cursor Sync 仍负责补账。

### 9.4 Outbox / Worker

`cmd/worker` 现已正式消费 `outbox_events`：

- `FOR UPDATE SKIP LOCKED` 并发领取。
- 至少一次处理。
- `sync_events` 唯一键幂等。
- 失败指数退避。
- 单条消费失败通过 SAVEPOINT 回到可提交状态，再记录 attempts / last_error / available_at。

开发环境 `run-auth-dev.ps1` 现在会统一启动 PostgreSQL / Redis / Mailpit / LiveKit，并构建启动 API 与 Worker；`stop-auth-dev.ps1` 会按状态文件只停止本轮脚本负责的进程/容器。LiveKit 开发端口为 signal `17880`、RTC TCP `17881`、RTC UDP `17882`、TURN UDP `13478`，并按自动检测到的 LAN IP 对 Android 真机开放 LocalSubnet。

### 9.5 Redis 跨节点实时唤醒

P4 现在已接入 Redis Pub/Sub 跨 API 节点事件总线。设计刻意不在 Redis 保存一份必须重建的 Presence 真相：

```text
API A 提交消息
→ 本机 Hub 唤醒本机接收者连接
→ Redis 发布 userId + event_available
→ API B/C/... 收到后只唤醒各自本机该 userId 的 Socket
→ 客户端调用 /api/v1/sync?cursor=...
```

因此：

- Redis 只做跨节点低延迟提示，不存聊天事实。
- Redis Pub/Sub 短暂断开期间的提示允许丢失；消息不会丢，因为 Durable Outbox / sync_events 在 PostgreSQL。
- Redis 连接被 `CLIENT KILL TYPE pubsub` 强杀后，go-redis 自动重连，后续提示恢复投递；已有真 Redis 集成测试。
- `/api/v1/system/ready` 在配置 `REDIS_URL` 时会包含 Redis readiness。

### 9.6 Flutter P4 交互现状

当前后端/客户端链路已接通：

```text
会话最后消息 / 未读 / 时间
按账号+设备持久化草稿
文字发送
断网待发送
单条立即重试 / 取消发送
回复（离线重试保留 replyToMessageId）
复制
撤回事件链
仅本地删除
历史 sequence cursor
当前聊天自动推进 read sequence
```

2026-08-08 已完成两轮聊天体验补强：

```text
Web 置顶 / 免打扰：修复 CORS PATCH/DELETE 预检，并在成功响应后本地立即 upsert 会话
已读 UI：Conversation 新增 peerLastReadSequence；对端关闭 readReceiptsEnabled 时返回 null
已读可见性：只有聊天页真正可见 + App resumed + 当前 route 才推进 read sequence，隐藏 IndexedStack 不算“正在阅读”
未读：主消息入口/会话行保留红色角标；Android 未读会话支持“标为已读”
PC/Web 键盘：Enter=发送、Shift+Enter=换行；输入法 composing 阶段不发送
Android IME：adjustNothing + viewInsets + 合成层 Transform，减少键盘动画驱动长消息列表反复 layout；点击聊天空白可收键盘
移动菜单：紧凑圆角 Action Sheet，危险删除为红色
Token：Access Token 到期前主动轮换；401 发送失败保留 pending 并触发 refresh，不丢 clientMessageId
通知：前台非当前会话使用软件内提醒；Windows/Android 进程存活后台使用本地系统通知，杀进程 Push 仍留 P10
头像：大图在客户端后台旋转/缩放/压缩后上传；点击对方头像进入资料页
通话：聊天入口复用 P0 Call/LiveKit；主开发环境已真正启动/配置 LAN LiveKit，重复 hangup 等同状态动作幂等
Unicode Emoji：基础选择器已接入输入区
撤回：移除 2 分钟硬限制及 RECALL_WINDOW_EXPIRED，自己的消息默认不限时
客户端：正式 Auth → 主壳，移动四入口、桌面窄导航+会话/聊天双栏、微信式灰底和白/浅绿气泡
```

仍未完成或仍需真人/协议收口：

```text
独立“已送达”确认
Emoji 最近使用
图片表情 / Sticker
GIF
图片消息
语音条
完整 SQLite 本地库
三端微信式 UI 逐页细节与 Telegram 级性能 Profile
```

因此 API 有字段或后端状态存在，仍不等价于对应产品能力已经完整验收。产品基线见 `docs/12-产品体验与UI功能基线.md`。

### 9.7 P4 专项负载基线

可重复执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\benchmark-p4.ps1
```

脚本自动启动所需 PostgreSQL / Redis（只停止自己启动的服务），执行 Migration 后验证：

```text
真实 PostgreSQL >= 100 msg/s
200 条 /api/v1/realtime 正式鉴权 WebSocket 同时在线并全部 Ping/Pong
Redis 两节点跨节点 event_available
强杀 Pub/Sub 连接后自动恢复后续事件投递
```

性能阈值不作为共享 CI Runner 的硬门禁，避免共享机器负载造成伪失败；功能正确性、Redis reconnect 和消息并发幂等仍有 CI / 集成测试门禁。

### 9.8 当前仍未完成

以下仍属于 P4 收口，不应从本节误判为完成：

- Flutter 完整会话/消息/联系人本地数据库和正式迁移链；当前本地持久化重点仍是 Sync cursor、待发送队列与草稿。
- Golden 视觉基准与真人 Windows / Android 双端 E2E Checkpoint。
