extends SceneTree
func _initialize() -> void: _run()
func _run() -> void:
	for i in 8:
		var r := WinRegistry.read_string(WinRegistry.APP_KEY, "Key")
		if i == 0:
			print(">>> 第 1 次 reg 调用 ok=%s" % str(r["ok"]))
	print(">>> 8 次调用结束")
	await create_timer(15.0).timeout
	print(">>> 15 秒观察结束，退出")
	quit()
