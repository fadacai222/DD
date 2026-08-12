# Codemagic iOS 云构建接入

> 当前状态：`CONFIGURED / CLOUD-BUILD-PENDING`（2026-08-12）

仓库根目录已经提供 `codemagic.yaml`，Flutter iOS Runner 位于 `clients/app/ios`。当前工作流 `ios-unsigned-validation` 使用 Flutter 3.44.9、Xcode 26.6 和 Mac mini M2 构建机，执行依赖解析、静态分析、Flutter 测试、无签名 iOS Release 编译，并用 `xcodebuild archive ... CODE_SIGNING_ALLOWED=NO` 验证 Release archive 工程结构。

该工作流没有自动触发规则，必须在 Codemagic 后台手动启动，因此不会因为普通 push 自动消耗云构建额度。

## 首次启用

1. 将仓库发布到受控的 GitHub、GitLab 或 Bitbucket 私有仓库；当前本地仓库尚未配置 Git 远端。
2. 登录 Codemagic，选择 **Add application**，授权只访问目标私有仓库。
3. 选择该仓库和 Flutter 项目类型，让 Codemagic 从仓库根目录读取 `codemagic.yaml`。
4. 手动运行 **DD iOS unsigned validation**。
5. 只有云端日志明确显示 `flutter build ios --release --no-codesign` 和 unsigned `xcodebuild archive` 都成功后，才可把 iOS Release 工程编译写为 `AUTO-VERIFIED`；这仍不等于签名/安装/TestFlight/真机通过。

## 后续签名与 TestFlight

当前配置故意不包含签名或发布。准备真机/TestFlight 时，需要 Apple Developer Program，并在 Codemagic 的 Team integrations / Code signing identities 中添加 App Store Connect API Key、证书和 Provisioning Profile，然后再新增独立的签名发布工作流。

不得把 Apple ID 密码、`.p8`、`.p12`、`.mobileprovision`、证书密码或 App Store Connect 私钥写入仓库、普通环境变量或构建日志。签名材料只放 Codemagic Secret/Integration；本仓库 `.gitignore` 已拦截常见私钥与签名文件。

## Platform Foundation 当前合同

- iOS Bundle ID：`org.openimx.client`；deployment target：iOS 13.0；目标设备族为 iPhone + iPad。
- `Info.plist` 已声明当前真实产品链需要的 Camera、Microphone、Photo Library read/add、Local Network 文案，以及 `audio` / `remote-notification` Background Modes；通知授权本身由 iOS runtime API 请求，不存在 `NSNotificationsUsageDescription` 这类 plist key。
- Bluetooth 未声明：当前 AVAudioSession/LiveKit 音频路由不需要为了蓝牙耳机额外请求 CoreBluetooth 权限。若后续确实扫描/连接 BLE 设备，再由对应功能 owner 增加权限并给出用途。
- Universal Links / Associated Domains 当前未声明：现有 DD 路由先使用 `dd://` custom scheme；在正式 HTTPS 域名、AASA 文件和 Developer Portal Associated Domains 能力齐备前，不伪造 production entitlement。
- `Runner.entitlements` 只保留 Push capability 结构，`aps-environment` 由 Debug/Profile=`development`、Release=`production` 的 build setting 注入。该值只有与 Apple Developer Portal 中启用 Push 的 App ID + 匹配 provisioning profile 一起签名时才有效。
- Keychain 使用 `flutter_secure_storage` 默认 iOS Keychain access group；当前没有跨 App/Extension 共享需求，因此不添加额外 `keychain-access-groups` entitlement，避免无必要扩大签名能力。
- `Runner/Services/NativeServiceRegistrar.swift` 是公共 native service 注册入口；后续 Push/Media/Call service 通过小型独立 service 接入，避免继续膨胀 `AppDelegate`。
- `NativeRouteService` 提供 native → Flutter 路由事件入口和启动期有界 pending queue；当前只接 custom URL lifecycle，后续 Push service 可调用 notification ingress，不在 foundation 中实现 APNs token lifecycle。

## Firebase / Apple HUMAN-REQUIRED

- 仓库当前没有正式 iOS `GoogleService-Info.plist`。若 iOS 继续使用 FCM provider，项目 owner 必须从对应 Firebase iOS App（Bundle ID 必须是 `org.openimx.client`）下载正式 client config，并以受控方式提供；不得伪造或提交 Admin service account。
- Apple Developer Portal 必须为 `org.openimx.client` 创建/确认 App ID 并启用 Push Notifications；真实 Team ID、development/distribution certificate、Provisioning Profile、App Store Connect API Key 均属于 `SECRET/HUMAN-REQUIRED`，不得提交仓库。
- Associated Domains 只有在正式 Universal Links 域名 + AASA 已部署后才启用。
- Windows 本机不能执行 Xcode/iOS 编译；当前只能验证工程文本合同、plist/entitlements XML、Dart analyze/test。Swift 编译、archive、codesign、安装、权限弹窗、Keychain 真机行为、APNs/FCM delivery 必须来自 macOS/Codemagic/真实 iPhone/iPad。
