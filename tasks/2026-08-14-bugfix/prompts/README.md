# 多 AI 修复提示词使用顺序

## 冻结基线

Wave 1 固定从：

`396e672339429100ae5288f3408e20f9d3858dcd`

创建独立 worktree。

不要让 AI 直接在 `C:\Users\admin\Desktop\复刻微信` 的 master checkout 修改代码。

## Wave 1：现在可同时投喂 7 个 AI

1. `AI11-注册验证码60秒倒计时.md`：B16。
2. `AI01-群通话生产配置.md`：B11，P0。
3. `AI02-Android-Push杀后台.md`：B15，P0。
4. `AI03-iOS图标与聊天底栏.md`：B01/B02。
5. `AI04-首页滑动与朋友圈颜色.md`：B09/B10。
6. `AI05-Telegram贴纸包提示.md`：B13。
7. `AI12-锁屏恢复Realtime.md`：B17，P0。

并行所有权：AI02 不改 Shell/Messaging lifecycle；AI12 不改 `conversations_page.dart`，连接中旋转 UI 留给总集成；AI03 对 `text_chat_page.dart` 仅做 footer 最小视觉修复。

## Wave 2：不要提前投喂

等总负责人把 Wave 1 commits 合流、测试并产生 `WAVE2_BASE_COMMIT` 后，再同时启动：

8. `AI06-全平台备注显示名契约.md`：B03。
9. `AI07-群聊持久化@提醒.md`：B12。
10. `AI08-语音播放与转文字基础.md`：B04-B07/B05。
11. `AI09-Windows剪贴板图片.md`：B14。
12. `AI10-LivePhoto传输基础.md`：B08。

Wave 2 的 AI 被明确要求不要大改 `text_chat_page.dart` / `conversations_page.dart` / `main_shell_page.dart`。它们先交付 server/model/controller/adapter。

## Wave 3：不再并行抢热点

由总负责人集中接线：

- `text_chat_page.dart`：Voice/STT、未听红点、连续播放、长按头像 @、Windows clipboard image、Live Photo send/view。
- `conversations_page.dart` / shell：持久 `【有人@你】`、点击精准定位。
- 全平台 viewer-relative remark display name。
- 将 AI12 暴露的 `connecting` 状态接成会话列表明确的旋转 loading 反馈。
- 最后统一回归 1:1 Calls / Push / Realtime。

## 每个 AI 回来必须提供

- commit hash
- 根因
- 改动文件
- 自动测试结果
- `tasks/2026-08-14-bugfix/reports/AIxx.md`
- 仍需真人验证项
- 状态 `FIXED-PENDING-RETEST`

如果只说“已修复”但没有 commit/test/report，不进入合并队列。
