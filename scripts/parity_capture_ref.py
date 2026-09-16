# -*- coding: utf-8 -*-
"""parity_capture_ref.py — 1:1 界面对比「参考版 kazusa」批 3 设置域自动截图采集。

目的：
  在装有参考版 io.legato.kazusa 的设备上，自动导航采集批 3「设置域」9 屏截图，
  供与我方 docs/parity_shots/ours_<version>/ 做 1:1 对比。
  每屏流程：导航 → uiautomator dump 文本断言（屏独有元素关键词命中）→
  截图落盘 docs/parity_shots/ref_batch3/<NN>_<english_short_name>.png →
  标准输出打印 [OK/FAIL] <screen> <keyword> <file>。

设计原则（风格对齐 .tmp/ui/uiutil.py 与 scripts/parity_capture_ours.py）：
  - 纯 adb + uiautomator dump + input tap/swipe/keyevent 驱动，无 Appium 依赖
  - 断言仅用 dump 文本节点（text 或 content-desc 关键词），全程不识别截图内容
  - **dump 优先定位**：所有行/入口一律按 dump 文本节点找中心点按，
    目标不在屏内时自动上滑（列表下滑）再找，最多 3 次；预置坐标仅作兜底
  - **每步导航后 dump 校验**：进深页前必须先断言「上一页特征」命中，
    防止点错进深页（历史事故：驱动误入书源编辑器）
  - 断言失败 → 不落盘（保留旧图避免错态覆盖）+ 打印前 8 个文本节点辅助定位
  - 每屏独立 try/except：单屏失败不中断整体运行
  - uiautomator dump 偶发段错误/空文件 → sleep 2 重试（最多 6 次）
  - 冷启动 = force-stop + am start + 8s + 点「我的」tab（972,1822），
    每屏从确定状态起步，互不污染
  - MSYS/Git Bash 路径转换：本地落盘用 Windows 绝对路径，截图用
    exec-out screencap 二进制直写（不经 shell 重定向）

用法：
  python scripts/parity_capture_ref.py                      # 全 9 屏 + 明暗最佳努力屏
  python scripts/parity_capture_ref.py --only 02_read_record,03_settings
  python scripts/parity_capture_ref.py --only 05_theme_dark  # 单屏
  python scripts/parity_capture_ref.py --out docs/parity_shots/ref_batch3
  python scripts/parity_capture_ref.py --device 192.168.1.19:5555
退出码：0 = 全部 OK；1 = 存在失败/跳过屏。

屏清单（输出文件名 <key>.png，key 即 --only 用屏名）：
  02_read_record   阅读记录   —— 我的页→「阅读记录」
  03_settings      设置主页   —— 我的页→「设置」
  04_appearance    外观       —— 设置页→「外观」（主题设置页）
  05_theme         主题设置   —— 外观页 12 色卡（与 04 同页，断言色卡名）
  06_backup        备份与恢复 —— 设置页→「备份与恢复」
  07_font          字体       —— 设置页→「阅读界面」
  08_tts           朗读       —— 设置域找「朗读」（阅读界面/高级，最佳努力）
  10_auto_task     定时任务   —— 我的页→「定时任务」
  11_highlight     高亮/书签  —— 我的页→「高亮标注」
  最佳努力（--only 可单独指定，主跑自动追加）：
  04_appearance_dark / 05_theme_dark —— 我的页「主题模式」切深色后重拍，拍完切回；
                                        找不到明暗切换则跳过并汇报
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

# ===== 常量 =====
PKG = "io.legato.kazusa"
ACT = f"{PKG}/io.legado.app.ui.main.MainActivity"
ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DEVICE = "192.168.1.19:5555"
OUT_DIR = ROOT / "docs" / "parity_shots" / "ref_batch3"
TMP_UI = Path(os.environ.get("TEMP", "/tmp")) / f"parity_ref_ui_{os.getpid()}.xml"
REMOTE_UI = "/sdcard/.parity_ref_ui.xml"

# 设备分辨率 1080x1920（实测坐标基准）
W, H = 1080, 1920
# 底部导航 5 tab；「我的」tab 中心（实测 dump [864,1724][1080,1920] 中心 (972,1822)）
TAB_MINE = (972, 1822)

# 上滑（列表下滑）手势：从 (540,1500) 滑到 (540,700)
SWIPE_UP = (540, 1500, 540, 700)
# 下滑（列表上滑）手势：从 (540,700) 滑到 (540,1500)
SWIPE_DOWN = (540, 700, 540, 1500)

# 列表滚动后稳定等待（秒）：uiautomator dump 在 fling 动画未停时取到的是
# 旧帧/中间态树，点按坐标会偏移甚至打穿页面；滑动后必须先 settle 再 dump。
SETTLE_S = 2.0
# 滑动未生效判定：目标未命中且 dump 行集合与上一次完全相同（列表已在端点）
MAX_SAME_DUMPS = 2

# 「我的」页特征（用于进深页前断言上一页；实测该页常驻元素）
MINE_PAGE_KWS = ("我的",)
# 「设置」子页特征（实测：外观/高级/阅读界面/备份与恢复 等行）
SETTINGS_PAGE_KWS = ("外观", "高级", "阅读界面", "备份与恢复")


def resolve_adb() -> str:
    """adb 解析：PATH 优先，其次 LDPlayer9，再退化 local.properties sdk.dir。"""
    p = shutil.which("adb")
    if p:
        return p
    cand = Path(r"D:/leidian/LDPlayer9/adb.exe")
    if cand.exists():
        return str(cand)
    props = ROOT / "flutter_legado" / "android" / "local.properties"
    if props.exists():
        for line in props.read_text(encoding="utf-8").splitlines():
            if line.startswith("sdk.dir"):
                sdk = line.split("=", 1)[1].replace("\\\\", "\\").strip()
                pc = Path(sdk) / "platform-tools" / "adb.exe"
                if pc.exists():
                    return str(pc)
    raise SystemExit("adb 未找到：PATH / D:/leidian/LDPlayer9 / local.properties 均无")


ADB = resolve_adb()
DEV = DEFAULT_DEVICE


def rec(msg: str) -> None:
    print(f"[ref3] {msg}", flush=True)


def sh(*args: str, binary: bool = False) -> subprocess.CompletedProcess:
    if binary:
        return subprocess.run([ADB, "-s", DEV, *args], capture_output=True)
    return subprocess.run(
        [ADB, "-s", DEV, *args], capture_output=True,
        text=True, encoding="utf-8", errors="replace")


def shell(*args: str) -> str:
    r = sh("shell", *args)
    return (r.stdout or "") + (r.stderr or "")


def wait(s: float) -> None:
    time.sleep(s)


def tap(x: int, y: int) -> None:
    sh("shell", "input", "tap", str(x), str(y))


def swipe(x1: int, y1: int, x2: int, y2: int, ms: int = 350) -> None:
    sh("shell", "input", "swipe", str(x1), str(y1), str(x2), str(y2), str(ms))


def keyevent(code: str) -> None:
    sh("shell", "input", "keyevent", code)


def swipe_up(ms: int = 600) -> None:
    """列表下滑（露出下方内容）：(540,1500)→(540,700)。

    默认 600ms：时长越长速度越慢，fling 惯性滚动量越小，
    避免一次性甩过目标行（甩过后只向下扫会把目标甩出视野）。
    """
    swipe(*SWIPE_UP, ms)


def swipe_down(ms: int = 600) -> None:
    """列表上滑（回到顶部方向）：(540,700)→(540,1500)。"""
    swipe(*SWIPE_DOWN, ms)


def unesc(s: str) -> str:
    return (s.replace("&#10;", "\n").replace("&#12;", "\n").replace("&#13;", "\n")
             .replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">"))


def nodes(x: str):
    """解析 <node ...> 标签，返回 (text, desc, bounds) 列表。"""
    out = []
    for m in re.finditer(r"<node[^>]*>", x):
        tag = m.group(0)

        def g(k: str) -> str:
            mm = re.search(k + r'="([^"]*)"', tag)
            return mm.group(1) if mm else ""

        nums = [int(v) for v in re.findall(r"\d+", g("bounds"))]
        if len(nums) == 4:
            out.append((unesc(g("text")), unesc(g("content-desc")), nums))
    return out


def center_of(b: list[int]) -> tuple[int, int]:
    return ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2)


def dump(tag: str = "") -> str:
    """uiautomator dump + pull。偶发段错误/空文件 → sleep 2 重试（最多 6 次）。"""
    for i in range(6):
        shell(f"rm -f {REMOTE_UI}")
        shell("uiautomator", "dump", REMOTE_UI)  # 可能打印 Segmentation fault，忽略
        sh("pull", REMOTE_UI, str(TMP_UI))
        if TMP_UI.exists() and TMP_UI.stat().st_size > 0:
            try:
                x = TMP_UI.read_text(encoding="utf-8", errors="replace")
                if "<node" in x:
                    return x
            except OSError:
                pass
        wait(2)
    return ""


def has_kw(x: str, kws: tuple[str, ...]) -> str:
    """返回命中的第一个关键词（在 text 或 content-desc 中），未命中返回 ''。"""
    for t, d, _b in nodes(x):
        for kw in kws:
            if kw and (kw in t or kw in d):
                return kw
    return ""


def screenshot(name: str) -> Path:
    """exec-out screencap -p 二进制直写本地（不经 shell 重定向，规避 MSYS 问题）。"""
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    p = OUT_DIR / name
    r = sh("exec-out", "screencap", "-p", binary=True)
    data = r.stdout or b""
    if not data or len(data) < 10_000:
        # 退化：pull 方式
        shell("screencap", "-p", "/sdcard/.parity_ref_shot.png")
        sh("pull", "/sdcard/.parity_ref_shot.png", str(p))
        if not p.exists():
            raise RuntimeError("截图失败（exec-out 与 pull 均失败）")
        return p
    p.write_bytes(data)
    if len(data) < 10_000:
        raise RuntimeError(f"截图过小（{len(data)}B），疑似黑屏/失败")
    return p


# ===== 设备 / 冷启动 =====
def ensure_device() -> bool:
    """adb connect（幂等，已连接无副作用）+ 可达性 ping。"""
    shell_connect = subprocess.run(
        [ADB, "connect", DEV], capture_output=True,
        text=True, encoding="utf-8", errors="replace")
    rec(f"adb connect {DEV} → {(shell_connect.stdout or '').strip() or (shell_connect.stderr or '').strip()}")
    r = sh("shell", "echo", "ref3-ping")
    return "ref3-ping" in (r.stdout or "") + (r.stderr or "")


def cold_start() -> None:
    """force-stop + 冷启动 + 8s + 点「我的」tab（972,1822）。

    包名守卫（2026-09-16 抢设备事故修复）：冷启后必须确认前台包是 kazusa，
    否则我方应用（同为「我的」tab 文案、同坐标）会误判通过。
    """
    shell("am", "force-stop", PKG)
    wait(1)
    shell("am", "start", "-n", ACT)
    wait(8)
    focus = shell("dumpsys", "window", "|", "grep", "mCurrentFocus")
    if PKG not in focus:
        raise RuntimeError(f"冷启后前台非 {PKG}（mCurrentFocus={focus.strip()[:80]}）——疑似设备被占用")
    tap(*TAB_MINE)
    wait(3)


# ===== 通用导航原语 =====
def _find_node_center(x: str, row_pat: str,
                      require: tuple[str, ...] = ()) -> tuple[int, int] | None:
    """在 dump 文本 x 中找「首行」匹配 row_pat（正则）且全文含 require 全部词的节点中心。

    row_pat 作用于节点 text 的首行（text 以 \n 分隔标题/副标题；compact 渲染下
    标题与副标题为独立节点，首行即标题本身）。未命中返回 None。
    """
    pat = re.compile(row_pat)
    for t, d, b in nodes(x):
        s = t if (t and t.strip()) else d
        if not s:
            continue
        first_line = s.split("\n")[0].strip()
        if not pat.match(first_line):
            continue
        full = (t or "") + " " + (d or "")
        if require and not all(k in full for k in require):
            continue
        return center_of(b)
    return None


def _row_hits(x: str, row_pat: str, require: tuple[str, ...]) -> bool:
    """dump 文本中是否存在首行匹配 row_pat 且全文含 require 的节点（不取坐标）。"""
    pat = re.compile(row_pat)
    for t, d, _b in nodes(x):
        s = t if (t and t.strip()) else d
        if not s:
            continue
        if not pat.match(s.split("\n")[0].strip()):
            continue
        full = (t or "") + " " + (d or "")
        if require and not all(k in full for k in require):
            continue
        return True
    return False


def _fp(x: str, n: int = 4) -> tuple:
    """dump 前 n 个非空行文本指纹（判断列表是否已在端点/未再滚动）。"""
    return tuple(t for t, _d, _b in nodes(x) if t.strip())[:n]


def reset_list_top(label: str = "list_top", max_swipes: int = 6) -> None:
    """把当前列表滚动复位到顶部（连续上滑到顶部方向）。

    我的页列表较长且冷启动滚动位置不定，先复位再自顶向下找，
    保证同一目标的最大滑动量恒定、可预期。
    """
    prev: tuple | None = None
    for i in range(max_swipes):
        x = dump(f"{label}#top{i + 1}")
        fp = _fp(x)
        if prev is not None and fp and fp == prev:
            rec(f"  [nav] {label}：列表已在顶部（指纹稳定）")
            return
        prev = fp
        swipe_down()
        wait(SETTLE_S)


def tap_row(row_name: str, label: str, require: tuple[str, ...] = (),
            max_swipes: int = 3, exact: bool = True,
            fallback_xy: tuple[int, int] | None = None) -> tuple[int, int] | None:
    """按文本定位行/入口并点其中心；不在屏内则上滑再找，最多 max_swipes 次。

    row_name：行首行文本（exact=True 时按精确首行匹配，防「定时任务」误配「运行定时任务」）。
    require：全文须再含的全部词（用于「设置」行 vs「设置」组标题消歧）。
    搜索策略：先把列表复位到顶部（冷启动滚动位置不定），再自顶向下上滑查找，
    保证同一目标的最大滑动量恒定、可预期；滑后「文本存在性」命中即停，
    坐标以最后一次 dump 为准重新定位（滚动动画中 dump 可能取旧树）。
    fallback_xy：dump 始终未命中时的兜底坐标（默认放弃，返回 None 不硬点）。
    返回实际点按坐标；未找到且无兜底则返回 None。
    """
    if exact:
        row_pat = r"^" + re.escape(row_name) + r"$"
    else:
        row_pat = row_name
    reset_list_top(label)
    x = dump(label)
    if _row_hits(x, row_pat, require):
        xy = _find_node_center(x, row_pat, require)
    else:
        xy = None
        prev_fp: tuple | None = None
        same_cnt = 0
        for i in range(max_swipes):
            prev_rows = [t for t, _d, _b in nodes(x) if t.strip()]
            swipe_up()
            wait(SETTLE_S)
            x = dump(f"{label}#swipe{i + 1}")
            if _row_hits(x, row_pat, require):
                break
            # fling 甩过保护：上一屏顶行已完全滚出（新 dump 全行中消失）
            # → 可能甩过目标；回滑半步补搜一次（本轮不再上滑，下轮继续推进）
            cur_rows = [t for t, _d, _b in nodes(x) if t.strip()]
            if prev_rows and prev_rows[0] not in cur_rows:
                rec(f"  [nav] {label}：滑动量超一屏（顶行「{prev_rows[0]}」滚出），回滑补搜")
                swipe_down()
                wait(SETTLE_S)
                x = dump(f"{label}#back{i + 1}")
                if _row_hits(x, row_pat, require):
                    break
                cur_rows = [t for t, _d, _b in nodes(x) if t.strip()]
            # 列表已到端点：连续 MAX_SAME_DUMPS 次 dump 指纹不变 → 继续滑无意义
            fp = _fp(x, 8)
            if fp and fp == prev_fp:
                same_cnt += 1
                if same_cnt >= MAX_SAME_DUMPS:
                    rec(f"  [nav] {label}：列表已到端点仍未命中「{row_name}」，停止上滑")
                    break
            else:
                same_cnt = 0
            prev_fp = fp
        xy = _find_node_center(x, row_pat, require)
    if xy is None and fallback_xy is not None:
        xy = fallback_xy
        rec(f"  [nav] {label}：dump 未命中，回退坐标 {xy}")
    if xy is None:
        rec(f"  [nav] {label}：dump 未命中且无兜底，放弃")
        return None
    tap(*xy)
    rec(f"  [nav] {label}：点 {xy}")
    wait(3)
    return xy


def verify_page(kws: tuple[str, ...], label: str) -> bool:
    """dump 校验当前页含 kws 任一（进深页前断言上一页特征）。"""
    x = dump(label)
    hit = has_kw(x, kws)
    if hit:
        rec(f"  [verify] {label}：命中「{hit}」，页特征 OK")
        return True
    rec(f"  [verify] {label}：未命中 {kws}（可能不在预期页）")
    return False


def go_mine() -> None:
    """冷启动 → 「我的」tab，并校验已落到我的页。"""
    cold_start()
    if not verify_page(MINE_PAGE_KWS, "我的页"):
        # 冷启可能恢复二级页：BACK 回主壳再点 tab
        keyevent("4")
        wait(1)
        tap(*TAB_MINE)
        wait(2)
        verify_page(MINE_PAGE_KWS, "我的页(补)")


def go_settings_home() -> None:
    """我的页 → 「设置」行 → 设置子页（外观/高级/阅读界面/...）。

    进深页前先断言「我的页」特征；「设置」行须含「外观」副标题以区别于「设置」组标题。"""
    go_mine()
    if not verify_page(MINE_PAGE_KWS, "进设置前(我的页)"):
        rec("  [warn] 未确认我的页特征，仍尝试点「设置」行")
    # 我的页「设置」行为唯一精确文本行（组标题在 x=96 左缘、行内容在 x=216，
    # 且实测部分渲染下行无「外观」副标题节点），故不做 require 消歧。
    xy = tap_row("设置", "我的页「设置」行", max_swipes=3)
    if xy is None:
        raise RuntimeError("未找到「设置」行，无法进入设置子页")
    if not verify_page(SETTINGS_PAGE_KWS, "设置子页"):
        rec("  [warn] 设置子页特征未完全命中，继续（断言阶段会兜底）")


def go_appearance() -> None:
    """设置子页 → 「外观」行 → 主题设置页（12 色卡）。"""
    go_settings_home()
    if not verify_page(SETTINGS_PAGE_KWS, "进外观前(设置子页)"):
        raise RuntimeError("未确认设置子页特征，放弃进入外观")
    xy = tap_row("外观", "设置子页「外观」行", max_swipes=3)
    if xy is None:
        raise RuntimeError("未找到「外观」行")


def _scroll_to_and_tap_in_settings(target: str, label: str,
                                   require: tuple[str, ...] = ()) -> None:
    """设置子页内找 target 行并点（子页列表可滚动，上滑重试）。"""
    go_settings_home()
    xy = tap_row(target, label, require=require, max_swipes=3)
    if xy is None:
        raise RuntimeError(f"设置子页未找到「{target}」行")


# ===== 各屏导航函数 =====
def nav_02_read_record() -> None:
    """02 阅读记录：我的页 → 「阅读记录」行。"""
    go_mine()
    verify_page(MINE_PAGE_KWS, "进阅读记录前(我的页)")
    xy = tap_row("阅读记录", "我的页「阅读记录」行", max_swipes=3)
    if xy is None:
        raise RuntimeError("未找到「阅读记录」行")


def nav_03_settings() -> None:
    """03 设置主页：我的页 → 「设置」行。"""
    go_settings_home()


def nav_04_appearance() -> None:
    """04 外观：设置子页 → 「外观」行（主题设置页）。"""
    go_appearance()


def nav_05_theme() -> None:
    """05 主题设置（12 色卡）：与 04 同页（外观入口即主题设置页），仅断言色卡名。"""
    go_appearance()


def nav_06_backup() -> None:
    """06 备份与恢复：设置子页 → 「备份与恢复」行。"""
    _scroll_to_and_tap_in_settings("备份与恢复", "设置子页「备份与恢复」行")


def nav_07_font() -> None:
    """07 字体：设置子页 → 「阅读界面」行（字号/背景/翻页动画/排版）。"""
    _scroll_to_and_tap_in_settings("阅读界面", "设置子页「阅读界面」行")


def nav_08_tts() -> None:
    """08 朗读：设置域找「朗读」。优先「阅读界面」页，未命中回退「高级」页。

    朗读在 legado 常为阅读器功能，设置域未必有独立入口；找不到则抛错由 run_screen
    记为 FAIL（最佳努力屏）。"""
    go_settings_home()
    # 先试「阅读界面」
    xy = tap_row("阅读界面", "设置子页「阅读界面」行", max_swipes=3)
    if xy is not None:
        x = dump("08_阅读界面")
        if has_kw(x, ("朗读", "语速")):
            return
        rec("  [08] 阅读界面页无「朗读/语速」，回退「高级」页")
        keyevent("4")
        wait(2)
    # 再试「高级」
    go_settings_home()
    xy = tap_row("高级", "设置子页「高级」行", max_swipes=3)
    if xy is None:
        raise RuntimeError("未找到「高级」行")
    # 高级页内找「朗读」
    x = dump("08_高级")
    if has_kw(x, ("朗读", "语速")):
        return
    for _ in range(3):
        swipe_up()
        wait(SETTLE_S)
        x = dump("08_高级#swipe")
        if has_kw(x, ("朗读", "语速")):
            return
    raise RuntimeError("设置域（阅读界面/高级）未找到「朗读/语速」入口")


def nav_10_auto_task() -> None:
    """10 定时任务：我的页 → 「定时任务」行（区别于「运行定时任务」）。"""
    go_mine()
    verify_page(MINE_PAGE_KWS, "进定时任务前(我的页)")
    xy = tap_row("定时任务", "我的页「定时任务」行", max_swipes=3)
    if xy is None:
        raise RuntimeError("未找到「定时任务」行")


def nav_11_highlight() -> None:
    """11 高亮/书签类：我的页 → 「高亮标注」行（自动高亮标注规则）。

    次选「书签」行；优先「高亮标注」（任务标题「高亮/书签类列表」，高亮标注更贴切）。"""
    go_mine()
    verify_page(MINE_PAGE_KWS, "进高亮前(我的页)")
    xy = tap_row("高亮标注", "我的页「高亮标注」行", max_swipes=3)
    if xy is None:
        rec("  [11] 未找到「高亮标注」行，回退「书签」行")
        xy = tap_row("书签", "我的页「书签」行", max_swipes=3)
    if xy is None:
        raise RuntimeError("未找到「高亮标注」或「书签」行")


# ===== 明暗切换（最佳努力：04_appearance_dark / 05_theme_dark） =====
DARK_MODE_KWS = ("深色", "暗色", "夜间", "黑夜", "Dark")
LIGHT_MODE_KWS = ("浅色", "亮色", "日间", "白天", "跟随系统", "Light")


def _find_theme_mode_toggle() -> bool:
    """我的页找「主题模式」行并点开；返回是否进入主题模式选项页。"""
    go_mine()
    xy = tap_row("主题模式", "我的页「主题模式」行", max_swipes=3)
    if xy is None:
        rec("  [dark] 未找到「主题模式」行，跳过明暗切换")
        return False
    x = dump("theme_mode")
    if not (has_kw(x, DARK_MODE_KWS) or has_kw(x, LIGHT_MODE_KWS)):
        rec("  [dark] 主题模式页未见明暗选项，跳过")
        return False
    return True


def _switch_to_dark() -> bool:
    """在主题模式选项页点「深色/暗色/夜间/Dark」切到深色；成功返回 True。"""
    x = dump("theme_mode_dark")
    xy = None
    for t, d, b in nodes(x):
        full = (t or "") + " " + (d or "")
        if any(k in full for k in DARK_MODE_KWS):
            xy = center_of(b)
            break
    if xy is None:
        rec("  [dark] 未找到深色选项")
        return False
    tap(*xy)
    rec(f"  [dark] 点深色选项 {xy}")
    wait(2)
    return True


def _switch_to_light() -> None:
    """切回浅色/跟随系统（复位，避免污染后续屏）。"""
    x = dump("theme_mode_light")
    xy = None
    for t, d, b in nodes(x):
        full = (t or "") + " " + (d or "")
        if any(k in full for k in LIGHT_MODE_KWS):
            xy = center_of(b)
            break
    if xy is not None:
        tap(*xy)
        rec(f"  [dark] 切回浅色/跟随系统 {xy}")
        wait(2)
    else:
        keyevent("4")
        rec("  [dark] 未见浅色选项，BACK 退出主题模式页")
        wait(2)


def nav_04_appearance_dark() -> None:
    """04 外观（深色）：我的页「主题模式」切深色 → 设置子页「外观」→ 主题设置页。"""
    if not _find_theme_mode_toggle():
        raise RuntimeError("无主题模式明暗切换，跳过 04_appearance_dark")
    _switch_to_dark()
    keyevent("4")  # 退出主题模式选项页回我的页
    wait(1)
    go_appearance()
    # 复位：切回浅色
    _switch_to_light()


def nav_05_theme_dark() -> None:
    """05 主题设置（深色）：同 04_appearance_dark 路径（外观页即主题设置页）。"""
    nav_04_appearance_dark()


# ===== 单屏执行器 =====
class ScreenResult:
    def __init__(self, key: str, ok: bool, keyword: str, file: str, reason: str = ""):
        self.key, self.ok = key, ok
        self.keyword, self.file, self.reason = keyword, file, reason

    def log(self) -> None:
        line = f"[{'OK' if self.ok else 'FAIL'}] {self.key} {self.keyword} {self.file}"
        if not self.ok:
            line += f"  原因：{self.reason}"
        print(line, flush=True)


def _debug_nodes(x: str, n: int = 8) -> str:
    """取前 n 个带 text/desc 的节点，供断言失败时人工定位（打印用）。"""
    out = []
    for t, d, _b in nodes(x):
        if t or d:
            out.append(f"t={t!r} d={d!r}" if t else f"d={d!r}")
            if len(out) >= n:
                break
    return " | ".join(out) if out else "(dump 无文本节点)"


def run_screen(key: str, navigate, kws: tuple[str, ...],
               and_kws: tuple[str, ...] = (),
               neg_kws: tuple[str, ...] = ()) -> ScreenResult:
    """navigate() 完成导航 → dump 断言（失败重试 1 次，2s 刷新）→ 截图。

    断言语义（防错态误存）：
      - kws（OR，主特征）必须命中其一；
      - and_kws（OR，附加特征）非空时须再命中其一（与 kws 构成 AND）；
      - neg_kws 任一命中即判错态。
    断言失败时**不落盘**（保留旧图，避免错态覆盖正图），并打印 dump 前 8 个文本节点。
    """
    fname = f"{key}.png"
    try:
        navigate()
        x = dump()
        hit = has_kw(x, kws)
        and_hit = has_kw(x, and_kws) if and_kws else True
        neg_hit = has_kw(x, neg_kws) if neg_kws else ""
        if not (hit and and_hit) or neg_hit:
            wait(2)
            x = dump()
            hit = has_kw(x, kws)
            and_hit = has_kw(x, and_kws) if and_kws else True
            neg_hit = has_kw(x, neg_kws) if neg_kws else ""
        if not (hit and and_hit) or neg_hit:
            parts = []
            if not hit:
                parts.append(f"未命中主关键词 {kws}")
            if not and_hit:
                parts.append(f"未命中附加关键词 {and_kws}")
            if neg_hit:
                parts.append(f"命中负向关键词 {neg_hit}（错态特征）")
            r = ScreenResult(key, False, "/".join(kws), fname,
                             "；".join(parts) + "；保留旧图不覆盖")
            r.log()
            rec(f"  [debug] 前 8 个文本节点：{_debug_nodes(x, 8)}")
            return r
        f = screenshot(fname)
        r = ScreenResult(key, True, hit, f.name)
        r.log()
        return r
    except Exception as e:  # 任何异常不中断整体运行
        r = ScreenResult(key, False, "/".join(kws), fname,
                         f"执行异常：{type(e).__name__}: {e}")
        r.log()
        return r


# ===== 屏幕登记表 =====
# (key, 导航函数, 主关键词(OR), 附加关键词(OR, AND), 负向关键词)
# 主特征取屏独有元素（实测 dump 关键词）；负向排除其他页特征，防错态误存。
SCREENS: list[tuple[str, "callable", tuple[str, ...], tuple[str, ...],
                    tuple[str, ...]]] = [
    # 02 阅读记录：标题「阅读记录」+ 阅读时长/书名类（空态也照拍）
    ("02_read_record", nav_02_read_record,
     ("阅读记录", "阅读时长", "阅读时间"), (), ()),
    # 03 设置主页：设置子页含「外观」行（子页独有）
    ("03_settings", nav_03_settings,
     ("外观",), ("高级", "阅读界面"), ()),
    # 04 外观：主题设置页（标题「主题设置」+ 主题引擎/内置主题）
    ("04_appearance", nav_04_appearance,
     ("主题", "主题设置", "主题模式", "字体"), (), ()),
    # 05 主题设置（12 色卡）：与 04 同页，断言色卡名（纯白/森绿/柠檬 等任一）
    ("05_theme", nav_05_theme,
     ("纯白", "森绿", "柠檬", "小春", "优香", "菲比", "穹", "八月",
      "卡洛塔", "姆吉卡", "墨水", "透明"), ("内置主题", "外观预览"), ()),
    # 06 备份与恢复：行标题「备份与恢复」+ 副标题 WebDav/导入
    ("06_backup", nav_06_backup,
     ("备份", "恢复", "WebDav", "WebDAV"), (), ()),
    # 07 字体：阅读界面页（字号/背景/翻页动画/排版）
    ("07_font", nav_07_font,
     ("字体", "字号"), (), ()),
    # 08 朗读：设置域找「朗读/语速」（最佳努力；阅读器功能未必在设置域）
    ("08_tts", nav_08_tts,
     ("朗读", "语速"), (), ()),
    # 10 定时任务：我的页「定时任务」行（管理按计划执行的 JavaScript 任务）
    ("10_auto_task", nav_10_auto_task,
     ("定时任务", "任务", "定时"), (), ()),
    # 11 高亮/书签：我的页「高亮标注」行（自动高亮标注规则）
    ("11_highlight", nav_11_highlight,
     ("标注", "高亮", "书签"), (), ()),
]

# 最佳努力明暗屏（主跑自动追加到末尾；--only 指定时也可单独跑）
SCREENS_DARK: list[tuple[str, "callable", tuple[str, ...], tuple[str, ...],
                         tuple[str, ...]]] = [
    ("04_appearance_dark", nav_04_appearance_dark,
     ("主题", "主题设置", "主题模式", "字体"), (), ()),
    ("05_theme_dark", nav_05_theme_dark,
     ("纯白", "森绿", "柠檬", "小春", "优香", "菲比", "穹", "八月",
      "卡洛塔", "姆吉卡", "墨水", "透明"), (), ()),
]


def main() -> int:
    global DEV, OUT_DIR
    ap = argparse.ArgumentParser(
        description="参考版 kazusa 批 3 设置域批量截图采集（9 屏 + 明暗最佳努力屏）")
    ap.add_argument("--device", default=DEFAULT_DEVICE,
                    help=f"adb 设备（默认 {DEFAULT_DEVICE}）")
    ap.add_argument("--only", default="",
                    help="只跑指定屏，逗号分隔（屏名 key，如 02_read_record,03_settings）")
    ap.add_argument("--out", default="",
                    help="截图输出目录（默认 docs/parity_shots/ref_batch3）")
    ap.add_argument("--no-dark", action="store_true",
                    help="跳过明暗最佳努力屏（04_appearance_dark/05_theme_dark）")
    args = ap.parse_args()

    DEV = args.device
    OUT_DIR = (Path(args.out) if args.out
               else ROOT / "docs" / "parity_shots" / "ref_batch3")
    if not OUT_DIR.is_absolute():
        OUT_DIR = ROOT / OUT_DIR

    want = set()
    if args.only:
        for tok in args.only.split(","):
            tok = tok.strip()
            if tok:
                want.add(tok)
    all_keys = {s[0] for s in SCREENS} | {s[0] for s in SCREENS_DARK}
    unknown = want - all_keys
    if unknown:
        rec(f"警告：--only 含未知屏名 {sorted(unknown)}（有效：{sorted(all_keys)}）")

    rec(f"设备：{DEV}；adb：{ADB}")
    rec(f"输出目录：{OUT_DIR}")
    if want:
        rec(f"目标：--only {','.join(sorted(want))}")
    else:
        rec(f"目标：全 9 屏{' + 明暗最佳努力屏' if not args.no_dark else ''}")

    if not ensure_device():
        rec("设备不可达，整体中止（exit 1）")
        return 1

    results: list[ScreenResult] = []

    def _run(screens, keys_filter):
        for key, nav, kws, and_kws, neg_kws in screens:
            if keys_filter and key not in keys_filter:
                continue
            try:
                res = run_screen(key, nav, kws, and_kws=and_kws, neg_kws=neg_kws)
            except Exception as e:  # 双保险：单屏任何异常都不中断
                res = ScreenResult(key, False, "/".join(kws), f"{key}.png",
                                   f"未捕获异常：{type(e).__name__}: {e}")
                res.log()
            results.append(res)

    _run(SCREENS, want)
    # 明暗屏：仅在未显式 --only 或显式指定明暗屏时执行
    if not args.no_dark and (not want or (want & {s[0] for s in SCREENS_DARK})):
        _run(SCREENS_DARK, (want & {s[0] for s in SCREENS_DARK}) or None)

    ok = [r for r in results if r.ok]
    fail = [r for r in results if not r.ok]
    rec("=" * 60)
    rec(f"完成：{len(ok)}/{len(results)} 屏 OK")
    if fail:
        rec("失败/跳过清单：")
        for r in fail:
            rec(f"  - {r.key}：{r.reason}")
    rec(f"截图目录：{OUT_DIR}")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
