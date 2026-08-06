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
  "inviteCode": null
}
```

登录响应：

```json
{
  "data": {
    "accessToken": "short-lived-token",
    "expiresIn": 900,
    "refreshToken": "native-client-only",
    "user": {},
    "device": {}
  }
}
```

Web 客户端 Refresh Token 不返回 JSON，使用 HttpOnly Cookie。

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
GET   /api/v1/me
PATCH /api/v1/me/profile
PATCH /api/v1/me/privacy
GET   /api/v1/users/{userId}
GET   /api/v1/users/by-handle/{handle}
POST  /api/v1/me/avatar/upload
POST  /api/v1/me/export
POST  /api/v1/me/deletion-request
DELETE /api/v1/me/deletion-request
```

搜索不提供无上限 `GET /users?q=`，避免账号枚举。模糊搜索需单独权限、限流和最小查询长度。

## 3.5 Contacts

```text
GET    /api/v1/contacts
GET    /api/v1/contact-requests?direction=incoming
POST   /api/v1/contact-requests
POST   /api/v1/contact-requests/{requestId}/accept
POST   /api/v1/contact-requests/{requestId}/reject
DELETE /api/v1/contact-requests/{requestId}
PATCH  /api/v1/contacts/{userId}
DELETE /api/v1/contacts/{userId}
POST   /api/v1/blocks
DELETE /api/v1/blocks/{userId}
GET    /api/v1/blocks
```

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
- `status`
- `created_at`
- `resolved_at`

唯一约束避免同方向重复待处理申请。

### contacts

建议每个方向各一行，便于存备注和标签：

- `owner_user_id`
- `contact_user_id`
- `remark`
- `is_starred`
- `created_at`

### blocks

- `owner_user_id`
- `blocked_user_id`
- `created_at`

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
