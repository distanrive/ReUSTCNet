# 旧版 `main.py` 代码审阅

对 `oldversion/main.py`（约 1020 行的 Tkinter 单文件实现）做的一次逐函数审阅，按严重程度分组。
每一条都给了证据行号，并注明在新实现（纯 GDScript）里的对应处理。

> 行号以移入 `oldversion/` **之前**的 `main.py` 为准（文件内容未改动）。

---

## A. 严重：会让用户看到错误行为

### A1　点「停止」之后，程序仍会在后台重连一次

**位置**：`main.py:355-407`（`start_monitoring`）、`main.py:409-414`（`stop_monitoring`）

`stop_monitoring()` 做两件事：把 `running` 置 `False`、把 `persistent_session` 置 `None`。
但监控线程可能正卡在 `time.sleep(interval)` 里 —— 常规模式下这个 `interval` 默认 **900 秒**。
线程醒来后的循环体是这样开头的：

```python
if state == "normal":
    time.sleep(interval)
    if self.check_permission():          # ← 没有复查 self.running
```

`check_permission()` 第一行是 `if self.persistent_session is None: return False`，
而 `stop_monitoring()` 刚好把它清空了，于是必然返回 `False`，流程走进「网络异常」分支：

```python
status_callback("网络异常，正在重连...", True)
success, msg = self.full_reconnect()     # ← 真的重新建 session、登录、开通网络
```

**用户看到的现象**：点了「停止」，日志里过一会儿（最多 15 分钟）冒出一串
「网络异常，正在重连...」，而且程序**真的重新登录了一次校园网**。
若此时窗口已经关闭（隐藏到托盘再退出），`status_callback` 里的
`self.root.after(0, ...)`（`main.py:906`）会在 Tk 已经销毁之后调用，
抛 `RuntimeError: main thread is not in main loop`。

**新实现**：`scripts/core/net_monitor.gd`。循环改成主线程上的协程，
`stop()` 只做 `_generation += 1`，每次 `await` 之后第一件事就是核对代号：

```gdscript
while not _stale(gen):
    await _sleep(_interval_for_phase(), gen)
    if _stale(gen):
        return
```

等待还被切成 0.25 秒一片，所以「停止」最多 0.25 秒生效，不用等满 900 秒。

---

### A2　一次运行里，系统代理只会被关闭一次

**位置**：`main.py:368-383`（normal 分支）与 `main.py:385-390`（fast 分支）

`proxy_closed` 这个标志只在 **fast 分支**成功恢复联网时被复位：

```python
else:  # state == "fast"
    if self.check_permission():
        proxy_closed = False             # ← 只有这里复位
```

normal 分支里重连成功后（`main.py:378-383`）没有复位。于是：

1. 断网 → 关掉系统代理，`proxy_closed = True`；
2. 重连成功，回到 normal 模式 —— 标志位还是 `True`；
3. 再断网 → `if auto_close_proxy and not proxy_closed` 为假，**再也不关代理了**。

**新实现**：把这件复位提到两条路径共用的「已确认联网」出口
（`net_monitor.gd` 的 `_mark_online()`），normal / fast 都必经此处。

---

### A3　在非主线程里操作 Tk

**位置**：`main.py:995-1007`（托盘回调）、`main.py:696-709`（定时任务守护线程）

pystray 的回调跑在它自己的线程里，却直接调用 Tk：

```python
def run_icon():
    self.icon.run()                      # ← pystray 的线程
...
def show_window(self, _icon, _item):
    self.root.deiconify()                # ← 从那个线程里碰 Tk
def quit_app(self, _icon, _item):
    self.root.quit()
```

`_command_watcher_loop` 同样跨线程读写 `tk.BooleanVar`（`self.auto_command_var.get()`）。
Tk 不是线程安全的，这是挂起和随机崩溃的经典来源 —— 且这类问题很难复现、很难归因。

**新实现**：整个程序没有第二个线程。监控是主线程协程，定时器是 `Timer` 节点，
全部在 Godot 的主循环里跑。

---

## B. 中等：功能不正确或语义不符

### B1　`get_current_port_info()` 白花一次网络往返

**位置**：`main.py:296-315`

```python
def get_current_port_info(self):
    if self.persistent_session is None:
        return "未知"
    r = self.safe_get(self.persistent_session, base_url, params={"cmd": "disp"})
    if not r:                            # ← r 拿到之后完全没用上
        return "未知"
    port_map = {...}
    current_type = self.config_manager.config["export_type"]
    return port_map.get(current_type, ...)   # ← 返回值只取决于**配置**
```

它发了一次 HTTP GET，把响应丢掉，然后返回**配置里**的出口编号。
所以：每次状态更新都多一次请求；而界面上的「当前出口」永远反映不了网页上的真实出口
（如果用户在网页上手动换了出口，程序显示的还是配置里那个）。

**新实现**：`get_current_port_info()` 这类函数直接删掉，不发那个请求。
界面把这一项标成 **「目标出口」** 并注明是配置值，不冒充从网页读到的「当前出口」——
要从中文页面里可靠地解析出当前出口属于没把握的推断，宁可不做，也不显示一个可能是错的值。
（每 900 秒省下一次请求，对校园网认证服务器也算友好一点。）

---

### B2　在输入框里改完数字直接关窗，改动会丢

**位置**：`main.py:819-850`（`save_settings`）、各处回调

`save_settings()` 只在三个时机被调用：勾选/取消某个复选框、点「启动」、清除密码。
「常规检测时间」「断网重连时间」「确认倒计时」这几个输入框**没有绑定任何 `FocusOut` 或修改回调**，
用户改完数字直接关窗，`config.json` 里还是旧值。

**新实现**：所有输入控件都接到 `_on_setting_edited()`，由 0.6 秒防抖的 `Timer` 汇合到
`_commit_settings()` 落盘；关窗时（`NOTIFICATION_WM_CLOSE_REQUEST`）再强制保存一次。

---

### B3　登录成功的判据过宽

**位置**：`main.py:262`

```python
if "用户" in r.text and "拥有的权限" in r.text:
    return True, "登录成功"
```

`"用户"` 是登录页本身就有的词。只要返回的是「登录页回显」（比如密码为空、参数不对时），
两个条件就可能同时成立，于是程序**跳过登录**直接去开通网络，然后报一个与真实原因无关的错。

**新实现**：判据收紧成只看 `拥有的权限`（`wlt_client.gd` 的 `MARK_HAS_ACCOUNT`），
和 `is_logged_in()` 用同一条证据。

---

### B4　中文判据全靠猜编码，猜错就静默失效

**位置**：`main.py:199-205`（`set_encoding`）、`main.py:234`、`main.py:294`

```python
@staticmethod
def set_encoding(response):
    if response.apparent_encoding and response.apparent_encoding.lower() not in ('ascii','iso-8859-1'):
        response.encoding = response.apparent_encoding
    else:
        response.encoding = 'gb2312'
```

三类判据（`"权限: 国际" in r.text`、`"拥有的权限" in r.text`、`"网络设置成功" in r.text`）
全部建立在这个「猜」出来的编码上，而且**猜完不验证**。

实测（2026-09-22）：`http://wlt.ustc.edu.cn/cgi-bin/ip` 的响应头是

```
HTTP/1.1 200 OK
Content-Type: text/html          ← 不带 charset
```

响应的确是按 GB2312 发的（`<META ... charset=gb2312>`）。一旦 `apparent_encoding` 猜成别的
（不同版本 charset_normalizer 的启发式会有差异），`r.text` 就是乱码，
所有中文判据同时返回 `False` —— 表现为**「网络明明是好的，程序却一直报断网、一直重连」**，
而且日志里看不出任何异常，因为请求本身是成功的。

**新实现**：不再猜，按页面自己声明的 charset 选解码器，并修好两处会踩的坑：

- Windows 上只有编码名 **`"gb2312"`** / `"gb18030"` 是有效的；
  实测 `"936"` / `"GBK"` / `"cp936"` 都会返回**空串**并往控制台打一行
  `Conversion failed: Unknown encoding`（见 `tools/self_check.gd` 的回归项）。
- `String.to_multibyte_char_buffer()` 会**带上结尾的 `\0`**，不清掉的话每个中文表单参数
  末尾都会多一个 `%00` 发给服务端（这条是自检抓出来的，见 `wlt_client.gd` 的
  `_trim_trailing_nuls`）。

另外补了一条比「数替换字符」更硬的判据：**字节本身是不是合法 UTF-8**。
GBK 几乎能接受任意字节对，把 UTF-8 字节喂给 GBK 解出来的东西往往一个替换字符都没有、
只是内容全是错字 —— 光看替换字符分辨不出来。回归项见
`tools/self_check.gd` 的「真实 GB2312 页面片段不被误判」。

---

### B5　「取消」也算今天已经触发过

**位置**：`main.py:696-709`（`_command_watcher_loop`）

```python
if (now.hour == target_h and now.minute == target_m and
        self._command_last_triggered != trigger_key):
    self._command_last_triggered = trigger_key      # ← 弹窗**之前**就写死了
    self.root.after(0, self._on_command_triggered)
```

`_on_command_triggered` 里才 `save_settings()` 落盘。用户在倒计时窗口点「取消」，
记录已经写下去了 —— 而 README 写的是「**执行后**…不会重复触发」。
结果是：点了一次取消，当天这个时间点就再也不会响了，只能手动点「重置触发」。

**新实现**：`command_scheduler.gd` 把两件事分开：

- `_handled_key`（**内存**）：无论执行还是取消，同一分钟内不再重复弹窗；
- `last_triggered`（**持久化**）：只在用户确认**执行**之后才写（`resolve(key, true)`）。
  点「取消」调 `resolve(key, false)`，不消耗当天的机会。

---

### B6　开发期点「自启」会往注册表写一条没用的项

**位置**：`main.py:858-873`（`toggle_auto_start`）、`main.py:970-981`（`is_startup_enabled`）

```python
exe_path = os.path.abspath(sys.argv[0])       # 源码运行时是 main.py 的路径
winreg.SetValueEx(key, "ReUSTCNet", 0, winreg.REG_SZ, exe_path)
```

从源码运行时写进去的是 `main.py` 的路径，Windows 登录后无法执行 `.py`，
于是「开机自启」开关显示已打开、注册表里也确实有一项，但**永远不会生效**。

**新实现**：路径一律取 `OS.get_executable_path()`（导出后就是 exe 自己）；
并且在开发期（`OS.has_feature("editor")`）**直接禁用这个开关**
（`win_system.gd` 的 `autostart_supported()`），从根上避免写出无效项。

---

## C. 轻微 / 结构问题

| # | 位置 | 问题 | 新实现 |
|---|---|---|---|
| C1 | `main.py:29-36` | 单实例靠「CPython 不会自动 `CloseHandle` 局部变量」这个巧合成立（`mutex` 没有被保存成全局）。目前能用，但属于依赖实现细节 | 改用 `TCPServer` 占 127.0.0.1 高位端口（`instance_guard.gd`），端口占用是内核级的，没有竞态；顺带把「再开一次就唤起已有窗口」做出来了 |
| C2 | `main.py:270` | `f"登录失败: {r.text[:50]}..."` 把带换行和标签的 HTML 片段写进日志，一条错误摊成好几行、时间戳也对不上 | `wlt_client.gd` 的 `_headline()` 先剥标签、压空白再截断；`log_store.gd` 再把换行压成空格 |
| C3 | `main.py:178-190` | 每次保存都重新 DPAPI 加密同一个密码 → 同样的密码产生不同密文，配置文件每次写入都变，「配置有没有改过」用文件哈希判断不了 | `app_config.gd` 的 `_cipher_for_disk()` 只在明文变化时才重新加密 |
| C4 | `main.py:160-176` | `expire` 恒为 `"0"`，UI 与代码都不碰它 —— 死配置项 | 从配置里去掉，只在请求参数里保留（`wlt_client.gd` 的 `activate()`） |
| C5 | `main.py:904-931` | 用正则从人类可读的消息文本里抠出口名（`re.search(r'当前连接到:\s*(.+)', msg)`），靠字符串约定在模块间传结构化数据 | 状态用 `(短状态, 完整消息, 种类)` 三元组经信号传递，界面各取所需；出口名由 `WltClient.export_name()` 从编号直接算 |
| C6 | `main.py:897-902` | 日志按天追加，无轮转、无清理，跑久了单文件能到几十 MB | `log_store.gd`：单文件超过 2 MB 轮转成 `.1`，并清理 14 天前的日志 |
| C7 | `main.py:146-158` | 配置损坏时 `except: pass` 后直接落到「写一份默认配置」，把用户原来的文件**覆盖掉** | 解析失败时保留原文件、只在内存里用默认值，并打一行 `push_warning` |
| C8 | `main.py:711-782` | 倒计时对话框每次触发都新建，`self.command_dialog` 只用来防重入；`running` 用单元素列表做可变闭包，可读性差 | 对话框状态收到成员变量上，并用「关掉时返回 bool」防止长按与倒计时同时到达时重复执行 |

---

## 附：新实现顺带做的两件事

1. **键盘输入不再是唯一入口**：旧版所有参数只有「改完就存」一条路，
   现在关窗、点启动、托盘切换都会先 `_collect()` 再落盘，不存在「改了没生效」的中间态。

2. **界面状态只有一个来源**：头部状态点、头部文字、状态卡里的点和文字这四处
   由 `app.gd` 的 `_set_status()` 统一改，不会再出现「上面显示已连接、下面显示失败」。
