# -*- coding: utf-8 -*-
"""parity_capture_ours.py — 1:1 界面对比「我方」批量截图采集（batch 1，16 屏）。

目的：
  在装有我方 io.legado.flutter_legado（期望版本动态读取自 flutter_legado/pubspec.yaml）
  的 Android 设备上，自动导航采集 batch 1 的 16 屏截图，
  供与参考侧 docs/parity_shots/ref_20260913/ 做 1:1 对比。
  每屏流程：导航 → uiautomator dump 文本断言（content-desc/text 关键词命中）→
  截图落盘 docs/parity_shots/ours_<version>/<NN>_<english_short_name>.png →
  标准输出打印 [OK/FAIL] <screen> <keyword> <file>。
  文件名与参考侧一一对应（参考侧为 <NN>_<name>.png + .xml 配对，本脚本只出 PNG）。

设计原则（风格对齐 .tmp/ui/uiutil.py）：
  - 纯 adb + uiautomator dump + input tap/swipe/keyevent 驱动，无 Appium 依赖
  - 所有断言仅用 dump 文本节点（Flutter 语义多在 content-desc，正文在 text），
    全程不读取/不识别截图内容
  - 每屏独立 try/except：断言失败先等 2s 刷新 dump 重试一次，仍失败则跳过该屏
    并记录原因，绝不卡死整个运行
  - uiautomator dump 偶发 Segmentation fault：文件空则 sleep 2 重试（最多 4 次）
  - MSYS/Git Bash 路径转换问题：本地落盘一律用 Windows 绝对路径，截图用
    exec-out screencap 二进制直写（不经 shell 重定向）
  - 开跑前 am force-stop + 冷启动 + 等待 8s，并经 dumpsys 校验
    versionName 与 pubspec.yaml 版本一致（不符则整体中止）

用法：
  python scripts/parity_capture_ours.py                      # 全 16 屏
  python scripts/parity_capture_ours.py --only 01,03,06      # 只跑指定屏（07 含 07b）
  python scripts/parity_capture_ours.py --device 127.0.0.1:16416
  python scripts/parity_capture_ours.py --out docs/parity_shots/ours_<version>
退出码：0 = 全部 OK；1 = 存在失败/跳过屏。

期望版本不再硬编码：运行时从 flutter_legado/pubspec.yaml 的 `version:` 行动态读取
（取 `+` 前主版本号），设备 versionName 需与之匹配；读取失败时回退到
FALLBACK_EXPECT_VERSION（需随版本手工更新，仅作兜底）。
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
PKG = "io.legado.flutter_legado"
ACT = f"{PKG}/io.legado.flutter.MainActivity"
ROOT = Path(__file__).resolve().parent.parent
# 期望版本：优先动态读取 flutter_legado/pubspec.yaml 的 version: 行（取 `+` 前主版本号），
# 升级版本后无需手改本脚本；动态读取失败时回退到此兜底常量（需随版本手工更新）。
FALLBACK_EXPECT_VERSION = "2.0.260"
PUBSPEC = ROOT / "flutter_legado" / "pubspec.yaml"


def read_expect_version() -> str:
    """从 pubspec.yaml 的 `version:` 行读取版本号（取 `+` 前部分，如 2.0.260+261 → 2.0.260）。

    读取/解析失败时回退 FALLBACK_EXPECT_VERSION 并告警，不中止运行。
    """
    try:
        text = PUBSPEC.read_text(encoding="utf-8")
    except OSError as e:
        print(f"[parity] 警告：无法读取 {PUBSPEC}（{e}），回退兜底版本 {FALLBACK_EXPECT_VERSION}",
              file=sys.stderr, flush=True)
        return FALLBACK_EXPECT_VERSION
    m = re.search(r"(?m)^\s*version\s*:\s*[\"']?([^\"'\s]+)", text)
    if not m:
        print(f"[parity] 警告：{PUBSPEC} 中未找到 version: 行，回退兜底版本 {FALLBACK_EXPECT_VERSION}",
              file=sys.stderr, flush=True)
        return FALLBACK_EXPECT_VERSION
    return m.group(1).split("+", 1)[0]  # 去掉 build 号（+261）


EXPECT_VERSION = read_expect_version()
OUT_DIR = ROOT / "docs" / "parity_shots" / f"ours_{EXPECT_VERSION}"
TMP_UI = Path(os.environ.get("TEMP", "/tmp")) / f"parity_ui_{os.getpid()}.xml"
REMOTE_UI = "/sdcard/.parity_ui.xml"
DEFAULT_DEVICE = "192.168.1.19:5555"

# 设备分辨率 1080x1920@480dpi（探测确认的坐标基准）
W, H = 1080, 1920
# 底部导航 5 tab（y=1800）
TAB_HOME, TAB_SHELF, TAB_DISCOVER, TAB_SUB, TAB_MINE = (
    (108, 1800), (324, 1800), (540, 1800), (756, 1800), (972, 1800))
# 书架页
BTN_SHELF_SEARCH = (882, 168)     # 顶栏 搜索 圆形钮
BTN_SHELF_MENU = (1014, 168)      # 顶栏 Show menu（⋮）
CARD_BOOK = (279, 1208)           # 书卡（斗罗大陆；2.0.260 实测 bounds[36,1148,522,1268] 中心）
MENU_ITEM_SELECT = (804, 1008)    # 溢出菜单「选择模式」
# 搜索页
CHIP_HISTORY = (540, 807)         # 搜索历史 chip（斗罗大陆）
INPUT_BAR = (540, 444)            # 输入条（body 顶部）
# 书详情页
BTN_VIEW_TOC = (917, 1500)       # 查看目录
BTN_READ = (887, 1788)           # 阅读
# 目录页（/toc）
TOC_TAB, BMK_TAB, NOTE_TAB = (180, 312), (540, 312), (900, 312)
TOC_CHAP_0 = (540, 456)          # 首章（引子）
TOC_FAB = (948, 1644)            # 底部跳转 FAB（默认右下，16dp 边距，480dpi 推算）
# 阅读器
READER_CENTER = (540, 960)       # 中心点（唤出/收起菜单）
READER_MENU_ROW = {              # 菜单底部快捷行 y=1806
    "章节梗概": (108, 1806), "全文搜索": (540, 1806),
    "自动翻页": (756, 1806), "目录": (972, 1806)}


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
    print(f"[parity] {msg}", flush=True)


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


def swipe(x1: int, y1: int, x2: int, y2: int, ms: int = 300) -> None:
    sh("shell", "input", "swipe", str(x1), str(y1), str(x2), str(y2), str(ms))


def keyevent(code: str) -> None:
    sh("shell", "input", "keyevent", code)


def unesc(s: str) -> str:
    return (s.replace("&#10;", "\n").replace("&#12;", "\n").replace("&#13;", "\n")
             .replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">"))


def nodes(x: str):
    """解析 <node ...> 标签，返回 (text, desc, bounds) 列表（uiutil 风格）。"""
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


def dump(tag: str = "") -> str:
    """uiautomator dump + pull。偶发段错误/空文件 → sleep 2 重试（最多 4 次）。"""
    for i in range(4):
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


def locate_or_fallback(pat: str, fallback_xy: tuple[int, int],
                       label: str = "") -> None:
    """dump 优先定位：正则 pat 命中的可点击节点点其中心；未命中则回退坐标。

    原则：以 dump 文本为准灵活调整导航（任务硬性要求），预置坐标仅作兜底，
    界面改版后无需改坐标即可跑通。
    """
    x = dump(label)
    for t, d, b in nodes(x):
        if (t or d) and re.search(pat, t + " " + d):
            tap(*center_of(b))
            rec(f"  [locate] {label or pat}：dump 命中，点 ({(b[0]+b[2])//2},{(b[1]+b[3])//2})")
            return
    rec(f"  [locate] {label or pat}：dump 未命中，回退坐标 {fallback_xy}")
    tap(*fallback_xy)


def center_of(b: list[int]) -> tuple[int, int]:
    return ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2)


def screenshot(name: str) -> Path:
    """exec-out screencap -p 二进制直写本地（不经 shell 重定向，规避 MSYS 问题）。"""
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    p = OUT_DIR / name
    r = sh("exec-out", "screencap", "-p", binary=True)
    data = r.stdout or b""
    if not data or len(data) < 10_000:
        # 退化：pull 方式
        shell("screencap", "-p", "/sdcard/.parity_shot.png")
        sh("pull", "/sdcard/.parity_shot.png", str(p))
        if not p.exists():
            raise RuntimeError("截图失败（exec-out 与 pull 均失败）")
        return p
    p.write_bytes(data)
    if len(data) < 10_000:
        raise RuntimeError(f"截图过小（{len(data)}B），疑似黑屏/失败")
    return p


def cold_start() -> None:
    """force-stop + 冷启动 + 8s 等待。"""
    shell("am", "force-stop", PKG)
    wait(1)
    shell("am", "start", "-n", ACT)
    wait(8)


def check_version() -> str:
    out = shell("dumpsys", "package", PKG)
    m = re.search(r"versionName=([^\s]+)", out)
    return m.group(1) if m else ""


# ===== 单屏执行器 =====
class ScreenResult:
    def __init__(self, num: str, name: str, ok: bool,
                 keyword: str, file: str, reason: str = ""):
        self.num, self.name, self.ok = num, name, ok
        self.keyword, self.file, self.reason = keyword, file, reason

    def log(self) -> None:
        line = f"[{'OK' if self.ok else 'FAIL'}] {self.num}_{self.name} {self.keyword} {self.file}"
        if not self.ok:
            line += f"  原因：{self.reason}"
        print(line, flush=True)


def run_screen(num: str, name: str, navigate: callable, kws: tuple[str, ...],
               filename: str) -> ScreenResult:
    """navigate() 完成导航 → dump 断言（失败重试 1 次，2s 刷新）→ 截图。"""
    try:
        navigate()
        x = dump()
        hit = has_kw(x, kws)
        if not hit:
            wait(2)
            x = dump()
            hit = has_kw(x, kws)
        if not hit:
            # 断言失败仍留档截图（便于事后人工排查），但标记 FAIL
            try:
                f = screenshot(filename)
            except Exception:
                f = Path(filename)
            r = ScreenResult(num, name, False, "/".join(kws), f.name,
                             "dump 断言未命中关键词（重试 1 次后仍失败）")
            r.log()
            return r
        f = screenshot(filename)
        r = ScreenResult(num, name, True, hit, f.name)
        r.log()
        return r
    except Exception as e:  # 任何异常不中断整体运行
        r = ScreenResult(num, name, False, "/".join(kws), filename,
                         f"执行异常：{type(e).__name__}: {e}")
        r.log()
        return r


# ===== 各屏导航函数（坐标基于 1080x1920 探测结果） =====
def go_home() -> None:
    """冷启动后落点在最后使用的 tab（常为书架），统一先回首页。"""
    cold_start()
    tap(*TAB_HOME)
    wait(3)


def go_bookshelf() -> None:
    tap(*TAB_SHELF)
    wait(3)


def _to_shelf() -> None:
    """冷启动 → 书架 tab（每屏从确定状态起步，互不污染）。"""
    cold_start()
    go_bookshelf()


def nav_01() -> None:
    cold_start()
    # 底部 tab 可能无 content-desc（纯图标），dump 未命中则回退坐标
    locate_or_fallback(r"首页", TAB_HOME, "底部首页 tab")
    wait(3)


def nav_02() -> None:
    # 与 01 同屏（首页即底部导航形态），仅换文件名
    cold_start()
    locate_or_fallback(r"首页", TAB_HOME, "底部首页 tab")
    wait(3)


def nav_03() -> None:
    # 书架 tab 用已验证坐标（顶栏标题也含「书架」，dump 优先易误命中）
    _to_shelf()


def nav_04() -> None:
    _to_shelf()
    locate_or_fallback(r"更多|菜单|menu|overflow", BTN_SHELF_MENU, "书架顶栏 ⋮")
    wait(2)


def nav_05() -> None:
    _to_shelf()
    locate_or_fallback(r"更多|菜单|menu|overflow", BTN_SHELF_MENU, "书架顶栏 ⋮")
    wait(2)
    locate_or_fallback(r"选择模式", MENU_ITEM_SELECT, "溢出菜单「选择模式」")
    wait(3)


def nav_06() -> None:
    _to_shelf()
    locate_or_fallback(r"搜索|search", BTN_SHELF_SEARCH, "书架顶栏 搜索")
    wait(3)


def _trigger_search() -> None:
    """点历史 chip 预填 → 点输入条聚焦 → ENTER 触发搜索。"""
    tap(*CHIP_HISTORY)
    wait(2)
    tap(*INPUT_BAR)
    wait(1)
    keyevent("66")  # ENTER → Flutter onSubmitted → search()


def _poll(kws: tuple[str, ...], total_s: float, step_s: float = 3.0) -> bool:
    t0 = time.time()
    while time.time() - t0 < total_s:
        if has_kw(dump(), kws):
            return True
        wait(step_s)
    return False


def nav_07_searching() -> None:
    """07a 搜索进行中态：触发搜索后尽快捕获「结果/进度/停止搜索」。"""
    _to_shelf()
    tap(*BTN_SHELF_SEARCH)
    wait(3)
    _trigger_search()
    # 轮询等待「进行中」特征出现（最多 25s）；若搜索过快直接完成，
    # 断言会失败并跳过（记录原因），不卡死
    _poll(("进度", "停止搜索"), 25)


def nav_07_done() -> None:
    """07b 搜索完成态：触发搜索后等待「加载下一页」出现（完成且还有下一页）。"""
    _to_shelf()
    tap(*BTN_SHELF_SEARCH)
    wait(3)
    _trigger_search()
    _poll(("加载下一页",), 90)


def _to_reader_menu() -> None:
    _to_shelf()
    tap(*CARD_BOOK)
    wait(4)
    tap(*BTN_VIEW_TOC)
    wait(4)
    tap(*TOC_CHAP_0)
    wait(6)
    tap(*READER_CENTER)
    wait(2)


def nav_08() -> None:
    """书详情：从书架点书卡（瀚海书阁源，目录可正常加载）。"""
    _to_shelf()
    tap(*CARD_BOOK)
    wait(4)


def nav_09() -> None:
    _to_shelf()
    tap(*CARD_BOOK)
    wait(4)
    locate_or_fallback(r"查看目录", BTN_VIEW_TOC, "详情页「查看目录」")
    wait(4)


def nav_10() -> None:
    _to_shelf()
    tap(*CARD_BOOK)
    wait(4)
    tap(*BTN_VIEW_TOC)
    wait(4)
    tap(*TOC_CHAP_0)
    wait(6)


def nav_11() -> None:
    _to_reader_menu()


def nav_12() -> None:
    _to_shelf()
    tap(*CARD_BOOK)
    wait(4)
    tap(*BTN_VIEW_TOC)
    wait(4)
    tap(*TOC_CHAP_0)
    wait(6)
    swipe(READER_CENTER[0], READER_CENTER[1],
          READER_CENTER[0], READER_CENTER[1], 800)  # 长按（同点 800ms）
    wait(2)


def nav_13() -> None:
    _to_reader_menu()
    locate_or_fallback(r"全文搜索", READER_MENU_ROW["全文搜索"], "菜单「全文搜索」")
    wait(3)


def nav_14() -> None:
    _to_shelf()
    tap(*CARD_BOOK)
    wait(4)
    tap(*BTN_VIEW_TOC)
    wait(4)
    locate_or_fallback(r"书签", BMK_TAB, "目录页「书签」页签")
    wait(3)


def nav_15() -> None:
    """目录页底部跳转 FAB → 展开快捷菜单（定位至当前阅读/移至顶部/移至底部/一键缓存）。"""
    _to_shelf()
    tap(*CARD_BOOK)
    wait(4)
    tap(*BTN_VIEW_TOC)
    wait(4)
    locate_or_fallback(r"跳转|定位", TOC_FAB, "目录页「跳转」FAB")
    wait(2)


def nav_16() -> None:
    """自动翻页开启态：阅读器菜单 → 点 自动翻页（切换为 停止翻页）。"""
    _to_reader_menu()
    locate_or_fallback(r"自动翻页|停止翻页", READER_MENU_ROW["自动翻页"], "菜单「自动翻页」")
    wait(2)


# ===== 屏幕登记表（顺序执行，状态链式推进） =====
# (编号, 英文短名, 导航函数, 断言关键词, 是否双态)
SCREENS: list[tuple[str, str, str, callable, tuple[str, ...]]] = [
    ("01", "home_page",        nav_01,        ("最近", "累计阅读", "统计")),
    ("02", "bottom_nav",       nav_02,        ("Tab 1 of 5", "首页")),
    ("03", "bookshelf",        nav_03,        ("斗罗大陆",)),
    ("04", "bookshelf_overflow_menu", nav_04, ("选择模式", "书架管理", "分组管理")),
    ("05", "bookshelf_select_mode",   nav_05, ("全选", "删除", "取消")),
    ("06", "search",           nav_06,        ("搜索历史", "清空")),
    # 07 = 完成态（任务屏 07 文件名）；07b = 搜索中态（补拍，07b 前缀）
    ("07",  "search_results",           nav_07_done,      ("加载下一页",)),
    ("07b", "search_results_loading",  nav_07_searching, ("进度", "停止搜索")),
    ("08", "book_info",        nav_08,        ("换源", "阅读", "查看目录")),
    ("09", "toc",              nav_09,        ("引子", "跳转顶部")),
    ("10", "reader",           nav_10,        ("唐门", "斗罗大陆", "唐三")),
    ("11", "reader_menu",      nav_11,        ("全文搜索", "自动翻页", "退出阅读")),
    # 长按浮条按钮（text_selection_panel.dart 实证：复制/分享/浏览器/朗读/书签/更多）
    ("12", "reader_longpress", nav_12,        ("复制", "分享", "朗读", "浏览器", "书签", "更多")),
    ("13", "search_content",   nav_13,        ("搜索正文", "搜索选项", "搜索历史")),
    ("14", "bookmark_toc",     nav_14,        ("暂无书签", "书签", "标注")),
    ("15", "chapter_jump",     nav_15,        ("定位至当前阅读", "移至顶部", "一键缓存")),
    # 必须命中「停止翻页」才证明已切换为开启态（按钮标签 自动翻页→停止翻页，
    # 二者互斥；若点空仍显示 自动翻页 则断言失败并记录原因）
    ("16", "auto_flip",        nav_16,        ("停止翻页",)),
]
SCREEN_FILE = {
    "01": "01_home_page.png", "02": "02_bottom_nav.png",
    "03": "03_bookshelf.png", "04": "04_bookshelf_overflow_menu.png",
    "05": "05_bookshelf_select_mode.png", "06": "06_search.png",
    # 任务约定：07 文件名存「已完成」态；07b 前缀存「搜索中」态
    "07": "07_search_results.png", "07b": "07b_search_results_loading.png",
    "08": "08_book_info.png", "09": "09_toc.png", "10": "10_reader.png",
    "11": "11_reader_menu.png", "12": "12_reader_longpress.png",
    "13": "13_search_content.png", "14": "14_bookmark_toc.png",
    "15": "15_chapter_jump.png", "16": "16_auto_flip.png",
}


def main() -> int:
    # global 声明必须在函数内首次使用 DEV/OUT_DIR（argparse default 引用 OUT_DIR）之前，
    # 否则 SyntaxError: name 'OUT_DIR' is used prior to global declaration
    global DEV, OUT_DIR
    ap = argparse.ArgumentParser(description="我方 1:1 对比批量截图采集（batch 1）")
    ap.add_argument("--device", default=DEFAULT_DEVICE,
                    help=f"adb 设备（默认 {DEFAULT_DEVICE}）")
    ap.add_argument("--only", default="",
                    help="只跑指定屏编号，逗号分隔，如 --only 01,03,06（07 会同时跑 07/07b）")
    ap.add_argument("--out", default=str(OUT_DIR),
                    help=f"截图输出目录（默认 {OUT_DIR}）")
    args = ap.parse_args()

    DEV = args.device
    OUT_DIR = Path(args.out)
    if not OUT_DIR.is_absolute():
        OUT_DIR = ROOT / OUT_DIR

    want = set()
    if args.only:
        for tok in args.only.split(","):
            tok = tok.strip()
            if not tok:
                continue
            want.add(tok)
            if tok == "07":
                want.add("07b")  # 07 屏含双态：完成态(07) + 搜索中态(07b)

    rec(f"设备：{DEV}；adb：{ADB}")
    if not want:
        rec("目标：全 16 屏")
    else:
        rec(f"目标：--only {','.join(sorted(want))}")

    # 设备可达性
    r = sh("shell", "echo", "parity-ping")
    if "parity-ping" not in (r.stdout or "") + (r.stderr or ""):
        rec("设备不可达，整体中止（exit 1）")
        return 1

    # 版本校验
    ver = check_version()
    if ver != EXPECT_VERSION:
        rec(f"版本校验失败：versionName={ver or '未知'}（期望 {EXPECT_VERSION}），整体中止")
        return 1
    rec(f"版本校验通过：{PKG} versionName={ver}")

    results: list[ScreenResult] = []
    for num, name, nav, kws in SCREENS:
        if want and num not in want:
            continue
        try:
            res = run_screen(num, name, nav, kws, SCREEN_FILE[num])
        except Exception as e:  # 双保险：单屏任何异常都不中断
            res = ScreenResult(num, name, False, "/".join(kws),
                               SCREEN_FILE[num], f"未捕获异常：{type(e).__name__}: {e}")
            res.log()
        results.append(res)
        # 注：每屏导航自带冷启动（_to_shelf/cold_start），状态天然隔离，
        # 选择模式(05)/自动翻页(16) 的污染不会带到下一屏，无需额外复位

    # 汇总
    ok = [r for r in results if r.ok]
    fail = [r for r in results if not r.ok]
    rec("=" * 60)
    rec(f"完成：{len(ok)}/{len(results)} 屏 OK")
    if fail:
        rec("失败/跳过清单：")
        for r in fail:
            rec(f"  - {r.num}_{r.name}：{r.reason}")
    rec(f"截图目录：{OUT_DIR}")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
