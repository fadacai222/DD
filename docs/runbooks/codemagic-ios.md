# Codemagic iOS 云构建 / 签名 / TestFlight

> 当前状态：`U30 LOCAL-AUTO-VERIFIED / CODEMAGIC-FIRST-RUN / CLOUD-RETRY-PENDING / SECRET-HUMAN-REQUIRED`（2026-08-13）

仓库根目录 `codemagic.yaml` 提供两个独立工作流。`ios-unsigned-validation` 不需要任何 Apple Secret，使用 Flutter 3.44.9、Xcode 26.6 和 Mac mini M2 执行依赖解析、静态分析、Flutter 测试、`flutter build ios --release --no-codesign`，并用 `xcodebuild archive ... CODE_SIGNING_ALLOWED=NO` 验证 Release archive 工程结构；`ios-signed-release` 只用于正式 tag，由 U25 GitHub Release DAG 通过 Codemagic API 触发并生成 `DD-vX.Y.Z-ios-arm64.ipa`。

## 1. Unsigned validation

`ios-unsigned-validation` 保留为安全的手动/云端编译验证：

1. 当前受控私有远端为 `fadacai222/DD`，默认分支 `master`；Codemagic 已能拉取该仓库。
2. 登录 Codemagic，选择 **Add application**，授权只访问目标私有仓库。
3. 选择该仓库和 Flutter 项目类型，让 Codemagic 从仓库根目录读取 `codemagic.yaml`。
4. 手动运行 **DD iOS unsigned validation**。
5. 云端顺序应为：`flutter pub get` → 仅对 DD 自有 `lib/`、`test/`、`tool/` 依次执行 `dart analyze --fatal-infos` → `flutter test` → `flutter build ios --release --no-codesign` → unsigned `xcodebuild archive`。
6. 只有上述 Release compile + archive 都成功后，才可把 iOS Release 工程编译写为 `AUTO-VERIFIED`；这仍不等于签名/安装/TestFlight/真机通过。

它不会上传 TestFlight，不读取 certificate/profile/App Store Connect key，也不能作为正式 IPA 证据。2026-08-13 前两次真实 Mac mini M2 云构建都在进入 Xcode compile 前暴露 analyzer 输入边界问题：Xcode/SwiftPM 生成的 `build/ios/SourcePackages/firebase_messaging-16.5.0/...` 与 `livekit_client-2.10.0/...` 被根级 `dart analyze --fatal-infos` 当作应用源码扫描，产生第三方 example/test 缺失依赖以及 lint 诊断。仅在根 `analysis_options.yaml` 配置 `exclude: build/**` 在该嵌套 package 场景下并不足以可靠阻止扫描，因此 Codemagic 两个 iOS workflow 现改为显式只分析 DD 自有 `lib/`、`test/`、`tool/` 三个源码根；`build/**` exclude 继续作为防御性配置。该修复不降低 DD 自有源码 lint 严格度，也不修改 Firebase/LiveKit 或业务功能，仍需下一次 Codemagic 重跑验证；在 Release compile + archive 真正通过前状态保持 `CLOUD-RETRY-PENDING`。

## 2. Codemagic signing contract

Codemagic Team integrations 中创建名为 `DD_APP_STORE_CONNECT` 的 Apple Developer Portal / App Store Connect integration，并把 `.p8` 只上传到 Codemagic。`ios-signed-release` 使用该 integration 获取 App Store distribution certificate 与 provisioning profile；仓库不保存 `.p8`、`.p12`、`.mobileprovision`、private key、certificate password 或 Apple ID password。

## Platform Foundation 当前合同

- iOS Bundle ID：`org.openimx.client`；deployment target：iOS 15.0；Runner Debug/Profile/Release 保持一致；目标设备族为 iPhone + iPad。当前锁定的 `firebase_core 4.13.0` / `firebase_messaging 16.5.0` iOS native metadata 要求 iOS 15.0，因此 Runner deployment target 必须保持 15.0。
- `Info.plist` 已声明当前真实产品链需要的 Camera、Microphone、Photo Library read/add、Local Network 文案，以及 `audio` / `remote-notification` Background Modes；通知授权本身由 iOS runtime API 请求，不存在 `NSNotificationsUsageDescription` 这类 plist key。
- Bluetooth 未声明：当前 AVAudioSession/LiveKit 音频路由不需要为了蓝牙耳机额外请求 CoreBluetooth 权限。若后续确实扫描/连接 BLE 设备，再由对应功能 owner 增加权限并给出用途。
- Universal Links / Associated Domains 当前未声明：现有 DD 路由先使用 `dd://` custom scheme；在正式 HTTPS 域名、AASA 文件和 Developer Portal Associated Domains 能力齐备前，不伪造 production entitlement。
- `Runner.entitlements` 只保留 Push capability 结构，`aps-environment` 由 Debug/Profile=`development`、Release=`production` 的 build setting 注入。该值只有与 Apple Developer Portal 中启用 Push 的 App ID + 匹配 provisioning profile 一起签名时才有效。
- Keychain 使用 `flutter_secure_storage` 默认 iOS Keychain access group；当前没有跨 App/Extension 共享需求，因此不添加额外 `keychain-access-groups` entitlement，避免无必要扩大签名能力。
- `Runner/Services/NativeServiceRegistrar.swift` 是公共 native service 注册入口；U30 总集成已注册 `PushNotificationService`、`FilePickerService`、`CameraCaptureService`、`MediaExportService`、`CallPlatformService`，并将对应 Swift 文件加入 Runner Sources，避免继续膨胀 `AppDelegate`。
- `NativeRouteService` 提供 native → Flutter 路由事件入口和启动期有界 pending queue；当前只接 custom URL lifecycle，后续 Push service 可调用 notification ingress，不在 foundation 中实现 APNs token lifecycle。

## Firebase / Apple HUMAN-REQUIRED

- 仓库当前没有正式 iOS `GoogleService-Info.plist`。若 iOS 继续使用 FCM provider，项目 owner 必须从对应 Firebase iOS App（Bundle ID 必须是 `org.openimx.client`）下载正式 client config，并以受控方式提供；不得伪造或提交 Admin service account。
- Apple Developer Portal 必须为 `org.openimx.client` 创建/确认 App ID 并启用 Push Notifications；真实 Team ID、development/distribution certificate、Provisioning Profile、App Store Connect API Key 均属于 `SECRET/HUMAN-REQUIRED`，不得提交仓库。
- Associated Domains 只有在正式 Universal Links 域名 + AASA 已部署后才启用。
- `AppDelegate` 已接 APNs registration success/failure、foreground `willPresent` 与 notification response tap，并继续调用 `FlutterAppDelegate` 的 `super` 链以保留 FlutterFire/Firebase Messaging delegate；Windows 本机不能执行 Xcode/iOS 编译，因此 Swift 编译、archive、codesign、安装、权限弹窗、Keychain 真机行为、APNs/FCM delivery 必须来自 macOS/Codemagic/真实 iPhone/iPad。

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

Apple 不接受 `1.2.3-rc.1` 作为 `CFBundleShortVersionString`，所以 prerelease 必须确定性映射到 `1.2.3`。为避免 rc.1/rc.2 同一 commit 时产生相同 Apple build identity，U25 release contract 现在强制**一个 commit 最多一个 DD 正式 SemVer tag**；`nightly-test` 等非正式 tag 不影响发布。这样 RC/stable 继续使用 SemVer core + commit-count，同时不会让两个正式 DD release 共享同一个 `(Bundle ID, version, build)`。Codemagic 在复制 IPA 前真实执行：

```text
codesign --verify --deep --strict
security cms -D -i embedded.mobileprovision
```

并检查 `CFBundleIdentifier`、`CFBundleShortVersionString`、`CFBundleVersion`、profile `TeamIdentifier`、profile/signed `application-identifier` 与预期 Bundle/Team identity 完全一致。GitHub 下载后再做跨平台结构检查：必须有 `embedded.mobileprovision`、`_CodeSignature/CodeResources`，且版本/build number 必须匹配；Linux 结构检查不是对 macOS `codesign` 的替代。

## 5. TestFlight

`ios-signed-release` 使用 `publishing.app_store_connect.auth: integration` **自动上传 IPA 到 App Store Connect**；Apple 随后可以进行 build/TestFlight processing。当前同时保持 `submit_to_testflight: false` 和 `submit_to_app_store: false`：不会自动提交 TestFlight Beta App Review、不会自动把 build 分发给 tester groups，也不会自动提交 Production App Store review。

正式顺序：

```text
U25 release gates
→ GitHub release-signing Environment approval
→ Codemagic signed IPA
→ capture resolved native dependency evidence
→ pinned Syft SBOM + pinned Trivy HIGH/CRITICAL fail-closed gate
→ signing identity verification
→ App Store Connect upload / possible TestFlight processing
→ U25 checksum + provenance + attestation + GitHub Release
```

当前没有真实 Apple certificate/profile/API key，也没有执行 TestFlight 上传，所以状态只能写 `CONFIGURED / SECRET-HUMAN-REQUIRED / CLOUD-PENDING`，不能写 `SIGNED VERIFIED` 或 `TESTFLIGHT VERIFIED`。

## 6. iOS SBOM 与漏洞覆盖边界

现有通用 client SBOM 不能单独宣称覆盖完整 iOS native dependency。Codemagic evidence 明确拆成 `ios-dependency-evidence/dart/` 与 `ios-dependency-evidence/native/`：Dart 目录保存 `pubspec.lock`/`dart-pub-deps.json`；native 目录按原相对路径保存 `Package.resolved`、`Podfile.lock` 和上下文 `Package.swift`，禁止 flatten basename。正式 native gate 要求至少一个非空 `Package.resolved` 或 `Podfile.lock`，`Package.swift` 不能替代 resolved lockfile。在 `publishing.app_store_connect` **之前**，Codemagic 下载固定版本 Syft/Trivy，并先校验固定 SHA-256 checksum manifest，再校验 scanner archive；Syft/Trivy 都只扫描 native 目录。Trivy 显式 `--list-all-pkgs`，扫描后 JSON 必须包含 basename 为 `Package.resolved`/`Podfile.lock` 的 target 且该 target 至少识别一个 package；SPDX JSON 的 `packages` 也必须大于 0。任何下载失败、checksum 错误、scanner 缺失、resolved lockfile 缺失、native target/package 未识别、空 SBOM/report 或 HIGH/CRITICAL 命中都会直接失败，IPA 不会进入 Apple upload。Codemagic 产出 `DD-<tag>-ios-codemagic-resolved.spdx.json` 与 `DD-<tag>-ios-codemagic-resolved.trivy.json`；GitHub `build-ios` 解压后再次要求同样的 native lockfile/target/package/SPDX 合同，再使用 U25 已 pin digest 的 Syft/Trivy独立重扫，产出 `DD-<tag>-ios-github-verified.spdx.json` 与 `DD-<tag>-ios-github-verified.trivy.json`。

当前 Runner 使用 Flutter 生成的本地 Swift Package，仓库基线没有 `Podfile/Podfile.lock`，因此不能伪造 CocoaPods 清单。若以后引入 CocoaPods，云端 evidence 会自动带入实际 `Podfile.lock`。Syft/Trivy 对 Xcode build settings、Apple SDK、预编译 framework 内部组件及部分 SPM metadata 的识别并不等于 Apple 平台全覆盖；U25 仍保持 repository Trivy `HIGH/CRITICAL` fail closed，但这些 native blind spot 必须明确保留为 coverage gap，而不是宣称“已扫描全部 iOS native 组件”。

## 7. Rollback / retention

iOS IPA、native dependency evidence、Codemagic pre-publish SBOM/Trivy report、GitHub 二次验证 SBOM/Trivy report 全部进入 U25 `assemble-attest-and-sign`，因此进入 `SHA256SUMS`、descriptive provenance、GitHub Artifact Attestation 与 GitHub Release assets。Retention 继续使用 U25 同一策略：保留当前和立即上一条 published DD SemVer release，包含 prerelease（例如 rc.2 的 predecessor 可以是 rc.1）。
