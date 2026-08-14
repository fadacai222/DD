# AI03：修复 iOS AppIcon 白边 + 聊天底栏色差

使用 `@dd`：

`C:\Users\admin\Desktop\复刻微信`

你是 **AI03 / iOS visual regression**。

## Git

- 基线：`396e672339429100ae5288f3408e20f9d3858dcd`
- 独立 worktree。
- 不 merge/rebase master。
- 原子 commit。

## 任务范围

只修两个实测问题：

1. iOS icon 尺寸不对、显示有白边。
2. iOS 聊天底部输入区域与聊天 wallpaper 有明显色差；纯白背景不明显，换自定义背景就能看到色块。

不要开发 Live Photo；Live Photo 由其他 AI 处理。

## B01 已发现的代码线索

`clients/app/tool/generate_ios_app_icons.dart` 使用：

`设计图/brand-assets/DD-icon-1024.png`

`clients/app/tool/ios_app_icon_generator.dart` 会把 source resize 到各尺寸，并转换为 opaque RGB。

但 `scripts/generate-brand-assets.ps1` 当前生成 canonical iOS source 时存在：

```text
DD-icon-1024.png -> Scale 0.86 + White background
```

这意味着 source 本身已经人为缩小留白，再被 AppIcon generator 原样缩放，极可能正是主屏图标“缩一圈+白边”的来源。

### B01 必须做到

- 追踪真正品牌源图，不要仅对最终 png 二次裁剪掩盖问题。
- iOS AppIcon 应 full-bleed 到系统 mask，由 iOS 自己裁圆角；不能预先塞白色安全边距。
- 1024 marketing icon 必须 opaque，无 alpha。
- 所有 Contents.json 声明尺寸都正确生成。
- 不破坏 Android/Windows/Web 现有图标，如需修改共享品牌脚本必须加平台合同，避免 iOS 修好后其他平台变形。
- 增加自动 regression test：检查生成尺寸、alpha/opaque，以及能识别“整张 source 被 0.86 inset”的回归。不要只比文件存在。

## B02 已确认根因

`text_chat_page.dart` 的聊天 body 先铺：

`ChatWallpaperSurface`

但 `_composerBar()` 外层又：

```dart
final surface = Theme.of(context).colorScheme.surface;
Material(color: surface, child: Container(...))
```

因此 footer 形成不透明色块，custom wallpaper 下非常明显。

### B02 必须做到

- footer 的**外层区域**要与聊天 wallpaper 连续，不出现整条 surface 色块。
- 输入框本身、按钮本身仍要有足够对比度，不是把所有控件都透明到看不见。
- 深色模式同样可读。
- Android/Windows/Web 不能因这个修改出现 keyboard lift、安全区、底部遮挡回归。
- iOS safe area/home indicator 下不能出现另一条突兀颜色。
- 尽量把 wallpaper/footer 背景策略封装，不要在多个地方写魔法颜色。

## 测试

新增/强化：

1. iOS AppIcon generator contract tests。
2. 自定义 wallpaper 下 footer 外层不是 opaque theme surface 的 widget test。
3. light/dark 基本视觉合同。
4. composer 输入、emoji、+、voice 控件仍存在且可点击。
5. Android keyboard 相关现有测试必须继续通过。

运行至少：

```text
clients/app: dart analyze --fatal-infos
clients/app: dart run tool/generate_ios_app_icons.dart
clients/app: flutter test <iOS icon相关测试>
clients/app: flutter test <text_chat相关定向测试>
```

如果当前 Windows 机器不能跑 Xcode，明确标记真人/cloud build pending，不得声称 iOS 主屏视觉已 VERIFIED。

## 冲突控制

你可以修改 `text_chat_page.dart`，但**只允许触及 composer/footer 背景相关最小区块**。不要格式化整文件，不要碰 voice/mention/clipboard/LivePhoto 逻辑，因为后续还有其他分支要集成该热点文件。

不要修改：

- `messaging_coordinator.dart`
- `main_shell_page.dart`
- call recovery
- push lifecycle

## 交付

新增 `tasks/2026-08-14-bugfix/reports/AI03.md`，写：

- icon 白边根因最终证据
- footer 色差根因
- 改动文件
- tests
- iPhone 真机需要检查：主屏、设置 App 列表、Spotlight/通知相关图标、不同 wallpaper/footer
- 状态 `FIXED-PENDING-RETEST`

建议 commit：

`fix(ios): remove icon inset and blend chat composer wallpaper`
