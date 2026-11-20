#!/usr/bin/env python3
"""
ADB 客户端测试工具 —— 协议语义 1:1 对齐 ios/AdbWebCast/AdbProtocol.swift：
- CNXN version=0x01000001, maxData=1MB, payload "host::\\0"
- AUTH type=2: RSA PKCS1v15-SHA1(Digest 变体) 签 20 字节 token
- AUTH type=3: 公钥 blob = base64 文本 + '\\0'
- 设备 maxdata 协商：所有 WRTE 负载 <= min(64KB, 设备 maxdata)
- 每发一帧 WRTE 必须等本通道 OKAY（官方流控）
- sync 包：包头单独一帧、body 分帧；字节流解析（黏包/跨帧安全）
- CLSE 双向关闭；shell 截图 CRLF 修复；pm install -r -d
"""
import base64
import os
import socket
import struct
import sys
import time

ADB_PRIV_DER_B64 = (
    "MIIEowIBAAKCAQEAmLGjXzJ11wBrsi0IcQ5MBsTltcvMQXCfd9v6Hb1jn6cJjC4Y7pUzs98yqXIOGNAqhznWVoePiBQ4+MPna32s"
    "gSyCnAzYQ2MESZDwJVkxHobbVktypTo85veTw/VAQPDTudIvIfhZgqJvzONtDBbkpDCIXopV+H46Yd545LQ2gdz9fdT++EP77r4S"
    "b0MhQV8fq76jH2DvUkJ0C/mtISnf5QjiwSbPruS+TfDuCoWd4ZUypwzCg5AY3W7mfBzgP9alBbRlYYWM7ITVyDN1ncvFhYldQCSO"
    "5j94OhEaskX4wpeY2DZBWPusW6TOITePRoQ6I5GtmHxERflxQJ5IxkyMbQIDAQABAoIBADGyTyvirnvFhUe+ZGr3bkMdvm3G4LnD"
    "wAMws10OkOgbY34eWrr8EJHQaRrBJllpFw5gAqSzBkIR4uEEUcOoaYa5R+EmRRTZm0GeTKq7NsNqvOR/NdcU91Fs7sjuf3UjbKWk"
    "BPcXb3qXB7A1rP4sTUorCZdLiuOPoczMragyBzOIilRVTm0te6xoLWYTNsZVBcpOF6agDzdTzl1XCNqdOeO4krdufdT/02ACHDG0"
    "ntv/SHFYQIvd0wZIFserC2+umBfiOIciEkCQAfmzmlA66ZwDHAHVVhGqBScJE4mcshH4pnjJllb+7k9OHpcBGg0RiZ7jtxfm04cK"
    "2YkAQwhuarkCgYEA1ix58K++F+pKVImXpZk78BfTQSjEiiKy9uQoWInJ6Bu0CMa0nwavVIpZw1NSTO73FQAGMgcMDbJDxZIkhKF5"
    "vjiysPYkxSv06R6CaSExGFlWExK2xH96fNV7e1mqSro1usc0cekdxZbdyBo8Xua7IFGl5Bp2uUaRe24i8+q0mgsCgYEAtoOA/yGQ"
    "5fBjA3T9KFhgGxxVjUHqBnluiRJXb+NGFfjIBCcgZOU0zv1l0A5AlWAAQwrx5gKk8SvZ6UCNxJovlc5xb/HKt1mbZE0Q8Y5457Tq"
    "xjGKmKdWpqWhwu94Cb453zOMOfVojjEmMx3oksmZWWB2mdlz8WxaxnbvE8BU9mcCgYBmsWzGu32qeeyqHE9aV98lgEcLN0EF+x1U"
    "xJGT4n2tjZsFmkGA/vOS1cO0pH8R5IMUzq4pzrc42gEk+q4H6mU1kHod3+hBopIMNVTSk9e2lR9whcic74ML2FEdFCFTM3YP2PSM"
    "qfpcg7pT+EB6QKf5Fy0z8nx62htn06duzVtLgQKBgQCEzlvnSj1tk+X4dgBggy4rjAqUpwnrfCD6jOYi/HXbNxQUMYRY5o/urmSP"
    "aE+GYjzOjABJJlNvSkFegSKnlKpbj8TreD3R/NoduhZCLzG7KOJNJW98dQeQa6Wxex8Vt93UlGXNJs3V6d2qBHFfnmJ/rrmeaaT8"
    "X6QOFi0RajposQKBgA+jicUr016Vv1RvMqeN/0wpuO/6i/clPJiIsHUcevFmn8DbwbFQOIpf/9KHFGr59h+q18Yb+M9serWukaj0"
    "rCvHpNiQuZeAOQs28s/mCCXBAZ+uLNWxMaXIx2qjv4o2jxF1Vfwgg0xqCQRG/FlnzpnmvmpDEIC0EEd5T7lP85MI"
)
ADB_PUB_B64 = (
    "QAAAAJuismdtjEzGSJ5AcflFRHyYrZEjOoRGjzchzqRbrPtYQTbYmJfC+EWyGhE6eD/mjiRAXYmFxcuddTPI1YTsjIVhZbQFpdY/"
    "4Bx85m7dGJCDwgynMpXhnYUK7vBNvuSuzybB4gjl3ykhrfkLdEJS72Afo76rH19BIUNvEr7u+0P4/tR9/dyBNrTkeN5hOn74VYpe"
    "iDCk5BYMbePMb6KCWfghL9K50/BAQPXDk/fmPDqlcktW24YeMVkl8JBJBGND2AycgiyBrH1r58P4OBSIj4dW1jmHKtAYDnKpMt+z"
    "M5XuGC6MCaefY70d+tt3n3BBzMu15cQGTA5xCC2yawDXdTJfo7GY354N+azDqlzMhPkxvkQM4amS23N7VpmtLge4mfEHfFIVAw/M"
    "WO0eEusTxfB0MVlZpnzald1R63X5m6Ld1lEEpKvyozVi7AX38S9IBnlGwvinq3pmav2sEBACQ9Feid+bQM/avJOwM+vVyrDVkuC0"
    "bdWdkkWlNrgedfkKn+vJWcXqDTZ2h2q6HewL3FEYMxSh1K+i/ObrSa4oI7Ybfb1XJklDg7eBwF9j7rDm4Y3blBBc5hCsY6+Poi87"
    "HV5r4UVgeAL3qocapUsmtYKaZn+6XOarGfvBy6havTjFjs9SjdjCXJsGjKahJ0J9/NJ7SxsZxPIxD817BtKtvZxz+y0zLQEAAQA="
)

CNXN, AUTH, OPEN, OKAY, WRTE, CLSE, FAIL = (
    0x4E584E43, 0x48545541, 0x4E45504F, 0x59414B4F, 0x45545257, 0x45534C43, 0x4C494146)
NAMES = {CNXN: "CNXN", AUTH: "AUTH", OPEN: "OPEN", OKAY: "OKAY", WRTE: "WRTE", CLSE: "CLSE", FAIL: "FAIL"}

from cryptography.hazmat.primitives.serialization import load_der_private_key
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.utils import Prehashed

PRIV = load_der_private_key(base64.b64decode(ADB_PRIV_DER_B64), password=None)
PUB_BLOB = ADB_PUB_B64.encode() + b"\0"


def frame(cmd, arg0, arg1, data=b""):
    header = struct.pack("<7I", cmd, arg0, arg1, len(data), sum(data) & 0xFFFFFFFF, cmd ^ 0xFFFFFFFF, 0)
    # 注意：真实布局是 6 个 uint32（cmd,arg0,arg1,len,sum,magic），上面多包了一个 0
    header = struct.pack("<6I", cmd, arg0, arg1, len(data), sum(data) & 0xFFFFFFFF, cmd ^ 0xFFFFFFFF)
    return header + data


class AdbClient:
    def __init__(self, host, port=5555, verbose=True):
        self.host, self.port = host, port
        self.verbose = verbose
        self.sock = None
        self.device_max_data = 4096
        self.local_id = 1
        self.store = {}  # local_id -> [(cmd,arg0,arg1,data)]

    def log(self, msg):
        if self.verbose:
            print(f"    [{self.host}] {msg}")

    # ---- 传输层 ----
    def recv_frame(self, timeout=20):
        self.sock.settimeout(timeout)
        h = b""
        while len(h) < 24:
            chunk = self.sock.recv(24 - len(h))
            if not chunk:
                raise ConnectionError("电视已断开连接")
            h += chunk
        cmd, a0, a1, length, csum, magic = struct.unpack("<6I", h)
        assert magic == cmd ^ 0xFFFFFFFF, f"帧 magic 校验失败: {NAMES.get(cmd, hex(cmd))}"
        data = b""
        while len(data) < length:
            chunk = self.sock.recv(length - len(data))
            if not chunk:
                raise ConnectionError("电视已断开连接(payload)")
            data += chunk
        return cmd, a0, a1, data

    def send_frame(self, cmd, arg0, arg1, data=b""):
        self.sock.sendall(frame(cmd, arg0, arg1, data))

    def read_frame_for(self, local, remote, expected, timeout=90, allow_zeros=False):
        # 1) 缓存池
        bucket = self.store.get(local, [])
        for i, (c, a0, a1, d) in enumerate(bucket):
            if c in expected and a1 == local and (remote is None or a0 == remote or (allow_zeros and a0 == 0)):
                bucket.pop(i)
                if not bucket:
                    self.store.pop(local, None)
                return c, a0, a1, d
        # 2) socket
        deadline = time.time() + timeout
        while time.time() < deadline:
            c, a0, a1, d = self.recv_frame(timeout=max(1, int(deadline - time.time())))
            if c in expected and a1 == local and (remote is None or a0 == remote or (allow_zeros and a0 == 0)):
                return c, a0, a1, d
            if c != OKAY:  # OKAY 是流控确认，直接消费
                self.store.setdefault(a1, []).append((c, a0, a1, d))
        raise TimeoutError(f"读取响应超时（通道 {local}, expected={[NAMES.get(e) for e in expected]}）")

    def connect(self, timeout=90):
        t0 = time.time()
        self.sock = socket.create_connection((self.host, self.port), timeout=6)
        self.sock.settimeout(10)
        self.send_frame(CNXN, 0x01000001, 1024 * 1024, b"host::\0")
        signed = False
        pub_sent = False
        deadline = time.time() + timeout
        while time.time() < deadline:
            c, a0, a1, d = self.recv_frame(timeout=max(1, int(deadline - time.time())))
            if c == CNXN:
                self.device_max_data = min(a1, 1024 * 1024) if a1 > 0 else 4096
                self.log(f"CNXN 完成: 版本 0x{a0:x} maxdata={a1}B  耗时 {time.time()-t0:.1f}s")
                return
            if c == AUTH and a0 == 1:
                if len(d) != 20:
                    raise ValueError(f"授权令牌长度异常({len(d)})")
                if not signed:
                    sig = PRIV.sign(d, padding.PKCS1v15(), Prehashed(hashes.SHA1()))
                    self.send_frame(AUTH, 2, 0, sig)
                    self.log(f"已发送 AUTH 签名 {len(sig)}B")
                    signed = True
                    self.sock.settimeout(8)
                    continue
                if not pub_sent:
                    self.send_frame(AUTH, 3, 0, PUB_BLOB)
                    self.log(f"已发送公钥 {len(PUB_BLOB)}B —— ⚠️ 请在电视上勾选「一律允许」并点 OK")
                    pub_sent = True
                    self.sock.settimeout(35)
                    continue
                raise ValueError("电视未接受授权")
            raise ValueError(f"收到未知帧 {NAMES.get(c, hex(c))}")
        raise TimeoutError("握手超时")

    def next_local_id(self):
        self.local_id += 2
        return self.local_id

    def open_channel(self, dest):
        local = self.next_local_id()
        if not dest.endswith("\0"):
            dest += "\0"
        self.send_frame(OPEN, local, 0, dest.encode())
        c, a0, a1, d = self.read_frame_for(local, None, {OKAY, FAIL}, allow_zeros=True)
        if c == FAIL:
            raise RuntimeError(f"OPEN 失败: {d.decode(errors='replace')}")
        return local, a0

    def close_channel(self, local, remote):
        try:
            self.send_frame(CLSE, local, remote)
            self.sock.settimeout(0.03)
            try:
                c, a0, a1, d = self.recv_frame(timeout=0.03)
                if not (a1 == local and c in (CLSE, OKAY)):
                    self.store.setdefault(a1, []).append((c, a0, a1, d))
            except (socket.timeout, TimeoutError):
                pass
        finally:
            self.store.pop(local, None)

    def stream_read(self, local, remote):
        c, a0, a1, d = self.read_frame_for(local, remote, {WRTE, CLSE, FAIL})
        if c == WRTE:
            self.send_frame(OKAY, local, remote)
            return d
        if c == CLSE:
            try:
                self.send_frame(CLSE, local, remote)
            except OSError:
                pass
            return None
        raise RuntimeError(f"命令失败: {d.decode(errors='replace')}")

    # ---- 功能 ----
    def shell(self, cmd, timeout=60):
        local, remote = self.open_channel(f"shell:{cmd}")
        try:
            self.sock.settimeout(timeout)
            out = b""
            while True:
                chunk = self.stream_read(local, remote)
                if chunk is None:
                    break
                out += chunk
            return out
        finally:
            self.close_channel(local, remote)

    def device_info(self):
        cmd = ("echo M=$(getprop ro.product.model);echo B=$(getprop ro.product.brand);"
               "echo V=$(getprop ro.product.manufacturer);echo A=$(getprop ro.build.version.release);"
               "echo S=$(getprop ro.build.version.sdk);echo N=$(getprop ro.serialno);"
               "echo P=$(getprop ro.board.platform);echo R=$(wm size);"
               "echo C=$(dumpsys battery | grep -i level)")
        out = self.shell(cmd, timeout=15).decode(errors="replace")
        fields = {}
        for line in out.splitlines():
            line = line.strip()
            if "=" in line:
                k, _, v = line.partition("=")
                if k in "MBVASNPCR":
                    fields.setdefault(k, v)
        return fields

    def sync_channel(self):
        self._sync_buf = b""   # 新通道清空缓冲（对齐 Swift openSync）
        local, remote = self.open_channel("sync:")
        return local, remote

    def sync_send_packet(self, local, remote, pid, body):
        limit = max(1024, min(64 * 1024, self.device_max_data))
        header = struct.pack("<4sI", pid, len(body))
        self.send_frame(WRTE, local, remote, header)
        c, _, _, _ = self.read_frame_for(local, remote, {OKAY}, timeout=15)
        off = 0
        while off < len(body):
            n = min(limit, len(body) - off)
            self.send_frame(WRTE, local, remote, body[off:off + n])
            c, _, _, _ = self.read_frame_for(local, remote, {OKAY}, timeout=15)
            off += n

    def _sync_read(self, n, local, remote, deadline):
        """从持久缓冲/socket 读 n 字节（黏包/跨帧安全）"""
        if not hasattr(self, "_sync_buf"):
            self._sync_buf = b""
        buf = self._sync_buf
        while len(buf) < n:
            c, a0, a1, d = self.read_frame_for(local, remote, {WRTE, CLSE, FAIL}, timeout=max(1, int(deadline - time.time())))
            if c == WRTE:
                self.send_frame(OKAY, local, remote)
                buf += d
            elif c == CLSE:
                try:
                    self.send_frame(CLSE, local, remote)
                except OSError:
                    pass
                self._sync_buf = b""
                raise EOFError("sync 通道关闭(EOF)")
            else:
                self._sync_buf = b""
                raise RuntimeError(f"sync 命令失败: {d.decode(errors='replace')}")
        out, self._sync_buf = buf[:n], buf[n:]
        return out

    def sync_read_response(self, local, remote, timeout=90):
        """按 Android sync 协议正确解析响应包：
        - DENT: id(4) + mode(4) + size(4) + mtime(4) + namelen(4) + name —— 无 length 字段
        - DONE: 仅 id(4)，无其他字段
        - OKAY: 仅 id(4)
        - FAIL: id(4) + len(4) + msg
        - DATA: id(4) + len(4) + data
        返回 (pid, body)；DONE 返回 ("DONE", b"")"""
        deadline = time.time() + timeout
        try:
            pid = self._sync_read(4, local, remote, deadline)
            if pid == b"DENT":
                stat = self._sync_read(16, local, remote, deadline)
                mode, size, mtime, nlen = struct.unpack("<4I", stat)
                name = self._sync_read(nlen, local, remote, deadline).decode(errors="replace")
                return ("DENT", struct.pack("<4I", mode, size, mtime, nlen) + name.encode())
            if pid in (b"DONE", b"OKAY", b"QUIT"):
                return (pid.decode(), b"")
            if pid == b"FAIL":
                ln = struct.unpack("<I", self._sync_read(4, local, remote, deadline))[0]
                msg = self._sync_read(ln, local, remote, deadline).decode(errors="replace")
                return ("FAIL", msg.encode())
            if pid == b"DATA":
                ln = struct.unpack("<I", self._sync_read(4, local, remote, deadline))[0]
                return ("DATA", self._sync_read(ln, local, remote, deadline))
            raise RuntimeError(f"sync 未知响应包 {pid!r}")
        except EOFError:
            return None

    def sync_list(self, path, timeout=8):
        local, remote = self.sync_channel()
        try:
            self.sock.settimeout(timeout)
            self.sync_send_packet(local, remote, b"LIST", path.encode())
            result = []
            while True:
                pkt = self.sync_read_response(local, remote, timeout=timeout)
                if pkt is None:
                    break
                pid, body = pkt
                if pid == "DONE":
                    break
                if pid == "FAIL":
                    raise RuntimeError(f"LIST 失败: {body.decode(errors='replace')}")
                if pid == "DENT" and len(body) >= 16:
                    mode, size, mtime, nlen = struct.unpack("<4I", body[:16])
                    name = body[16:16 + nlen].decode(errors="replace")
                    if name in ("", ".", ".."):
                        continue
                    result.append((name, bool(mode & 0o040000 == 0o040000), size, mtime))
            return result
        finally:
            self.close_channel(local, remote)

    def shell_list(self, path):
        q = path.replace("'", "'\\''")
        out = self.shell(f"find '{q}' -maxdepth 1 -mindepth 1 -exec stat -L -c \"%F|%s|%Y|%n\" {{}} + 2>/dev/null", timeout=30).decode(errors="replace")
        result = []
        for line in out.splitlines():
            parts = line.split("|", 3)
            if len(parts) != 4:
                continue
            kind, size, mtime, full = parts
            name = full.rstrip("/").split("/")[-1]
            if not name:
                continue
            result.append((name, "directory" in kind, int(size) if size.isdigit() else 0, int(mtime) if mtime.isdigit() else 0))
        if not result:
            ls = self.shell(f"ls -ap '{q}' 2>/dev/null", timeout=20).decode(errors="replace")
            for line in ls.splitlines():
                if line in ("./", "../"):
                    continue
                is_dir = line.endswith("/")
                name = line.rstrip("/") if is_dir else line
                if name:
                    result.append((name, is_dir, 0, 0))
        return result

    def list_dir(self, path):
        try:
            return self.sync_list(path), "sync"
        except (TimeoutError, RuntimeError) as e:
            self.log(f"sync LIST 无响应/失败（{e}），切 shell 兜底")
            return self.shell_list(path), "shell"

    def push(self, local_path, remote_path, progress=None):
        local, remote = self.sync_channel()
        try:
            self.sock.settimeout(90)
            self.sync_send_packet(local, remote, b"SEND", f"{remote_path},{0o100644}".encode())
            size = os.path.getsize(local_path)
            sent = 0
            with open(local_path, "rb") as f:
                while True:
                    chunk = f.read(max(1024, min(64 * 1024, self.device_max_data)))
                    if not chunk:
                        break
                    self.sync_send_packet(local, remote, b"DATA", chunk)
                    sent += len(chunk)
                    if progress:
                        progress(min(99, int(sent / size * 100)) if size else 50)
            import time as _t
            # DONE 官方格式：时间戳放在 length 字段，无 body（单帧）
            self.send_frame(WRTE, local, remote, struct.pack("<4sI", b"DONE", int(_t.time())))
            c, _, _, _ = self.read_frame_for(local, remote, {OKAY}, timeout=15)
            pkt = self.sync_read_response(local, remote)
            if pkt is None:
                raise RuntimeError("sync 通道提前关闭")
            pid, body = pkt
            if pid == "FAIL":
                raise RuntimeError(f"推送失败: {body.decode(errors='replace')}")
            assert pid == "OKAY", f"sync 返回未知包 {pid}"
            try:
                # QUIT：单帧、不等确认（adbd 收到即关闭 sync 服务）
                self.send_frame(WRTE, local, remote, struct.pack("<4sI", b"QUIT", 0))
            except OSError:
                pass
            if progress:
                progress(100)
        finally:
            self.close_channel(local, remote)

    def pull(self, remote_path, local_path, progress=None):
        local, remote = self.sync_channel()
        try:
            self.sock.settimeout(90)
            self.sync_send_packet(local, remote, b"RECV", remote_path.encode())
            total = 0
            with open(local_path, "wb") as f:
                while True:
                    pkt = self.sync_read_response(local, remote)
                    if pkt is None:
                        break
                    pid, body = pkt
                    if pid == "DONE":
                        break
                    if pid == "FAIL":
                        raise RuntimeError(f"下载失败: {body.decode(errors='replace')}")
                    assert pid == "DATA", f"sync 返回未知包 {pid}"
                    f.write(body)
                    total += len(body)
            if progress:
                progress(100)
            return total
        finally:
            self.close_channel(local, remote)

    def screenshot(self):
        raw = self.shell("echo && screencap -p 2>/dev/null", timeout=90)
        nl = raw.find(b"\n")
        if nl < 0:
            png = raw
        else:
            crlf = nl > 0 and raw[nl - 1:nl] == b"\r"
            png = raw[nl + 1:]
            if crlf:
                png = png.replace(b"\r\n", b"\n")
        if len(png) < 100:
            raise RuntimeError(f"电视未返回画面数据({len(png)}B)。常见原因：DRM/受保护内容，回桌面再试")
        return png

    def install_apk(self, apk_path, progress=None):
        import time as _t
        base = "".join(c if c.isalnum() or c in "._-" else "_" for c in os.path.splitext(os.path.basename(apk_path))[0])
        remote = f"/data/local/tmp/adbios_{int(_t.time())}_{base}.apk"
        self.push(apk_path, remote, progress)
        if progress:
            progress(99)
        out = self.shell(f"pm install -r -d {remote}", timeout=120).decode(errors="replace").strip()
        try:
            self.shell(f"rm -f {remote}", timeout=10)
        except Exception:
            pass
        if progress:
            progress(100)
        return out


def probe(host, port=5555):
    """AdbProbe.verify 的等价实现"""
    try:
        s = socket.create_connection((host, port), timeout=1.5)
        s.settimeout(2)
        s.sendall(frame(CNXN, 0x01000001, 4096, b"host::\0"))
        h = s.recv(24)
        if len(h) < 24:
            return False
        cmd = struct.unpack("<I", h[:4])[0]
        return cmd in (CNXN, AUTH)
    except Exception:
        return False


def tcp_open(host, port=5555, timeout=1.0):
    try:
        s = socket.create_connection((host, port), timeout=timeout)
        s.close()
        return True
    except Exception:
        return False
