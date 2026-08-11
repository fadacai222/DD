# Push Provider 生产运维手册

> 范围：FCM / APNs / UnifiedPush 的凭据、健康、失败诊断、失效 endpoint、积压与真实设备验收。
>
> 原则：服务端已经存在 Push 业务发送主链，本手册只描述如何安全运营现有实现，不重新定义 Push 架构。

## 1. 生产 Secret 配置

Worker 支持现有 `appconfig.ReadSecret` 约定：优先使用 `*_FILE` 从文件注入 Secret；生产环境不要把完整凭据写进 Compose、Git、日志或聊天截图。

### FCM

推荐配置：

```text
FCM_SERVICE_ACCOUNT_JSON_FILE=/run/secrets/fcm_service_account_json
```

文件内容是 Firebase/Google service-account JSON。当前实现使用 FCM HTTP v1，并在 Worker 内按需获取 OAuth access token。

不要提交：

- service-account JSON；
- private_key；
- client_email 对应私钥材料；
- OAuth access token。

### APNs

推荐配置：

```text
APNS_KEY_ID=<Apple Key ID>
APNS_TEAM_ID=<Apple Team ID>
APNS_BUNDLE_ID=<DD iOS bundle id>
APNS_PRIVATE_KEY_FILE=/run/secrets/apns_private_key
```

`APNS_PRIVATE_KEY_FILE` 保存 `.p8` 私钥正文。Key ID / Team ID / Bundle ID 不是私钥，但也应作为生产配置管理，避免散落在多份脚本里。

### UnifiedPush

当前 UnifiedPush endpoint 由客户端注册，服务端不会保存额外全局 provider secret。endpoint 本身属于敏感投递地址，不得进入 metrics label 或普通日志。

## 2. 凭据轮换

### FCM rotation

1. 在 Google/Firebase 侧创建新的 service-account key，旧 key 暂时保留。
2. 将新 JSON 写入新的受限 secret 文件，文件权限仅允许运行 DD 的账户读取。
3. 原子替换 `FCM_SERVICE_ACCOUNT_JSON_FILE` 所指向的内容/挂载，滚动重启 Worker。
4. 确认：
   - `dd_push_provider_configured{provider="FCM"} == 1`；
   - `dd_push_provider_auth_failures_total{provider="FCM"}` 不继续增长；
   - `dd_push_provider_last_success_timestamp_seconds{provider="FCM"}` 在真实测试 Push 后更新。
5. **真人设备确认新凭据可投递后**再撤销旧 key。

不要先删旧 key 再试新 key，否则一次格式/权限错误会直接造成全部 FCM 离线通知中断。

### APNs rotation

1. 创建新的 APNs signing key，并保留旧 key。
2. 更新 `APNS_KEY_ID` 与 `APNS_PRIVATE_KEY_FILE`；Team ID / Bundle ID 继续核对目标 App。
3. 滚动重启 Worker。
4. 观察 `dd_push_provider_auth_failures_total{provider="APNS"}` 与 provider request result。
5. 在真实 iPhone 上完成 Sandbox/Production 对应环境测试后再撤销旧 key。

APNs `.p8` key 自身不是“每小时过期”；Worker 每次按 Apple token 规则生成 provider JWT。被撤销的 key、错误 Key/Team/Bundle、系统时钟异常等都可能表现为 APNs 认证失败。

## 3. Provider 健康判断

以下指标是首选入口：

```text
dd_push_provider_configured{provider="FCM|APNS|UNIFIEDPUSH"}
dd_push_provider_requests_total{provider,result}
dd_push_provider_duration_seconds{provider}
dd_push_provider_auth_failures_total{provider}
dd_push_provider_last_success_timestamp_seconds{provider}
dd_push_provider_last_failure_timestamp_seconds{provider}
dd_push_invalid_endpoint_ratio{provider}
dd_push_jobs{state="queued|retry_waiting|failed_recent"}
dd_push_oldest_pending_seconds
dd_push_retries_total
dd_push_failed_total
```

注意：`configured=1` **只说明 Worker 加载了该 provider**，不代表真实凭据一定有效。真正的 provider 健康至少需要最近有成功/可接受结果，并且认证失败与重试率没有异常上升。

推荐 PromQL：

```text
sum by (provider,result) (rate(dd_push_provider_requests_total{job="dd-worker"}[10m]))
```

```text
rate(dd_push_provider_auth_failures_total{job="dd-worker"}[10m])
```

```text
max(dd_push_oldest_pending_seconds{job="dd-worker"})
```

## 4. Credential failure

### FCM

优先看：

- `result="auth_failure"`；
- `dd_push_provider_auth_failures_total{provider="FCM"}`；
- Worker 结构化错误日志。

常见方向：

- service-account key 已撤销；
- JSON 文件内容错误/权限错误；
- Google OAuth 返回 400/401/403；
- 主机时间明显漂移；
- service account 没有目标 Firebase 项目发送权限；
- service-account project 与客户端 Firebase 项目不一致。

**不要**为了排障打印完整 JSON、private key 或 OAuth token。

### APNs

常见方向：

- `APNS_KEY_ID` / `APNS_TEAM_ID` / `APNS_BUNDLE_ID` 不匹配；
- `.p8` key 被撤销；
- Sandbox / Production endpoint 环境不匹配；
- provider token 被 Apple 判定无效/过期；
- 主机系统时间错误。

APNs HTTP 403 会被归入 `auth_failure`，用于正式告警。

Worker 对 provider 级故障有一条重要保护：FCM/APNs authentication failure，以及 provider 明确标记的 retryable 网络/429/5xx，不会累计到设备 endpoint 的 `failure_count`，避免一次凭据失效或 provider outage 把大量正常设备误 DISABLED。FCM/APNs 只有 adapter 明确判断为 InvalidToken 时才会污染 endpoint 状态；UnifiedPush 的 capability URL 是逐设备 endpoint，因此重复永久 4xx 仍可按 endpoint failure 处理。

## 5. Invalid endpoint 生命周期

现有发送链的处理顺序：

```text
provider 明确返回 InvalidToken
→ device_push_endpoints.status = INVALID
→ 后续 Push 查询立即排除该 endpoint
→ 保留失败时间/失败码用于诊断
→ INVALID 满 30 天后 Worker 每小时最多物理删除 500 条
```

这意味着失效 token **不会继续被反复发送**，但也不会在 provider 第一次拒绝时立即硬删除，便于短期诊断和指标统计。

客户端重新取得有效 token 并重新注册同一 device/provider 时，现有注册逻辑会重新写入 ACTIVE endpoint、清零 failure_count。

`dd_push_invalid_endpoint_ratio{provider=...}` 如果长期升高，应优先确认：

1. App 是否正确处理 token refresh；
2. 用户是否大规模卸载/重装；
3. Firebase/APNs 环境是否错配；
4. 某次客户端版本是否注册了错误 token。

## 6. Backlog

告警入口：`DDPushBacklog`。

先看：

```text
sum by (state) (dd_push_jobs{job="dd-worker"})
```

```text
max(dd_push_oldest_pending_seconds{job="dd-worker"})
```

```text
time() - dd_worker_last_heartbeat_timestamp_seconds{job="dd-worker"}
```

然后区分：

- Worker heartbeat 停止：先查 Worker 进程/DB；
- `retry_waiting` 上升：看 provider 网络/认证/5xx/限流；
- `queued` 上升但 provider 没请求：查 Outbox、DB 锁等待和 Worker 错误；
- FCM/APNs 单一 provider 失败：不要把 UnifiedPush 或其他 provider 一起重启/旋转；
- 全 provider 同时失败：优先查 Worker 出网、DNS、时间、数据库和宿主机资源。

数据库只做聚合排障时可使用：

```sql
SELECT status, attempts, count(*)
FROM push_jobs
GROUP BY status, attempts
ORDER BY status, attempts;
```

不要查询/导出 `device_push_endpoints.endpoint` 去做普通统计；endpoint 是敏感投递地址。

## 7. Delivery / click correlation 的真实边界

当前可以证明的是：

- Worker 是否成功调用 provider；
- provider API 是否接受请求；
- provider 返回 InvalidToken / retryable / auth 等哪一类结果；
- job 是否 SENT / retry / DROPPED；
- 客户端 Push payload 中的 event/resource/conversation 信息可用于点击后恢复业务页面。

当前**不能**宣称：

- FCM/APNs API 返回成功就等于手机一定收到；
- 手机一定展示通知；
- 用户一定点击；
- 服务端已经能把 provider Message ID 与客户端 click receipt 一一关联。

当前 provider `MessageID` 并未持久化为业务 delivery receipt，客户端也没有向服务端提交正式 click receipt。因此完整的“provider accepted → device delivered/displayed → user clicked”链路仍是：

```text
HUMAN-PENDING
```

需要真实 Android FCM 与真实 iPhone APNs 环境完成前台、后台、系统杀进程、网络切换等真人验收。没有真实设备时，不得把 mock/provider HTTP 200 写成 delivery success。

## 8. 隐私与日志红线

Prometheus label 禁止出现：

- userId / deviceId；
- requestId；
- messageId / conversationId；
- endpoint/token；
- Access/Refresh Token；
- FCM/APNs secret；
- message content；
- raw URL / 原始错误字符串。

当前 Push metrics 只使用固定 provider 与固定结果枚举。错误详情留在受控结构化日志，且不得新增打印 credential/endpoint 的调试日志。
