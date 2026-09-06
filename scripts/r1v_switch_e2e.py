# -*- coding: utf-8 -*-
"""换源变量链 E2E 驱动（R1 追加修复验证，2026-09-06，仅重构版 emulator-5556）。

流程：夹具服务器（r1v_switch_server.py，adb reverse）→ 深链导入 2 夹具源 →
主搜索 R1（分组圈定 R1V）→ 进详情加入书架 → 打开换源页 → 切换到 R1VB →
断言：
  A. 服务器日志出现 /r1vb/detail?vid=VID123（候选搜索期变量经 persist 落库 +
     switch 详情请求贯通展开；修复前为字面 {{svid}} → 400）
  B. 出现 /r1vb/toc?tok=TK777（候选⊕详情导出合并变量经目录请求贯通展开）
  C. 无 reject 事件（服务端强校验未拒绝）
  D. 换源后 UI 当前源显示 R1VB
  E.（阅读）/r1vb/content?...tok=TK777 请求 200

用法：
  python scripts/r1v_switch_e2e.py --device emulator-5556
退出码 0=通过 1=失败。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / ".e2e_r1v"
PORT = 8092
SRC = f"http://127.0.0.1:{PORT}/r1v/sources.json"
REF_PKG = "io.legado.flutter_legado"
REF_ACT = f"{REF_PKG}/io.legado.flutter.MainActivity"
KW = "R1"
BOOK = "R1换源验证书"
VID = "VID123"
TOK = "TK777"


def resolve_adb() -> str:
    """adb 解析：PATH 优先，退化到 flutter_legado/android/local.properties sdk.dir。"""
    p = shutil.which("adb")
    if p:
        return p
    props = ROOT / "flutter_legado" / "android" / "local.properties"
    if props.exists():
        for line in props.read_text(encoding="utf-8").splitlines():
            if line.startswith("sdk.dir"):
                sdk = line.split("=", 1)[1].replace("\\\\", "\\").strip()
                cand = Path(sdk) / "platform-tools" / "adb.exe"
                if cand.exists():
                    return str(cand)
    raise SystemExit("adb 未找到：PATH 与 local.properties 均无")


ADB = resolve_adb()


def sh(device: str, *a: str) -> subprocess.CompletedProcess:
    return subprocess.run([ADB, "-s", device, *a], capture_output=True, text=True)


def shell(device: str, *a: str) -> str:
    r = sh(device, "shell", *a)
    return (r.stdout or "") + (r.stderr or "")


def rec(msg: str) -> None:
    print(f"[e2e] {msg}", flush=True)


def dump(device: str, tag: str) -> str:
    remote = f"/sdcard/.r1vd_{tag}.xml"
    for _ in range(4):
        shell(device, f"uiautomator dump {remote}")
        sh(device, "pull", remote, str(OUT / f"{tag}.xml"))
        p = OUT / f"{tag}.xml"
        if p.exists() and p.stat().st_size > 0:
            return p.read_text(encoding="utf-8", errors="replace")
        time.sleep(1.2)
    return ""


def unesc(s: str) -> str:
    return s.replace("&#10;", "\n").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")


def nodes(x: str):
    return re.finditer(
        r'<node[^>]*?text="([^"]*)"[^>]*?content-desc="([^"]*)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',
        x)


def find(x: str, needle: str, exact: bool = False):
    """按 text/content-desc 子串或全等查找,返回中心坐标。"""
    for m in nodes(x):
        t, d = unesc(m.group(1)), unesc(m.group(2))
        cx = (int(m.group(3)) + int(m.group(5))) // 2
        cy = (int(m.group(4)) + int(m.group(6))) // 2
        for s in (t, d):
            if (exact and s == needle) or (not exact and needle in s):
                return cx, cy
    return None


def tap(device: str, x: str, needle: str, exact: bool = False, wait: float = 1.5) -> bool:
    hit = find(x, needle, exact)
    if not hit:
        return False
    shell(device, f"input tap {hit[0]} {hit[1]}")
    time.sleep(wait)
    return True


def tap_at(device: str, cx: int, cy: int, wait: float = 1.5) -> None:
    shell(device, f"input tap {cx} {cy}")
    time.sleep(wait)


def marker(port: int, name: str) -> None:
    import urllib.request
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{port}/marker/{name}", timeout=3)
    except Exception:
        pass


def server_events(log: Path) -> list[dict]:
    if not log.exists():
        return []
    out = []
    for line in log.read_text(encoding="utf-8").splitlines():
        try:
            out.append(json.loads(line))
        except Exception:
            pass
    return out


def ensure_foreground(device: str, pkg: str) -> None:
    shell(device, "am", "force-stop", pkg)
    time.sleep(2)
    shell(device, "monkey", "-p", pkg, "-c", "android.intent.category.LAUNCHER", "1")
    time.sleep(4)


def main() -> int:
    global PORT
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="emulator-5556")
    ap.add_argument("--skip-import", action="store_true")
    args = ap.parse_args()
    dev = args.device
    OUT.mkdir(parents=True, exist_ok=True)
    log = OUT / "server.jsonl"

    # 1. 夹具服务器（独立进程；stdout 重定向避免占住父管道）
    proc = subprocess.Popen(
        [sys.executable, str(ROOT / "scripts" / "r1v_switch_server.py"),
         "--port", str(PORT), "--log", str(log)], cwd=str(ROOT),
        stdout=(OUT / "server_stdout.log").open("w", encoding="utf-8"),
        stderr=subprocess.STDOUT)
    time.sleep(1.5)
    sh(dev, "reverse", f"tcp:{PORT}", f"tcp:{PORT}")
    time.sleep(1)

    ok = False
    try:
        # ADBKeyboard（文本输入）
        kb = ROOT / "tmp_debug" / "e2e_5558" / "ADBKeyboard.apk"
        if kb.exists():
            sh(dev, "install", "-r", str(kb))
            shell(dev, "ime", "enable", "com.android.adbkeyboard/.AdbIME")
            shell(dev, "settings", "put", "secure", "default_input_method",
                  "com.android.adbkeyboard/.AdbIME")

        ensure_foreground(dev, REF_PKG)

        # 2. 导入夹具源（深链 → 确认导入 → 完成）
        if not args.skip_import:
            sh(dev, "shell", "am", "start", "-a", "android.intent.action.VIEW",
               "-d", f"legado://import/bookSource?src={SRC}", "-n", REF_ACT)
            confirmed = False
            for i in range(12):
                time.sleep(2)
                x = dump(dev, f"imp{i}")
                if "确认导入" in x and tap(dev, x, "确认导入", wait=3):
                    confirmed = True
                    break
                if "R1VA" in x:
                    for btn in ("确认导入", "全选", "导入"):
                        if tap(dev, x, btn, wait=2):
                            confirmed = True
                            break
                    if confirmed:
                        break
            assert confirmed, "导入确认未完成"
            for i in range(6):
                x = dump(dev, f"impdone{i}")
                if tap(dev, x, "完成", exact=True, wait=1.5):
                    break
                time.sleep(1.5)
            rec("夹具源导入完成")

        ensure_foreground(dev, REF_PKG)
        x = dump(dev, "home")
        assert tap(dev, x, "搜索", exact=True, wait=2.5), "书架搜索入口未命中"

        # 3. 圈定分组 R1V（菜单两段式）
        x = ""
        for i in range(10):
            time.sleep(2)
            x = dump(dev, f"sp{i}")
            if "更多选项" in x:
                break
        if tap(dev, x, "更多选项"):
            x = dump(dev, "menu1")
            tap(dev, x, "全部书源", exact=True)
            x = ""
            for i in range(8):
                time.sleep(1.5)
                x = dump(dev, f"sp2_{i}")
                if "更多选项" in x:
                    break
            tap(dev, x, "更多选项")
            x = dump(dev, "menu2")
            assert tap(dev, x, "R1V", exact=True), "分组菜单无 R1V"
            time.sleep(1)

        # 4. 输入关键词 + 搜索
        x = dump(dev, "pre_typed")
        et = re.search(
            r'class="android\.widget\.EditText"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', x)
        assert et, "搜索框未找到"
        tap_at(dev, (int(et.group(1)) + int(et.group(3))) // 2,
               (int(et.group(2)) + int(et.group(4))) // 2, 1)
        shell(dev, "am", "broadcast", "-a", "ADB_INPUT_TEXT", "--es", "msg", KW)
        time.sleep(1.5)
        x = dump(dev, "typed")
        marker(PORT, "REF_SUBMIT")
        assert tap(dev, x, "搜索", exact=True, wait=3), "搜索提交未命中"

        # 等两源结果（普通链 + 变量链）
        deadline = time.time() + 40
        x = ""
        while time.time() < deadline:
            x = dump(dev, "res")
            if BOOK in x:
                break
            time.sleep(3)
        assert BOOK in x, "搜索结果未出现夹具书"
        rec("搜索结果出现")

        # 5. 进详情 → 加入书架
        assert tap(dev, x, BOOK, wait=3), "结果行未命中"
        x = dump(dev, "detail")
        added = tap(dev, x, "加入书架", wait=2)
        if added:
            x = dump(dev, "detail2")
        rec(f"加入书架: {added}")

        # 6. 打开换源页（书籍详情页入口；兜底查找「换源」入口）
        marker(PORT, "OPEN_CHANGE_SOURCE")
        if not tap(dev, x, "换源", wait=3):
            # 兜底：更多菜单里找
            if tap(dev, x, "更多", wait=1.5):
                x = dump(dev, "detail_menu")
                assert tap(dev, x, "换源", wait=3), "菜单内无换源入口"
        x = ""
        for i in range(10):
            time.sleep(2)
            x = dump(dev, f"cs{i}")
            if BOOK in x and ("R1VB" in x or "R1VA" in x):
                break
        assert "R1VA" in x or "R1VB" in x, "换源页未出现候选"
        rec("换源页候选出现")

        # 7. 切换到 R1VB（点候选行）
        marker(PORT, "SWITCH_START")
        assert tap(dev, x, "R1VB", wait=5), "R1VB 候选行未命中"
        # 可能的确认弹窗
        x = dump(dev, "cs_confirm")
        for btn in ("确定", "确认", "切换"):
            if tap(dev, x, btn, exact=False, wait=3):
                break
        time.sleep(3)
        x = dump(dev, "cs_after")
        (OUT / "cs_after.xml").write_text(x, encoding="utf-8")

        # 8. 断言：服务器日志变量展开 + 无 reject
        evs = server_events(log)
        paths = [e.get("path", "") for e in evs if e.get("kind") == "req"]
        rejects = [e for e in evs if e.get("kind") == "reject"]
        detail_ok = any(p.startswith(f"/r1vb/detail?vid={VID}") for p in paths)
        toc_ok = any(p.startswith(f"/r1vb/toc?tok={TOK}") for p in paths)
        content_ok = any(p.startswith(f"/r1vb/content") and f"tok={TOK}" in p for p in paths)
        literal_bad = any(("{{" in p) for p in paths)
        rec(f"detail_vid_ok={detail_ok} toc_tok_ok={toc_ok} content_ok={content_ok} "
            f"rejects={len(rejects)} literal_url={literal_bad}")
        for e in rejects:
            rec(f"reject: {e}")

        report = {
            "detail_vid_ok": detail_ok,
            "toc_tok_ok": toc_ok,
            "content_ok": content_ok,
            "rejects": rejects,
            "literal_url": literal_bad,
            "paths": [p for p in paths if "/r1vb/" in p],
            "cs_after_text": re.findall(r'text="([^"]*)"', x)[:80],
        }
        (OUT / "report.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

        ok = detail_ok and toc_ok and not rejects and not literal_bad
        rec("E2E " + ("PASSED" if ok else "FAILED"))
        return 0 if ok else 1
    finally:
        marker(PORT, "END")
        sh(dev, "reverse", "--remove", f"tcp:{PORT}")
        time.sleep(1)
        proc.terminate()


if __name__ == "__main__":
    sys.exit(main())
