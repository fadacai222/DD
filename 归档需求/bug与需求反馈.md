0.windows端的左侧大黑条不符合现代审美 

整个软件看着都土里土气的 

请参考windows端微信和telegram 

取其精华去其糟粕 

帮我设计并一下我的win端的dd 要求现代化UI再战未来三五年不成问题

<img title="" src="file:///C:/Users/admin/AppData/Roaming/marktext/images/2026-08-10-05-35-31-2026-08-10_05-35-30.png" alt="" width="507">

<img title="" src="file:///C:/Users/admin/AppData/Roaming/marktext/images/2026-08-10-05-35-25-2026-08-10_05-35-07.png" alt="" width="284"><img title="" src="file:///C:/Users/admin/AppData/Roaming/marktext/images/2026-08-10-05-36-33-2026-08-10_05-36-30.png" alt="" width="287">

1.安卓端的图片/视频/gif等复制按钮 全部取消  因为媒体类在安卓根本不好复制

2.长图头像裁剪 

我打开正方形图片还没事 

我打开一个截屏直接给我看了个鬼  

这写的是个什么鸡巴编辑器 

他妈的一打开的初始位置就是错误的 整个编辑器都需要推翻重构 

不要在图片编辑器代码死磕了 直接重写

<img src="file:///C:/Users/admin/AppData/Roaming/marktext/images/2026-08-10-05-10-30-2026-08-10_05-10-07.png" title="" alt="" width="163">

我给你看微信怎么做的：

背景层 满屏
图片层等比例对齐宽度 注意原图不可被压扁 等宽不等高 
裁剪框 有八个锚点 正方形 点击锚点可以缩放裁剪框  
有完成 取消 图片旋转 还原 四个按钮

<img title="" src="file:///C:/Users/admin/AppData/Roaming/marktext/images/2026-08-10-05-11-25-image.png" alt="" width="190">

3.操作：联系人--随便选一个---点击发消息会单开一个满窗口私聊，不符合逻辑：<img src="file:///C:/Users/admin/AppData/Roaming/marktext/images/2026-08-10-05-17-25-2026-08-10_05-17-24.png" title="" alt="" width="389">

正确的方式应该是跳转到消息，然后在消息内单开一个私聊

<img src="file:///C:/Users/admin/AppData/Roaming/marktext/images/2026-08-10-05-17-56-2026-08-10_05-17-55.png" title="" alt="" width="412">

4.消息通知显示异常 红框标记的那个小安卓头怎么没我DD的图标？我写的是个什么野鸡app吗？不配有一个通知图标吗？

![](C:/Users/admin/AppData/Roaming/marktext/images/2026-08-10-05-19-14-2026-08-10_05-19-04.png)

5.怎么只有安卓端有通话音效 妈的win端呢？win端连消息通知音效都没有了
来电铃声好难听 换一个

6.win端连语音条都没有了 直接语音播放失败，请稍后重试· 啥也没了

<img title="" src="file:///C:/Users/admin/AppData/Roaming/marktext/images/2026-08-10-05-21-11-2026-08-10_05-21-00.png" alt="" width="452">

7.发视频的一个都测不了 全员报错 你看看telegram怎么做的 给我重做

![](C:/Users/admin/AppData/Roaming/marktext/images/2026-08-10-05-22-13-2026-08-10_05-22-03.png)

8.这仨不符合逻辑  合并成一个“相册” 这样就同时支持图片 视频 gif了

8.![](C:/Users/admin/AppData/Roaming/marktext/images/2026-08-10-05-23-00-2026-08-10_05-22-56.png)

9.详细资料UI很明显没有对齐 需要重新设计成telegram同款的

<img src="file:///C:/Users/admin/AppData/Roaming/marktext/images/2026-08-10-05-24-56-2026-08-10_05-24-54.png" title="" alt="" width="205">

telegram参考图：

<img title="" src="file:///C:/Users/admin/AppData/Roaming/marktext/images/2026-08-10-05-26-15-2026-08-10_05-25-58.png" alt="" width="205">

10.表情功能目前只有一个emoji是不行的

需要支持微信自定义表情

一个小爱心选项卡表示自定义表情 点击加号可以进入自定义表情管理

![](C:/Users/admin/AppData/Roaming/marktext/images/2026-08-10-00-25-24-2026-08-10_00-25-22.png)

自定义表情管理有关闭和整理按钮 点击整理可以多选并删除

点击加号可以自己上传表情包

![](C:/Users/admin/AppData/Roaming/marktext/images/2026-08-10-00-25-42-2026-08-10_00-25-38.png)

需要支持telegram贴纸包 https://t.me/addstickers/tmeaddsticss_yang2_yang2_by_fStikBot

但是考虑到国内无法访问t.me 所以需要在服务端加上表情包服务作为中转

每次新增一个贴纸包则需要多加一个选项卡 选项卡层级与自定义表情包同级

![](C:/Users/admin/AppData/Roaming/marktext/images/2026-08-10-00-29-24-2026-08-10_00-29-22.png)

11.移动端的软件需要做个开机第一屏用于遮挡连接过程 你帮我绘制一个像模像样的出来贴进去，后续需要开发ios包的时候也要用到

并且安卓端每次打开都要跳一次登陆注册界面 过于傻逼了 我打开就进聊天主界面 进不去再跳登陆

12.请看实现用户提及的开发方案.md

13.更新开发进度跟踪.md和新增一个人工测试.md
