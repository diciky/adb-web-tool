#!/usr/bin/env python3
"""IPA 功能真机测试入口"""
import hashlib
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from adbclient import AdbClient, probe, tcp_open

IPS = sys.argv[1:] or ["10.10.10.28", "10.10.10.53"]

print("=" * 62)
print("① ADB 探测（TCP + CNXN 握手验证，等价 LanScanner + AdbProbe.verify）")
print("=" * 62)
targets = []
for ip in IPS:
    tcp = tcp_open(ip, timeout=2.0)
    adb = probe(ip) if tcp else False
    print(f"  {ip}:5555  TCP={'开' if tcp else '关'}  adbd={'✅ 确认' if adb else '❌'}")
    if adb:
        targets.append(ip)

results = {}
for ip in targets:
    print("\n" + "=" * 62)
    print(f"▶ 设备 {ip}")
    print("=" * 62)
    r = {}
    c = AdbClient(ip)
    try:
        # ② 握手
        t0 = time.time()
        print("② ADB 授权握手（AUTH/RSA 签名）...")
        c.connect()
        r["握手"] = f"✅ {time.time()-t0:.1f}s (maxdata={c.device_max_data}B)"

        # ③ shell
        t0 = time.time()
        out = c.shell("echo hello-from-ipa-test && id").decode(errors="replace").strip()
        print(f"③ shell 执行: {out[:120]}")
        r["shell"] = "✅" if "hello-from-ipa-test" in out else "❌ 输出异常"

        # ④ 设备信息
        info = c.device_info()
        print(f"④ 设备信息: 型号={info.get('M')} 品牌={info.get('B')} 厂商={info.get('V')} "
              f"安卓={info.get('A')}(SDK {info.get('S')}) CPU={info.get('P')} 分辨率={info.get('R')} "
              f"序列号={info.get('N')} 电池={info.get('C')}")
        r["设备信息"] = "✅" if info.get("M") else "❌ 全空"

        # ⑤ 列目录（sync LIST + shell 兜底）
        t0 = time.time()
        files, via = c.list_dir("/sdcard")
        print(f"⑤ 列目录 /sdcard ({via} 通道, {time.time()-t0:.1f}s): 共 {len(files)} 项，前 8 项: "
              + ", ".join(n for n, *_ in files[:8]))
        r["列目录"] = f"✅ ({via}, {len(files)} 项)" if files else f"⚠️ 空目录 ({via})"

        # ⑥ 截图
        t0 = time.time()
        png = c.screenshot()
        fn = f"/tmp/shot_{ip.replace('.', '_')}.png"
        open(fn, "wb").write(png)
        head = png[:8].hex()
        ok = head.startswith("89504e47")
        print(f"⑥ 截图: {len(png)}B → {fn} PNG头={head} {'✅' if ok else '❌ 非PNG'} {time.time()-t0:.1f}s")
        r["截图"] = "✅" if ok else "❌ 数据无效"

        # ⑦ push/pull 往返校验
        t0 = time.time()
        data = os.urandom(256 * 1024)
        src = "/tmp/ipa-rt-src.bin"
        dst = "/tmp/ipa-rt-back.bin"
        open(src, "wb").write(data)
        remote = "/data/local/tmp/ipa-test.bin"
        c.push(src, remote, progress=lambda p: print(f"\r   push {p}%", end="", flush=True))
        print()
        n = c.pull(remote, dst, progress=lambda p: print(f"\r   pull {p}%", end="", flush=True))
        print()
        back = open(dst, "rb").read()
        match = hashlib.sha256(data).hexdigest() == hashlib.sha256(back).hexdigest()
        print(f"⑦ push/pull 往返: {len(back)}B 校验 {'✅ 一致' if match else '❌ 不一致'} {time.time()-t0:.1f}s")
        r["push/pull"] = "✅ 数据一致" if match else "❌ 数据损坏"
        c.shell("rm -f /data/local/tmp/ipa-test.bin")

        # ⑧ 遥控按键（input keyevent，等价 RemoteViewController）
        c.shell("input keyevent 3", timeout=10)  # KEYCODE_HOME，无破坏性
        print("⑧ 遥控按键 (input keyevent 3/HOME): 已发送 ✅")
        r["遥控按键"] = "✅"

        # ⑨ 应用列表（等价 AppsViewController 的 pm list packages）
        t0 = time.time()
        pkgs = c.shell("pm list packages -3").decode(errors="replace").strip().splitlines()
        print(f"⑨ 第三方应用列表: {len(pkgs)} 个 (pm list packages -3)，含: "
              + ", ".join(p.replace('package:', '') for p in pkgs[:6]))
        r["应用列表"] = f"✅ {len(pkgs)} 个" if pkgs else "⚠️ 空"

    except Exception as e:
        print(f"❌ 测试中断: {type(e).__name__}: {e}")
        r["中断"] = f"❌ {type(e).__name__}: {e}"
    results[ip] = r

print("\n" + "=" * 62)
print("测试汇总")
print("=" * 62)
for ip, r in results.items():
    print(f"  {ip}: " + "  ".join(f"{k}{v}" for k, v in r.items()))
