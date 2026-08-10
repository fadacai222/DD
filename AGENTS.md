# DD 工具调用长期规则

> 本文件用于持久化本项目在 DD 工具中的常见坑。以后打开本仓库时优先遵守，避免重复踩坑。

## DD / Windows 常见坑

1. `dd.bash` 运行的是 Bash，不是 PowerShell。
   - 不要直接运行 `Get-ChildItem`、`Select-Object`、`Format-Table` 等 PowerShell cmdlet。
   - Bash 下优先使用 `ls`、`find`、`rg`、`grep`、`sed`。
   - 确实需要 PowerShell 时显式调用 `powershell.exe -NoProfile -Command "..."`。

2. `dd.bash.timeout` 单位是秒，最大 300。
   - 例如 2 分钟写 `120`，不要写 `120000`。

3. 同一个项目不要重复 `open_workspace`。
   - 首次打开后复用已有 `workspaceId`。
   - 只有切换目录/工作树、workspaceId 失效或用户明确要求重开时才重新打开。

4. 项目文件修改必须使用 `dd.edit` / `dd.write`。
   - `dd.bash` 只用于搜索、读取、测试、构建、Git 检查等。
   - 不要用 shell 重定向、`tee`、`sed -i`、Python/Node 脚本等方式写项目文件。

5. 路径与 `~` 展开要谨慎。
   - 不要假定 DD 的文件读取工具会自动展开 `~`。
   - 项目内文件优先使用相对项目根目录的路径。
   - 技能文件需要时使用工具返回的可读路径或完整 Windows 路径。

6. 避免一次读取过大文件。
   - 终端输出可能被截断。
   - 大文件先用 `rg -n` 定位，再分段读取。

7. Windows 仓库中的 `nul` 可能让 `rg` 报 `函数不正确 (os error 1)`。
   - 搜索时限定目录，或添加 `--glob '!nul'`。

8. 中文文件统一按 UTF-8 处理。
   - 看到乱码先核对编码，不要直接判断文件损坏。

9. 网页项目默认不要启动长期服务或浏览器。
   - 优先使用 build / lint / test / typecheck 等一次性验证。
   - 必须临时启动时记录端口/PID，并在测试结束后主动关闭。

10. 工具报错先判断调用问题还是项目问题。
    - `command not found`：先检查 Bash / PowerShell 是否用错。
    - schema / timeout 报错：检查参数单位与工具限制。
    - 输出截断：缩小读取范围，不要误判代码缺失。
    - 路径沙箱报错：不要反复重试同一非法路径。

## 当前项目固定路径

```text
C:\Users\admin\Desktop\复刻微信
```

打开后，所有项目内操作优先基于 workspace 根目录使用相对路径。

## DD 开发文档优先级

11. 后续开发必须以 `docs/` 为主要规格入口。
   - 每次开工先读 `docs/README.md`。
   - 再读 `docs/15-当前实现状态与开发路线.md`。
   - 然后只加载与当前任务相关的专题文档和源代码，不要无差别读取全部 docs。
   - 当前源代码、migration、自动测试用于判断“实际上实现了什么”；docs 用于约束“产品应该怎么做、下一步先做什么”。
   - 如果代码事实已经改变，同一次开发必须同步更新相关 docs。
   - 根目录 `开发进度跟踪.md`、`人工测试-BUG修复-todolist.md` 是进度/真人反馈证据；`tasks/*.md` 和归档需求不得覆盖当前代码与 docs 结论。
   - 真人未重新验收的修复必须标为 `FIXED-PENDING-RETEST`，不能仅凭代码或 Widget Test 写成已完成。
