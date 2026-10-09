#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""给 Godot 源码打上「chunk 长度行容错」补丁 —— 不开这个补丁，本程序在校园网上**一条请求都发不出去**。

背景（2026-10-03 实测，整条链都验过）
------------------------------------
`wlt.ustc.edu.cn` 的响应是 `Transfer-Encoding: chunked`，而它的分块长度行**末尾多一个空格**：

    fe5\r\n            <- 第一块，正常
    <4069 字节数据>\r\n
    8c \r\n            <- 第二块，长度后面多了个空格（RFC 7230 只允许十六进制数字）
    ...

curl / Chrome / Python 的 requests 都**容错**（跳过空白），所以老版本（Python）一直能用；
但 **Godot 4.7 的 HTTP 客户端是严格的**，见到空格直接判 `HTTP Chunk len not in hex!!`、
把状态置成 `STATUS_CONNECTION_ERROR` —— 表面现象是 `HTTPRequest` 返回
`RESULT_CONNECTION_ERROR`（"连接被断开"），**看起来像网络问题，其实连接和数据都好好的**。

实测对照（同一个本地服务器，只改长度行里那个空格）：

    规范 `7\\r\\n`   -> result=0  code=200  body=34
    带空格 `7 \\r\\n` -> result=4  code=0    + ERROR: HTTP Chunk len not in hex!!

补丁做的事
----------
在 `core/io/http_client_tcp.cpp` 的 `read_response_body_chunk()` 里，解析分块长度时：
* 跳过空格/制表符（curl 也是这么做的）；
* 遇到 `;` 就停 —— 那是 RFC 允许的 chunk-extension，后面本来就不该当长度解析。

**为什么打在引擎里而不是改我们的脚本**：Godot 没有让我们自己控制 HTTP 版本/分块解析的接口，
而 `HTTPRequest` 的重定向跟随、超时、gzip 解压都是现成好用的，重新手写一套 HTTP 客户端
风险更大。代价是**这份源码树成了本项目的必需品** —— 用官方模板导出的 exe
**连不上校园网**，所以 `build_template.sh` 每次都会先跑这个补丁（幂等）。

升级 Godot 版本时：这个脚本会在找不到锚点时**明确报错**（而不是悄悄跳过），
照着新版源码把 `else if (c == ';')` 那两行补上即可。
"""

import io
import os
import sys

GODOT_SRC = os.environ.get("GODOT_SRC", r"D:\godot-build\godot")
TARGET = os.path.join(GODOT_SRC, "core", "io", "http_client_tcp.cpp")

MARK = "ReUSTCNet patch: chunk 长度行容错"

ANCHOR = """						} else if (c >= 'A' && c <= 'F') {
							v = c - 'A' + 10;
						} else {
							ERR_PRINT("HTTP Chunk len not in hex!!");"""

PATCHED = """						} else if (c >= 'A' && c <= 'F') {
							v = c - 'A' + 10;
						} else if (c == ';') {
							// %s：分号后面是 RFC 7230 允许的 chunk-extension，不是长度的一部分
							break;
						} else if (c == ' ' || c == '\\t') {
							// %s：容忍长度数字周围的空白（curl / 浏览器都这么做）。
							// 校园网 wlt.ustc.edu.cn 的分块长度行就带一个尾随空格。
							continue;
						} else {
							ERR_PRINT("HTTP Chunk len not in hex!!");""" % (MARK, MARK)


def main() -> int:
    if not os.path.isfile(TARGET):
        print("[patch] 找不到 %s" % TARGET, file=sys.stderr)
        print("[patch] 用 GODOT_SRC=<Godot 源码目录> 指定路径", file=sys.stderr)
        return 1
    src = io.open(TARGET, encoding="utf-8").read()

    if MARK in src:
        print("[patch] 已经打过补丁，跳过")
        return 0

    if ANCHOR not in src:
        print("[patch] 在 %s 里找不到锚点 —— Godot 源码可能换了版本/改了实现。" % TARGET,
              file=sys.stderr)
        print("[patch] 请照着 tools/patch_godot_chunked.py 顶部说明手工补上那两行，", file=sys.stderr)
        print("[patch] 否则编出来的模板会让本程序**在校园网上一条请求都发不出去**。", file=sys.stderr)
        return 1

    io.open(TARGET, "w", encoding="utf-8", newline="\n").write(src.replace(ANCHOR, PATCHED, 1))
    print("[patch] 已给 %s 打上 chunk 长度行容错补丁" % TARGET)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
