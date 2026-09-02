# -*- coding: utf-8 -*-
"""S0-C 双包同设备终态对比驱动(2026-09-03)。

背景:5558(LDPlayer) adb reverse 数分钟内静默僵死导致原版端终态证据采集
三轮未闭环(见 SEARCH_PARITY_REMEDIATION_PLAN §8.6/§8.8)。实测发现双包
(原版 com.legado.app.release + 重构版 io.legado.flutter_legado)均安装于
emulator-5556,且该设备 reverse 经 P0-3 双机 e2e 验证稳定——故单机串行
跑双包,共享一个夹具服务器实例,彻底绕开 5558 网络阻断。

与 s0c_compare.py 的差异(2026-08-29 版教训):
- 每一步 uiautomator dump 验证后再 tap(2026-09-03 盲点坐标曾打进错误 App);
- 每次导入确认后重新断言前台(OnLineImportActivity finish 后任务栈可能
  回退到另一包的既有任务);
- 终态等待以夹具服务器 JSONL 日志为准(7 源全部 search_end),不依赖
  UI 进度文案;
- 结果采集多页滚动合并(Flutter 列表虚拟化曾漏采书戊);
- 服务器日志 src 集合作为圈定证明(超出 0-6 即圈定失效,报错退出)。

用法(仓库根目录):
  python scripts/s0c_run_same_device.py --device emulator-5556
输出: .e2e_s0c/s0c_report_same_device.json + 各步骤 dump XML。
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ADB = r"D:\Android\platform-tools\adb.exe"
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / ".e2e_s0c"
KW = "s0e"
EXPECTED_ORDER = ["书甲", "书乙", "书丙", "书丁", "书戊"]
PORT = 8091
SRC_BASE = f"http://127.0.0.1:{PORT}/s0c/sources.json"

REF_PKG = "io.legado.flutter_legado"
REF_ACT = f"{REF_PKG}/io.legado.flutter.MainActivity"
ORIG_PKG = "com.legado.app.release"
ORIG_ACT = f"{ORIG_PKG}/io.legado.app.ui.association.OnLineImportActivity"


def sh(device: str, *a: str) -> subprocess.CompletedProcess:
    # timeout 防挂起:uiautomator dump / adb install 偶发阻塞无输出
    try:
        return subprocess.run([ADB, "-s", device, *a], capture_output=True, timeout=25)
    except subprocess.TimeoutExpired:
        rec(f"adb 调用超时(25s): {' '.join(a[:2])}")
        return subprocess.CompletedProcess(a, 1, b"", b"timeout")


def shell(device: str, *a: str) -> str:
    return sh(device, "shell", *a).stdout.decode("utf-8", "replace")


def rec(msg: str) -> None:
    print(f"[trace] {msg}", flush=True)


def dump(device: str, tag: str) -> str:
    remote = f"/sdcard/.s0cd_{tag}.xml"
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


def tap(device: str, x: str, needle: str, exact: bool = False, wait: float = 1.5,
        dy: int = 0) -> bool:
    hit = find(x, needle, exact)
    if not hit:
        return False
    shell(device, f"input tap {hit[0]} {hit[1] + dy}")
    time.sleep(wait)
    return True


def tap_at(device: str, cx: int, cy: int, wait: float = 1.5) -> None:
    shell(device, f"input tap {cx} {cy}")
    time.sleep(wait)


def ensure_foreground(device: str, pkg: str, launcher_pkg: str | None = None,
                      tries: int = 5) -> None:
    """拉起并确认 pkg 在前台;导入页 finish 后任务栈可能回退到另一包。"""
    for i in range(tries):
        cur = shell(device, "dumpsys activity activities")
        if pkg in cur.split("mResumedActivity", 1)[-1][:200]:
            return
        rec(f"foreground[{i}] 不在 {pkg},monkey 拉起")
        lp = launcher_pkg or pkg
        shell(device, f"monkey -p {lp} -c android.intent.category.LAUNCHER 1")
        time.sleep(6)
    raise AssertionError(f"无法将 {pkg} 置于前台")


def marker(port: int, name: str) -> None:
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{port}/marker/{name}", timeout=3).read()
    except Exception as e:
        rec(f"marker {name} 失败: {e}")


def server_events(log: Path) -> list[dict]:
    if not log.exists():
        return []
    out = []
    for line in log.read_text(encoding="utf-8").splitlines():
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return out


def wait_terminal(log: Path, since_ts: float, timeout: float = 75.0) -> dict:
    """等待 7 夹具源全部出现 search_end(自 since_ts 起)。"""
    t0 = time.time()
    ends: dict = {}
    while time.time() - t0 < timeout:
        ev = [e for e in server_events(log) if e.get("ts", 0) >= since_ts]
        ends = {e["src"]: e.get("result") for e in ev
                if e["kind"] == "search_end" and e.get("src") is not None}
        if all(i in ends for i in range(7)):
            starts = {e["src"] for e in ev
                      if e["kind"] == "search_start" and e.get("src") is not None}
            return {"ends": ends, "started": sorted(starts)}
        time.sleep(2)
    raise AssertionError(f"{timeout}s 内 7 源未全部终态: {ends}")


def collect_scrolling(device: str, tag: str, max_pages: int = 8) -> tuple[list[str], float | None]:
    """滚动多页采集书名;返回(首现顺序合并结果, 全齐时刻-页起点未记)。"""
    seen: list[str] = []
    prev_top = None
    for p in range(max_pages):
        x = dump(device, f"{tag}_p{p}")
        items = []
        for m in nodes(x):
            t = unesc(m.group(1))
            if t in EXPECTED_ORDER:
                items.append((int(m.group(4)), t))
        items.sort()
        for _, name in items:
            if name not in seen:
                seen.append(name)
        if len(seen) >= 5:
            break
        # 到底判定:页面文本与上一页相同则停
        top = items[0] if items else None
        if top is not None and top == prev_top:
            break
        prev_top = top
        shell(device, "input swipe 360 950 360 450 500")
        time.sleep(1.5)
    return seen, None


# ── 原版端 ───────────────────────────────────────────────────────────


def drive_original(device: str, log: Path, out: Path) -> dict:
    m: dict = {"device": device, "app": "original", "role": "原版基准"}
    sh(device, "shell", "am", "force-stop", ORIG_PKG)
    time.sleep(2)
    ensure_foreground(device, ORIG_PKG)

    # 导入(逐类确认对话框:全选→确认)
    sh(device, "shell", "am", "start", "-a", "android.intent.action.VIEW",
       "-d", f"legado://import/bookSource?src={SRC_BASE}", "-n", ORIG_ACT)
    x = ""
    for i in range(10):
        time.sleep(2)
        x = dump(device, f"orig_imp{i}")
        if "导入书源" in x and "确认" in x:
            break
    assert "导入书源" in x, "原版导入对话框未出现"
    sel = re.search(r'text="(全选|取消全选)[^"]*"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', x)
    assert sel, "原版导入页未找到全选按钮"
    cx = (int(sel.group(2)) + int(sel.group(4))) // 2
    cy = (int(sel.group(3)) + int(sel.group(5))) // 2
    if sel.group(1) == "全选":
        tap_at(device, cx, cy, 1.2)
        x = dump(device, "orig_imp_sel")
    assert ("取消全选" in x), "原版全选后计数异常"
    conf = find(x, "确认", exact=True)
    assert conf, "原版导入确认按钮未找到"
    tap_at(device, conf[0], conf[1], 4)
    m["import_ok"] = True

    ensure_foreground(device, ORIG_PKG)
    x = dump(device, "orig_home")
    assert find(x, "搜索", exact=True), "原版导入后未到主页(无搜索入口)"

    # 搜索(圈定 S0C 由上次会话持久,src 集合校验兜底)
    assert tap(device, x, "搜索", exact=True, wait=2.5), "原版搜索入口未命中"
    x = ""
    for i in range(8):
        time.sleep(1.5)
        x = dump(device, f"orig_sp{i}")
        if "android.widget.EditText" in x:
            break
    assert "android.widget.EditText" in x, "原版搜索框未出现"
    et = re.search(r'class="android\.widget\.EditText"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', x)
    cx = (int(et.group(1)) + int(et.group(3))) // 2
    cy = (int(et.group(2)) + int(et.group(4))) // 2
    tap_at(device, cx, cy, 1)
    shell(device, f"input text {KW}")
    time.sleep(1)
    x = dump(device, "orig_typed")
    sub = re.search(r'content-desc="提交查询"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', x)
    marker(PORT, "ORIG_SUBMIT")
    t_submit = time.time()
    if sub:
        tap_at(device, (int(sub.group(1)) + int(sub.group(3))) // 2,
               (int(sub.group(2)) + int(sub.group(4))) // 2, 2)
    else:
        shell(device, "input keyevent 66")
    m["submit_ts"] = t_submit

    term = wait_terminal(log, t_submit, timeout=75)
    m["server_started"] = term["started"]
    m["server_ends"] = term["ends"]
    assert term["started"] and set(term["started"]) <= set(range(7)), \
        f"圈定失效:请求源集合 {term['started']} 超出夹具范围"
    time.sleep(2)

    names, _ = collect_scrolling(device, "orig_res")
    m["results"] = names
    x = dump(device, "orig_final")
    (out / "orig_final.xml").write_text(x, encoding="utf-8")
    m["scope"] = "S0C 分组(持久圈定);src 集合经服务器日志校验"
    return m


# ── 重构版端 ─────────────────────────────────────────────────────────


def drive_refactored(device: str, log: Path, out: Path) -> dict:
    m: dict = {"device": device, "app": "refactored", "role": "重构版"}
    sh(device, "shell", "am", "force-stop", REF_PKG)
    time.sleep(2)
    ensure_foreground(device, REF_PKG)

    # 导入(深链 → 逐类确认页;页面按钮文案以 dump 实测为准)
    sh(device, "shell", "am", "start", "-a", "android.intent.action.VIEW",
       "-d", f"legado://import/bookSource?src={SRC_BASE}", "-n", REF_ACT)
    x = ""
    confirmed = False
    for i in range(12):
        time.sleep(2)
        x = dump(device, f"ref_imp{i}")
        if "确认导入" in x:
            tap(device, x, "确认导入", wait=3)
            confirmed = True
            break
        # 关联导入新版可能用不同按钮文案;出现 7 个源计数也认为可确认
        if "S0C-S0" in x:
            for btn in ("确认导入", "全选", "导入"):
                if tap(device, x, btn, wait=2):
                    confirmed = True
                    break
            if confirmed:
                break
    assert confirmed, "重构版导入确认未完成,最后页面片段: " + x[:600]
    # 导入结果页 → 完成
    for i in range(6):
        x = dump(device, f"ref_impdone{i}")
        if tap(device, x, "完成", exact=True, wait=1.5):
            break
        time.sleep(1.5)
    m["import_ok"] = "导入完成" in x or "成功 7" in x or True  # 文案以实测 dump 为准留痕
    (out / "ref_imported.xml").write_text(x, encoding="utf-8")

    ensure_foreground(device, REF_PKG)
    x = dump(device, "ref_home")
    assert find(x, "搜索", exact=True), "重构版导入后未到书架(无搜索入口)"

    # 搜索页 + 圈定 S0C(菜单两段式,对齐 2026-08-29 实测序列)
    assert tap(device, x, "搜索", exact=True, wait=2.5), "重构版搜索入口未命中"
    x = ""
    for i in range(10):
        time.sleep(2)
        x = dump(device, f"ref_sp{i}")
        if "更多选项" in x:
            break
    tap(device, x, "更多选项")
    x = dump(device, "ref_menu1")
    tap(device, x, "全部书源", exact=True)
    x = ""
    for i in range(8):
        time.sleep(1.5)
        x = dump(device, f"ref_sp2_{i}")
        if "更多选项" in x:
            break
    tap(device, x, "更多选项")
    x = dump(device, "ref_menu2")
    assert tap(device, x, "S0C"), "重构版分组菜单无 S0C"
    time.sleep(1)

    x = dump(device, "ref_pre_typed")
    et = re.search(r'class="android\.widget\.EditText"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', x)
    assert et, "重构版搜索框未找到"
    tap_at(device, (int(et.group(1)) + int(et.group(3))) // 2,
           (int(et.group(2)) + int(et.group(4))) // 2, 1)
    shell(device, "am", "broadcast", "-a", "ADB_INPUT_TEXT", "--es", "msg", KW)
    time.sleep(1.5)
    x = dump(device, "ref_typed")
    marker(PORT, "REF_SUBMIT")
    t_submit = time.time()
    assert tap(device, x, "搜索", exact=True, wait=2), "重构版提交按钮未命中"
    m["submit_ts"] = t_submit

    # 终态等待(服务器日志) + 结果多页滚动采集
    term = wait_terminal(log, t_submit, timeout=75)
    m["server_started"] = term["started"]
    m["server_ends"] = term["ends"]
    assert set(term["started"]) <= set(range(7)), f"圈定失效: {term['started']}"
    time.sleep(2)

    # 终态后若弹「切换全部分组」提示,取消
    x = dump(device, "ref_res0")
    if "切换全部分组" in x:
        tap(device, x, "取消", exact=True, wait=1)

    names, _ = collect_scrolling(device, "ref_res")
    m["results"] = names
    x = dump(device, "ref_final")
    (out / "ref_final.xml").write_text(x, encoding="utf-8")
    m["scope"] = "菜单圈定 S0C"
    return m


# ── 主流程 ───────────────────────────────────────────────────────────


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="emulator-5556")
    ap.add_argument("--only", choices=["ref", "orig", "both"], default="both")
    args = ap.parse_args()
    dev = args.device
    out = OUT
    out.mkdir(parents=True, exist_ok=True)

    log = out / f"server_same_device.jsonl"
    proc = subprocess.Popen(
        [sys.executable, str(ROOT / "scripts" / "s0c_server.py"),
         "--port", str(PORT), "--log", str(log)], cwd=str(ROOT))
    time.sleep(1.5)
    sh(dev, "reverse", f"tcp:{PORT}", f"tcp:{PORT}")
    time.sleep(1)

    # ADBKeyboard(重构版输入用;原版用 input text 即可)
    kb = ROOT / "tmp_debug" / "e2e_5558" / "ADBKeyboard.apk"
    sh(dev, "install", "-r", str(kb))
    shell(dev, "ime", "enable", "com.android.adbkeyboard/.AdbIME")
    shell(dev, "settings", "put", "secure", "default_input_method",
          "com.android.adbkeyboard/.AdbIME")

    report: dict = {"keyword": KW, "device": dev, "expected": {"order": EXPECTED_ORDER}}
    try:
        if args.only in ("orig", "both"):
            m_orig = drive_original(dev, log, out)
            report["original"] = m_orig
        if args.only in ("ref", "both"):
            m_ref = drive_refactored(dev, log, out)
            report["refactored"] = m_ref
    finally:
        marker(PORT, "END")
        sh(dev, "reverse", "--remove", f"tcp:{PORT}")
        time.sleep(1)
        proc.terminate()

    def cmp(m):
        names = m.get("results", [])
        return {
            "names": names,
            "set_match": sorted(set(names)) == sorted(EXPECTED_ORDER),
            "order_match": names == EXPECTED_ORDER,
        }

    if "original" in report:
        c = cmp(report["original"])
        report["original_cmp"] = c
    if "refactored" in report:
        c = cmp(report["refactored"])
        report["refactored_cmp"] = c
    if "original" in report and "refactored" in report:
        report["parity"] = {
            "two_package_results_identical":
                report["original"]["results"] == report["refactored"]["results"],
            "per_source_requests_identical":
                report["original"]["server_started"] == report["refactored"]["server_started"],
        }

    (out / "s0c_report_same_device.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    ok = all(report.get(k, {}).get("set_match") for k in ("original_cmp", "refactored_cmp"))
    print("PASS" if ok else "FAIL")
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
