# DD Admin Control Plane

状态：`IMPLEMENTED / AUTO-VERIFIED / HUMAN-PENDING`

## 入口与技术栈

生产入口仍与 API 同源：

```text
https://<DD_API_DOMAIN>/admin/
```

前端继续使用 Vite + React 19，在现有 Admin Auth/MFA/RBAC/CSRF 上引入 Refine + Ant Design 作为开源管理后台骨架，不迁移到独立 Umi 服务，也不新增公网端口。

## 当前页面

- 运营总览：用户、注册、在线近似口径、活跃设备、消息、通话、群组、Moments、媒体、Push/STT/Outbox 队列与 14 天趋势；
- 用户管理：资料、好友/群/消息/Moments 统计、设备、活跃会话、Push endpoint 状态、冻结/解冻；
- 群组管理：群元数据、成员规模、创建者、加入方式、状态；
- 朋友圈治理：作者、正文、可见性、状态、媒体/点赞/评论统计；
- 媒体与存储：READY/UPLOADING/FAILED/QUARANTINED/DELETED、过期未完成上传、按 purpose 占用；
- Push 运营：队列、重试、24h sent/dropped、endpoint provider/status；
- LiveKit/RTC：DD 权威通话状态、群通话参与者；
- 服务健康：API/PostgreSQL/Redis readiness；其它依赖严格区分 `CONFIGURED` 与 `UNKNOWN`；
- 举报治理、管理员审计筛选、管理员会话；
- 管理员账号：创建、角色/状态、MFA reset；
- 集成服务：Telegram Sticker Relay Token 加密配置与 getMe 验证；
- 系统设置：运行时注册 `open/closed`。

## 安全边界

1. 普通 DD Bearer Token 不能访问 `/api/v1/admin/*`。
2. Admin 写操作必须同时满足 Admin Session + CSRF + RBAC。
3. `SUPER_ADMIN` 不能通过后台把自己禁用/降权；系统不允许移除最后一个 ACTIVE `SUPER_ADMIN`。
4. MFA reset 不能对当前管理员自己执行；reset 会清 TOTP/Recovery Code/未消费 challenge 并撤销目标全部 Admin Session。
5. Telegram Bot Token 不回显，使用 Admin Security Secret 派生独立加密域落库。
6. DB/Redis/SMTP/FCM/APNs/S3/STT/Admin Security Secret 等凭据不进入通用 Web 设置页。
7. 不提供 Web Shell、SQL Console、Redis Console、任意对象浏览/删除或按用户 ID 任意 Push 群发。
8. 群组/朋友圈治理当前只读；强制解散/下架必须复用正式业务状态机和 outbox 后再开放，不直接手写破坏性 SQL。

## 运行时注册开关

`000038_admin_runtime_settings` 持久化 Admin override。

- `closed -> open` 只有 EMAIL_CODE_PEPPER + SMTP 初始化完成时允许；
- 切换会立即影响 Auth `SendRegistrationCode/Register`；
- `/api/v1/instance` 返回当前真实运行模式；
- 若数据库期望 `open` 但某次重启 SMTP/验证码依赖缺失，API 保持 fail-closed，不因该配置整个启动失败；后台显示“持久化期望值 != 当前运行值”。

## 健康状态口径

- `UP/DOWN`：API 真实执行了 readiness check；
- `CONFIGURED/NOT_CONFIGURED`：只能证明配置或服务初始化存在；
- `UNKNOWN`：API 当前没有足够证据证明运行状态。

尤其：TURN 配置存在/端口可达不能证明真实 relay 成功，因此在接入远端探针或真实媒体会话证据前不得显示为 `UP`。

## 上线后真人验收

1. SUPER_ADMIN 登录、TOTP、侧栏路由与刷新；
2. Dashboard 数据与数据库抽样核对；
3. 用户详情/冻结/解冻及审计记录；
4. 管理员创建、角色变更、禁用、最后一个 SUPER_ADMIN 保护、MFA reset；
5. Telegram Token 保存/测试/重启后恢复；
6. 注册 closed/open 实际发送验证码与注册；依赖缺失时 open 必须拒绝；
7. PostgreSQL/Redis 故障时健康页状态变化；
8. 手机/桌面宽度下页面与表格可用。

自动测试通过只能标 `AUTO-VERIFIED`，完成以上生产操作前不得写成人工验收通过。
