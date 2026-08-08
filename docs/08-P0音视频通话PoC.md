# P0 音视频通话 PoC

## 目标

验证自托管一对一音视频通话的最小闭环：

1. Go 服务端持有 LiveKit API Secret，并签发短期、房间级 JWT。
2. Flutter 客户端仅接收短期 Token，不接触 API Secret。
3. Windows、Web、Android 共用同一套房间、麦克风、摄像头和远端轨道逻辑。
4. 本地 LiveKit 能完成房间加入、信令、ICE 协商和媒体发布。
5. 失败、重连、挂断时能够释放房间、摄像头、麦克风和监听器。

## 当前实现

### Go Token API

接口：

```text
POST /api/calls/token
Content-Type: application/json
```

请求：

```json
{
  "room_name": "call-demo",
  "participant_identity": "user-001",
  "participant_name": "测试用户"
}
```

响应：

```json
{
  "server_url": "ws://127.0.0.1:7880",
  "participant_token": "短期JWT",
  "expires_at": "RFC3339时间"
}
```

安全边界：

- 默认有效期 15 分钟，最长限制为 1 小时。
- Token 只允许加入指定房间、发布和订阅媒体。
- 禁止发布 Data Track。
- 房间号和身份限制为 1-64 位安全 ASCII 标识符。
- 显示名称限制为 1-80 个 Unicode 字符，拒绝控制字符。
- 请求体限制 4 KiB，并拒绝未知字段和多余 JSON 对象。
- API Secret 只存在于服务端环境变量。

### 双端呼叫信令

新增一对一呼叫状态流：

```text
呼叫方创建通话
  -> 被叫方收到 call.incoming
  -> 被叫方接听或拒绝
  -> 双方收到 call.updated
  -> 接听后双方领取受限 LiveKit Token
  -> 自动进入同一个媒体房间
  -> 任一端挂断后双方同步结束并释放媒体
```

接口：

| 方法 | 路径 | 用途 |
|---|---|---|
| `POST` | `/api/calls` | 创建语音或视频呼叫 |
| `GET` | `/api/calls/active` | 上线或重连后恢复当前通话 |
| `POST` | `/api/calls/{id}/actions` | 接听、拒绝、取消或挂断 |
| `POST` | `/api/calls/{id}/token` | 接听后签发当前通话房间的受限 Token |

当前 PoC 已处理：

- 呼叫方与被叫方状态同步。
- 被叫方实时来电事件。
- 接听、拒绝、呼叫前取消和通话中挂断。
- 单用户忙线冲突，阻止同时加入两通电话。
- 非通话参与者操作和领取 Token 时返回拒绝。
- 信令断线期间漏掉事件时，重连后通过活动通话接口恢复状态。
- 默认 45 秒无人接听自动超时，双方同步结束并释放忙线状态。
- 媒体连接失败时尽力同步挂断，避免另一端长期卡在通话中。

### Flutter 通话调试台

路径：`clients/app/lib/features/calls/`

功能：

- Token API 地址、房间号、身份和显示名称配置。
- 加入/离开房间。
- 加入后可选择自动开启麦克风和摄像头。
- 麦克风静音/恢复。
- 摄像头开启/关闭。
- 前后摄像头切换。
- 本地视频和多个远端视频网格。
- 参与者加入/离开、轨道订阅和媒体重连日志。
- 离开页面或挂断时释放 Room、监听器和本地媒体。

Flutter 入口增加了模块选择页：

```text
实时通信
音视频通话
双端通话
```

## 本地服务

配置：`compose.call-poc.yml`

默认端口：

| 端口 | 用途 |
|---|---|
| `127.0.0.1:18473` | Go Token API 与实时通信 API |
| `127.0.0.1:7880` | LiveKit HTTP/WebSocket 信令 |
| `127.0.0.1:7881` | LiveKit RTC TCP |
| `127.0.0.1:7882/udp` | LiveKit 本地 RTC UDP |
| `127.0.0.1:3478/udp` | LiveKit 内置 TURN/UDP 入口 |
| `127.0.0.1:30000-30019/udp` | TURN relay allocation 端口范围 |

本地 Docker PoC 必须显式让 LiveKit 公布 `127.0.0.1` 作为节点地址，并固定 UDP 端口 `7882`。否则 LiveKit 可能向浏览器下发 Docker 内网地址（例如 `172.18.x.x:7882`），导致 Web 端信令已连通但 ICE/PeerConnection 超时。当前 Compose 使用 `--node-ip 127.0.0.1 --udp-port 7882`，自动媒体测试也会检查该运行时配置。

开发凭据：

```text
API Key: devkey
API Secret: secret
```

这些凭据只允许用于本地 PoC，禁止用于公网或生产部署。

启动：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-call-poc.ps1
```

停止：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop-call-poc.ps1
```

### Windows ↔ Web 本机跨端验收

先构建并启动 Web Release 静态站点：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-web-client.ps1
```

脚本会：

- 构建最新 Web Release。
- 从 `10000-65535` 随机选择未占用端口。
- 仅绑定 `127.0.0.1`，不向局域网公开调试站点。
- 记录 PID 和端口到 `.data/web-client.json`。
- 不自动打开浏览器；终端会打印需要手工打开的 URL。

已有最新 Web 构建时可跳过重新构建：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-web-client.ps1 -SkipBuild
```

停止 Web Release：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop-web-client.ps1
```

停止脚本只会结束状态文件记录且命令行仍匹配 `http.server` 的精确 PID，避免误杀 PID 复用后的其他进程。

### Windows ↔ Android 真机 LAN 验收

Android 真机不能使用 `127.0.0.1` 访问电脑。项目提供独立 LAN PoC 模式，不改变默认 localhost 模式：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-call-poc-lan.ps1
```

当前脚本会：

- 自动选择带默认网关、状态为 Up 的私网 IPv4，过滤 VMware/WSL 等无默认网关虚拟地址；也可通过 `-LanIP 192.168.x.x` 显式指定。
- 同时保留 localhost 和 LAN 端口映射。
- LiveKit 使用电脑 LAN IP 作为 `node-ip`，固定 RTC TCP `7881`、UDP `7882`，并启用内置 TURN/UDP `3478`。
- TURN relay allocation 固定为 UDP `30000-30019`，避免只开放 3478 但实际 relay 端口无法进入容器。
- LiveKit 1.12+ 默认限制 TURN 转发到私网 peer；LAN PoC 通过 `allow_restricted_peer_cidrs` 仅放行当前 SFU LAN IP `/32`，不开放整个局域网。
- Windows 防火墙仅允许 `Private` Profile + `LocalSubnet` 访问 TCP `18473/7880/7881` 与 UDP `3478/7882/30000-30019`。
- 首次创建/删除防火墙规则时会触发管理员 UAC；不会开放 Public Profile。
- 将 LAN 地址写入 `.data/call-poc-lan.json`，便于停止时精确清理。

本机当前验证地址为 `192.168.6.158`；实际使用时以脚本打印结果为准。Android 客户端“服务地址”填写：

```text
http://<电脑LAN-IP>:18473
```

停止 LAN 模式并删除防火墙规则：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop-call-poc-lan.ps1
```

Android Debug APK 一键安装：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-android-debug.ps1 -SkipBuild -Launch
```

安装脚本会拒绝无授权设备和多设备场景，避免 APK 安装到错误目标。

### Windows / Web / Android 三端联合验收

一条命令同时准备 LAN 通话服务与 Web Release：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-call-poc-crossplatform.ps1 -SkipWebBuild
```

脚本会复用启动前已经存在的 Web/LAN 服务，只启动缺失组件；对应停止脚本只清理它自己启动的资源：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop-call-poc-crossplatform.ps1
```

推荐身份：Windows=`alice`、Web=`bob`、Android=`charlie`。2026-08-08 本轮 Windows / Web / Android 联合人工验收已全部通过。

### WebRTC / TURN relay-only 诊断

“音视频通话 PoC”页面新增 `检查 WebRTC / TURN` 按钮。它会申请短期 LiveKit Token，并依次执行 WebSocket、WebRTC、TURN 三项诊断。当前 `livekit_client 2.10.0` 的 TURN 检查会把 ICE transport policy 强制设为 `relay`，因此只有真正建立 TURN relay 才会显示成功；普通 host/srflx 直连成功不能冒充 TURN 成功。

本地 PoC 已启用 LiveKit 内置 TURN/UDP `3478`；生产 TURN/TLS 仍是独立验收项，不能用本地 TURN/UDP 结果代替。

自动媒体测试：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-call-poc.ps1
```

该测试会：

1. 临时停止旧实时 PoC。
2. 启动 Go Token API 和 LiveKit。
3. 验证健康接口和 JWT 签发。
4. 使用官方 `lk` CLI 加入房间并发布内置演示视频。
5. 等待房间统计达到 `participants >= 1`、`publishers >= 1`。
6. 检查 LiveKit 日志中实际出现 `udp relay` TURN candidate。
7. 终止 CLI、关闭通话容器并恢复旧实时 PoC。

## 已通过验证

- Go Token、输入校验、JWT 权限和 CORS 单元测试：通过。
- Go 全量测试：通过。
- Flutter/Dart 静态分析：通过。
- Flutter 单元和 Widget Tests：20 项通过。
- LiveKit 根探针：通过。
- Token API 实际签发：通过。
- 官方 LiveKit CLI 实际加入房间：通过。
- 官方 LiveKit CLI 发布演示视频：通过。
- 房间统计：`participants=1`、`publishers=1`。
- Web Release：构建通过。
- Android Debug APK：构建通过。
- 双端信令集成测试：来电、接听、双方同步、忙线、越权和受限 Token 通过。
- 浏览器式跨域信令测试：带真实 `Origin` 的 WebSocket 握手、CORS 接听请求和双方状态同步通过。
- 不可信 HTTP Origin 在进入业务 Handler 前直接拒绝，避免跨站请求产生呼叫副作用。
- 信令重连后活动通话恢复测试：通过。
- LiveKit 内置 TURN/UDP `3478`：已启用；自动媒体测试观察到 `udp relay` candidate。
- 客户端 WebSocket/WebRTC/TURN relay-only 诊断：Windows / Web / Android 三端人工执行均通过。

## 人工验收记录

- 2026-08-07：Windows Release 构建通过。
- 2026-08-07：Windows 本机双客户端进入同一房间通过。
- 2026-08-07：远端人数更新、麦克风开关、摄像头开关和挂断通过。
- 2026-08-07：新版双端流程人工验收通过：身份校验、呼叫、来电、接听、拒绝、取消、挂断、45 秒超时和超时后再次呼叫均正常。
- 2026-08-07：Windows ↔ Web 真实浏览器媒体互通通过；修复 LiveKit 误公布 Docker `172.18.x.x` ICE 地址后，浏览器 PeerConnection 正常建立。
- 2026-08-07：Android LAN Docker 路径预验证通过：`192.168.6.158:18473` 与 `:7880` HTTP 探针均为 200，LiveKit 启动日志确认 `nodeIP=192.168.6.158`。
- 2026-08-07：Windows ↔ Android 真机媒体互通通过；呼叫/接听、音频、视频、静音、摄像头开关与挂断同步正常。
- 2026-08-08：用户确认 `人工测试清单.md` 本轮项目全部通过，包括 Web ↔ Android、Windows/Web/Android 三端 relay-only TURN、Android 后台/锁屏/短时断网恢复、蓝牙音频路由和窄屏布局。

## 尚未完成

- 公网 / CGNAT / 多运营商网络矩阵和生产 TURN/TLS 回退测试。
- 更激进的弱网、长时断网和服务端重启后的媒体恢复专项。
- iOS、macOS 和 Linux 构建与真机/真系统验收。
- 正式 Auth 会话与通话身份绑定、数据库持久化、离线推送和多设备来电仲裁。

开启 Windows 开发者模式：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\enable-windows-developer-mode.ps1
```

完成管理员确认后，关闭并重新打开 PowerShell、VS Code 和 Android Studio，再执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1 -Target windows
```

## 已知边界

1. P2 正式注册/登录/Access/Refresh Token 已开始落地，但当前 P0 呼叫接口还没有接入正式 Auth 会话，客户端仍可自行填写呼叫身份；最终 P7 通话必须改为从已认证 user/device 会话派生身份和权限。
2. 通话状态目前保存在 Go 进程内存中，服务重启会丢失；已有 45 秒 PoC 级自动超时，但没有数据库持久化、离线推送和未接来电历史。
3. 当前“响铃”是前台页面状态，没有系统铃声、后台来电通知、锁屏接听和多设备仲裁。
4. `LIVEKIT_URL=auto` 会根据请求 Host 推导本地 LiveKit 地址，只用于开发环境；生产必须配置固定的可信 `wss://` 地址。
5. 当前 Compose 已有开发级 TURN/UDP `3478` + relay `30000-30019/udp`，但没有生产级 TLS、TURN/TLS、高可用和公网 NAT 配置；LAN relay-only 验证不能替代公网 TURN/TLS 验收。
6. Android Debug 允许明文 HTTP；Release 默认禁止明文通信。
7. Windows 开发者模式属于 Flutter 原生插件构建前置条件，不是应用运行权限。

## 官方依据

- Flutter SDK：`https://github.com/livekit/client-sdk-flutter`
- Flutter 连接和媒体发布：`https://docs.livekit.io/home/client/connect/`
- LiveKit 本地运行：`https://docs.livekit.io/transport/self-hosting/local/`
- LiveKit CLI：`https://github.com/livekit/livekit-cli`
- 自托管端口：`https://docs.livekit.io/transport/self-hosting/ports-firewall/`
- 生产部署：`https://docs.livekit.io/transport/self-hosting/deployment/`
