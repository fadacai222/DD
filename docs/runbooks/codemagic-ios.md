# Codemagic iOS 云构建接入

> 当前状态：`CONFIGURED / CLOUD-BUILD-PENDING`（2026-08-12）

仓库根目录已经提供 `codemagic.yaml`，Flutter iOS Runner 位于 `clients/app/ios`。当前工作流 `ios-unsigned-validation` 使用 Flutter 3.44.9、Xcode 26.6 和 Mac mini M2 构建机，执行依赖解析、静态分析、Flutter 测试和无签名 iOS Debug 编译。

该工作流没有自动触发规则，必须在 Codemagic 后台手动启动，因此不会因为普通 push 自动消耗云构建额度。

## 首次启用

1. 将仓库发布到受控的 GitHub、GitLab 或 Bitbucket 私有仓库；当前本地仓库尚未配置 Git 远端。
2. 登录 Codemagic，选择 **Add application**，授权只访问目标私有仓库。
3. 选择该仓库和 Flutter 项目类型，让 Codemagic 从仓库根目录读取 `codemagic.yaml`。
4. 手动运行 **DD iOS unsigned validation**。
5. 只有云端日志明确显示 `flutter build ios --debug --no-codesign` 成功后，才可把 iOS 云编译写为 `AUTO-VERIFIED`。

## 后续签名与 TestFlight

当前配置故意不包含签名或发布。准备真机/TestFlight 时，需要 Apple Developer Program，并在 Codemagic 的 Team integrations / Code signing identities 中添加 App Store Connect API Key、证书和 Provisioning Profile，然后再新增独立的签名发布工作流。

不得把 Apple ID 密码、`.p8`、`.p12`、`.mobileprovision`、证书密码或 App Store Connect 私钥写入仓库、普通环境变量或构建日志。签名材料只放 Codemagic Secret/Integration；本仓库 `.gitignore` 已拦截常见私钥与签名文件。

## 当前边界

- iOS Bundle ID：`org.openimx.client`。
- 现有 Dart/Flutter 代码可复用，但 iOS 权限、APNs、Firebase 配置、后台模式、相机/媒体、LiveKit、Secure Storage 和真机行为尚未完成验收。
- Windows 本机不能执行 Xcode/iOS 编译；当前只能验证 YAML、Dart 分析和 Flutter 测试，真正的 iOS 编译结果必须来自 Codemagic macOS 构建机。
