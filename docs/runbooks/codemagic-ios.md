# Codemagic iOS 云构建 / 签名 / TestFlight

> 当前状态：`CONFIGURED / SECRET-HUMAN-REQUIRED / CLOUD-PENDING`（2026-08-12）

仓库根目录 `codemagic.yaml` 提供两个独立工作流。`ios-unsigned-validation` 不需要任何 Apple Secret，使用 Flutter 3.44.9、Xcode 26.6 和 Mac mini M2 执行依赖解析、静态分析、Flutter 测试、`flutter build ios --release --no-codesign`，并用 `xcodebuild archive ... CODE_SIGNING_ALLOWED=NO` 验证 Release archive 工程结构；`ios-signed-release` 只用于正式 tag，由 U25 GitHub Release DAG 通过 Codemagic API 触发并生成 `DD-vX.Y.Z-ios-arm64.ipa`。

## 1. Unsigned validation

`ios-unsigned-validation` 保留为安全的手动/云端编译验证：

1. 将仓库发布到受控的 GitHub、GitLab 或 Bitbucket 私有仓库；当前本地仓库尚未配置 Git 远端。
2. 登录 Codemagic，选择 **Add application**，授权只访问目标私有仓库。
3. 选择该仓库和 Flutter 项目类型，让 Codemagic 从仓库根目录读取 `codemagic.yaml`。
4. 手动运行 **DD iOS unsigned validation**。
5. 云端顺序应为：`flutter pub get` → `dart analyze --fatal-infos` → `flutter test` → `flutter build ios --release --no-codesign` → unsigned `xcodebuild archive`。
6. 只有上述 Release compile + archive 都成功后，才可把 iOS Release 工程编译写为 `AUTO-VERIFIED`；这仍不等于签名/安装/TestFlight/真机通过。

它不会上传 TestFlight，不读取 certificate/profile/App Store Connect key，也不能作为正式 IPA 证据。只有 Codemagic macOS 日志真实成功后，才能把该次云编译标记为 `AUTO-VERIFIED`；当前仍是 `CLOUD-PENDING`。

## 2. Codemagic signing contract

Codemagic Team integrations 中创建名为 `DD_APP_STORE_CONNECT` 的 Apple Developer Portal / App Store Connect integration，并把 `.p8` 只上传到 Codemagic。`ios-signed-release` 使用该 integration 获取 App Store distribution certificate 与 provisioning profile；仓库不保存 `.p8`、`.p12`、`.mobileprovision`、private key、certificate password 或 Apple ID password。

## Platform Foundation 当前合同

- iOS Bundle ID：`org.openimx.client`；deployment target：iOS 15.0；Runner Debug/Profile/Release 保持一致；目标设备族为 iPhone + iPad。当前锁定的 `firebase_core 4.13.0` / `firebase_messaging 16.5.0` iOS native metadata 要求 iOS 15.0，因此 Runner deployment target 必须保持 15.0。
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

Codemagic protected variable group 固定命名：

```text
dd_ios_release
```

其中必须存在：

```text
DD_IOS_BUNDLE_ID=org.openimx.client
DD_IOS_TEAM_ID=<Apple Team ID>
```

由 GitHub U25 bridge 每次构建注入、且必须与 tag/SHA 一一对应：

```text
DD_RELEASE_TAG=vX.Y.Z[-prerelease]
DD_RELEASE_VERSION=X.Y.Z[-prerelease]
DD_IOS_MARKETING_VERSION=X.Y.Z
DD_RELEASE_BUILD_NUMBER=<git rev-list --count HEAD>
DD_RELEASE_SHA=<40-char tagged commit SHA>
```

缺任一 release identity、Bundle ID、Team ID、Apple distribution certificate、App Store profile 或 App Store Connect integration，工作流必须失败；不存在 ad-hoc/unsigned 正式 IPA fallback。

## 3. GitHub `release-signing` Environment

GitHub 不保存 Apple signing material，只保存 Codemagic bridge 所需值：

```text
Secret: DD_CODEMAGIC_API_TOKEN
Variable: DD_CODEMAGIC_APP_ID
```

`build-ios` 只有在 exact-SHA CI、full-history Secret Scan 与 HIGH/CRITICAL dependency gate 通过后才会进入 `release-signing` Environment。它触发 Codemagic `ios-signed-release`，轮询到 `finished` 后下载精确名称的 IPA 与 native dependency evidence；任何 API、build、artifact 缺失都 fail closed。

## 4. Version / signing verification

正式构建固定：

```text
CFBundleShortVersionString = SemVer core MAJOR.MINOR.PATCH
CFBundleVersion            = Git commit count
Git tag                    = v + full SemVer (including prerelease)
IPA                        = DD-<tag>-ios-arm64.ipa
```

Apple 不接受 `1.2.3-rc.1` 作为 `CFBundleShortVersionString`，所以 prerelease 必须确定性映射到 `1.2.3`；RC 与 stable 仍由不同 Git tag + commit-count build number 区分。Codemagic 在复制 IPA 前真实执行：

```text
codesign --verify --deep --strict
security cms -D -i embedded.mobileprovision
```

并检查 `CFBundleIdentifier`、`CFBundleShortVersionString`、`CFBundleVersion`、profile `TeamIdentifier`、profile/signed `application-identifier` 与预期 Bundle/Team identity 完全一致。GitHub 下载后再做跨平台结构检查：必须有 `embedded.mobileprovision`、`_CodeSignature/CodeResources`，且版本/build number 必须匹配；Linux 结构检查不是对 macOS `codesign` 的替代。

## 5. TestFlight

`ios-signed-release` 使用 `publishing.app_store_connect.auth: integration` 上传已签名 IPA 到 App Store Connect，因此成功处理后进入 TestFlight 构建链；默认 `submit_to_app_store: false`，绝不自动提交 Production App Store review。

正式顺序：

```text
U25 release gates
→ GitHub release-signing Environment approval
→ Codemagic signed IPA
→ signing identity verification
→ App Store Connect upload / TestFlight processing
→ U25 checksum + provenance + attestation + GitHub Release
```

当前没有真实 Apple certificate/profile/API key，也没有执行 TestFlight 上传，所以状态只能写 `CONFIGURED / SECRET-HUMAN-REQUIRED / CLOUD-PENDING`，不能写 `SIGNED VERIFIED` 或 `TESTFLIGHT VERIFIED`。

## 6. iOS SBOM 与漏洞覆盖边界

现有通用 client SBOM 不能单独宣称覆盖完整 iOS native dependency。Codemagic 会在实际 iOS 依赖解析后收集 Dart pub dependency、`pubspec.lock`，以及生成/存在的 `Package.swift`、`Package.resolved`、`Podfile.lock`，打成 `DD-<tag>-ios-native-deps.zip`；U25 再对这份云端解析结果运行 pinned Trivy（HIGH/CRITICAL `--exit-code 1`）和 pinned Syft，分别生成 `DD-<tag>-ios.trivy.json` 与 `DD-<tag>-ios.spdx.json`。

当前 Runner 使用 Flutter 生成的本地 Swift Package，仓库基线没有 `Podfile/Podfile.lock`，因此不能伪造 CocoaPods 清单。若以后引入 CocoaPods，云端 evidence 会自动带入实际 `Podfile.lock`。Syft/Trivy 对 Xcode build settings、Apple SDK、预编译 framework 内部组件及部分 SPM metadata 的识别并不等于 Apple 平台全覆盖；U25 仍保持 repository Trivy `HIGH/CRITICAL` fail closed，但这些 native blind spot 必须明确保留为 coverage gap，而不是宣称“已扫描全部 iOS native 组件”。

## 7. Rollback / retention

iOS IPA、iOS SPDX SBOM 与 native dependency evidence 都进入 U25 `assemble-attest-and-sign`，因此进入 `SHA256SUMS`、descriptive provenance、GitHub Artifact Attestation 与 GitHub Release assets。Retention 继续使用 U25 同一策略：保留当前和立即上一条 published DD SemVer release，包含 prerelease（例如 rc.2 的 predecessor 可以是 rc.1）。
