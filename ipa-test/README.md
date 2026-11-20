# ADB Sync 真机测试工具

对 iOS 端（`ios/AdbWebCast`）ADB 协议实现做真机全功能测试的工具，协议语义与
`AdbProtocol.swift` 1:1 对齐（版本 0x01000001、maxdata 协商、帧限 ≤ 设备 maxdata、
每帧 WRTE 等传输层 OKAY、sync 字节流缓冲、截图 CRLF 修复、内置同一对 RSA 密钥）。

## 用法

```bash
# 全功能测试（扫描 → 握手 → shell → 设备信息 → 列目录 → 截图 → push/pull 往返 → 遥控 → 应用列表）
python3 run_tests.py                 # 默认 10.10.10.28 与 10.10.10.53
python3 run_tests.py <ip> [<ip>...]  # 指定电视

# 安装测试（零副作用：从电视拉同版本 base.apk 再覆盖回装）
# 单项命令见 adbclient.py 底部 AdbClient 类
```

依赖：Python 3.9+，`pip3 install cryptography`

## 实测环境（2026-11-20）

| 设备 | 系统 | 结果 |
|---|---|---|
| 10.10.10.28 Sony BRAVIA 4K UR3 | Android 9 (SDK 28) | 全项通过（截图需回桌面，DRM 内容时 screencap 返回 0B 属正常） |
| 10.10.10.53 Amazon Fire TV AFTKA | Android 9 (SDK 28) | 全项通过 |

## 重要发现（影响 AdbProtocol.swift）

1. **DENT 响应没有 length 字段**：adbd 的 sync 响应格式是
   `DENT: id+mode+size+mtime+namelen+name（固定 20B 头）`、`DONE/OKAY: 仅 4B id`、
   `FAIL/DATA: id+len+payload`。按「8 字节头(id+len)」解析会把 mode 误读为 length
   （如 0x41f9=16889B）→ 死等 → 超时。「VIDAA adbd 对 sync LIST 零响应」的怪癖
   不存在，修正解析后两台电视 sync LIST 均 0.1s 返回，shell 兜底可废弃。
   修复代码见 `sync-fix.swift.patch`。
2. **push 的 DONE 包**：官方格式是时间戳放在 length 字段、无 body；发 body 会被
   adbd 当作垃圾包不回 ACK → 安装卡死（两台电视实测复现）。QUIT 同理。

## 已知设备行为

- Sony BRAVIA：`screencap` 在 DRM/受保护画面下输出 0 字节（文件方式同样 0B），
  回到桌面后正常（约 1.5MB PNG）。
- Sony BRAVIA：adb shell 带 PTY 时 `ls` 输出列式排版，shell 兜底解析会出碎片名；
  sync LIST 修正后不再依赖该路径。
