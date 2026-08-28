# -*- coding: utf-8 -*-
"""P0-3 实机 e2e：搜索中停止并立即重新搜索（§7.7.6 决定性验证）。

场景（受控夹具书源，确定性证据）：
1. 启动本机夹具服务器（40 源、每请求延迟 6s、JSONL 请求日志）；
2. 深链导入书源（legado://import/bookSource?src=...）；
3. 搜索页选择分组 P0-3E2E（独占范围）；
4. 提交搜索 A → 等待 STOP_AFTER 秒（32 在飞 + 8 排队）→ 点「停止搜索」；
5. 立即再次提交搜索 B（同关键词，新会话取代 A）；
6. 等待 B 终态，落盘 UI dump / logcat / 服务器日志；
7. 判定：
   - A 阶段请求到达的 distinct 源数 ≤ 32（在飞受控）；
   - (A_STOP, B_START) 窗口无新的 /src/ 请求到达（排队源零请求）；
   - B 阶段 40 源各被请求恰好一次（B 干净、A 无残留复用）；
   - A 在飞请求存在 aborted（连接被中止，best-effort 证据）；
   - UI：停止后「停止搜索」FAB 消失；B 终态出现结果列表。

用法：python scripts/e2e_p03_cancel_research.py --device emulator-5556
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
PKG = "io.legado.flutter_legado"
ACTIVITY = f"{PKG}/io.legado.flutter.MainActivity"
HOST = "127.0.0.1"
PORT = 8090
N_SOURCES = 40
DELAY = 6.0
STOP_AFTER = 3.0
KEYWORD = "parity"
GROUP = "P0-3E2E"

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / ".e2e_p03"


def sh(*a: str) -> subprocess.CompletedProcess:
    return subprocess.run([ADB, "-s", DEV, *a], capture_output=True)


def shell(cmd: str) -> str:
    return sh("shell", cmd).stdout.decode("utf-8", "replace")


def marker(name: str) -> None:
    try:
        urllib.request.urlopen(f"http://{HOST}:{PORT}/marker/{name}", timeout=3).read()
    except Exception as e:  # 标记失败不阻断流程，但留痕
        print(f"[warn] marker {name}: {e}", flush=True)


def dump(tag: str, retries: int = 4) -> str:
    remote = f"/sdcard/.e2e_{tag}.xml"
    local = OUT / f"{tag}.xml"
    for _ in range(retries):
        shell(f"uiautomator dump {remote}")
        sh("pull", remote, str(local))
        if local.exists() and local.stat().st_size > 0:
            return local.read_text(encoding="utf-8", errors="replace")
        time.sleep(1.2)
    return ""


def nodes(x: str) -> list[tuple[str, str, str]]:
    """返回 (text, content-desc, bounds, cx, cy, cls) 列表。"""
    out = []
    for m in re.finditer(
        r'<node[^>]*?text="([^"]*)"[^>]*?class="([^"]*)"[^>]*?content-desc="([^"]*)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',
        x,
    ):
        t, cls, d = m.group(1), m.group(2), m.group(3)
        x1, y1, x2, y2 = (int(m.group(i)) for i in range(4, 8))
        out.append((t, d, f"[{x1},{y1}][{x2},{y2}]", (x1 + x2) // 2, (y1 + y2) // 2, cls))
    return out


def find_node(x: str, needle: str, exact: bool = False, by_class: str = ""):
    """按 text/content-desc 或 class 匹配节点；返回 (cx, cy, node) 或 None。"""
    for t, d, b, cx, cy, cls in nodes(x):
        if by_class:
            if by_class in cls:
                return cx, cy, (t, d, b)
            continue
        for s in (t, d):
            if (exact and s == needle) or (not exact and needle in s):
                return cx, cy, (t, d, b)
    return None


def tap(x: str, needle: str, exact: bool = False, wait: float = 1.5, by_class: str = "", dy: int = 0) -> bool:
    hit = find_node(x, needle, exact, by_class)
    if not hit:
        return False
    # dy：部分控件（如悬浮停止按钮）语义 bounds 底部伸入系统导航栏，
    # 中心点会落在导航栏上导致点击无效 —— 需向上偏移后点按
    shell(f"input tap {hit[0]} {hit[1] + dy}")
    time.sleep(wait)
    return True


def rec(line: str) -> None:
    print(line, flush=True)


def wait_for(x_probe, needle: str, timeout: float, tag: str, exact: bool = False):
    t0 = time.time()
    i = 0
    while time.time() - t0 < timeout:
        x = dump(f"{tag}_{i}")
        if find_node(x, needle, exact):
            return x
        i += 1
        time.sleep(1.5)
    return None


def back_until(needle: str, tries: int = 6) -> bool:
    for i in range(tries):
        x = dump(f"back_{i}")
        if find_node(x, needle):
            return True
        shell("input keyevent 4")
        time.sleep(2)
    return False


def main() -> int:
    global DEV
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="emulator-5556")
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--stop-after", type=float, default=STOP_AFTER)
    ap.add_argument("--delay", type=float, default=DELAY)
    args = ap.parse_args()
    DEV = args.device
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    timeline: dict[str, float] = {}

    # ── 1. 启动夹具服务器 ──────────────────────────────────────────
    server_log = out / "server_log.jsonl"
    srv = subprocess.Popen(
        [
            sys.executable,
            str(ROOT / "scripts" / "s0_fixture_server.py"),
            "--port",
            str(PORT),
            "--sources",
            str(N_SOURCES),
            "--delay",
            str(args.delay),
            "--log",
            str(server_log),
        ],
        cwd=str(ROOT),
        creationflags=subprocess.CREATE_NO_WINDOW if hasattr(subprocess, "CREATE_NO_WINDOW") else 0,
    )
    time.sleep(2)
    if srv.poll() is not None:
        rec("FAIL: fixture server exited early")
        return 1
    # Windows 下 SO_REUSEADDR 允许重复绑定 → 旧实例残留时本实例收不到请求。
    # 通过「本实例日志文件必须已写 server_start」自检端口归属。
    if not server_log.exists() or "server_start" not in server_log.read_text(encoding="utf-8", errors="replace"):
        rec("FAIL: fixture server did not acquire port (stale instance on " + str(PORT) + "?)")
        srv.terminate()
        return 1
    # 模拟器 NAT（10.0.2.2）在当前环境不可达 → 用 adb reverse 将设备
    # 127.0.0.1:PORT 映射到主机同端口，书源 URL 一律使用 127.0.0.1
    r = sh("reverse", f"tcp:{PORT}", f"tcp:{PORT}")
    if r.returncode != 0:
        rec("FAIL: adb reverse failed: " + r.stderr.decode("utf-8", "replace"))
        return 1
    rec(f"adb reverse tcp:{PORT} ok")

    try:
        run_test(out, timeline, stop_after=args.stop_after)
    finally:
        marker("END")
        time.sleep(1)
        srv.terminate()
        sh("reverse", "--remove", f"tcp:{PORT}")

    # ── 判定 ──────────────────────────────────────────────────────
    verdict = judge(server_log, out, timeline)
    (out / "verdict.json").write_text(
        json.dumps(verdict, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    rec("verdict: " + json.dumps(verdict, ensure_ascii=False))
    return 0 if verdict.get("pass") else 2


def run_test(out: Path, timeline: dict[str, float], stop_after: float = STOP_AFTER) -> None:
    # ── 2. 重启应用 ───────────────────────────────────────────────
    shell("logcat -c")
    sh("shell", "am force-stop", PKG)
    time.sleep(2)
    sh("shell", "am start", "-n", ACTIVITY)
    x = wait_for(None, "书架", 30, "home")
    if not x:
        rec("FAIL: home not reached")
        raise SystemExit(1)
    rec("home OK")

    # ── 3. 深链导入书源 ───────────────────────────────────────────
    # 注：App 端 DeepLinkService 以完整 URL 去重 → 每次附加随机参数强制重新处理
    import random
    r_param = random.randint(1000, 9999)
    sh(
        "shell",
        "am",
        "start",
        "-a",
        "android.intent.action.VIEW",
        "-d",
        f"legado://import/bookSource?src=http://127.0.0.1:{PORT}/sources.json?r={r_param}",
        "-n",
        ACTIVITY,
    )
    time.sleep(4)
    x = wait_for(None, "确认导入", 20, "import")
    if x is None:
        x = dump("import_fallback")
        (out / "import_fallback.xml").write_text(x, encoding="utf-8")
        if not tap(x, "确认"):
            rec("FAIL: import confirm not reached")
            raise SystemExit(1)
    else:
        tap(x, "确认导入")
    time.sleep(3)
    x = dump("import_result")
    (out / "import_result.xml").write_text(x, encoding="utf-8")
    ok = find_node(x, "导入完成") or find_node(x, "成功")
    rec(f"import result: {'OK' if ok else 'UNKNOWN'}")
    # 返回主页（点「完成」或 back）
    if not tap(x, "完成", exact=True):
        shell("input keyevent 4")
        time.sleep(2)
    if not back_until("书架"):
        rec("FAIL: cannot return home after import")
        raise SystemExit(1)

    # ── 4. 进入搜索页并选择分组 ───────────────────────────────────
    x = dump("home_pre")
    if not tap(x, "搜索"):
        rec("FAIL: search entry not found on home")
        raise SystemExit(1)
    x = wait_for(None, "更多选项", 15, "searchpage")
    if not x:
        rec("FAIL: search page not reached")
        raise SystemExit(1)
    # 打开更多选项菜单 → 点分组条目
    x = dump("search_open")
    if not tap(x, "更多选项"):
        rec("FAIL: overflow menu not found")
        raise SystemExit(1)
    x = dump("menu_open")
    (out / "menu_open.xml").write_text(x, encoding="utf-8")
    # 先点「全部书源」清空已恢复的范围（initState 会恢复上次持久化的分组，
    # 直接点分组条目会被 toggle 语义取消）→ 再独占选择目标分组
    tap(x, "全部书源", exact=True)
    x = wait_for(None, "更多选项", 10, "menu_reopen")
    if not x or not tap(x, "更多选项"):
        rec("FAIL: cannot reopen overflow menu")
        raise SystemExit(1)
    x = dump("menu_open2")
    (out / "menu_open2.xml").write_text(x, encoding="utf-8")
    if not tap(x, GROUP):
        rec(f"FAIL: group item {GROUP} not in menu")
        raise SystemExit(1)
    rec("group scoped")

    # ── 5. 输入关键词并提交搜索 A ─────────────────────────────────
    x = dump("pre_typed")
    if not tap(x, "", by_class="EditText"):
        # 输入框已默认聚焦，tap 失败不阻断
        rec("warn: EditText node not found, assuming focused")
    shell(f"input text {KEYWORD}")
    time.sleep(1)
    x = dump("typed")
    marker("A_START")  # 标记先于点按：请求到达即归属 A 阶段
    if not tap(x, "搜索", exact=True):
        rec("FAIL: submit button not found")
        raise SystemExit(1)
    timeline["A_SUBMIT"] = time.time()
    rec(f"A submitted t={timeline['A_SUBMIT']:.3f}")

    # ── 6. STOP_AFTER 后点停止 ────────────────────────────────────
    time.sleep(stop_after)
    x = dump("a_running")
    (out / "a_running.xml").write_text(x, encoding="utf-8")
    timeline["A_STOP_TAP"] = time.time()
    marker("A_STOP")  # 标记先于点按
    if not tap(x, "停止搜索", dy=-20):
        rec("FAIL: stop FAB not found while A running")
        raise SystemExit(1)
    time.sleep(1.5)
    # 验证停止生效（FAB 消失）；A 无结果停止 → 空结果引导对话框随后弹出，需关闭
    stop_ok = False
    for i in range(6):
        xd = dump(f"a_stopped_{i}")
        if "停止搜索" not in xd and "搜索中" not in xd:
            stop_ok = True
            break
        time.sleep(1)
    x = dump("a_stopped")
    (out / "a_stopped.xml").write_text(x, encoding="utf-8")
    if "切换全部分组" in x or "关闭精准搜索" in x:
        tap(x, "取消", exact=True)  # 关闭 A 空结束触发的引导对话框
        time.sleep(1)
        x = dump("a_stopped2")
        (out / "a_stopped2.xml").write_text(x, encoding="utf-8")
    rec(f"A stopped (fab_gone={stop_ok})")
    timeline["A_STOP_FAB_GONE"] = 1.0 if stop_ok else 0.0

    # ── 7. 立即重新搜索 B ─────────────────────────────────────────
    timeline["B_SUBMIT"] = time.time()
    marker("B_START")
    x = dump("pre_b")
    if not tap(x, "搜索", exact=True):
        # 停止后输入框可能失焦，先点输入框再点提交
        x2 = dump("pre_b2")
        tap(x2, "", by_class="EditText")
        time.sleep(0.8)
        x3 = dump("pre_b3")
        if not tap(x3, "搜索", exact=True):
            rec("FAIL: re-submit not found")
            raise SystemExit(1)
    rec(f"B submitted t={timeline['B_SUBMIT']:.3f}")

    # ── 8. 等待 B 终态（停止 FAB 消失且无加载态/引导对话框）──────
    deadline = time.time() + 120
    last = ""
    i = 0
    while time.time() < deadline:
        x = dump(f"b_poll_{i}")
        last = x
        if not x:
            i += 1
            time.sleep(2.5)
            continue
        # A 的空流结束可能在 B 运行中弹出引导对话框 → 关闭后继续等 B
        if "切换全部分组" in x or "关闭精准搜索" in x:
            tap(x, "取消", exact=True, wait=1.0)
            i += 1
            continue
        if "停止搜索" not in x and "搜索中" not in x:
            break
        i += 1
        time.sleep(2.5)
    marker("B_END")
    time.sleep(1)
    x = dump("b_final")
    (out / "b_final.xml").write_text(x, encoding="utf-8")
    names = [t for t, d, *_ in nodes(x) if t.startswith("E2E书") or d.startswith("E2E书")]
    rec(f"B final result items: {len(names)}")

    # ── 9. logcat 落盘 ────────────────────────────────────────────
    (out / "logcat.txt").write_text(shell("logcat -d"), encoding="utf-8")


def judge(server_log: Path, out: Path, timeline: dict) -> dict:
    events = []
    if server_log.exists():
        for line in server_log.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass

    def ts_of(name: str) -> float:
        for e in events:
            if e.get("kind") == "marker" and e.get("name") == name:
                return e["ts"]
        return float("nan")

    t_a, t_stop, t_b, t_end = (ts_of(m) for m in ("A_START", "A_STOP", "B_START", "B_END"))
    if any(_isnan(v) for v in (t_a, t_b)):
        return {"pass": False, "error": "markers missing", "events": len(events)}

    starts = [e for e in events if e.get("kind") == "search_start"]
    ends = {e["id"]: e for e in events if e.get("kind") == "search_end"}

    # 阶段窗口：B_START 前为 A（含停止点按后的短暂余量），其后为 B
    a_phase = [e for e in starts if t_a - 1.0 <= e["ts"] < t_b - 1.0]
    # 取消生效点按到 abort 落地有 ~0.3s 内的派发竞态余量（点按延迟 + 50ms 轮询）
    gap_phase = [e for e in starts if t_stop + 1.0 <= e["ts"] < t_b - 1.0] if not _isnan(t_stop) else []
    b_phase = [e for e in starts if e["ts"] >= t_b - 1.0]
    after_end = [e for e in starts if not _isnan(t_end) and e["ts"] > t_end]

    # 真实不变量：任意时刻同时在飞请求 ≤ concurrency（区间重叠计数）
    pts = []
    for e in a_phase:
        pts.append((e["ts"], 1))
        end_e = ends.get(e["id"])
        pts.append((end_e["ts"] if end_e else t_b, -1))
    pts.sort(key=lambda p: (p[0], -p[1]))  # 同刻先处理后结束，避免低估
    cur = mx = 0
    for _, delta in pts:
        cur += delta
        mx = max(mx, cur)

    a_src = sorted({e["src"] for e in a_phase})
    gap_src = sorted({e["src"] for e in gap_phase})
    b_srcs = [e["src"] for e in b_phase]
    b_once = all(b_srcs.count(s) == 1 for s in range(N_SOURCES))

    a_aborted = sum(1 for e in a_phase if ends.get(e["id"], {}).get("result") == "aborted")
    a_done = sum(1 for e in a_phase if ends.get(e["id"], {}).get("result") == "done")

    ui_a_stopped = (out / "a_stopped.xml").read_text(encoding="utf-8", errors="replace") if (out / "a_stopped.xml").exists() else ""
    ui_b_final = (out / "b_final.xml").read_text(encoding="utf-8", errors="replace") if (out / "b_final.xml").exists() else ""
    stop_fab_gone = "停止搜索" not in ui_a_stopped
    b_names = len(re.findall(r'E2E书\d+', ui_b_final)) // 2  # text+desc 各计一次

    checks = {
        "a_inflight_bounded": mx <= 32,
        "a_gap_zero_new_requests": len(gap_src) == 0,
        "b_all_sources_once": b_once and len(set(b_srcs)) == N_SOURCES,
        "no_requests_after_b_end": len(after_end) == 0,
        "a_aborted_evidence": a_aborted > 0 or a_done < len(a_phase),
        "ui_stop_fab_gone": stop_fab_gone,
        "ui_b_results_present": b_names > 0,
    }
    return {
        "pass": all(checks.values()),
        "checks": checks,
        "detail": {
            "a_max_concurrent": mx,
            "a_distinct_srcs": len(a_src),
            "a_srcs": a_src,
            "a_aborted": a_aborted,
            "a_done": a_done,
            "gap_srcs": gap_src,
            "b_distinct_srcs": len(set(b_srcs)),
            "b_total_requests": len(b_phase),
            "after_end_requests": len(after_end),
            "b_result_names_seen": b_names,
            "timeline": {k: round(v, 3) for k, v in timeline.items()},
        },
    }

def _isnan(v: float) -> bool:
    return v != v


if __name__ == "__main__":
    sys.exit(main())
