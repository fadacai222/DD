# DD 管理后台：Telegram Sticker Relay 配置

## 目标

生产 API 镜像内置 DD Admin Web，并由同一个 API 服务托管：

```text
https://<DD_API_DOMAIN>/admin/
```

不新增公网端口。BaoTa/Nginx 模式继续只把 API 域名反代到 `127.0.0.1:18473`；`/admin/` 与 `/api/v1/admin/*` 同源。

## 数据库与 Secret

`000037_admin_integrations` 新增 `admin_integration_secrets`。

Telegram Bot Token 的规则：

- 页面只接受新 Token，不回显已有 Token；
- 保存前通过 Telegram `getMe` 验证；
- 只有 `SUPER_ADMIN` 可以修改；
- 所有修改要求 Admin CSRF，并写入 Admin Audit；
- Token 使用 `ADMIN_SECURITY_SECRET` 派生的独立 `dd-admin-integration-secret-v1` 加密域进行 AES-GCM 加密；
- 数据库保存密文，不保存明文 Token；
- 后台数据库配置优先于旧 `TELEGRAM_BOT_TOKEN[_FILE]`；
- 保存成功后当前 API 进程立即热切换 Relay Provider；重启后会从数据库恢复该配置。

当前正式 Production Compose 是单 API 实例。未来如果扩成多 API 副本，需要增加跨节点配置刷新/广播，不能假定一次 HTTP 更新会瞬时修改其它进程内存。

## 第一次创建管理员

生产服务已经部署并且 API 正常运行后：

```bash
cd /opt/dd/infra/prod
bash scripts/create-admin.sh admin@example.com SUPER_ADMIN
```

脚本会在终端中静默读取两次管理员密码，不把密码写进命令行历史。密码至少 14 个字符。

创建成功后访问：

```text
https://<DD_API_DOMAIN>/admin/
```

第一次登录会进入 TOTP MFA 绑定流程，并生成一次性 Recovery Codes。Recovery Codes 只在生成当次显示，应离线保存。

## 配置 Telegram Bot Token

登录后台后：

```text
集成服务
→ Telegram Sticker Relay
→ 设置 Bot Token
→ 验证并保存
```

成功时页面会显示：

- 已配置；
- 配置来源：后台加密配置；
- 最近修改时间；
- Telegram Bot username / ID。

页面不会显示 Bot Token 本身。

可以点击“测试当前配置”，服务端会用当前内存中的 Token 调用 Telegram `getMe`。

## 失败判断

常见错误：

```text
TELEGRAM_BOT_TOKEN_INVALID
```

Telegram 拒绝 Token 或格式非法。

```text
TELEGRAM_PROVIDER_UNAVAILABLE
```

Telegram Bot API 网络不可达、超时或响应异常。

```text
TELEGRAM_RELAY_NOT_CONFIGURED
```

当前没有环境 Secret，也没有后台数据库配置。

```text
ADMIN_FORBIDDEN
```

当前管理员不是 `SUPER_ADMIN`，不能修改 Token。

## 部署验证

代码门禁至少包括：

```text
server: go test ./...
server: go vet ./...
admin:  npm audit --audit-level=high
admin:  npm run typecheck
admin:  npm run build
OpenAPI: Redocly recommended-strict
Production Compose: docker compose config
API Docker image: admin web + adminctl must be present
```

不要用 Vite dev server 作为生产后台。生产只使用编译后的 `/app/admin` 静态文件。
