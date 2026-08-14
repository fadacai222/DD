# 2026-08-14 实测 Bug 修复 TODO

> 状态约定：`TODO` → `IN-PROGRESS` → `FIXED-PENDING-RETEST` → `VERIFIED/HUMAN-PASS`。  
> 最新冻结基线（Wave 2）：`b601d98317fb3478d3c84227a4ee9dac76d0ae17`；Wave 1 原始冻结点：`396e672339429100ae5288f3408e20f9d3858dcd`。  
> 需求总数：17 项（原 B01-B15 + 新增 B16/B17）。

## A. 总负责人 / 基线

- [x] 读取 2026-08-14 01:34 最新 `实测需求与bug.md`。
- [x] 确认当前 `master == origin/master`。
- [x] 冻结当前 HEAD `396e672339429100ae5288f3408e20f9d3858dcd`。
- [x] 确认基线包含 `a6d33ba` shared realtime 来电恢复。
- [x] 确认基线包含 `943de00` formal LiveKit token 修复。
- [x] 确认基础公网 1:1 Calls 已记录 HUMAN-PASS，后续不得回退。
- [x] 保护未跟踪 `DD-Windows.bat` / `实测需求与bug.md`。
- [x] 新增 B16 注册验证码倒计时分析：server 已有固定 60s cooldown，客户端缺 UX。
- [x] 新增 B17 锁屏恢复分析：RealtimeClient 有自动 backoff，但 Shell resume 缺显式 Messaging/Realtime recover。
- [x] 已创建独立 integration worktree：`C:\Users\admin\.devspace\worktrees\repo-7f74fe49`，集成底座使用当前最新主线 `12a858a41d14190736f8b3fc09cd44f1c691acc8`。
- [x] 已逐支确认 AI01/02/03/04/11/12 commit 的直接 parent 均为冻结 hash `396e672339429100ae5288f3408e20f9d3858dcd`；AI05 worktree HEAD 同样停在该基线。
- [x] Wave 1 已物理合流到 `integrate/2026-08-14-wave1`，建立 `WAVE2_BASE_COMMIT=b601d98317fb3478d3c84227a4ee9dac76d0ae17`。

## A.1 Wave 1 负责人复审快照（2026-08-14 03:xx）

- [x] AI11 `715ff5b1370ea3a452d065991f8f1fdcba2cf12c`：负责人复跑 Auth 25/25 PASS，analyze 0，`FIXED-PENDING-RETEST`。
- [x] AI01 `f54578ae095bc85db76949ef059c9fddec04652d`：负责人复跑 Group/httpapi/appconfig/cmd-api Go 定向 PASS，`FIXED-PENDING-RETEST`。
- [x] AI02 `637f4f6c1898e83cc57f4f7240fb5826f6dbf90b`：负责人复跑 Push/Notification/Account 16 tests PASS，analyze 0，`FIXED-PENDING-RETEST`。
- [x] AI03 `dc27ba01f01cf580fddaeb6af5ba926dafd4f3e7`：负责人复跑 iOS icon + TextChat 45 test events PASS，analyze 0，`FIXED-PENDING-RETEST`。
- [x] AI04 `326e9025b2f6cca53ad170138b28797d34b1b53a`：负责人复跑 Conversations/Moments 20 tests PASS，analyze 0，`FIXED-PENDING-RETEST`。
- [x] AI05：负责人发现“只有 timeout 异常映射、没有真实 HTTP deadline”的 blocker，已补为 Sticker HTTP 请求统一 15 秒硬超时；API 5/5 + Sheet/Link/TextChat 59 events + Go sticker/httpapi PASS，analyze 0。已提交 `518a91320144ab425bae68a9a22c16e8fa124893` + `48175a82713684373d85acdb77af4a45745e7cd1` 并合流。
- [x] AI12 `695f93ebec4720783d2b7b7b782e7f38c9ec4675`：负责人复跑 Shell/Messaging/Calls 40 + Realtime 3 PASS，analyze 0，`FIXED-PENDING-RETEST`。
- [x] 六个已提交分支业务 patch 对实际集成底座 `12a858a` 均可干净应用；唯一已知冲突是共享 docs，业务代码无已知冲突。
- [x] `merge-wave1.ps1` 已完成 AI05 显式提交、Wave 1 cherry-pick、全量门禁和 Windows/Android build smoke：App 485 PASS / 5 条件 SKIP / 0 FAIL，analyze 0，Windows Release 与 Android APK 均构建成功。
- [x] Wave 2 已放行；AI06-AI10 统一基于 `b601d98317fb3478d3c84227a4ee9dac76d0ae17` 开工。

## B. Wave 1：7 条可并行修复

### AI11 / B16 注册验证码 60 秒倒计时

- [ ] 成功发送后开始 60 秒倒计时。
- [ ] 倒计时按钮 disabled/灰色，显示剩余秒数。
- [ ] 60 秒结束自动恢复“发送验证码”。
- [ ] 失败发送不启动倒计时。
- [ ] 成功提示改为 `验证码发送成功，收不到就去邮箱垃圾箱看看`。
- [ ] Timer dispose 安全；rebuild/Tab 切换不重复创建 timer。
- [ ] 服务端 `registrationCodeCooldown = 60s` 不改、不弱化。
- [ ] Widget fake-time 测试覆盖 60→59→0/恢复，不真实 sleep 60 秒。
- [ ] 状态：`TODO`。

### AI01 / B11 群通话生产配置

- [ ] 写失败测试：生产 `_FILE` secret/已解析 config 下 group call 应可用。
- [ ] 移除 `groups/calls.go` 对 raw `LIVEKIT_API_KEY/SECRET` 的隐藏依赖。
- [ ] 将 LiveKit URL/key/secret 通过 `groups.Config` 显式注入。
- [ ] dev/test 兼容，不在日志暴露 secret。
- [ ] `Start/Join` 不再因 secret-file 部署误报 `GROUP_CALL_UNAVAILABLE`。
- [ ] 不碰已通过真人的正式 1:1 Call token/state machine。
- [ ] 跑 group call service/httpapi 定向 + `go test ./...`。
- [ ] 状态：`TODO`。

### AI02 / B15 Android Push killed-state

- [ ] 证明 endpoint → push job → worker → FCM → Android isolate → local notification 整条链。
- [ ] background handler 不再无痕吞掉所有错误；增加安全诊断分类。
- [ ] 保持 Android data-only + HIGH，不制造系统通知/DD 本地通知双路径。
- [ ] 校验 Android 13+ permission / channel / Firebase initialization。
- [ ] token refresh/logout/account-switch lease 不回退。
- [ ] recent-task swipe/system process kill 与 Android Force Stop 明确区分。
- [ ] 禁止改 `main_shell_page.dart` / `messaging_coordinator.dart`，resume/reconnect 所有权归 AI12。
- [ ] 输出 ADB/FCM 真机矩阵。
- [ ] 状态：`TODO`。

### AI03 / B01-B02 iOS icon + chat footer

- [ ] icon generator regression test：最终 AppIcon 无人为留白/错误二次缩放。
- [ ] 修复 canonical source/generator，App Store 1024 icon 保持 opaque。
- [ ] 聊天 footer 不再用不透明 surface 覆盖 wallpaper。
- [ ] 输入区仍可读；深色模式、安全区、键盘行为不回退。
- [ ] 只对 `text_chat_page.dart` 做 footer 视觉最小修改，不碰 Voice/Mention/Clipboard/Live Photo。
- [ ] 跑 iOS icon/native contract + Flutter 定向/analyze。
- [ ] 状态：`TODO`。

### AI04 / B09-B10 swipe + Moments

- [ ] `_ConversationSwipeActions` 改显式 opened/closed 状态机。
- [ ] closed → 左侧/右侧打开。
- [ ] 已打开一侧后反向手势第一下只关闭，不允许穿越另一边。
- [ ] 下一次反向手势才能打开另一侧。
- [ ] 两个方向完全对称。
- [ ] action 完成回 closed；busy 期间不穿越状态。
- [ ] Moments 评论作者/回复名/正文合同测试禁止 danger/red。
- [ ] 点赞红心、删除/错误仍允许 danger。
- [ ] 状态：`TODO`。

### AI05 / B13 Telegram sticker import

- [ ] 覆盖无 Bot Token、relay unavailable、错误 set、404、timeout、部分格式失败。
- [ ] 服务端错误码与客户端 `_operationErrorText()` 对齐。
- [ ] 错误在 sheet/dialog 生命周期变化后仍稳定可见。
- [ ] 成功导入仍切到新 pack；部分失败显示数量。
- [ ] 不回退 TGS/WebM/视频 Sticker。
- [ ] 状态：`TODO`。

### AI12 / B17 锁屏/前后台 Realtime 恢复

- [ ] 复现并写测试：App pause/inactive → resumed 后旧连接失效时应主动恢复。
- [ ] 不新造第二套永久 reconnect timer；复用 RealtimeClient heartbeat/backoff。
- [ ] 在 `resumed` 触发幂等 Messaging recover：cursor sync + pending flush + realtime recovery。
- [ ] stale/half-open socket 不能只因 enum 仍为 connected 就永久跳过恢复。
- [ ] 避免并发多次 resume 导致重复 connect/重复 event subscription。
- [ ] `connecting` 时 UI 有明确 loading/旋转反馈；connected 绿、disconnected 灰。
- [ ] 不回退 Push `onAppResumed()`。
- [ ] 不回退 `a6d33ba` shared realtime Call recovery / `943de00` formal token。
- [ ] `clients/realtime_poc` reconnect tests + App lifecycle Widget/unit tests。
- [ ] 状态：`TODO`。

## C. Wave 1 合流检查

固定合并顺序：AI11 → AI01 → AI02 → AI03 → AI04 → AI05 → AI12。

- [ ] 每个 commit 先 review diff，再定向测试。
- [ ] 禁止整文件 `ours/theirs` 解决冲突。
- [ ] `server: go test ./...`。
- [ ] `server: go vet ./...`。
- [ ] `clients/realtime_poc: dart test`。
- [ ] `clients/app: dart analyze --fatal-infos`。
- [ ] `clients/app: flutter test`。
- [ ] 可执行的 Windows/Android/iOS build/contract gates 通过。
- [ ] 专门复审 Shell lifecycle：Messaging / Push / Calls resume 不互相重复抢状态。
- [x] 创建 `WAVE2_BASE_COMMIT=b601d98317fb3478d3c84227a4ee9dac76d0ae17`。

## D. Wave 2：能力层并行

> 2026-08-14 总负责人复审完成：Wave2 已物理合流到 `integrate/2026-08-14-wave2`，全量门禁、Windows Release 与 Android APK build 均通过；最终 `WAVE3_BASE_COMMIT=6ac4e6e6c2d37a234cde3219bb4ce5685a0c5298`，AI08 coordinator retry follow-up=`5cb98d97c75a62402d1bc1097f6ba391a19efaef`。AI06-AI10 继续保持 `FIXED-PENDING-RETEST`，待 Wave3 热点接线与真人复测。

### AI06 / B03 viewer-relative 备注名

- [ ] 盘点 contacts/messaging/groups/moments/calls/push/search/forward 的用户可见名字来源。
- [ ] 定义统一 `effectiveDisplayName` / viewer-relative preview。
- [ ] 只读取当前 principal 自己的 `contacts.remark`。
- [ ] remark 非空优先，否则 fallback 公共 `display_name`。
- [ ] A 给 B 的私人备注绝不泄漏给 C。
- [ ] 共享消息/群事实不永久写 viewer-private remark。
- [ ] 加跨用户 privacy regression。
- [x] 为 Wave 3 提供最小 UI 接口。
- [x] 状态：`FIXED-PENDING-RETEST`；搜索/mention overlay 的显式 UI 接线留给 Wave3。

### AI07 / B12 durable mention

- [ ] migration 优先 `000034_message_mentions`，开工先确认未占用。
- [ ] server-authoritative entities 与 mention index 同事务落库。
- [ ] 支持 direct mention / `MENTION_ALL` 授权语义。
- [ ] Conversation summary 返回当前用户 latest unread mention 精确定位字段。
- [ ] 重启/漏 WebSocket/多设备仍恢复。
- [ ] mark-read 按产品语义消除 mention 状态。
- [ ] IDOR：不能读其他用户 mention state。
- [ ] 复用现有 message locate/highlight：最终 UI 接线留给 Wave3。
- [x] 状态：`FIXED-PENDING-RETEST`。

### AI08 / B04-B07/B05 Voice/STT

- [ ] Voice 点击立即 active/loading，不等完整下载后才响应。
- [ ] 有界预取，不制造无上限缓存洪泛。
- [ ] heard 作为红点事实源；真正开始播放后再标已听。
- [ ] 用户主动播第一条后可顺序播后续未听远端 Voice。
- [ ] 离开会话/暂停/失败/通话/切媒体终止队列。
- [ ] STT provider interface；未配置明确 unavailable。
- [ ] 跨设备转写如需持久化，migration 优先 `000035_voice_transcriptions`。
- [ ] 支持单条转文字 + 用户级自动转文字 preference。
- [x] 不静默上传语音到未声明第三方。
- [x] 总负责人已补“耗尽临时失败后允许显式重试重新排队”的状态机 follow-up，并用隔离 PostgreSQL 验证。
- [x] 状态：`FIXED-PENDING-RETEST`；最终聊天 UI/真机播放/真实 STT 质量仍待 Wave3 与人工验收。

### AI09 / B14 Windows clipboard image

- [ ] Windows clipboard image reader，优先复用现有 `pasteboard`。
- [ ] Ctrl+V 有图片时走现有图片发送/预览/上传链。
- [ ] 只有文本时保留 TextField 原生粘贴。
- [ ] 同一次快捷键不重复插入文本/重复发送。
- [ ] 空剪贴板、坏格式、超大图、连续粘贴有边界处理。
- [x] 非 Windows 不受影响。
- [x] 状态：`FIXED-PENDING-RETEST`；Ctrl+V 热点接线留给 Wave3。

### AI10 / B08 Live Photo

- [ ] 证明当前 PHPicker 单 representation 丢 paired motion。
- [ ] iOS picker 识别 Live Photo，缓存 still + paired video；保持 path-based。
- [ ] 定义向后兼容 message/media transport。
- [ ] still/video 归属、授权、失败回滚完整。
- [ ] 非 iOS 安全显示 still + 实况标识。
- [ ] 支持端可触发 motion playback。
- [x] migration 使用 `000036_live_photo_message_media`，与 `000034/000035` 无编号冲突。
- [x] 状态：`FIXED-PENDING-RETEST`；最终实况标识/motion playback 与真实 iPhone 验收留给 Wave3/人工测试。

## E. Wave 3：总负责人热点接线

> 唯一基线：`6ac4e6e6c2d37a234cde3219bb4ce5685a0c5298`；独立单写者 worktree：`C:\Users\admin\.devspace\worktrees\repo-d1b35e04`。禁止从 dirty master 开工，禁止并行 AI 抢写聊天热点文件。

- [ ] 单写者修改 `text_chat_page.dart`。
- [ ] Voice controller/STT/red dot/auto-play 接线。
- [ ] Windows clipboard image adapter 接线。
- [ ] Live Photo sender/viewer 接线。
- [ ] 群消息头像 long-press 插入精确 mention entity，不只字符串 `@名字`。
- [ ] 群内/群外红色 `【有人@你】`。
- [ ] 点击 mention 进入 conversation 并定位/highlight message。
- [ ] viewer-relative effective display name 全局接线。
- [ ] 复核 AI12 resume 不与 Call/Push lifecycle 打架。

## F. 最终自动门禁

- [ ] `server: go test ./...`。
- [ ] `server: go vet ./...`。
- [ ] `clients/realtime_poc: dart test`。
- [ ] `clients/app: dart analyze --fatal-infos`。
- [ ] `clients/app: flutter test`。
- [ ] migration embed/contract/integration。
- [ ] Android APK build。
- [ ] Windows build/package。
- [ ] iOS unsigned/cloud 可执行合同门禁。
- [ ] Git diff 无 secret/token/build/cache/临时垃圾。

## G. 真人验收后收口

- [ ] B16 注册验证码倒计时/成功文案。
- [ ] B17 锁屏 1/5/30 分钟恢复连接与消息补齐。
- [ ] iOS B01/B02/B08。
- [ ] B03 备注显示名 + 隐私。
- [ ] B04-B07/B05 Voice/STT。
- [ ] B09 swipe。
- [ ] B10 Moments 评论颜色。
- [ ] B11 生产群通话双/多设备。
- [ ] B12 @ 提醒重启/多设备/直达。
- [ ] B13 Telegram 实际 pack。
- [ ] B14 Windows Ctrl+V 图片。
- [ ] B15 Android Push 前台/后台/recent-task swipe/system kill；Force Stop 做对照。
- [ ] 通过项改 `VERIFIED/HUMAN-PASS`。
- [ ] 总负责人统一更新 docs/progress/changelog。
