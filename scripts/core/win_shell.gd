class_name WinShell
extends RefCounted
## Windows 外部命令调用的统一收口。
##
## 为什么要有这一层：整个工程对外部程序的调用（`reg.exe`、`cmd.exe`、资源管理器）
## 都在这里，参数怎么拼、要不要等、会不会弹黑框，只有一处需要想清楚。
##
## 两条已知事实（取自 Godot 4.7 官方文档，实现时也实测过）：
##   * `OS.execute` **没有 working_directory 参数** —— 需要指定工作目录的场合
##     （执行 command.bat）得自己拼 `cmd /c "cd /d ... && ..."`，见 `run_detached`。
##   * `open_console` 默认 false，**只有显式设为 true 且目标是控制台程序才会弹新终端窗口**，
##     所以下面默认都不弹黑框。
##
## 参数一律以 PackedStringArray 传入，不经 shell —— 路径里的空格由 Godot 负责加引号。

## 运行一条短命令并等它结束，返回 `{"ok": bool, "code": int, "out": String}`。
##
## **会阻塞主线程**直到子进程退出。只用于 `reg` 这种几十毫秒就返回的命令；
## 会长时间运行的（批处理）请用 `run_detached()`。
static func run(exe: String, args: PackedStringArray) -> Dictionary:
	var chunks: Array = []
	var code := OS.execute(exe, args, chunks, true)
	var text := ""
	for c in chunks:
		text += str(c)
	return {"ok": code == 0, "code": code, "out": text}


## 起一条命令后立刻返回，不等它结束。返回 pid（失败为 -1）。
##
## `OS.create_process` 起的进程**不会随 Godot 退出而结束** —— 这是引擎文档明确写的。
## 本工程的用途（跑用户的 command.bat、开资源管理器）正好就是要它活下去，
## 所以不接管生命周期；要收进程的话记得先 `OS.is_process_running(pid)` 再 `OS.kill(pid)`。
static func run_detached(exe: String, args: PackedStringArray) -> int:
	return OS.create_process(exe, args)


## 在指定工作目录里执行一条 cmd 命令（把 `cd /d` 与命令拼成**同一个参数**，
## 这样 Godot 的加引号规则不会把 `&&` 拆散）。
static func run_cmd_in_dir(command: String, working_dir: String) -> int:
	var native := working_dir.replace("/", "\\").rstrip("\\")
	var script := "cd /d \"%s\" && %s" % [native, command]
	return run_detached("cmd.exe", PackedStringArray(["/c", script]))
