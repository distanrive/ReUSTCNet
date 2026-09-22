class_name SecretStore
extends RefCounted
## 密码的加解密（AES-256-CBC），密钥存在 `HKCU\Software\ReUSTCNet`。
##
## 为什么不是 DPAPI：GDScript 没有 Win32 API，`CryptProtectData` 用不了。
## 这里换成「一把随机密钥放注册表 + AES 加密后写配置」，保护的是**同一个威胁模型**：
## 配置文件被单独拷走（备份、同步到网盘、发给别人）时解不出密码。
##
## 比 DPAPI **弱**的一点要说清楚：能读到当前 Windows 用户注册表的人，密钥和密文一起拿到。
## DPAPI 的多一层是「密钥绑在用户的 master key 上」—— 这一层这里没有。
## 所以：登录了你的 Windows 账户的攻击者，两种方案都挡不住；区别只在配置文件单独泄漏时。
##
## 密钥**不混入 `OS.get_unique_id()`**：官方文档明确写它「可能因重装系统/升级/更换硬件而
## 变化，不要用于安全用途」。混进去只会多一个「密码突然解不开」的失败模式，不增加安全性。

const PREFIX := "enc:"
const KEY_VALUE_NAME := "Key"
const KEY_SIZE := 32      # AES-256
const IV_SIZE := 16

enum Source { NONE, REGISTRY, FILE }

static var _cached_key := PackedByteArray()
static var _source := Source.NONE
static var _crypto := Crypto.new()


## 加密成 `enc:<base64(iv + 密文)>`。空串原样返回（表示「不保存密码」）。
##
## 用 `AESContext`（AES-256-CBC）而不是 `Crypto.encrypt()` —— 后者要的是 `CryptoKey`
## 资源（非对称密钥那套），拿一把裸的对称密钥喂不进去。
## CBC 要求数据是 16 字节的整数倍，所以自己补 PKCS#7 填充（解密时再摘掉）。
static func encrypt(plain: String) -> String:
	if plain.is_empty():
		return ""
	var iv := _crypto.generate_random_bytes(IV_SIZE)
	var body := _pkcs7_pad(plain.to_utf8_buffer())
	var aes := AESContext.new()
	if aes.start(AESContext.MODE_CBC_ENCRYPT, _get_key(), iv) != OK:
		push_error("[SecretStore] 加密初始化失败，密码未保存")
		return ""
	var cipher := aes.update(body)
	aes.finish()
	if cipher.is_empty():
		push_error("[SecretStore] 加密失败，密码未保存")
		return ""
	var blob := iv.duplicate()
	blob.append_array(cipher)
	return PREFIX + Marshalls.raw_to_base64(blob)


## 解密。不以 `enc:` 开头的值原样返回 —— 用户手工在配置里写了明文时按明文用（保存时会重新加密）。
static func decrypt(stored: String) -> String:
	if stored.is_empty():
		return ""
	if not stored.begins_with(PREFIX):
		return stored
	var blob := Marshalls.base64_to_raw(stored.substr(PREFIX.length()))
	if blob.size() <= IV_SIZE or (blob.size() - IV_SIZE) % IV_SIZE != 0:
		push_warning("[SecretStore] 密文长度不对，按空密码处理")
		return ""
	var aes := AESContext.new()
	if aes.start(AESContext.MODE_CBC_DECRYPT, _get_key(), blob.slice(0, IV_SIZE)) != OK:
		push_warning("[SecretStore] 解密初始化失败，按空密码处理")
		return ""
	var plain := _pkcs7_unpad(aes.update(blob.slice(IV_SIZE)))
	aes.finish()
	if plain.is_empty():
		push_warning("[SecretStore] 解密失败（换过机器/用户，或密钥已丢失），按空密码处理")
		return ""
	return plain.get_string_from_utf8()


## PKCS#7 填充：补 n 个值为 n 的字节，n = 16 - (长度 % 16)，n 恒在 1..16。
static func _pkcs7_pad(data: PackedByteArray) -> PackedByteArray:
	var pad := IV_SIZE - (data.size() % IV_SIZE)
	var out := data.duplicate()
	for _i in pad:
		out.append(pad)
	return out


## 摘掉 PKCS#7 填充。填充不合法（密钥不对时会这样）就返回空数组。
static func _pkcs7_unpad(data: PackedByteArray) -> PackedByteArray:
	if data.is_empty():
		return PackedByteArray()
	var pad := data[data.size() - 1]
	if pad < 1 or pad > IV_SIZE or pad > data.size():
		return PackedByteArray()
	for i in range(data.size() - pad, data.size()):
		if data[i] != pad:
			return PackedByteArray()
	return data.slice(0, data.size() - pad)


## 密钥当前存在哪 —— 界面要把「已降级为文件存储」这件事明确告诉用户，不能静默。
static func key_source() -> Source:
	_get_key()
	return _source


static func key_source_text() -> String:
	match key_source():
		Source.REGISTRY:
			return "注册表（HKCU\\Software\\ReUSTCNet）"
		Source.FILE:
			return "文件（%s）—— 安全性低于注册表" % AppPaths.fallback_key_file()
		_:
			return "不可用"


# ---------------------------------------------------------------- 内部

static func _get_key() -> PackedByteArray:
	if _cached_key.size() == KEY_SIZE:
		return _cached_key
	var key := _load_registry_key()
	if key.size() != KEY_SIZE:
		key = _create_registry_key()      # 首次运行：生成一把并写进注册表
	if key.size() == KEY_SIZE:
		_cached_key = key
		_source = Source.REGISTRY
		return _cached_key
	_cached_key = _load_or_create_file_key()
	_source = Source.FILE
	return _cached_key


static func _load_registry_key() -> PackedByteArray:
	var r := WinRegistry.read_string(WinRegistry.APP_KEY, KEY_VALUE_NAME)
	if not r["ok"]:
		return PackedByteArray()
	var key := Marshalls.base64_to_raw(str(r["value"]).strip_edges())
	if key.size() != KEY_SIZE:
		return PackedByteArray()
	return key


## 首次运行：生成一把随机密钥写进注册表，**读回来核对一遍**再采用。
## 读回校验是必要的：组策略或权限问题可能让 `reg add` 返回成功但值没落下去，
## 那样下次启动就会「密钥变了 → 密码解不开」。
static func _create_registry_key() -> PackedByteArray:
	var key := _crypto.generate_random_bytes(KEY_SIZE)
	if not WinRegistry.write_string(WinRegistry.APP_KEY, KEY_VALUE_NAME,
			Marshalls.raw_to_base64(key)):
		return PackedByteArray()
	if _load_registry_key() != key:
		return PackedByteArray()
	return key


static func _load_or_create_file_key() -> PackedByteArray:
	var path := AppPaths.fallback_key_file()
	var existing := _read_key_file(path)
	if existing.size() == KEY_SIZE:
		return existing
	var key := _crypto.generate_random_bytes(KEY_SIZE)
	_write_key_file(path, key)
	var check := _read_key_file(path)
	return check if check.size() == KEY_SIZE else key


static func _read_key_file(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var key := Marshalls.base64_to_raw(f.get_as_text().strip_edges())
	f.close()
	return key if key.size() == KEY_SIZE else PackedByteArray()


static func _write_key_file(path: String, key: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[SecretStore] 无法写入密钥文件 %s" % path)
		return
	f.store_string(Marshalls.raw_to_base64(key))
	f.close()
	# 顺手设成隐藏 —— 不是安全措施，只是别让用户在文件夹里看着它碍眼
	OS.execute("attrib.exe", PackedStringArray(["+h", path.replace("/", "\\")]))
