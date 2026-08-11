# ADR-010：二维码采用实例绑定 Payload + 服务端一次性凭证

## 状态

Accepted

## 日期

2026-08-11（对 P9 当前实现补录）

## 背景

DD 需要个人二维码、群邀请二维码和 PC/Web 扫码登录。二维码图像只是传输载体，不能把“扫到字符串”本身当授权。

主要风险：

- 跨实例误识别；
- 群 invite 重放；
- 登录 nonce 被 proxy/access log 记录；
- QR 被截图后长期可用；
- A 扫描后 B 抢确认；
- approve 后重复 consume 签发多套 Session；
- 群使用次数与实际成员写入发生双真相。

## 决策

### 个人码

使用带 DD scheme/version/instance 的 stable user payload。payload 中的 userId 只负责定位，资料与关系权限仍由 authenticated API 判断。

### 群二维码

服务端签发高熵随机 nonce，对应数据库 `group_qr_invites`：

- nonce 只保存 SHA-256；
- Owner/Admin 才能签发；
- expiresAt；
- revokedAt；
- maxUses/useCount；
- redeem 时重新检查 group active、Block、capacity；
- member 写入、Group Outbox、useCount 在同一 PostgreSQL transaction。

### QR 登录

服务端创建 `qr_login_sessions`：

```text
PENDING
→ SCANNED
→ CONFIRMED | REJECTED
→ CONSUMED | EXPIRED
```

规则：

- 原始 nonce 只返回创建端/二维码，不落数据库；
- DB 只存 SHA-256；
- nonce 通过 POST JSON body，不进入 URL path/query；
- target origin + target device name/platform/appVersion 固化在 challenge；
- 扫码后绑定当前 authenticated scanner user/device；
- confirm 必须来自同一 scanner user/device；
- target new device Session 创建与 consume 同一 transaction；
- consume 一次后永久不能第二次签发。

## 客户端

QR renderer/scanner library 只负责“画/读二维码”，不负责授权。

当前 Flutter 使用：

```text
qr_flutter
mobile_scanner
```

Windows 不伪装 Camera Scanner 支持；允许手动粘贴/解析 payload 作为桌面兜底。

## 当前状态

服务端：`IMPLEMENTED + AUTO-VERIFIED`。

Flutter：代码已实现；2026-08-11 的 QR 定向 analyzer/tests/build 阻断已修复并有通过证据。2026-08-12 本轮全 App analyzer/test 也已重新通过；当前 worktree 仍需真实扫码、跨设备登录与生产发布链验收，但不再被 Shell/Sticker analyzer 回归阻断。

## 后果

优点：

- 可审计；
- 可过期/撤销；
- 抗重放；
- secret 不进入 URL log；
- 状态与授权由服务端控制。

成本：

- 扫码登录必须轮询/状态机；
- 多一步手机确认；
- QR 客户端与服务端实例信息必须一致。
