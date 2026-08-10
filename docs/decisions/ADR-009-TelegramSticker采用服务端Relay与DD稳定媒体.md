# ADR-009：Telegram Sticker 采用服务端 Relay，并转换为 DD 稳定媒体

## 状态

Accepted

## 日期

2026-08-10（对现有实现补录）

- 当前实现复核：2026-08-11

## 背景

DD 希望支持用户导入 Telegram Sticker Pack，但不能把 Telegram Bot Token 暴露给客户端，也不能让聊天消息长期依赖 Telegram CDN/file path。

直接由客户端访问 Telegram Provider 还会带来：

- Bot Token 泄漏。
- provider URL 生命周期不受 DD 控制。
- 多端行为不一致。
- 难做发送权限。
- 用户退出 Telegram/Provider 变化会破坏历史消息。

另一方面，如果服务端提供“给我任意 URL，我帮你下载并转存”的接口，会直接形成 SSRF/代理攻击面。

## 决策

Telegram Sticker Pack 使用：

```text
Telegram link/deep link
→ Client extracts validated setName
→ DD API receives only setName
→ Server Telegram Bot Provider
→ getStickerSet/getFile
→ download provider bytes
→ write DD private object storage
→ create stable DD mediaId
→ cache pack/items globally
→ create per-user subscription
```

DD 聊天消息只引用 DD `mediaId`。

## 客户端只提交 setName

允许：

```text
MyPack_by_bot
```

拒绝：

```text
https://arbitrary-internal-url/
file:///...
http://169.254.169.254/...
```

服务端不提供任意 URL fetch 参数。

## Bot Token

```text
TELEGRAM_BOT_TOKEN / TELEGRAM_BOT_TOKEN_FILE
```

只存在服务端。

绝不：

- 打包到 Flutter。
- 返回给客户端。
- 写进日志。
- 拼到持久业务 URL。

## Provider 可选

Telegram Provider 没配置时：

```text
Custom Sticker = 继续可用
Telegram Import = 明确 PROVIDER_NOT_CONFIGURED/等价错误
```

不能因为 Telegram Token 缺失让整个 Sticker Service 变 unavailable。

## Pack 全局缓存 + 用户订阅

同一个 Telegram set：

```text
telegram_sticker_packs         global metadata/cache
telegram_sticker_items         global item → DD media
user_sticker_packs             per-user subscription
```

优点：

- 多用户不重复下载同一 Pack。
- 历史消息引用稳定。
- 用户 unsubscribe 不影响其他订阅者。

## 当前格式支持

稳定基线：

```text
static image/webp
```

TGS/WebM：

- 记录 unsupported。
- 不显示假成功 item。
- 后续有独立转码/渲染策略后再启用。

## 发送权限

“用户收到过某 Sticker”不等于“用户拥有发送权”。

发送 STICKER message 时服务端需要确认当前用户：

- own custom sticker；或
- subscribe 对应 Telegram pack；或
- 未来其它明确授权来源。

否则拒绝 media reuse。

## 下载权限

接收者为了查看历史消息，必须能下载消息引用的 Sticker media。

因此“read authorization”和“send authorization”是两件事：

```text
read: conversation/message membership may authorize
send: own library/subscription authorizes reuse
```

不能混成一个 owner 检查。

## Rate Limit

Telegram Import 是外部 provider 调用，应做：

- per-user rate limit。
- bounded pack item count。
- bounded file size。
- provider timeout。
- retry/backoff。

当前 schema 已有：

```text
sticker_rate_events
scope = TELEGRAM_IMPORT
```

## Cleanup

用户最后一个 subscription 删除后，也不能立刻无条件删 pack/media。

先确认：

- 没有其它 subscriber。
- 没有 message_media/history reference。
- 没有 custom/其它业务 reference。

再进入延迟 cleanup。

## 备选方案

### 客户端直接 Telegram API

拒绝：Secret、跨端、稳定性、历史引用都差。

### 直接保存 Telegram CDN URL

拒绝：URL 生命周期和访问策略不属于 DD。

### 服务端任意 URL 代理

拒绝：SSRF 高风险。

## 后果

正面：

- 用户可获得 Telegram Pack 导入体验。
- DD 历史消息不依赖 provider URL。
- Secret 只在服务器。
- 多用户复用缓存。

成本：

- 服务端承担 provider 下载与对象存储空间。
- 需要版权/provider policy 注意。
- 动态 TGS/WebM 需要后续支持。

## 约束

- Provider 下载逻辑必须严格限制 Telegram 官方 API/file endpoint。
- 所有 provider input/response 视为外部不可信数据。
- 新增其它 Sticker Provider 时必须复用“provider adapter → DD stable media”原则，必要时另写 ADR。
