# -*- coding: utf-8 -*-
"""parity_capture_ours.py — 1:1 界面对比「我方」批量截图采集（批 1 16 屏 + 批 2 10 屏）。

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
  python scripts/parity_capture_ours.py                      # 批 1 16 屏 + 批 2 10 屏
  python scripts/parity_capture_ours.py --only 01,03,06      # 批 1 屏编号（07 含 07b）
  python scripts/parity_capture_ours.py --only 01_discover,08_source_manage
                                                             # 批 2 屏全名 key（可与批 1 混用）
  python scripts/parity_capture_ours.py --device 127.0.0.1:16416
  python scripts/parity_capture_ours.py --out docs/parity_shots/ours_<version>
退出码：0 = 全部 OK；1 = 存在失败/跳过屏。
批 2（发现与源管理）屏 key：01_discover / 02_discover_overflow / 03_discover_expand /
06_booklist / 07_source_switch / 08_source_manage / 09_source_editor /
10_replace_rule_edit / 11_rss_source / 12_web_service（即输出文件名 <key>.png）。

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
# 搜索页历史区实为整行条目（2.0.260 实测 bounds）：
#   「玄幻」[48,768,1032,942]；「斗罗大陆」[48,972,1032,1146] → 中心 (540,1059)。
# 点历史行即触发该关键词搜索（无需再点输入条/回车）。
HIST_ROW_BOOK = (540, 1059)      # 搜索历史行「斗罗大陆」中心
RESULT_ITEM_1 = (540, 780)       # 搜索结果第 1 行（标题+作者行）中心兜底坐标
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
# 发现页顶栏（批 2 用：⋮ 更多菜单 + 源卡/展开区/书单定位）
BTN_DISCOVER_MENU = (1014, 168)      # 发现页顶栏 ⋮（更多，tooltip「更多」）
DISCOVER_TILE_1 = (270, 420)         # 发现页第一源卡兜底中心（顶部为第一张源卡）
DISCOVER_CHIP_1 = (180, 720)         # 展开区分节首个 chip 兜底（3 列 chips 网格）
# 书源管理 /sources（我的页「书源管理」入口进入；顶栏内嵌「搜索书源」框）
SRC_FIRST_ROW = (540, 360)           # 第一行源卡兜底中心（顶栏搜索框之下）
# 设置/我的 页条目兜底（dump 命中时优先点 dump 节点中心）
TILE_REPLACE_PURIFY = (540, 900)     # 「替换净化」条目兜底
BTN_REPLACE_ADD = (1044, 168)        # 替换规则页顶栏最右「新增」(add) 按钮兜底
# 订阅页 RSS 源瓦片兜底（头部双卡「规则订阅|收藏」之下的 72dp 小瓦片网格首格）
RSS_TILE_1 = (144, 560)
# 详情页「换源」钮兜底（详情页按钮行：换源/加入书架/查看目录/继续阅读）
BTN_CHANGE_SOURCE = (108, 1500)


# 长按浮条（text_selection_panel.dart ReaderSelectionToolbar 的 6 按钮，
# uiautomator content-desc 实证：复制/分享/浏览器/朗读/书签/更多 均可见）。
# 主特征取前 5 个：实测菜单态 dump 无这 5 词（只有「更多」重叠），
# 故「更多」不作主特征，防菜单+选中错态误判。
LONGPRESS_TOOLBAR_KWS = ("复制", "分享", "浏览器", "朗读", "书签")
# 「仍在阅读器」特征：正文行以 content-desc 暴露（如「唐三道…」）；
# 浮条态不显示页码指示（「章」/「1/8」仅在菜单态出现），故改用正文词。
LONGPRESS_READER_KWS = ("唐三", "斗罗大陆")
# 长按探点：正文中部 3 行（任务指定坐标），依次试直到 dump 命中浮条
LONGPRESS_PROBES = ((540, 700), (540, 1000), (540, 1300))
# 12 屏 3 探点全不命中时的连拍兜底标记（main 汇总时汇报）
_LP12_BURST = False


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


def _debug_nodes(x: str, n: int = 5) -> str:
    """取前 n 个带 text/desc 的节点，供断言失败时人工定位（打印用）。"""
    out = []
    for t, d, _b in nodes(x):
        if t or d:
            out.append(f"t={t!r} d={d!r}" if t else f"d={d!r}")
            if len(out) >= n:
                break
    return " | ".join(out) if out else "(dump 无文本节点)"


def run_screen(num: str, name: str, navigate: callable, kws: tuple[str, ...],
               filename: str, and_kws: tuple[str, ...] = (),
               neg_kws: tuple[str, ...] = (),
               post: callable | None = None) -> ScreenResult:
    """navigate() 完成导航 → dump 断言（失败重试 1 次，2s 刷新）→ 截图 → post 复位。

    断言语义（收紧后，防错态误存）：
      - kws（OR，主特征）必须命中其一；
      - and_kws（OR，附加特征）非空时须再命中其一（与 kws 构成 AND）；
      - neg_kws 任一命中即判错态（如自动翻页控制条/退出阅读等阅读器特征）。
    断言失败时**不再保存截图**（保留旧图，避免错态覆盖正图），
    并打印 dump 前 5 个文本节点辅助定位。
    """
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
            r = ScreenResult(num, name, False, "/".join(kws), Path(filename).name,
                             "；".join(parts) + "；保留旧图不覆盖")
            r.log()
            rec(f"  [debug] 前 5 个文本节点：{_debug_nodes(x)}")
            return r
        f = screenshot(filename)
        r = ScreenResult(num, name, True, hit, f.name)
        r.log()
        if post is not None:
            post()
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


def _to_reader() -> None:
    """干净进入阅读器：冷启动 → 书架 → 点书卡（继续最近阅读）。"""
    _to_shelf()
    tap(*CARD_BOOK)
    wait(6)


def _ensure_auto_flip_off() -> None:
    """若自动翻页控制条在跑（自动翻页设置持久化，冷启后仍会运行）则先停止，
    避免污染后续屏（12 长按 / 13 全文搜索 等均要求干净阅读态）。"""
    x = dump()
    if has_kw(x, ("自动翻页", "停止自动翻页")):
        xy = None
        for _t, d, b in nodes(x):
            if "停止自动翻页" in d or "停止翻页" in d:
                xy = center_of(b)
                break
        if xy is None:
            xy = (823, 1776)  # 控制条「停止自动翻页」钮实测中心
        tap(*xy)
        wait(2)
        rec(f"  [reset] 检测到自动翻页运行中，已点停止 {xy}")


def _search_to_book_detail() -> None:
    """搜索路径进书籍详情页（08 专用）：
    书架 → 搜索页 → 点搜索历史行「斗罗大陆」（点行即触发搜索）→
    等结果出现（最多 40s）→ 点第一个搜索结果行 → 详情页。
    注意：书架卡点按是「继续阅读」语义（直达阅读器），详情页必须走搜索路径。
    """
    _to_shelf()
    tap(*BTN_SHELF_SEARCH)
    wait(3)
    # 点历史行：dump 优先定位 desc 恰为「斗罗大陆」的整行条目，未命中回退坐标
    x = dump()
    xy = None
    for _t, d, b in nodes(x):
        if d.strip() == "斗罗大陆":
            xy = center_of(b)
            break
    if xy is not None:
        tap(*xy)
        rec(f"  [08] 搜索历史行「斗罗大陆」：dump 命中，点 {xy}")
    else:
        tap(*HIST_ROW_BOOK)
        rec(f"  [08] 搜索历史行「斗罗大陆」：dump 未命中，回退坐标 {HIST_ROW_BOOK}")
    wait(3)
    # 等结果出现：完成态（加载下一页）/进行中（停止搜索）/书架结果行（书名+作者）
    if not _poll(("加载下一页", "停止搜索", "唐家三少"), 40):
        raise RuntimeError("搜索 40s 未出现结果特征，无法进入详情页")
    # 点第一个搜索结果行（标题+作者同一行的节点），未命中回退坐标
    x = dump()
    xy = None
    for _t, d, b in nodes(x):
        if "斗罗大陆" in d and "唐家三少" in d and b[1] < 960:
            xy = center_of(b)
            break
    if xy is not None:
        tap(*xy)
        rec(f"  [08] 首个搜索结果行：dump 命中，点 {xy}")
    else:
        tap(*RESULT_ITEM_1)
        rec(f"  [08] 首个搜索结果行：dump 未命中，回退坐标 {RESULT_ITEM_1}")
    wait(5)


def nav_08() -> None:
    """书详情：搜索路径（历史行触发搜索 → 首个结果行 → 详情页）。

    书架卡点按是「继续阅读」语义，直达阅读器，必然采成阅读态；
    详情页（封面大图/书名/作者/来源徽标/换源/目录/继续阅读）必须走搜索路径。
    """
    _search_to_book_detail()


def _detail_to_toc() -> None:
    """详情页 → 点「查看目录」进目录页（09 专用，复用 08 的搜索进详情路径）。"""
    _search_to_book_detail()
    locate_or_fallback(r"查看目录", BTN_VIEW_TOC, "详情页「查看目录」")
    wait(4)


def nav_09() -> None:
    """目录页：详情页 → 查看目录。断言须命中「书签」页签 + 章节/跳转特征。"""
    _detail_to_toc()


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
    """长按浮条：干净进入阅读器 → 停止运行中的自动翻页 → 正文中部 3 探点依次长按。

    探点协议（每点）：`input swipe x y x y 950`（同点 950ms，超 Flutter 500ms
    长按阈值触发 onLongPressStart → ReaderSelectionToolbar 浮条）→ sleep 1.5s → dump：
      - 命中浮条按钮词（复制/分享/浏览器/朗读/书签，content-desc 实证）
        且命中正文词（唐三/斗罗大陆，证明仍在阅读器）→ 立即停止探测返回，
        由 run_screen 截图存 12_reader_longpress.png；
      - 未命中则试下一探点（浮条若已弹出则全屏屏障拦截后续长按，
        旧浮条保持，连拍兜底时画面即真实状态）。
    3 点全不命中：首探点长按后 0.5/1.5/3s 连拍 3 张存
    12_reader_longpress_t1/t2/t3.png 供人工目视，并置 _LP12_BURST 汇报；
    run_screen 断言随后失败 → 12_reader_longpress.png 不覆盖（保留旧图）。
    浮条为会话态（force-stop 即清除），截图后无需复位，冷启动兜底。
    """
    global _LP12_BURST
    _LP12_BURST = False
    _to_reader()
    _ensure_auto_flip_off()
    for i, (x, y) in enumerate(LONGPRESS_PROBES, 1):
        swipe(x, y, x, y, 950)  # 同点 950ms 长按
        wait(1.5)
        d = dump()
        tb = has_kw(d, LONGPRESS_TOOLBAR_KWS)
        rd = has_kw(d, LONGPRESS_READER_KWS)
        if tb and rd:
            rec(f"  [12] 探点 {i} ({x},{y}) 命中：浮条「{tb}」+ 阅读器「{rd}」")
            return
        rec(f"  [12] 探点 {i} ({x},{y}) 未命中（浮条={tb or '-'}，阅读器={rd or '-'}）")
    # 3 点全不命中：连拍兜底（长按后 0.5/1.5/3s 各一张）
    bx, by = LONGPRESS_PROBES[0]
    swipe(bx, by, bx, by, 950)
    for delay, tag in ((0.5, "t1"), (1.5, "t2"), (3.0, "t3")):
        wait(delay)
        f = screenshot(f"12_reader_longpress_{tag}.png")
        rec(f"  [12] 连拍 {tag}（长按后 +{delay}s）落盘：{f.name}（{f.stat().st_size}B）")
    _LP12_BURST = True
    rec("  [12] 3 探点 dump 均未命中浮条：已连拍 t1/t2/t3 供目视；"
        "12_reader_longpress.png 将保留旧图不覆盖")


def nav_13() -> None:
    """搜索内容页（全文搜索）：干净进入阅读器 → 唤菜单 → 菜单底部「全文搜索」。"""
    _to_reader()
    _ensure_auto_flip_off()
    tap(*READER_CENTER)
    wait(2)
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
    """自动翻页开启态：干净进阅读器 → 停掉可能残留的自动翻页 →
    唤菜单 → 点「自动翻页」启动 → 收菜单露出底部控制条
    （自动翻页/10秒/减慢/加快/停止自动翻页/阅读设置）。"""
    _to_reader()
    _ensure_auto_flip_off()
    tap(*READER_CENTER)
    wait(2)
    locate_or_fallback(r"自动翻页", READER_MENU_ROW["自动翻页"], "菜单「自动翻页」")
    wait(2)
    tap(*READER_CENTER)  # 收起菜单，露出自动翻页控制条
    wait(2)


def reset_after_16() -> None:
    """16 截图后复位：停止自动翻页（设置持久化，冷启后仍会运行并泄漏到后续屏）
    → 唤菜单 → 退出阅读。保证后续屏/下次运行不残留自动翻页态。"""
    x = dump()
    if has_kw(x, ("停止自动翻页", "自动翻页")):
        xy = None
        for _t, d, b in nodes(x):
            if "停止自动翻页" in d or "停止翻页" in d:
                xy = center_of(b)
                break
        if xy is None:
            xy = (823, 1776)
        tap(*xy)
        wait(2)
        rec(f"  [reset] 16 后停止自动翻页 {xy}")
    else:
        rec("  [reset] 16 后未发现自动翻页控制条（已处于停止态）")
    tap(*READER_CENTER)
    wait(2)
    locate_or_fallback(r"退出阅读", (72, 144), "菜单「退出阅读」")
    wait(2)


# ===== 批 2 导航函数（发现与源管理；编号 01/02/03/06-12 与批 1 数字同号，
#      以 key=<编号>_<短名> 独立注册表 SCREENS_B2 区分，--only 用全名） =====
def _to_mine() -> None:
    """冷启动 → 底部「我的」tab（设置页：书源管理/替换净化/Web 服务/MCP 服务）。

    冷启会恢复上次路由（可能是 /sources 等二级页，无底栏 → 点 tab 坐标会
    落到内容行上）。主壳 PopScope(canPop=false)，BACK 对主壳无副作用，
    故先 BACK 弹回主壳再点 tab；仍不在设置页则再 BACK + 点按一轮，
    最多 3 轮。注意：KeepAlive 页保留滚动位置，设置列表可能停在下方
    → 点 tab 后先滚回列表顶再校验（在顶时下滑为无害空操作）。
    校验用多行标记 OR：滚顶后「定时任务/书源管理/TXT 目录规则」必可见。"""
    cold_start()
    markers = ("定时任务", "书源管理", "TXT 目录规则")
    for i in range(3):
        keyevent("4")
        wait(1)
        tap(*TAB_MINE)
        wait(2)
        for _ in range(3):  # 列表滚到顶
            swipe(W // 2, 500, W // 2, 1400, 350)
            wait(1)
        x = dump("to_mine")
        blob = " ".join(t + " " + d for t, d, _b in nodes(x))
        if any(m in blob for m in markers):
            return
        rec(f"  [b2] to_mine 第 {i + 1} 轮未落到设置页，BACK + 重点")


def _first_content_row(y_lo: int, y_hi: int, exclude: tuple[str, ...],
                       label: str) -> None:
    """在 [y_lo, y_hi] 纵带内找首个非排除词内容行并点其中心；未命中回退坐标。"""
    x = dump(label)
    cands = []
    for t, d, b in nodes(x):
        s = (t or d).strip()
        if not s or not (y_lo <= b[1] <= y_hi):
            continue
        if any(k in s for k in exclude):
            continue
        cands.append(((b[1], b[0]), center_of(b)))
    if cands:
        cands.sort()
        _fb, xy = cands[0]
        tap(*xy)
        rec(f"  [b2] {label}：dump 命中首个内容行，点 {xy}")
    else:
        fb = SRC_FIRST_ROW
        tap(*fb)
        rec(f"  [b2] {label}：dump 未命中，回退坐标 {fb}")


def nav_b2_01() -> None:
    """01_discover 发现页：冷启动 → 底部「发现」tab（源名瓦片/分组 chip）。

    冷启落点是上次持久化 tab；个别情况下首次点按未生效（页面仍在原 tab），
    故点按后 dump 校验顶栏标题「发现」，未切换则补点一次。"""
    cold_start()
    tap(*TAB_DISCOVER)
    wait(3)
    switched = any("发现" in (t + " " + d) for t, d, _b in nodes(dump("01_discover")))
    if not switched:
        tap(*TAB_DISCOVER)
        wait(3)


def nav_b2_02() -> None:
    """02_discover_overflow 发现页溢出菜单：发现页 → 顶栏 ⋮（更多）→ 分组菜单。"""
    cold_start()
    tap(*TAB_DISCOVER)
    wait(3)
    locate_or_fallback(r"更多", BTN_DISCOVER_MENU, "发现顶栏 ⋮（更多）")
    wait(2)


def nav_b2_03() -> None:
    """03_discover_expand 发现源展开区：发现页 → 点第一张源卡 → 展开分类 chips。"""
    cold_start()
    tap(*TAB_DISCOVER)
    wait(3)
    # 第一张源卡 = 顶栏之下首个内容行（排除顶栏词/空态词），未命中回退坐标
    x = dump("03_discover_expand")
    cands = []
    for t, d, b in nodes(x):
        s = (t or d).strip()
        if not s or not (240 <= b[1] <= 1600):
            continue
        if any(k in s for k in ("发现", "全部", "筛选发现源", "更多",
                                "当前没有发现源", "加载中")):
            continue
        cands.append(((b[1], b[0]), center_of(b)))
    if cands:
        cands.sort()
        _fb, xy = cands[0]
        tap(*xy)
        rec(f"  [b2] 03 第一源卡：dump 命中，点 {xy}")
    else:
        tap(*DISCOVER_TILE_1)
        rec(f"  [b2] 03 第一源卡：dump 未命中，回退坐标 {DISCOVER_TILE_1}")
    wait(3)


def nav_b2_06() -> None:
    """06_booklist 分类书单页：发现页 → 展开第一源卡 → 点首个分类 chip。
    展开后源卡标题行仍在最上（再点会收起），故取「标题行之下」首个内容行
    作为首个 chip/分节标题，点之进入书单。"""
    nav_b2_03()
    x = dump("06_booklist")
    rows = []
    for t, d, b in nodes(x):
        s = (t or d).strip()
        if not s or not (240 <= b[1] <= 1700):
            continue
        if any(k in s for k in ("发现", "全部", "筛选发现源", "更多",
                                "当前没有发现源")):
            continue
        rows.append(((b[1], b[0]), b))
    rows.sort(key=lambda c: c[0])
    if len(rows) >= 2:
        header_y1 = rows[0][1][3]
        for _k, b in rows[1:]:
            if b[1] > header_y1:  # 源卡标题行之下首个内容行 = 首个 chip/分节
                xy = center_of(b)
                tap(*xy)
                rec(f"  [b2] 06 首个分类 chip：dump 命中（标题行之下），点 {xy}")
                wait(4)
                return
    tap(*DISCOVER_CHIP_1)
    rec(f"  [b2] 06 首个分类 chip：dump 未命中，回退坐标 {DISCOVER_CHIP_1}")
    wait(4)


def nav_b2_07() -> None:
    """07_source_switch 换源弹层：搜索路径进详情页 → 点「换源」（底部弹层）。"""
    _search_to_book_detail()
    locate_or_fallback(r"换源", BTN_CHANGE_SOURCE, "详情页「换源」")
    wait(4)


def nav_b2_08() -> None:
    """08_source_manage 书源管理：我的页 → 「书源管理」条目 → /sources。

    行节点 text 为「标题\\n副标题」合并串（实测 2.0.264：「书源管理
    \\n新建、导入、编辑或管理书源」），故按 text 首行匹配；未命中先
    滚到列表顶再试一次（顶态行中心实测 (540,648)），最后才回退坐标。"""
    _to_mine()
    label = "我的页「书源管理」条目"
    xy = None
    for attempt in range(2):
        for t, d, b in nodes(dump(label)):
            s = (t or d).strip()
            if (s or "").split("\n")[0] == "书源管理":
                xy = center_of(b)
                break
        if xy:
            break
        swipe(W // 2, 500, W // 2, 1400, 350)  # 列表滚到顶
        wait(1)
    if xy is None:
        xy = (540, 648)  # 顶态实测「书源管理」行 y[540,756] 中心
        rec(f"  [b2] {label}：dump 未命中，回退坐标 {xy}")
    tap(*xy)
    rec(f"  [b2] {label}：点 {xy}")
    wait(4)


def nav_b2_09() -> None:
    """09_source_editor 书源编辑器：书源管理 → 点第一个源卡 → 编辑器。"""
    nav_b2_08()
    _first_content_row(240, 1700,
                       ("搜索书源", "已启用", "启用发现", "启用所选",
                        "新建书源", "暂无书源", "导入"),
                       "09 书源管理首个源卡")
    wait(4)


def nav_b2_10() -> None:
    """10_replace_rule_edit 替换净化编辑器：我的页 → 「替换净化」→ 新增规则。"""
    _to_mine()
    locate_or_fallback(r"替换净化", TILE_REPLACE_PURIFY, "我的页「替换净化」条目")
    wait(3)
    # 顶栏最右新增按钮无 tooltip（add 图标），dump 难命中，直接兜底坐标
    tap(*BTN_REPLACE_ADD)
    rec(f"  [b2] 10 新增规则按钮：点兜底坐标 {BTN_REPLACE_ADD}")
    wait(3)


def nav_b2_11() -> None:
    """11_rss_source RSS 源二级页：底部「订阅」tab → 点第一个 RSS 源瓦片。"""
    cold_start()
    tap(*TAB_SUB)
    wait(3)
    x = dump("11_rss_source")
    cands = []
    for t, d, b in nodes(x):
        s = (t or d).strip()
        if not s or not (300 <= b[1] <= 1700):
            continue
        if any(k in s for k in ("订阅", "规则订阅", "收藏", "删除 RSS 源",
                                "当前没有订阅源", "暂无订阅源", "加载")):
            continue
        cands.append(((b[1], b[0]), center_of(b)))
    if cands:
        cands.sort()
        _fb, xy = cands[0]
        tap(*xy)
        rec(f"  [b2] 11 首个 RSS 源瓦片：dump 命中，点 {xy}")
    else:
        tap(*RSS_TILE_1)
        rec(f"  [b2] 11 首个 RSS 源瓦片：dump 未命中，回退坐标 {RSS_TILE_1}")
    wait(4)


def nav_b2_12() -> None:
    """12_web_service Web 服务开启态：我的页（设置页含「Web 服务」开关行）。

    「Web 服务」行在设置列表第 9 位，_to_mine 滚顶后不可见 → 上滑
    1-2 屏使其露出（逐次 dump 校验，命中即停，防滑过头）。"""
    _to_mine()
    label = "设置页「Web 服务」行"
    x = dump(label)
    if not any("Web 服务" in (t + " " + d) for t, d, _b in nodes(x)):
        for _ in range(2):
            swipe(W // 2, 1400, W // 2, 500, 350)  # 列表下滑
            wait(1)
            x = dump(label)
            if any("Web 服务" in (t + " " + d) for t, d, _b in nodes(x)):
                break


# ===== 屏幕登记表（顺序执行，状态链式推进） =====
# (编号, 英文短名, 导航函数, 主关键词(OR), 附加关键词(OR, 与主构成 AND),
#  负向关键词(任一命中即错态), 截图后复位钩子(仅 16))
SCREENS: list[tuple[str, str, str, tuple[str, ...], tuple[str, ...],
                    tuple[str, ...], "callable | None"]] = [
    ("01", "home_page",        nav_01,        ("最近", "累计阅读", "统计"), (), (), None),
    ("02", "bottom_nav",       nav_02,        ("Tab 1 of 5", "首页"), (), (), None),
    ("03", "bookshelf",        nav_03,        ("斗罗大陆",), (), (), None),
    ("04", "bookshelf_overflow_menu", nav_04, ("选择模式", "书架管理", "分组管理"), (), (), None),
    ("05", "bookshelf_select_mode",   nav_05, ("全选", "删除", "取消"), (), (), None),
    ("06", "search",           nav_06,        ("搜索历史", "清空"), (), (), None),
    # 07 = 完成态（任务屏 07 文件名）；07b = 搜索中态（补拍，07b 前缀）
    ("07",  "search_results",           nav_07_done,      ("加载下一页",), (), (), None),
    ("07b", "search_results_loading",  nav_07_searching, ("进度", "停止搜索"), (), (), None),
    # 08 详情页：必须走搜索路径（书架卡点按是继续阅读语义，会进阅读器）。
    # 主特征取详情页独有元素（换源/加入书架/查看目录/继续阅读），
    # 负向排除阅读器特征（退出阅读顶栏、自动翻页控制条），防误存阅读态
    ("08", "book_info",        nav_08,
     ("换源", "加入书架", "查看目录", "继续阅读"), (),
     ("退出阅读", "自动翻页", "停止翻页"), None),
    # 09 目录页：「书签」页签 + 章节列表特征（目录页签/跳转顶部/引子）AND 断言，
    # 负向排除自动翻页运行态
    ("09", "toc",              nav_09,
     ("书签",), ("目录", "跳转顶部", "引子"),
     ("退出阅读", "自动翻页", "停止翻页"), None),
    ("10", "reader",           nav_10,        ("唐门", "斗罗大陆", "唐三"), (), (), None),
    ("11", "reader_menu",      nav_11,        ("全文搜索", "自动翻页", "退出阅读"), (), (), None),
    # 长按浮条（text_selection_panel.dart ReaderSelectionToolbar，uiautomator
    # content-desc 实证 6 按钮：复制/分享/浏览器/朗读/书签/更多）：
    # 主特征取浮条特有的 5 词（实测菜单态 dump 无这 5 词；「更多」与菜单重叠故剔除），
    # AND 条件为正文词（唐三/斗罗大陆；浮条态不显示页码，旧「章/1/8」必失败），
    # 双条件同中才判定浮条态在屏，防菜单+选中错态误存
    ("12", "reader_longpress", nav_12,
     LONGPRESS_TOOLBAR_KWS, LONGPRESS_READER_KWS, (), None),
    # 13 搜索内容页（全文搜索路由：标题「搜索正文」+ 搜索选项/搜索历史）；
    # 负向排除阅读器菜单/自动翻页特征（防误存发现页/订阅页/阅读器）
    ("13", "search_content",   nav_13,
     ("搜索正文", "搜索选项", "搜索历史"), (),
     ("退出阅读", "自动翻页", "停止翻页"), None),
    ("14", "bookmark_toc",     nav_14,        ("暂无书签", "书签", "标注"), (), (), None),
    ("15", "chapter_jump",     nav_15,        ("定位至当前阅读", "移至顶部", "一键缓存"), (), (), None),
    # 16 自动翻页：断言收起菜单后的底部控制条（自动翻页 + 秒/停止 组合特征，
    # 证明运行态）；负向排除发现/订阅瓦片（本系列曾误存订阅页）。
    # 截图后复位：停止自动翻页 + 退出阅读（设置持久化，不复位会泄漏到后续屏）
    ("16", "auto_flip",        nav_16,
     ("自动翻页",), ("秒", "停止"),
     ("半夏小说", "奈飞工厂", "小说拾遗", "Meow云", "规则订阅"), reset_after_16),
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

# ===== 批 2 登记表（发现与源管理，10 屏；key=<编号>_<短名> 即输出文件名） =====
# 元组结构与批 1 一致，但「编号」字段与批 1 数字同号（01/02/03/06-12），
# 靠 key=编号_短名 与 SCREEN_FILE 文件名区分（01_discover.png ≠ 01_home_page.png）。
# 断言关键词取自对应屏源码实证（见 docs/parity_shots 批 2 任务书与读码注释）。
SCREENS_B2: list[tuple[str, str, str, tuple[str, ...], tuple[str, ...],
                       tuple[str, ...], "callable | None"]] = [
    # 01 发现页：源名瓦片（批 1 16 屏负向词实证为发现/订阅瓦片名）AND 顶栏特征
    ("01", "discover",        nav_b2_01,
     ("半夏小说", "奈飞工厂", "小说拾遗", "Meow云"),
     ("发现", "筛选发现源"), (), None),
    # 02 发现页溢出菜单：⋮ 点开分组菜单（「全部」+ 分组名，数据相关），
    # 主特征用菜单常驻项「全部」（顶栏副标题未选分组时也是「全部」，
    # 故再 AND 「筛选发现源」证明仍在发现页顶栏语境）
    ("02", "discover_overflow", nav_b2_02,
     ("全部",), ("筛选发现源",), (), None),
    # 03 发现源展开区：点第一源卡后，源卡名仍在 + 展开区 chip/分节标题出现。
    # chip 文案随源数据（如「玄幻/排行榜」），故 AND 条件留空，
    # 仅凭「点开后源卡仍在发现页」+ 截图人工核对（错态会落在源卡收起/其他页，
    # 由 01/06 屏交叉兜底）
    ("03", "discover_expand",  nav_b2_03,
     ("半夏小说", "奈飞工厂", "小说拾遗", "Meow云"),
     ("发现",), (), None),
    # 06 分类书单页（explore_show）：顶栏 4 个独有 tooltip（筛选/切换密度/
    # 加入书架/页码「第 N 页」）为屏独有特征；AND 内容态（暂无书籍/加载失败/页码）
    ("06", "booklist",         nav_b2_06,
     ("加入书架", "切换为紧凑", "切换为舒适", "筛选"),
     ("第", "暂无书籍", "加载失败"), (), None),
    # 07 换源弹层（change_source 底部面板）：顶栏「重新搜索/搜索筛选」为弹层独有；
    # AND 书名/结果/空态文案（未找到可替换的书源 亦算，任务要求空态照拍）
    ("07", "source_switch",    nav_b2_07,
     ("重新搜索", "搜索筛选"),
     ("斗罗大陆", "找到", "未找到可替换的书源", "匹配书源"), (), None),
    # 08 书源管理（/sources）：顶栏搜索行可折叠（收起态无「搜索书源」hint，
    # 实测 2.0.264 常为收起态）→ 主词用顶栏常驻「更多选项」或展开态 hint；
    # AND 源行状态词（开启/已启用/启用发现）或空态（任务：列表与启用开关类）
    ("08", "source_manage",    nav_b2_08,
     ("更多选项", "搜索书源"),
     ("已启用", "启用发现", "暂无书源", "新建书源", "开启"), (), None),
    # 09 书源编辑器（SourceEditScreen）：必填字段「源 URL」「源名称」为屏独有
    ("09", "source_editor",    nav_b2_09,
     ("源 URL", "源名称"),
     ("启用", "保存", "分组"), (), None),
    # 10 替换净化编辑器（ReplaceRuleEditScreen）：「使用正则表达式」勾选行为
    # 编辑器独有（列表页规则副标题只含「正则:」，勿把「正则」当主词误命中列表页）
    ("10", "replace_rule_edit", nav_b2_10,
     ("使用正则表达式",),
     ("保存", "复制规则", "粘贴规则", "分组"), (), None),
    # 11 RSS 源二级页（rss_articles）：顶栏「刷新」钮为文章页独有（RSS 列表页
    # 无刷新钮，实测仅下拉手势）；「暂无文章/下拉刷新获取最新内容」为文章页
    # 空态文案。文章已加载时仅有卡片内容（动态），本组关键词不命中会 FAIL 跳过
    ("11", "rss_source",       nav_b2_11,
     ("暂无文章", "加载文章", "刷新"),
     ("刷新", "下拉刷新获取最新内容"), (), None),
    # 12 Web 服务开启态（我的/设置页「Web 服务」开关行）：
    # 开启时行下展开 URL + 「拷贝 URL/浏览器打开」按钮，关闭时副标题
    # 「用浏览器写源或看书」；AND 以上任一证明停在设置页且行可见
    ("12", "web_service",      nav_b2_12,
     ("Web 服务",),
     ("MCP 服务", "端口", "URL", "用浏览器写源或看书"), (), None),
]


def main() -> int:
    # global 声明必须在函数内首次使用 DEV/OUT_DIR/EXPECT_VERSION 之前，
    # 否则 SyntaxError: name used prior to global declaration
    global DEV, OUT_DIR, EXPECT_VERSION
    ap = argparse.ArgumentParser(
        description="我方 1:1 对比批量截图采集（批 1 16 屏 + 批 2 10 屏）")
    ap.add_argument("--device", default=DEFAULT_DEVICE,
                    help=f"adb 设备（默认 {DEFAULT_DEVICE}）")
    ap.add_argument("--only", default="",
                    help="只跑指定屏，逗号分隔：批 1 用编号（01,03,06，07 含 07/07b），"
                         "批 2 用全名（01_discover,08_source_manage），可混用")
    ap.add_argument("--expect-version", default="",
                    help="覆盖期望 versionName（默认动态读 pubspec.yaml）；"
                         "设备 APK 落后于 pubspec 版本号时用于固定版本校验，避免整体中止")
    ap.add_argument("--out", default="",
                    help="截图输出目录（默认 docs/parity_shots/ours_<期望版本>）")
    args = ap.parse_args()

    DEV = args.device
    if args.expect_version:
        EXPECT_VERSION = args.expect_version
        rec(f"版本校验固定为 {EXPECT_VERSION}（--expect-version 覆盖 pubspec 动态值）")
    OUT_DIR = (Path(args.out) if args.out
               else ROOT / "docs" / "parity_shots" / f"ours_{EXPECT_VERSION}")
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

    # 批 1/批 2 编号数字重叠（01/02/03/06-12），按 key 归属拆分：
    # 批 1 用纯数字编号（01..16/07b），批 2 用全名 key（01_discover 等）
    B1_NUMS = {s[0] for s in SCREENS}
    B2_KEYS = {f"{n}_{m}" for n, m, *_ in SCREENS_B2}
    want_b1 = {t for t in want if t in B1_NUMS}
    want_b2 = {t for t in want if t in B2_KEYS}

    rec(f"设备：{DEV}；adb：{ADB}")
    if not want:
        rec("目标：批 1 全 16 屏 + 批 2 全 10 屏")
    else:
        rec(f"目标：--only {','.join(sorted(want))}"
            f"（批 1：{','.join(sorted(want_b1)) or '无'}；"
            f"批 2：{','.join(sorted(want_b2)) or '无'}）")

    # 设备可达性
    r = sh("shell", "echo", "parity-ping")
    if "parity-ping" not in (r.stdout or "") + (r.stderr or ""):
        rec("设备不可达，整体中止（exit 1）")
        return 1

    # 版本校验
    ver = check_version()
    if ver != EXPECT_VERSION:
        rec(f"版本校验失败：versionName={ver or '未知'}（期望 {EXPECT_VERSION}），整体中止"
            f"；设备 APK 落后于 pubspec 时可加 --expect-version {ver or '?'} 重试")
        return 1
    rec(f"版本校验通过：{PKG} versionName={ver}")

    results: list[ScreenResult] = []
    # 注意：条件用 want（任意批被指定）而非 want_b1——只想跑批 2 时批 1 须全跳过
    for num, name, nav, kws, and_kws, neg_kws, post in SCREENS:
        if want and num not in want_b1:
            continue
        try:
            res = run_screen(num, name, nav, kws, SCREEN_FILE[num],
                             and_kws=and_kws, neg_kws=neg_kws, post=post)
        except Exception as e:  # 双保险：单屏任何异常都不中断
            res = ScreenResult(num, name, False, "/".join(kws),
                               SCREEN_FILE[num], f"未捕获异常：{type(e).__name__}: {e}")
            res.log()
        results.append(res)

    # 批 2（发现与源管理）：文件名 = key.png（01_discover.png 等），
    # 与批 1 同目录不同名，互不覆盖
    for num, name, nav, kws, and_kws, neg_kws, post in SCREENS_B2:
        key = f"{num}_{name}"
        if want and key not in want_b2:
            continue
        fname = f"{key}.png"
        try:
            res = run_screen(num, name, nav, kws, fname,
                             and_kws=and_kws, neg_kws=neg_kws, post=post)
        except Exception as e:
            res = ScreenResult(num, name, False, "/".join(kws),
                               fname, f"未捕获异常：{type(e).__name__}: {e}")
            res.log()
        results.append(res)
        # 注：每屏导航自带冷启动（_to_shelf/cold_start），会话态（选择模式等）天然隔离；
        # 但自动翻页是持久化设置，force-stop 后仍会运行，故 16 屏截图后
        # 经 post 钩子（reset_after_16）显式停止并退出阅读器，防止泄漏到后续屏/次次运行

    # 汇总
    ok = [r for r in results if r.ok]
    fail = [r for r in results if not r.ok]
    rec("=" * 60)
    rec(f"完成：{len(ok)}/{len(results)} 屏 OK")
    if fail:
        rec("失败/跳过清单：")
        for r in fail:
            rec(f"  - {r.num}_{r.name}：{r.reason}")
    if _LP12_BURST:
        rec("注：12 屏 3 探点 dump 均未命中浮条，已改连拍存 "
            "12_reader_longpress_t1/t2/t3.png（请目视确认浮条是否实际弹出）")
    rec(f"截图目录：{OUT_DIR}")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
