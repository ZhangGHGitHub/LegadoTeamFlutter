# -*- coding: utf-8 -*-
"""S0-C 双包同夹具同关键词终态对比(可机读证据)。

设备:--refactored(默认 emulator-5556,io.legado.flutter_legado)
     --original(默认 emulator-5558,com.legado.app.release)
夹具:scripts/s0c_server.py,7 确定性场景源(分组 S0C,递增延迟 2..14s),
     双设备各自 adb reverse 到独立端口实例,服务器日志给出逐源请求证据。

输出:.e2e_s0c/s0c_report.json —— 每端结果(名称/作者/UI 顺序)、逐源请求、
终态时间;与期望(到达序 书甲..书戊 5 项)三方比对。
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
EXPECTED_ORDER = ["书甲", "书乙", "书丙", "书丁", "书戊"]  # 到达序(延迟递增)

REF_PKG = "io.legado.flutter_legado"
REF_ACT = f"{REF_PKG}/io.legado.flutter.MainActivity"
ORIG_PKG = "com.legado.app.release"
ORIG_ACT = f"{ORIG_PKG}/io.legado.app.ui.association.OnLineImportActivity"


def sh(device: str, *a: str) -> subprocess.CompletedProcess:
    return subprocess.run([ADB, "-s", device, *a], capture_output=True)


def shell(device: str, cmd: str) -> str:
    return sh(device, "shell", cmd).stdout.decode("utf-8", "replace")


def rec(msg: str) -> None:
    print(f"[trace] {msg}", flush=True)


def dump(device: str, tag: str) -> str:
    remote = f"/sdcard/.s0c_{tag}.xml"
    for _ in range(4):
        shell(device, f"uiautomator dump {remote}")
        sh(device, "pull", remote, str(OUT / f"{tag}.xml"))
        p = OUT / f"{tag}.xml"
        if p.exists() and p.stat().st_size > 0:
            return p.read_text(encoding="utf-8", errors="replace")
        time.sleep(1.2)
    return ""


def unesc(s):
    return s.replace("&#10;", chr(10)).replace("&amp;", chr(38))

def nodes(x: str):
    return re.finditer(
        r'<node[^>]*?text="([^"]*)"[^>]*?content-desc="([^"]*)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',
        x)


def find(x: str, needle: str, exact: bool = False, by_class: str = ""):
    for m in nodes(x):
        t, d = unesc(m.group(1)), unesc(m.group(2))
        cx = (int(m.group(3)) + int(m.group(5))) // 2
        cy = (int(m.group(4)) + int(m.group(6))) // 2
        if by_class:
            if by_class in m.group(0):
                return cx, cy
            continue
        for s in (t, d):
            if (exact and s == needle) or (not exact and needle in s):
                return cx, cy
    return None


def tap(device: str, x: str, needle: str, exact: bool = False, wait: float = 1.5,
        by_class: str = "", dy: int = 0) -> bool:
    hit = find(x, needle, exact, by_class)
    if not hit:
        return False
    shell(device, f"input tap {hit[0]} {hit[1] + dy}")
    time.sleep(wait)
    return True


def marker(port: int, name: str) -> None:
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{port}/marker/{name}", timeout=3).read()
    except Exception as e:
        print(f"[warn] marker {name}: {e}", flush=True)


def back_home(device: str, markers: list[str], tries: int = 6) -> bool:
    for i in range(tries):
        x = dump(device, f"nav_{i}")
        if any(m in x for m in markers):
            return True
        shell(device, "input keyevent 4")
        time.sleep(1.5)
    return False


# ── 重构版侧 ─────────────────────────────────────────────────────────


def drive_refactored(device: str, port: int, out: Path) -> dict:
    m = {"device": device, "app": "refactored", "role": "重构版"}
    sh(device, "shell", "am", "force-stop", REF_PKG)
    time.sleep(2)
    sh(device, "shell", "am", "start", "-n", REF_ACT)
    x = ""
    for i in range(15):
        time.sleep(2)
        x = dump(device, f"ref_home{i}")
        if "书架" in x:
            break
    assert "书架" in x, "重构版未到主页"

    import random
    r = random.randint(1000, 9999)
    sh(device, "shell", "am", "start", "-a", "android.intent.action.VIEW",
       "-d", f"legado://import/bookSource?src=http://127.0.0.1:{port}/s0c/sources.json?r={r}",
       "-n", REF_ACT)
    x = ""
    for i in range(15):
        time.sleep(2)
        x = dump(device, f"ref_import{i}")
        if "确认导入" in x:
            break
    assert "确认导入" in x, "重构版导入确认页未出现"
    tap(device, x, "确认导入")
    time.sleep(3)
    x = dump(device, "ref_imported")
    (out / "ref_imported.xml").write_text(x, encoding="utf-8")
    m["import_ok"] = "导入完成" in x and "成功 7" in x
    tap(device, x, "完成", exact=True) or shell(device, "input keyevent 4")
    assert back_home(device, ["书架"]), "导入后未回主页"

    x = dump(device, "ref_pre_search")
    assert tap(device, x, "搜索"), "搜索入口未找到"
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
    assert tap(device, x, "S0C"), "分组 S0C 不在菜单"
    time.sleep(1)

    x = dump(device, "ref_pre_typed")
    tap(device, x, "", by_class="EditText")
    sh(device, "shell", "am", "broadcast", "-a", "ADB_INPUT_TEXT", "--es", "msg", KW)
    time.sleep(1)
    time.sleep(1)
    x = dump(device, "ref_typed")
    marker(port, "REF_SUBMIT")
    t0 = time.time()
    assert tap(device, x, "搜索", exact=True), "提交按钮未找到"

    first_seen = None
    for i in range(60):
        time.sleep(2.5)
        x = dump(device, f"ref_b{i}")
        if "切换全部分组" in x:
            tap(device, x, "取消", exact=True, wait=1.0)
            continue
        if ("书甲" in x or "书乙" in x) and first_seen is None:
            first_seen = time.time() - t0
        if "停止搜索" not in x and "搜索中" not in x:
            break
    m["first_result_s"] = round(first_seen, 1) if first_seen else None
    time.sleep(2)
    x = dump(device, "ref_final")
    (out / "ref_final.xml").write_text(x, encoding="utf-8")
    m["results"] = extract_ref_results(x)
    m["progress"] = sorted(set(re.findall(r"(\d+/\d+)", x)))
    return m


def extract_ref_results(x: str) -> list[str]:
    names = []
    for m in nodes(x):
        t, d = unesc(m.group(1)), unesc(m.group(2))
        for s in (d, t):
            if s and s.startswith("书") and chr(10) in s:
                name = s.split(chr(10))[0]
                if name in EXPECTED_ORDER and name not in names:
                    names.append(name)
    return names


# ── 原版侧 ───────────────────────────────────────────────────────────


def drive_original(device: str, port: int, out: Path) -> dict:
    m = {"device": device, "app": "original", "role": "原版基准"}
    sh(device, "shell", "am", "force-stop", ORIG_PKG)
    time.sleep(2)
    sh(device, "shell", "monkey", "-p", ORIG_PKG, "-c", "android.intent.category.LAUNCHER", "1")
    time.sleep(9)
    x = dump(device, "orig_home")
    assert "搜索" in x, "原版未到主页"

    # 深链导入(OnLineImportActivity → ImportBookSourceDialog:全选+确认)
    sh(device, "shell", "am", "start", "-a", "android.intent.action.VIEW",
       "-d", f"legado://import/bookSource?src=http://127.0.0.1:{port}/s0c/sources.json",
       "-n", ORIG_ACT)
    time.sleep(6)
    ok = False
    for i in range(10):
        x = dump(device, f"orig_import{i}")
        (out / f"orig_import{i}.xml").write_text(x, encoding="utf-8")
        if "全选" in x and "确认" in x:
            # 自定义源分组是菜单项 → 打开新建分组对话框(EditText+确定)填 S0C,
            # 否则导入的书源不落任何分组,搜索范围无法按分组圈定
            if tap(device, x, "自定义源分组", wait=1.5):
                xg = dump(device, f"orig_groupdlg{i}")
                (out / f"orig_groupdlg{i}.xml").write_text(xg, encoding="utf-8")
                hit = find(xg, "", by_class="android.widget.EditText")
                if hit:
                    shell(device, f"input tap {hit[0]} {hit[1]}")
                    time.sleep(0.8)
                    shell(device, "input text S0C")
                    time.sleep(0.8)
                tap(device, xg, "确定") or tap(device, xg, "OK") or shell(device, "input keyevent 66")
                time.sleep(1.5)
                x = dump(device, f"orig_import_g{i}")
                (out / f"orig_import_g{i}.xml").write_text(x, encoding="utf-8")
            tap(device, x, "全选")
            time.sleep(1)
            x = dump(device, f"orig_import_all{i}")
            tap(device, x, "确认")
            ok = True
            time.sleep(3)
            break
    m["import_ok"] = ok
    rec(f"import_ok={ok}")
    assert back_home(device, ["更多选项", "搜索"]), "原版导入后未回主页"
    rec("back home ok")

    # 进入搜索页
    x = dump(device, "orig_pre_search")
    assert tap(device, x, "搜索"), "原版搜索入口未找到"
    time.sleep(2.5)

    # 等自动重搜(恢复的关键词,未圈范围→真实源并行;夹具 7 源在 +2..14s 完成)
    started = False
    for k in range(10):
        x = dump(device, f"orig_auto{k}")
        if "停止" in x or re.search(r"\d+/\d+", x) or any(n in x for n in EXPECTED_ORDER):
            started = True
            break
        time.sleep(2.5)
    if not started:
        # 先清历史范围残留:溢出菜单 → 多分组/书源 → 勾「全部书源」→ 确认
        x2 = dump(device, "orig_menu_open2")
        tap(device, x2, "更多选项") or tap(device, x2, "Show menu") or tap(device, x2, "更多")
        x2 = dump(device, "orig_scope_menu2")
        (out / "orig_scope_menu2.xml").write_text(x2, encoding="utf-8")
        if tap(device, x2, "分组或书源") or tap(device, x2, "多分组/书源") or tap(device, x2, "分组"):
            time.sleep(1.5)
            x2 = dump(device, "orig_scope_dialog3")
            (out / "orig_scope_dialog3.xml").write_text(x2, encoding="utf-8")
            if tap(device, x2, "全部书源"):
                time.sleep(0.8)
                x2 = dump(device, "orig_scope_dialog4")
                tap(device, x2, "确认")
                time.sleep(2)
        hit = find(dump(device, "orig_field"), "", by_class="android.widget.EditText")
        assert hit, "原版搜索框未找到"
        shell(device, f"input tap {hit[0]} {hit[1]}")
        time.sleep(1)
        sh(device, "shell", "am", "broadcast", "-a", "ADB_INPUT_TEXT", "--es", "msg", KW)
        time.sleep(1.5)
        # 提交:优先点搜索历史词条 s0e(精确文本、y>200 非输入框);否则 Enter
        x3 = dump(device, "orig_typed")
        chip = None
        for nd in nodes(x3):
            if nd.group(1) == KW and int(nd.group(4)) > 200:
                cx = (int(nd.group(3)) + int(nd.group(5))) // 2
                cy = (int(nd.group(4)) + int(nd.group(6))) // 2
                chip = (cx, cy)
                break
        if chip:
            shell(device, f"input tap {chip[0]} {chip[1]}")
            time.sleep(2)
        else:
            shell(device, "input keyevent 66")
            time.sleep(2)

    marker(port, "ORIG_SUBMIT")
    t0 = time.time()

    # 夹具子集终态:五个期望书名全部可见即采集;结果列表较长需滚动收集,
    # 按首现顺序=列表相对序;采集后 force-stop 终止原版侧搜索
    first_seen = None
    seen_all = None
    for r2 in range(60):
        time.sleep(2.5)
        x = dump(device, f"orig_b{r2}")
        got = [n for n in EXPECTED_ORDER if n in x]
        if got and first_seen is None:
            first_seen = time.time() - t0
        if len(got) == 5:
            seen_all = time.time() - t0
            break
    m["first_result_s"] = round(first_seen, 1) if first_seen else None
    m["all_names_at_s"] = round(seen_all, 1) if seen_all else None
    m["results"] = []
    for k in range(30):
        x = dump(device, f"orig_scan{k}")
        if any(w in x for w in ("Cloudflare", "安全验证", "Just a moment")):
            shell(device, "input keyevent 4")
            time.sleep(1.5)
        for n in extract_orig_results(x):
            if n not in m["results"]:
                m["results"].append(n)
        if len(m["results"]) >= 5:
            break
        shell(device, "input swipe 360 1000 360 300")
        time.sleep(1.2)
    (out / "orig_final.xml").write_text(x, encoding="utf-8")
    m["scope"] = "全部书源(未圈定);夹具 7 源 +2..14s 确定性完成"
    shell(device, f"am force-stop {ORIG_PKG}")
    return m


def extract_orig_results(x: str) -> list[str]:
    """原版搜索结果页:按 y 序提取书名 TextView(文本恰为期望书名之一)。"""
    found = []
    items = []
    for m in nodes(x):
        t = m.group(1)
        if t in EXPECTED_ORDER:
            items.append((int(m.group(4)), t))
    items.sort(key=lambda p: p[0])
    for _, name in items:
        if name not in found:
            found.append(name)
    return found


# ── 汇总比对 ─────────────────────────────────────────────────────────


def analyze(server_log: Path, submit_ts: float | None) -> dict:
    ev = [json.loads(l) for l in server_log.read_text(encoding="utf-8").splitlines()]
    starts = [e for e in ev if e["kind"] == "search_start" and e.get("src") is not None]
    ends = {e["id"]: e for e in ev if e["kind"] == "search_end" and e.get("src") is not None}
    if submit_ts:
        starts = [e for e in starts if e["ts"] >= submit_ts - 1.0]
    from collections import Counter
    c = Counter(e["src"] for e in starts)
    res = Counter(ends.get(e["id"], {}).get("result", "no-end") for e in starts)
    return {
        "requests_per_source": {f"s{k}": v for k, v in sorted(c.items())},
        "end_results": dict(res),
        "aborted": res.get("aborted", 0),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--refactored", default="emulator-5556")
    ap.add_argument("--original", default="emulator-5558")
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--only-original", action="store_true")
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    # ADBKeyboard:双机安装并切换(绕过拼音 IME 组合缓冲)
    kb = ROOT / "tmp_debug" / "e2e_5558" / "ADBKeyboard.apk"
    for dev in {args.refactored, args.original}:
        sh(dev, "install", "-r", str(kb))
        sh(dev, "shell", "ime", "enable", "com.android.adbkeyboard/.AdbIME")
        sh(dev, "shell", "ime", "set", "com.android.adbkeyboard/.AdbIME")
    procs = []
    for dev, port in ((args.refactored, 8090), (args.original, 8091)):
        log = out / f"server_{dev}.jsonl"
        procs.append(subprocess.Popen(
            [sys.executable, str(ROOT / "scripts" / "s0c_server.py"),
             "--port", str(port), "--log", str(log)], cwd=str(ROOT)))
        time.sleep(1.5)
        sh(dev, "reverse", f"tcp:{port}", f"tcp:{port}")
    time.sleep(1)

    try:
        m_ref = drive_refactored(args.refactored, 8090, out)
        m_orig = drive_original(args.original, 8091, out)
    finally:
        for dev, port in ((args.refactored, 8090), (args.original, 8091)):
            marker(port, "END")
            sh(dev, "reverse", "--remove", f"tcp:{port}")
        time.sleep(1)
        for p in procs:
            p.terminate()

    m_ref["server"] = analyze(out / f"server_{args.refactored}.jsonl", m_ref.get("submit_t"))
    m_orig["server"] = analyze(out / f"server_{args.original}.jsonl", m_orig.get("submit_t"))

    def cmp(m):
        names = m["results"]
        return {
            "names": names,
            "set_match": sorted(set(names)) == sorted(EXPECTED_ORDER) and len(names) == 5,
            "order_match": names == EXPECTED_ORDER,
        }

    ref_cmp, orig_cmp = cmp(m_ref), cmp(m_orig)
    report = {
        "keyword": KW,
        "expected": {
            "order": EXPECTED_ORDER,
            "note": "s5 login_required 失败、s6 空结果 → 共 5 项;延迟递增保证到达序=稳定序",
        },
        "refactored": {k: m_ref.get(k) for k in ("device", "app", "import_ok", "first_result_s", "all_names_at_s", "results", "server", "scope")},
        "original": {k: m_orig.get(k) for k in ("device", "app", "import_ok", "first_result_s", "all_names_at_s", "results", "server", "scope")},
        "parity": {
            "refactored_set_match": ref_cmp["set_match"],
            "refactored_order_match": ref_cmp["order_match"],
            "original_set_match": orig_cmp["set_match"],
            "original_order_match": orig_cmp["order_match"],
            "two_package_results_identical": m_ref["results"] == m_orig["results"],
            "per_source_requests_identical": (
                m_ref["server"]["requests_per_source"] == m_orig["server"]["requests_per_source"]),
        },
    }
    (out / "s0c_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print("report:", json.dumps(report, ensure_ascii=False, indent=2))
    ok = all(v for v in report["parity"].values())
    print("PASS" if ok else "FAIL")
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
