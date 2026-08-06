# P0 实时通信 PoC

## 目标

验证首版实时通信最小闭环，不包含账号、数据库和聊天业务：

1. Go 服务端提供 `/health`、`/version`、`/ws`。
2. Flutter 客户端完成 HTTP 健康检查和 WebSocket 连接。
3. WebSocket 首包必须为 `hello`。
4. 服务端返回 `hello_ack` 并主动推送 `server_ready`。
5. 客户端支持 `ping/pong`、自动重连和事件 ID 去重。
6. 服务端默认拒绝跨域 WebSocket，仅允许显式配置的 Origin。
7. Windows、Web、Android 使用同一套 Dart 实时通信代码。

## 当前实现

### Go 服务端

路径：`server/`

- 默认端口：`18473`。
- `IM_PORT`：监听端口，限制为 `10000-65535`。
- `IM_ALLOWED_ORIGINS`：逗号分隔的 WebSocket Origin 模式。
- WebSocket 单消息上限：16 KiB。
- 连接 ID：128 位加密安全随机数。
- 事件序号：服务进程内全局递增，并以当前微秒时间初始化。
- 首包不是 `hello`、重复 `hello`、未知事件类型均返回结构化错误。
- 已补 `go.sum`，依赖可重复解析。

### 实时通信核心

路径：`clients/realtime_poc/`

该包被正式 Flutter App 通过 path dependency 引用：

- 调用 `/health`。
- 连接 `/ws` 并等待 `channel.ready` 后发送 `hello`。
- 发送最近事件游标。
- 断线后按 1、2、4、8、16、30 秒退避重连。
- 拒绝重复或倒序事件 ID。
- 支持 `ping/pong`。
- 客户端主动关闭使用 WebSocket 正常关闭码 `1000`。
- 提供一次握手冒烟测试和服务重启重连测试。

### 正式 Flutter 调试 App

路径：`clients/app/`

当前不是最终聊天 UI，而是三端实时通信调试台：

- 服务器地址输入。
- 健康检查。
- 连接、断开、发送 Ping。
- 连接状态、活动服务器和客户端 ID。
- 实时事件和错误日志。
- 日志最多保留 200 条。
- 桌面宽屏左右分栏，移动窄屏纵向排列。
- Android Release 默认禁止明文 HTTP；仅 Debug Manifest 允许本机 PoC 明文访问。
- 切换服务器前自动释放旧网关和 StreamSubscription。

## 协议示例

客户端首包：

```json
{
  "type": "hello",
  "requestId": "hello-001",
  "payload": {
    "clientId": "windows-test-client",
    "lastEventId": 0
  }
}
```

服务端确认：

```json
{
  "type": "hello_ack",
  "requestId": "hello-001",
  "eventId": 1,
  "payload": {
    "connectionId": "随机连接ID",
    "protocolVersion": "1"
  }
}
```

服务端主动事件：

```json
{
  "type": "server_ready",
  "eventId": 2,
  "payload": {
    "serverTime": "RFC3339时间"
  }
}
```

## 验证命令

### 完整质量检查

```powershell
cd C:\Users\admin\Desktop\复刻微信
powershell -ExecutionPolicy Bypass -File .\scripts\test-client.ps1
```

该脚本包含：

1. Go format、vet、test。
2. 实时通信包 format、analyze、test。
3. Flutter App format、analyze、Widget Test。
4. 临时启动 Go 服务端，执行真实 REST/WebSocket 握手和 Ping/Pong。
5. 检查服务和端口是否清理完成。

### 服务重启与自动重连

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-reconnect.ps1
```

脚本会：

1. 启动第一份 Go 服务。
2. Dart 客户端完成第一次 `server_ready`。
3. 强制停止服务端。
4. 等待客户端检测断线。
5. 启动第二份 Go 服务。
6. 客户端自动重连并再次完成 Ping/Pong。
7. 自动关闭全部临时进程。

### 三端构建

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1 -Target all
```

可选目标：

```powershell
-Target windows
-Target web
-Target android
```

## 当前验证结果

截至 2026-08-07：

- Go `gofmt`：通过。
- Go `vet`：通过。
- Go 测试：通过。
- Dart 格式：通过。
- Dart Analyze：通过。
- 实时通信核心测试：2/2 通过。
- Flutter App Analyze：通过。
- Flutter App 测试：7/7 通过。
- REST + WebSocket 真实握手：通过。
- 服务重启后自动重连：通过。
- 重连后 Ping/Pong：通过。
- Web Release 构建：通过。
- Windows Release 构建：通过。
- Android Debug APK 构建：通过。
- PowerShell 脚本语法：通过。

构建产物：

```text
clients\app\build\windows\x64\runner\Release\im_client.exe
clients\app\build\web\
clients\app\build\app\outputs\flutter-apk\app-debug.apk
```

## Windows 中文路径注意事项

项目根目录包含中文。当前工具链存在两个路径问题：

1. `flutter analyze` 的 LSP 服务器在该路径下可能发生 JSON 截断，因此质量脚本直接调用 Flutter 自带 Dart SDK 的 `dart analyze`。
2. Windows CMake/MSBuild 会把中文路径错误解码，因此构建脚本临时使用 `subst` 映射 ASCII 盘符，结束后自动删除映射。

不要把临时盘符当成固定项目路径，也不要留下永久映射。

## 当前未完成

- iOS 构建：需要 macOS 和 Xcode。
- macOS 构建：需要 macOS。
- Linux 桌面构建：需要 Linux CI 或 Linux 开发机。
- Android 真机 UI 验证：APK 已构建，尚未安装到真实设备测试。
- Web 浏览器运行时人工检查：Release 已构建，本轮未自动启动浏览器。
- Windows 可视化人工检查：EXE 已构建，本轮未自动打开窗口。

## 已知边界

1. 当前事件 ID 只保证单个服务进程内递增；正式离线同步必须改为数据库持久化用户游标。
2. 当前没有身份认证，任何能访问端口的客户端都可连接。
3. 当前没有心跳超时、连接限流、每用户连接数限制和全局背压。
4. `example.com/selfhosted-im/server` 是 PoC 模块路径，公开仓库确定后必须替换。
5. 当前 Android 包使用 Debug 签名，不能作为正式发行包。
6. Web 构建器存在未实际引用 Cupertino 字体的非阻断警告，当前没有为了消除警告引入无用依赖。
