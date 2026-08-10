# ADR-001：多端用户客户端采用 Flutter

## 状态

Accepted

## 日期

- 提议：2026-08-07
- 确认落地：2026-08-10
- 当前实现复核：2026-08-11

## 背景

DD 需要覆盖 Windows、Android、Web，并计划支持 iOS/macOS。聊天、联系人、媒体、通话和主题的大部分业务逻辑需要跨端一致；小团队维护多套原生 UI 的成本过高。

## 决策

用户客户端主技术栈采用 Flutter。

当前真实落地：

```text
clients/app/
```

已实际构建/使用：

- Windows。
- Android。
- Web。

目标平台：

- iOS。
- macOS。
- Linux（低优先级）。

管理后台不复用 Flutter，继续使用 React + TypeScript。

## 理由

- 大量 domain/data/UI 代码跨端复用。
- Flutter 适合高度定制 IM UI。
- 当前项目已经积累大量 Flutter 测试与组件，迁移成本极高。
- LiveKit、通知、媒体、文件、secure storage 等均已有 Flutter 生态方案。
- Windows/Android/Web 主链已证明架构可行。

## 原生例外

采用 Flutter **不代表 100% 不写原生代码**。

当前已经需要：

- Windows runner：无边框、resize、DWM、单实例、自定义通知。
- Android manifest/resources：通知权限、小图标、平台能力。
- Native media runtime：media_kit/libmpv 等。
- P9 QR 使用 Flutter `qr_flutter` / `mobile_scanner`，但当前 QR 客户端门禁仍有 `KNOWN-FAILURE`。
- iOS/macOS 后续需要 Push/权限/签名/扫码等平台适配。

原则：

> 业务状态和通用 UI 留在 Dart；必须依赖 OS window/media/push 的能力通过薄原生适配实现。

## 备选方案

### React + React Native + Tauri

拒绝原因：

- 会形成 Web/React Native/Desktop 多适配层。
- 当前 Flutter 代码资产已经非常大。
- 迁移会中断产品主线，收益不足。

### 四套原生客户端

拒绝原因：

- 人力和长期维护成本不可接受。
- 协议/状态/功能容易跨端漂移。

## 后果

正面：

- 快速迭代多端。
- 共用模型/Coordinator/测试。
- UI token 和信息架构更易统一。

负面：

- Windows native window 是高风险边界。
- Android 键盘/动画要防大树 rebuild。
- Web 与 Native 的 secure storage/file cache 能力不同。
- Native media plugin 需要额外 runtime/CI 环境。

## 约束

- 不因为 Flutter 方便就把平台差异强行抹平。
- 用户可见平台问题必须真机验收。
- 平台插件升级前检查维护状态/许可证/目标平台。
- 关键 native dependency 必须进入 CI/发布说明。

## 复审条件

只有出现以下情况才考虑 Supersede：

- Flutter 停止支持关键目标平台；
- 关键能力长期无法实现且原生桥接无法解决；
- 团队规模和业务价值足以承担特定平台重写。

单个 UI Bug 不是推翻 Flutter 的理由。
