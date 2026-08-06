# ADR-001：多端客户端采用 Flutter

## 状态

Proposed

## 日期

2026-08-07

## 背景

项目必须覆盖 Web、PC、Android 和 iOS，同时保持聊天、朋友圈、扫码和通话体验一致。团队不适合维护四套完全独立客户端。

## 决策

采用 Flutter 作为用户客户端主技术栈，覆盖：

- Android。
- iOS。
- Web。
- Windows。
- macOS。
- Linux。

管理后台不强制复用 Flutter，单独采用 React + TypeScript。

## 理由

- 官方支持目标平台。
- 领域模型、网络层、状态机、主题和大部分 UI 可复用。
- 适合定制 IM 界面。
- LiveKit 提供 Flutter SDK。

官方依据：

- https://docs.flutter.dev/reference/supported-platforms
- https://docs.flutter.dev/platform-integration/web

## 备选方案

### React + React Native + Tauri

优点：TypeScript 生态统一。

拒绝原因：Web、React Native 和 Tauri 的 UI/原生插件仍存在三套适配层；音频、视频、通知、文件和安全存储整合复杂。

### 原生多端

优点：平台体验最佳。

拒绝原因：人力成本和长期维护成本过高，不符合开源项目首版目标。

## 后果

- 平台权限和推送仍需原生适配，不能承诺 100% 共用代码。
- Web 首屏体积和 SEO 不是优势，但本项目属于应用型 Web，不以内容 SEO 为核心。
- 所有关键插件必须检查维护状态、平台覆盖和许可证。
