# -*- coding: utf-8 -*-
"""parity_capture_ours.py — 1:1 界面对比「我方」批量截图采集
（批 1 16 屏 + 批 2 10 屏 + 批 3 11 屏 + 批 4 长尾深页 4 屏）。

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
  python scripts/parity_capture_ours.py                      # 批 1 16 屏 + 批 2 10 屏 + 批 3 11 屏 + 批 4 4 屏
  python scripts/parity_capture_ours.py --only 01,03,06      # 批 1 屏编号（07 含 07b）
  python scripts/parity_capture_ours.py --only 01_discover,08_source_manage
                                                             # 批 2 屏全名 key（可与批 1 混用）
  python scripts/parity_capture_ours.py --only 01_mine,04_appearance
                                                             # 批 3 屏全名 key（可与批 1/2 混用）
  python scripts/parity_capture_ours.py --only 01_txt_toc_rule,02_dict_rule
                                                             # 批 4 屏全名 key（可与批 1/2/3 混用）
  python scripts/parity_capture_ours.py --device 127.0.0.1:16416
  python scripts/parity_capture_ours.py --out docs/parity_shots/ours_<version>
退出码：0 = 全部 OK；1 = 存在失败/跳过屏。
批 2（发现与源管理）屏 key：01_discover / 02_discover_overflow / 03_discover_expand /
06_booklist / 07_source_switch / 08_source_manage / 09_source_editor /
10_replace_rule_edit / 11_rss_source / 12_web_service（即输出文件名 <key>.png）。
批 3（我的与设置）屏 key：01_mine / 02_read_record / 03_settings / 04_appearance /
04_appearance_dark（深色态外观页，含像素断言与主题恢复）/ 05_theme /
06_backup / 07_font / 08_tts / 09_group_mgmt / 10_auto_task / 11_highlight
（即输出文件名 <key>.png）。

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
# 批 3（我的与设置）兜底坐标
MENU_ITEM_GROUPS = (786, 1008)      # 书架卡菜单「分组管理」第 5 卡中心（144x48dp 卡、88dp 起算，@3x 推算）
READER_TTS_BTN = (405, 1830)        # 阅读器底栏四钮（目录/朗读/界面/设置）第 2 钮兜底
READER_TTS_SETTINGS = (405, 1806)   # 朗读控制条底行四钮（目录/朗读设置/语速/转后台）第 2 钮兜底
# 设置主页第 1 卡「外观」中心兜底：SliverAppBar.large 112dp=336px + 上 padding
# 8dp=24px → 卡顶 360px，卡高约 134px（14dp 垂直 padding ×2 + 双行文本）→ 中心 ≈430
SETTINGS_APPEARANCE_FALLBACK = (540, 430)
# 我的页「设置」行兜底（第 2 组中段，@3x 经验值）
MINE_SETTINGS_ROW = (540, 1500)


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
def _tap_mine_tab() -> None:
    """点底部「我的」tab：dump 定位底栏（y>1600）内 text/desc 含「我的」的
    节点并点其中心，未命中回退 TAB_MINE 坐标。

    背景：底栏有 5 tab（首页/书架/发现/订阅/我的，我的 cx≈972）与
    4 tab（书架/发现/我的/订阅，我的 cx≈675）两种排布，固定坐标 TAB_MINE
    在 4 tab 布局下会误点「订阅」→ _to_mine 时好时坏。dump 定位对布局鲁棒。"""
    x = dump("tap_mine_tab")
    for t, d, b in nodes(x):
        s = (t or d).strip()
        if "我的" in s and b[1] > 1600:
            tap(*center_of(b))
            rec(f"  [b3] 底栏「我的」tab：dump 命中，点 {center_of(b)}")
            return
    tap(*TAB_MINE)
    rec(f"  [b3] 底栏「我的」tab：dump 未命中，回退坐标 {TAB_MINE}")


def _to_mine() -> None:
    """冷启动 → 底部「我的」tab（设置页：书源管理/替换净化/Web 服务/MCP 服务）。

    冷启会恢复上次路由（可能是 /sources 等二级页，无底栏 → 点 tab 坐标会
    落到内容行上）。主壳 PopScope(canPop=false)，BACK 对主壳无副作用，
    故先 BACK 弹回主壳再用 dump 定位点「我的」tab；仍不在则再 BACK + 重点，
    最多 3 轮。点 tab 后先上滑滚回列表顶再校验（在顶时上滑为无害空操作）。
    校验用「我的」页列表独有行「书源管理」（书架/首页/发现均无此词，
    顶态必可见）；3 轮均未落则 raise（防下游屏在错页上空滚/误点）。

    滚顶关键：KeepAlive 列表恢复在**底部**（书签/阅读记录/…/退出），列表高约
    3900px，仅 3 次上滑（900px/次）爬不到顶。改用 8 次手指下扫（500→1400，
    朝顶滚；顶边界空滚无害、不会像底部过扫那样 fling 切 tab）确保从任意位置
    到顶。"""
    cold_start()
    for i in range(3):
        keyevent("4")
        wait(1)
        _tap_mine_tab()
        wait(2)
        for _ in range(8):  # 列表滚到顶（KeepAlive 可能恢复在底部，需多次）
            swipe(W // 2, 500, W // 2, 1400, 350)
            wait(1)
        x = dump("to_mine")
        if has_kw(x, ("书源管理",)):
            return
        rec(f"  [b3] to_mine 第 {i + 1} 轮未落到「我的」页，BACK + 重点")
    raise RuntimeError("to_mine：3 轮未落到「我的」页（缺「书源管理」行）")


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


# ===== 批 3 导航函数（我的与设置；入口均经读码实证，路径以实际 dump 为准） =====
# 约定：列表行 dump 文本为「标题\n副标题」合并串（&#10; unesc 为 \n），
# 故按 text 首行【精确】匹配定位（防前缀误命中，如「定时任务」vs「运行定时任务」）；
# 我的页 _to_mine 滚顶后部分行（设置/书签/阅读记录/缓存管理 等第 2 组）在屏外，
# 需上滑（列表下滑）逐轮 dump 校验后再点。
def tap_first_line_row(first_line: str, label: str,
                       fallback_xy: tuple[int, int],
                       up_rounds: int = 0, down_rounds: int = 0) -> None:
    """按 text 首行精确匹配点列表行；未命中则滚动列表逐轮重试，最后兜底坐标。"""
    xy = None
    total = up_rounds + down_rounds
    for rnd in range(total + 1):
        for t, d, b in nodes(dump(label)):
            s = (t or d).strip()
            if s.split("\n")[0] == first_line:
                xy = center_of(b)
                break
        if xy or rnd == total:
            break
        if rnd < up_rounds:
            swipe(W // 2, 500, W // 2, 1400, 350)   # 列表滚到顶
        elif up_rounds == 0:
            swipe(W // 2, 1400, W // 2, 500, 350)   # 无滚顶轮：首轮起即下滑
        else:
            swipe(W // 2, 1400, W // 2, 500, 350)   # 滚顶轮后转下滑（露出下方行）
        wait(1)
    if xy is None:
        xy = fallback_xy
        rec(f"  [b3] {label}：dump 未命中，回退坐标 {xy}")
    tap(*xy)
    rec(f"  [b3] {label}：点 {xy}")


def _mine_row_xy(first_line: str, label: str,
                 up_rounds: int = 0, down_rounds: int = 0,
                 multi_line: bool = False) -> tuple[int, int] | None:
    """我的页列表行定位（不点击）：text 首行精确匹配，未命中则滚动逐轮重试。

    multi_line=True 时只匹配带副标题的多行节点（列表行「标题\\n副标题」），
    避开同名 section 头（如「设置」组头也是单行 text='设置'，点了无效）。
    滚动策略：先滚顶 up_rounds 轮归位，再逐轮下滑（每轮后 dump 校验），
    兼容 KeepAlive 列表任意初始位置（顶部/中段/底部）。"""
    for _ in range(up_rounds):
        swipe(W // 2, 500, W // 2, 1400, 350)   # 列表滚到顶
        wait(1)
    xy = None
    for rnd in range(down_rounds + 1):
        for t, d, b in nodes(dump(label)):
            s = (t or d).strip()
            if s.split("\n")[0] != first_line:
                continue
            if multi_line and "\n" not in s:
                continue   # 只认带副标题的行节点，跳过 section 头
            xy = center_of(b)
            break
        if xy or rnd == down_rounds:
            break
        swipe(W // 2, 1400, W // 2, 500, 350)   # 列表下滑（露出下方行）
        wait(1)
    if xy is None:
        rec(f"  [b3] {label}：dump 未命中")
    return xy


def _mine_top_sig(x: str) -> str:
    """我的页列表顶行签名（首个主列行 text 首行），用于判空滚（下滑后签名不变=空滚）。"""
    for t, d, b in nodes(x):
        s = (t or d).strip()
        if not s:
            continue
        if 400 <= (b[0] + b[2]) // 2 <= 700 and 300 < b[1] < 1680:
            return s.split("\n")[0]
    return ""


def _swipe_down_mine(label: str) -> bool:
    """我的页下滑并确保列表实际移动；空滚则换更强参数重试。
    返回 True=有前进，False=仍空滚（调用方应重新 _to_mine 复位）。"""
    before = _mine_top_sig(dump(label + "_pre"))
    # 递增强度：(末 y, 时长 ms)——距离越大/时长越短 fling 越强
    for y2, ms in ((500, 400), (400, 300), (300, 250)):
        swipe(W // 2, 1400, W // 2, y2, ms)
        wait(1)
        after = _mine_top_sig(dump(label + "_post"))
        if after != before:
            return True
    return False


def _settings_row_xy(max_rounds: int = 6) -> tuple[int, int] | None:
    """我的页「设置」行（带副标题多行节点）鲁棒定位。

    本模拟器 input swipe 非确定（偶发空滚 / fling 过冲切书架 tab），故不靠
    固定下滑轮数，改为逐轮「dump 判态 + 下滑 + 再判态」闭环，最多 max_rounds：
      - 命中「设置」多行节点 → 返回；
      - 切到书架（书架特征词）→ 重新 _to_mine 复位（回我的页顶态）；
      - 下滑空滚（顶行签名不变）→ 重新 _to_mine 复位（换干净顶态再来）。
    只认 multi_line（带副标题）节点，防误点同名单行组头 IosSectionHeader('设置')。"""
    shelf_mk = ("全部", "斗破苍穹", "斗罗大陆")
    for rnd in range(max_rounds):
        x = dump("settings_row_xy")
        xy = _mine_row_xy("设置", "我的页「设置」行",
                          up_rounds=0, down_rounds=0, multi_line=True)
        if xy:
            return xy
        if has_kw(x, shelf_mk):
            rec(f"  [b3] 设置行定位第 {rnd + 1} 轮：已切书架 tab，复位我的页")
            _to_mine()
            continue
        if not _swipe_down_mine(f"settings_row_{rnd}"):
            rec(f"  [b3] 设置行定位第 {rnd + 1} 轮：下滑空滚，复位我的页")
            _to_mine()
    rec("  [b3] 我的页「设置」行：多轮定位未命中")
    return None


def _to_settings_home() -> None:
    """我的页 → 第 2 组「设置」行 → 设置主页（SettingsHomeScreen，标题「设置」）。

    「设置」行在中段：_to_mine 滚顶后需恰好 1 次下滑才露出（第 2 次下滑滚出、
    第 4 次下滑切书架 tab），故 _settings_row_xy 限定最多 2 次下滑逐轮 dump。
    只匹配带副标题的多行节点，防误点同名单行组头 IosSectionHeader('设置')。"""
    _to_mine()
    xy = _settings_row_xy()
    if xy is None:
        # 盲点兜底易误触「退出」行（弹「确定退出阅读吗」），按任务要求记 FAIL 留主代理
        raise RuntimeError("我的页「设置」行 dump 未命中（顶态 + 2 次下滑均未定位）")
    tap(*xy)
    rec(f"  [b3] 我的页「设置」行：点 {xy}")
    wait(4)
    # 校验确已进设置主页（9 卡首页含「外观」）；未落则区分两种错态重试：
    #  a) 仍停我的页（点中不可点的组头/误点）→ 直接重定位重点，不 BACK（根 tab BACK 会退后台）
    #  b) 误落二级页（或切到书架等）→ 重新 _to_settings_home 前置（_to_mine 会 BACK 回主壳）
    chk = dump("settings_home_check")
    if not has_kw(chk, ("外观", "备份与恢复", "字体管理")):
        # 仅认「我的」页列表独有行（书源管理/替换净化/高亮标注/MCP 服务），
        # 不用「首页」（底栏 tab 名，各主 tab 均有，过滚切到书架时会误判）
        still_mine = has_kw(chk, ("书源管理", "替换净化", "高亮标注", "MCP 服务"))
        rec(f"  [b3] 点「设置」后未落设置主页（still_mine={bool(still_mine)}），重试")
        if still_mine:
            # 仍停我的页（疑点中组头或行被滚出）→ 重新定位重点
            xy2 = _settings_row_xy()
        else:
            # 误落他页（含被过滚切到书架）→ 重新回我的页并滚顶
            _to_mine()
            xy2 = _settings_row_xy()
        if xy2 is None:
            raise RuntimeError("我的页「设置」行重试仍未命中")
        tap(*xy2)
        rec(f"  [b3] 我的页「设置」行（重试）：点 {xy2}")
        wait(4)


def _to_theme_page() -> None:
    """设置主页 → 「外观」行 → 主题设置页（ThemeConfigScreen，即「外观」页，
    顶部预览卡 + 内置 12 色卡网格 + 主题引擎/通用/顶栏与布局）。

    每轮先 dump 判态：已在主题页（主题设置/内置主题/主题引擎/AMOLED 纯黑）
    直接返回；在设置主页（备份与恢复/字体管理/缓存管理 卡）则定位点「外观」
    卡；落他处（如误点「高级」）则 BACK 后重新进设置主页，最多 3 轮。
    设主「外观」是第 1 卡（顶栏下方首卡），常显，无需滚动。"""
    theme_mk = ("主题设置", "内置主题", "主题引擎", "AMOLED 纯黑")
    home_mk = ("备份与恢复", "字体管理", "缓存管理", "书源管理")
    _to_settings_home()
    for attempt in range(3):
        x = dump("04_appearance")
        if has_kw(x, theme_mk):
            rec(f"  [b3] 04 已在主题页（第 {attempt + 1} 轮）")
            return
        if has_kw(x, home_mk):
            xy = None
            for t, d, b in nodes(x):
                s = (t or d).strip()
                if s.split("\n")[0] == "外观":
                    xy = center_of(b)
                    break
            if xy is None:
                xy = SETTINGS_APPEARANCE_FALLBACK
                rec(f"  [b3] 设置主页「外观」卡：dump 未命中，回退坐标 {xy}")
            tap(*xy)
            rec(f"  [b3] 设置主页「外观」卡：点 {xy}")
            wait(4)
            if has_kw(dump("04_appearance_after"), theme_mk):
                return
            rec(f"  [b3] 04 点「外观」后未落主题页（第 {attempt + 1} 轮），BACK 重试")
            keyevent("4")   # 误落相邻二级页：BACK 回设置主页
            wait(1)
            continue
        # 落他处：BACK 一层后重新走设置主页链路
        rec(f"  [b3] 04 未落设主/主题页（第 {attempt + 1} 轮），BACK 重进设置主页")
        keyevent("4")
        wait(1)
        _to_settings_home()
    rec("  [b3] 04 三轮未落主题页，回退坐标强点")
    _to_settings_home()
    tap(*SETTINGS_APPEARANCE_FALLBACK)
    wait(4)


# ===== 04_appearance_dark 深色态采集（批 3 配色比对前置，2.0.266 实测探针） =====
# 实测结论（192.168.1.19:5555 / 2.0.266）：
#   - 主题模式行在我的页（settings_screen），content-desc 为三行合并串
#     「主题模式\n选择主题模式\n<浅色|深色|跟随系统>」；点行开底部弹层
#     （选择主题模式 头 + 跟随系统/浅色/深色 3 个 ListTile，y≥1392），
#     选中即全局实时生效并持久化（ThemeNotifier.setThemeMode）。
#   - 外观页（theme_config_screen「主题设置」）本身**无**主题模式控件，
#     其 dump 关键词为 主题设置/内置主题/主题引擎（任务断言词「主题模式」
#     保留在关键词组内：命中即通过，未命中时以页面真实特征词兜底）。
#   - 深色态外观页灰度均值实测 52.3（阈值 <90 判暗）；恢复「跟随系统」后
#     主题模式行 value 回到「跟随系统」。
DARK_MEAN_THRESHOLD = 90          # 像素断言：灰度均值 < 90 才算暗色
SHEET_OPTION_Y_MIN = 1000        # 主题模式底部弹层 tile 纵带（实测 y≥1116 起）
SHEET_DARK_FALLBACK = (540, 1812)      # 弹层「深色」tile 实测中心
SHEET_SYSTEM_FALLBACK = (540, 1476)    # 弹层「跟随系统」tile 实测中心
APPEARANCE_CARD_FALLBACK = (540, 651)  # 设置主页「外观」卡实测中心（2.0.266）


def _mine_row_down_xy(first_line: str, label: str, max_rounds: int = 5,
                      fallback_xy: tuple[int, int] | None = None) -> tuple[int, int]:
    """我的页 top 态起，≤max_rounds 次下滑找 text 首行精确匹配的多行行节点。

    专为 04_appearance_dark 的「主题模式/设置」行设计（top 态屏外，需上滑
    ≤5 次露出；任务约束①）：每轮 dump 校验，命中即返回中心；未命中时按
    顶/底标志位决定下滑还是回滚（防过滚后继续下滑永远找不着）。"""
    past_mk = ("阅读记录", "书签", "退出")  # 过滚标志（已滚到「其他」组）
    for rnd in range(max_rounds + 1):
        xy = _mine_row_xy(first_line, label, up_rounds=0, down_rounds=0,
                          multi_line=True)
        if xy:
            return xy
        if rnd == max_rounds:
            break
        x = dump(label + f"_r{rnd}")
        if has_kw(x, past_mk):
            swipe(W // 2, 500, W // 2, 1400, 350)   # 过滚 → 回滚
            rec(f"  [b3-d] {label}：第 {rnd + 1} 轮过滚（见 {past_mk}），回滚")
        else:
            swipe(W // 2, 1400, W // 2, 500, 350)   # top/中段 → 下滑露出下方行
        wait(1)
    if fallback_xy is not None:
        rec(f"  [b3-d] {label}：{max_rounds} 次下滑未命中，回退坐标 {fallback_xy}")
        return fallback_xy
    raise RuntimeError(f"{label}：{max_rounds} 次下滑未命中（顶/底标志位闭环失效）")


def _tap_sheet_option(label: str, fallback_xy: tuple[int, int]) -> None:
    """主题模式底部弹层内点指定选项 tile（跟随系统/浅色/深色）。

    弹层 tile 纵带实测 y≥1392（SHEET_OPTION_Y_MIN=1000 之上为 Scrim/背景），
    只认纵带内 text/desc 恰为 label 的节点，防背景行 value 标签同名误命中；
    未命中回退实测坐标。"""
    x = dump(f"sheet_{label}")
    cands = []
    for t, d, b in nodes(x):
        s = (t or d).strip()
        if s == label and b[1] >= SHEET_OPTION_Y_MIN:
            cands.append(((b[1], b[0]), center_of(b)))
    if cands:
        cands.sort()
        _fb, xy = cands[0]
        tap(*xy)
        rec(f"  [b3-d] 弹层「{label}」：dump 命中，点 {xy}")
        return
    tap(*fallback_xy)
    rec(f"  [b3-d] 弹层「{label}」：dump 未命中，回退坐标 {fallback_xy}")


def _gray_mean(data: bytes) -> float:
    """PIL 灰度均值（0~255）。Pillow 缺失时 raise（任务要求 PIL 读图）。"""
    import io
    from PIL import Image, ImageStat
    st = ImageStat.Stat(Image.open(io.BytesIO(data)).convert("L"))
    return float(st.mean[0])


def _screenshot_bytes() -> bytes:
    """exec-out screencap 内存直取（像素断言不落盘）；失败退化为 pull 读回。"""
    r = sh("exec-out", "screencap", "-p", binary=True)
    data = r.stdout or b""
    if data and len(data) >= 10_000:
        return data
    shell("screencap", "-p", "/sdcard/.parity_shot.png")
    TMP_SHOT = Path(os.environ.get("TEMP", "/tmp")) / f"parity_shot_{os.getpid()}.png"
    sh("pull", "/sdcard/.parity_shot.png", str(TMP_SHOT))
    if not TMP_SHOT.exists():
        raise RuntimeError("截图失败（exec-out 与 pull 均失败）")
    return TMP_SHOT.read_bytes()


def _theme_row_values(x: str) -> list[str]:
    """取 dump 中「主题模式」行节点末行（value：浅色/深色/跟随系统）。"""
    return [s.split("\n")[-1] for s in
            ((t or d).strip() for t, d, _b in nodes(x))
            if s and s.split("\n")[0] == "主题模式"]


def _switch_theme_dark() -> None:
    """我的页 → 主题模式行（≤5 轮）→ 底部弹层点「深色」→ 校验行 value 已切。

    冷启动由调用方保证（_to_mine 已含 force-stop + 滚顶校验「书源管理」）。
    点「深色」后校验失败（行 value 未变「深色」）时：打印当前 dump 文本
    节点（任务约束②）→ 先恢复「跟随系统」（主题可能已实际切深）再 raise，
    绝不把应用留在深色态（任务约束④），绝不带病截图。"""
    xy = _mine_row_down_xy("主题模式", "我的页「主题模式」行", max_rounds=5)
    tap(*xy)
    rec(f"  [b3-d] 我的页「主题模式」行：点 {xy}（开底部弹层）")
    wait(2)
    _tap_sheet_option("深色", SHEET_DARK_FALLBACK)
    wait(1.5)   # 任务指定 sleep 1.5：主题全局实时生效 + 弹层收起
    x = dump("after_dark")
    vals = _theme_row_values(x)
    if "深色" not in vals:
        rec(f"  [b3-d] 点「深色」后主题模式行 value 未变深色（当前={vals}），"
            f"前 5 个文本节点：{_debug_nodes(x)}")
        _restore_theme_system()
        raise RuntimeError("切深色失败：主题模式行 value 未变「深色」（已恢复跟随系统）")
    rec(f"  [b3-d] 主题模式行 value 已切「深色」")


def _restore_theme_system() -> None:
    """恢复「跟随系统」：BACK 回我的页 → 主题模式行（≤5 轮）→ 弹层点「跟随系统」。

    必须在深色截图后执行（任务约束④：不得让应用停在深色态）。弹层未收起
    时先点 Scrim 区（y=150，实测弹层顶 1116 之上无交互节点）收起。BACK 对
    主壳无副作用（_to_mine 已验证）。恢复后校验行 value == 「跟随系统」，
    未恢复则 raise（由 run_screen 捕获记 FAIL，主代理可见）。幂等：
    已是「跟随系统」时直接返回（供异常路径反复调用）。"""
    if "跟随系统" in _theme_row_values(dump("restore_chk")):
        rec("  [b3-d] 恢复校验：主题模式行已是「跟随系统」（幂等跳过）")
        return
    x = dump("restore_state")
    if has_kw(x, ("选择主题模式",)):        # 弹层还开着：先收起再走全链路
        tap(540, 150)
        wait(1)
    keyevent("4")
    wait(1)
    keyevent("4")
    wait(1)
    if not has_kw(dump("restore_chk2"), ("主题模式", "书源管理", "MCP 服务")):
        keyevent("4")                        # 仍非我的页（如设置主页）：再 BACK
        wait(1)
    xy = _mine_row_down_xy("主题模式", "恢复「主题模式」行", max_rounds=5)
    tap(*xy)
    rec(f"  [b3-d] 恢复：主题模式行点 {xy}（重开底部弹层）")
    wait(2)
    _tap_sheet_option("跟随系统", SHEET_SYSTEM_FALLBACK)
    wait(1.5)
    x = dump("after_restore")
    vals = _theme_row_values(x)
    if "跟随系统" not in vals:
        rec(f"  [b3-d] 恢复未生效（当前={vals}），force-stop + 冷启后重试一次")
        cold_start()
        _to_mine()
        _restore_theme_system()
        return
    rec("  [b3-d] 已恢复「跟随系统」（主题模式行 value 校验通过）")


def _assert_appearance_page(tag: str) -> str:
    """外观页断言（任务指定：dump 含「主题模式」；该词实际只在我的页，
    故以 OR 关键词组兜底——任务词 + 外观页真实特征词，命中其一即通过）。"""
    kws = ("主题模式", "主题设置", "内置主题", "主题引擎")
    x = dump(tag)
    if has_kw(x, kws):
        return x
    wait(2)
    x = dump(tag + "_retry")
    if has_kw(x, kws):
        return x
    rec(f"  [b3-d] 外观页断言未命中 {kws}，前 5 个文本节点：{_debug_nodes(x)}")
    raise RuntimeError(f"外观页断言失败：dump 未命中 {kws}")


def nav_b3_04d() -> None:
    """04_appearance_dark 深色态外观页（批 3 配色比对前置）。

    流程（任务指定；实机探针 2.0.266 修正了控件位置——「深色」切换实际在
    我的页主题模式底部弹层，外观页本身无主题模式控件，故先切深色再进
    外观页）：
      冷启动 → 我的 tab（_to_mine 滚顶）→ 主题模式行（≤5 次下滑）→
      弹层点「深色」→ sleep 1.5 → 我的页找「设置」行（首行匹配、只认
      多行节点，勿全行锚定；≤5 次下滑）→ 设置主页点「外观」卡 →
      外观页断言（dump 含「主题模式」或页面特征词）。
    断言通过后应用**留在深色外观页**：run_screen 随后标准截图落盘
    04_appearance_dark.png，post 钩子 _post_04d 做像素断言（PIL 灰度
    均值 <90 才算暗色，否则删图不落盘记 FAIL）并恢复「跟随系统」。
    nav 自身异常（切深色后中途失败）先恢复再抛出（任务约束④：不得
    让应用停在深色态）；run_screen 断言/截图失败不经 nav，由主流程
    汇报后人工兜底恢复。"""
    _to_mine()
    _switch_theme_dark()
    try:
        # 我的页（当前滚动位）→ 「设置」行（首行匹配多行节点，≤5 次下滑）
        xy = _mine_row_down_xy("设置", "我的页「设置」行", max_rounds=5)
        tap(*xy)
        rec(f"  [b3-d] 我的页「设置」行：点 {xy}")
        wait(4)
        # 设置主页 → 「外观」卡（dump 首行匹配，未命中回退 2.0.266 实测坐标）
        x = dump("04d_appearance_card")
        xy = None
        for t, d, b in nodes(x):
            s = (t or d).strip()
            if s.split("\n")[0] == "外观":
                xy = center_of(b)
                break
        if xy is None:
            xy = APPEARANCE_CARD_FALLBACK
            rec(f"  [b3-d] 设置主页「外观」卡：dump 未命中，回退坐标 {xy}")
        tap(*xy)
        rec(f"  [b3-d] 设置主页「外观」卡：点 {xy}")
        wait(4)
        _assert_appearance_page("04d_appearance")
    except Exception:
        # 切深色后中途失败：先恢复跟随系统再抛出（约束④）
        _restore_theme_system()
        raise


def _post_04d() -> None:
    """04_appearance_dark 截图后钩子：像素断言（未暗删图不落盘）→ 恢复跟随系统。

    run_screen 已把深色态截图落盘为 04_appearance_dark.png（此刻应用仍在
    深色外观页）；读回落盘文件算 PIL 灰度均值：
      - <90：判暗色，保留图 → 执行恢复「跟随系统」（约束④）；
      - ≥90：深色未生效/点错 → 删除落盘文件（不落盘）+ 打印当前 dump
        文本节点（约束②定位用）→ 执行恢复 → raise 记 FAIL。
    恢复无论断言结果如何都执行（约束④：不得让应用停在深色态）。"""
    p = OUT_DIR / "04_appearance_dark.png"
    mean = _gray_mean(p.read_bytes())
    rec(f"  [b3-d] 像素断言：灰度均值 {mean:.1f}（阈值 <{DARK_MEAN_THRESHOLD}）")
    if mean >= DARK_MEAN_THRESHOLD:
        p.unlink()
        rec(f"  [b3-d] 未达暗色（均值 {mean:.1f} ≥ {DARK_MEAN_THRESHOLD}）："
            f"已删除 {p.name} 不落盘；当前 dump 前 5 个文本节点："
            f"{_debug_nodes(dump('04d_dark_fail'))}")
        _restore_theme_system()
        raise RuntimeError(
            f"像素断言失败：灰度均值 {mean:.1f} ≥ {DARK_MEAN_THRESHOLD}，"
            f"深色未生效（已删图不落盘，已恢复跟随系统）")
    _restore_theme_system()


def nav_b3_01() -> None:
    """01_mine 我的页：冷启动 → 底部「我的」tab（设置列表，顶部管理入口组）。"""
    _to_mine()


def nav_b3_02() -> None:
    """02_read_record 阅读记录：我的页 → 「阅读记录」行（「其他」组，底部区，
    需滚顶归位后下滑露出）→ ReadRecordScreen。未命中记 FAIL（防误触「退出」）。"""
    _to_mine()
    xy = _mine_row_xy("阅读记录", "我的页「阅读记录」行",
                      up_rounds=3, down_rounds=5, multi_line=True)
    if xy is None:
        raise RuntimeError("我的页「阅读记录」行 dump 未命中")
    tap(*xy)
    rec(f"  [b3] 我的页「阅读记录」行：点 {xy}")
    wait(4)


def nav_b3_03() -> None:
    """03_settings 设置主页：我的页 → 「设置」行（外观/高级/阅读界面/备份与恢复/…）。"""
    _to_settings_home()


def nav_b3_04() -> None:
    """04_appearance 设置·外观：设置主页 → 「外观」→ 主题设置页顶部
    （预览卡 + 内置主题 12 色卡 + 主题引擎）。"""
    _to_theme_page()


def nav_b3_05() -> None:
    """05_theme 主题设置 12 色卡：同 04 页（外观即主题设置，色卡网格在页内
    「内置主题」节）→ 下滑使 12 张色卡（纯白/森绿/柠檬…）完整入镜；
    不点色卡（选中会改持久化主题，污染后续屏），只滚动定位。"""
    _to_theme_page()
    swipe(W // 2, 900, W // 2, 480, 350)
    wait(2)


def nav_b3_06() -> None:
    """06_backup 备份与恢复：设置主页 → 「备份与恢复」行 → WebDavSettingsScreen。"""
    _to_settings_home()
    tap_first_line_row("备份与恢复", "设置主页「备份与恢复」行", (540, 880))
    wait(4)


def nav_b3_07() -> None:
    """07_font 字体（Tt 入口）：设置主页 → 「字体管理」行（第 8 卡，在 9 卡
    滚动列表底部区，需下滑露出）→ FontScreen（我方 Tt 字体入口页；等价于
    阅读器设置面板 Tt 卡「选择字体」整页链路）。"""
    _to_settings_home()
    tap_first_line_row("字体管理", "设置主页「字体管理」行", (540, 1120),
                       down_rounds=3)
    wait(4)


def nav_b3_08() -> None:
    """08_tts 朗读（引擎页）：干净进阅读器 → 底栏「朗读」钮启动朗读 →
    朗读控制条 → 条内「朗读设置」→ ReadAloudConfigScreen（标题「朗读引擎」，
    添加引擎/引擎列表）。未配置 TTS 引擎时控制条可能不出现 → 断言失败
    记 FAIL 留主代理，不卡死。"""
    _to_reader()
    _ensure_auto_flip_off()
    x = dump("08_tts")
    xy = None
    for t, d, b in nodes(x):
        if (t or d).strip() == "朗读" and b[1] > 1600:  # 底栏区朗读钮
            xy = center_of(b)
            break
    if xy is None:
        xy = READER_TTS_BTN
        rec(f"  [b3] 08 底栏「朗读」钮：dump 未命中，回退坐标 {xy}")
    tap(*xy)
    rec(f"  [b3] 08 底栏「朗读」钮：点 {xy}")
    if not _poll(("朗读设置", "语速", "转后台"), 20):
        raise RuntimeError("朗读控制条 20s 未出现（疑似无 TTS 引擎或朗读未启动）")
    x = dump("08_tts_settings")
    xy = None
    for t, d, b in nodes(x):
        if (t or d).strip() == "朗读设置":
            xy = center_of(b)
            break
    if xy is None:
        xy = READER_TTS_SETTINGS
        rec(f"  [b3] 08 条内「朗读设置」：dump 未命中，回退坐标 {xy}")
    tap(*xy)
    rec(f"  [b3] 08 条内「朗读设置」：点 {xy}")
    wait(4)


def nav_b3_09() -> None:
    """09_group_mgmt 分组管理：书架顶栏 ⋮ 卡菜单 → 「分组管理」项。"""
    _to_shelf()
    locate_or_fallback(r"更多|菜单|menu|overflow", BTN_SHELF_MENU, "书架顶栏 ⋮")
    wait(2)
    x = dump("09_group_mgmt")
    xy = None
    for t, d, b in nodes(x):
        if (t or d).strip() == "分组管理":
            xy = center_of(b)
            break
    if xy is None:
        xy = MENU_ITEM_GROUPS
        rec(f"  [b3] 09 卡菜单「分组管理」：dump 未命中，回退坐标 {xy}")
    tap(*xy)
    rec(f"  [b3] 09 卡菜单「分组管理」：点 {xy}")
    wait(4)


def nav_b3_10() -> None:
    """10_auto_task 定时任务：我的页 → 「定时任务」行（顶部组第 2 行，滚顶可见；
    首行精确匹配防误点开关行「运行定时任务」，multi_line 防误点组头）。"""
    _to_mine()
    xy = _mine_row_xy("定时任务", "我的页「定时任务」行",
                      up_rounds=3, down_rounds=1, multi_line=True)
    if xy is None:
        raise RuntimeError("我的页「定时任务」行 dump 未命中")
    tap(*xy)
    rec(f"  [b3] 我的页「定时任务」行：点 {xy}")
    wait(4)


def nav_b3_11() -> None:
    """11_highlight 高亮标注：我的页 → 「高亮标注」行（顶部组第 8 行，
    滚顶后下滑露出）→ HighlightRulesScreen（标题「高亮规则」）。"""
    _to_mine()
    xy = _mine_row_xy("高亮标注", "我的页「高亮标注」行",
                      up_rounds=3, down_rounds=2, multi_line=True)
    if xy is None:
        raise RuntimeError("我的页「高亮标注」行 dump 未命中")
    tap(*xy)
    rec(f"  [b3] 我的页「高亮标注」行：点 {xy}")
    wait(4)


# ===== 批 4 导航函数（长尾深页，入口全在我的页；沿用批 3 的
# _to_mine / _mine_row_xy / _swipe_down_mine 机制） =====
# [2.0.270 批 4 用户裁决] 05_home_module（首页模块管理）暂不实施：两侧均不采，
# 仅在此注释登记（不进 SCREENS_B4，不会被执行）。


def _mine_deep_row_xy(first_line: str, label: str,
                      max_rounds: int = 6,
                      multi_line: bool = False) -> tuple[int, int] | None:
    """我的页深行（「其他」组下段：文件管理/关于等）鲁棒定位（不点击）。

    模拟器 input swipe 非确定（偶发空滚 / fling 过冲切书架 tab），沿用
    _settings_row_xy 的「dump 判态 + 下滑 + 再判态」闭环（批 1-3 逻辑不动，
    批 4 深行自配一份）：
      - 首行精确匹配（multi_line 只认带副标题行）命中 → 返回；
      - 切到书架（书架特征词）→ 重新 _to_mine 复位（回我的页顶态）；
      - 下滑空滚（顶行签名不变）→ 重新 _to_mine 复位。"""
    shelf_mk = ("全部", "斗破苍穹", "斗罗大陆")
    for rnd in range(max_rounds):
        x = dump(f"b4_deep_row_{rnd}")
        xy = _mine_row_xy(first_line, label,
                          up_rounds=0, down_rounds=0, multi_line=multi_line)
        if xy:
            return xy
        if has_kw(x, shelf_mk):
            rec(f"  [b4] {label} 第 {rnd + 1} 轮：已切书架 tab，复位我的页")
            _to_mine()
            continue
        if not _swipe_down_mine(f"b4_deep_{rnd}"):
            rec(f"  [b4] {label} 第 {rnd + 1} 轮：下滑空滚，复位我的页")
            _to_mine()
    rec(f"  [b4] {label}：多轮定位未命中")
    return None


def nav_b4_01() -> None:
    """01_txt_toc_rule TXT 目录规则：我的页 → 「TXT 目录规则」行（顶部组第 4 行，
    滚顶后可见）→ TxtTocRulesScreen（标题「TXT 目录规则」，空态「暂无目录规则」，
    工具条「导入默认/添加规则」）。multi_line 防误点单行组头。"""
    _to_mine()
    xy = _mine_row_xy("TXT 目录规则", "我的页「TXT 目录规则」行",
                      up_rounds=3, down_rounds=1, multi_line=True)
    if xy is None:
        raise RuntimeError("我的页「TXT 目录规则」行 dump 未命中")
    tap(*xy)
    rec(f"  [b4] 我的页「TXT 目录规则」行：点 {xy}")
    wait(4)


def nav_b4_02() -> None:
    """02_dict_rule 字典规则：我的页 → 「字典规则」行（顶部组第 6 行，滚顶后
    可见）→ DictScreen（字典查询页，标题「字典查询」）。下方「规则管理」行
    副标题也含「字典规则」且去的是字典规则管理页，首行精确匹配防误点。"""
    _to_mine()
    xy = _mine_row_xy("字典规则", "我的页「字典规则」行",
                      up_rounds=3, down_rounds=1, multi_line=True)
    if xy is None:
        raise RuntimeError("我的页「字典规则」行 dump 未命中")
    tap(*xy)
    rec(f"  [b4] 我的页「字典规则」行：点 {xy}")
    wait(4)


def nav_b4_03() -> None:
    """03_file_manage 文件管理：我的页 → 「文件管理」行（「其他」组下段，
    滚顶后需多次下滑）→ FileManageScreen（顶栏筛选框 hint「筛选 · 文件管理」
    + root 面包屑）。深行走 _mine_deep_row_xy（空滚/切书架自动复位）。"""
    _to_mine()
    xy = _mine_deep_row_xy("文件管理", "我的页「文件管理」行",
                           max_rounds=6, multi_line=True)
    if xy is None:
        raise RuntimeError("我的页「文件管理」行 dump 未命中（深行多轮定位失败）")
    tap(*xy)
    rec(f"  [b4] 我的页「文件管理」行：点 {xy}")
    wait(4)


def nav_b4_04() -> None:
    """04_about 关于页：我的页 → 「关于」行（「其他」组末行、「退出」之前，
    单行节点无副标题）→ AboutScreen（标题「关于」，「更新日志」行副标题含
    「版本 <v>」）。深行走 _mine_deep_row_xy；未命中 raise 记 FAIL（盲点
    兜底易误触「退出」行，按任务要求不落盘）。"""
    _to_mine()
    xy = _mine_deep_row_xy("关于", "我的页「关于」行", max_rounds=6)
    if xy is None:
        raise RuntimeError("我的页「关于」行 dump 未命中（深行多轮定位失败）")
    tap(*xy)
    rec(f"  [b4] 我的页「关于」行：点 {xy}")
    wait(4)


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
     ("发现", "Dismiss menu"), (), None),
    # 02 发现页溢出菜单：⋮ 点开分组菜单（「全部」+ 分组名，数据相关），
    # 主特征用菜单常驻项「全部」（顶栏副标题未选分组时也是「全部」，
    # 故再 AND 「筛选发现源」证明仍在发现页顶栏语境）
    ("02", "discover_overflow", nav_b2_02,
     ("全部",), ("Dismiss menu",), (), None),
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

# ===== 批 3 登记表（我的与设置，11 屏；key=<编号>_<短名> 即输出文件名） =====
# 断言关键词取自各屏源码实证（settings_screen/settings_home_screen/theme_config/
# read_record/auto_task/book_group/font/read_aloud_config/highlight_rules/
# webdav_settings/书架卡菜单），遵循批 2 教训：主特征取屏独有元素。
SCREENS_B3: list[tuple[str, str, str, tuple[str, ...], tuple[str, ...],
                       tuple[str, ...], "callable | None"]] = [
    # 01 我的页（settings_screen，AppStrings.my「我的」tab）：Web 服务卡 /
    # MCP 服务行 / 高亮标注 / 主题模式 / 书源管理 行均为本页独有（设置主页
    # 与二级页无这些行）。不设 AND：KeepAlive 列表滚动位置不定，顶部组行
    # （书源管理/定时任务）可能滚出屏外，主特征命中即判本页
    ("01", "mine",             nav_b3_01,
     ("Web 服务", "MCP 服务", "高亮标注", "主题模式", "书源管理"),
     (),
     ("选择模式", "退出阅读"), None),
    # 02 阅读记录（read_record_screen）：有记录态首行「阅读热力图」为屏独有
    # （展开卡「近一年每日阅读情况」），空态「暂无阅读记录」；AND 负向
    # 排除仍在我的页（书源管理行可见）
    ("02", "read_record",      nav_b3_02,
     ("阅读热力图", "暂无阅读记录", "未找到匹配的记录", "斗罗大陆"),
     (),
     ("书源管理", "替换净化"), None),
    # 03 设置主页（settings_home_screen，标题「设置」）：9 卡滚动列表，顶态
    # 可见前 5 卡（外观/高级/阅读界面/备份与恢复/缓存管理）。断言只用顶态
    # 可见且本页独有的词（我的页无「外观/高级/阅读界面/备份与恢复」行，
    # 但「书源管理/定时任务/缓存管理」行与我的页重名，不可作特征）；
    # 字体管理/关于 在第 8/9 卡（顶态屏外），不作 AND。负向取我的页顶组
    # 独有行「主题模式/MCP 服务」（设主无此二行）
    ("03", "settings",         nav_b3_03,
     ("外观", "高级", "阅读界面", "备份与恢复"),
     ("备份与恢复",),
     ("主题模式", "MCP 服务"), None),
    # 04 设置·外观（theme_config_screen「主题设置」页顶部）：内置 12 色卡
    # 网格 + 「主题引擎/AMOLED 纯黑/配色风格」节为屏独有；AND 「主题」
    # 字样（顶栏标题「主题设置」）
    # [2.0.268 用户裁决] 配色轮卡已移除 → 「配色轮」入负向（命中即判错态，
    # 防回归）；[2.0.269 用户裁决] 外观预览卡已移除 → 「外观预览」入负向
    # （命中即判错态，防回归），AND 加「导出主题」（导出/导入区为列表首项，
    # 顶态恒在屏）；任务指定正向词「主题模式」实际在我的页（与 04d 同理，
    # 外观页本体无该控件），入 OR 主特征词组兜底——任务词 + 外观页真实
    # 特征词命中其一即通过
    ("04", "appearance",       nav_b3_04,
     ("主题模式", "内置主题", "主题引擎", "AMOLED 纯黑", "配色风格"),
     ("主题", "导出主题"),
     ("退出阅读", "自动翻页", "配色轮", "外观预览"), None),
    # 04d 深色态外观页（批 3 配色比对前置）：先在我的页主题模式弹层切
    # 「深色」再进外观页，nav 断言通过后停留在深色外观页；run_screen 标准
    # 截图后由 post 钩子 _post_04d 做像素断言（PIL 灰度均值 <90 判暗，
    # 否则删图不落盘）并恢复「跟随系统」（nav 自身异常也会先恢复）。
    # 断言 OR 词组含任务指定词「主题模式」+ 外观页真实特征词（深色态外观页
    # dump 命中「主题设置/内置主题」；「主题模式」兜底误落我的页时命中）；
    # AND 「主题」字样外观页顶栏恒含
    ("04", "appearance_dark",  nav_b3_04d,
     ("主题模式", "主题设置", "内置主题", "主题引擎"),
     ("主题",),
     ("退出阅读", "自动翻页"), _post_04d),
    # 05 主题设置 12 色卡（同 04 页，下滑至色卡网格入镜）：色卡中文名
    # （md3_colors 12 套 label：纯白/森绿/柠檬/小春/优香/菲比/穹/八月/
    # 卡洛塔/姆吉卡/墨水/透明）任一命中即判色卡在屏；AND 「内置主题」节头
    ("05", "theme",            nav_b3_05,
     ("纯白", "森绿", "柠檬", "小春", "优香", "菲比", "穹", "八月",
      "卡洛塔", "姆吉卡", "墨水", "透明"),
     ("内置主题", "主题"),
     ("退出阅读",), None),
    # 06 备份与恢复（webdav_settings_screen，标题「备份与恢复」）：
    # WebDAV 服务器地址/账号/密码行 + 备份/恢复按钮为屏独有
    ("06", "backup",           nav_b3_06,
     ("WebDAV 服务器地址", "WebDAV 账号", "WebDAV 密码"),
     ("备份", "恢复"),
     (), None),
    # 07 字体（font_screen「字体管理」，Tt 入口整页链路）：「系统字体」
    # 节头 + 「阅读字体预览 Aa 汉」行为屏独有；AND 「字体」字样
    # （标题/当前字体/选择字体）
    ("07", "font",             nav_b3_07,
     ("系统字体", "阅读字体预览", "当前字体", "自定义字体"),
     ("字体",),
     ("退出阅读",), None),
    # 08 朗读（read_aloud_config_screen「朗读引擎」）：顶栏标题 +
    # 「添加引擎」FAB/「暂无朗读引擎」空态为屏独有；AND 「引擎」字样
    ("08", "tts",              nav_b3_08,
     ("朗读引擎", "添加引擎", "暂无朗读引擎", "管理 HTTP TTS 朗读引擎"),
     ("引擎",),
     (), None),
    # 09 分组管理（book_group_screen）：顶栏「分组管理」标题 +
    # 「新建分组」FAB tooltip/「还没有分组」空态为屏独有
    ("09", "group_mgmt",       nav_b3_09,
     ("分组管理", "新建分组", "还没有分组", "创建第一个分组"),
     ("分组",),
     ("选择模式",), None),
    # 10 定时任务（auto_task_screen）：顶栏「定时任务」标题常驻；
    # 有任务态「立即运行/编辑任务/调试」行或 cron 行，空态「暂无定时任务」
    ("10", "auto_task",        nav_b3_10,
     ("暂无定时任务", "立即运行", "编辑任务", "cron", "调试"),
     ("任务",),
     (), None),
    # 11 高亮标注（highlight_rules_screen「高亮规则」）：顶栏标题 +
    # 「暂无高亮规则/新增自动高亮规则」空态、规则卡「使用正则表达式」
    # 为屏独有（替换净化编辑器亦含「使用正则表达式」，故 AND 标注/高亮）
    ("11", "highlight",        nav_b3_11,
     ("高亮规则", "暂无高亮规则", "使用正则表达式", "新增自动高亮规则"),
     ("标注", "高亮"),
     ("书源管理",), None),
]

# ===== 批 4 登记表（长尾深页，4 屏；key=<编号>_<短名> 即输出文件名） =====
# 入口全在「我的」页，断言关键词取自各屏源码实证（txt_toc_rules_screen /
# dict_screen / file_manage_screen / about_screen），遵循批 2/3 教训：
# 主特征取屏独有元素；AND 词组覆盖任务指定断言词（目录规则/TXT、字典、
# 文件/目录/私有、版本）。
# [2.0.270 批 4 用户裁决] 05_home_module（首页模块管理）暂不实施：两侧均不采，
# 仅在此注释登记（不进登记表，不会被执行）。
SCREENS_B4: list[tuple[str, str, str, tuple[str, ...], tuple[str, ...],
                       tuple[str, ...], "callable | None"]] = [
    # 01 TXT 目录规则（txt_toc_rules_screen，标题「TXT 目录规则」）：
    # 工具条「导入默认/添加规则」tooltip + 空态「暂无目录规则/正则规则」为屏独有
    ("01", "txt_toc_rule",     nav_b4_01,
     ("TXT 目录规则", "暂无目录规则", "导入默认", "添加规则", "正则"),
     ("目录规则", "TXT"),
     ("退出阅读", "自动翻页"), None),
    # 02 字典规则（我的页「字典规则」行 → dict_screen 字典查询页，
    # 标题「字典查询」）：「输入单词开始查询」空态 + 「在线词典」节 +
    # 「词典规则管理」入口为屏独有（字典规则管理页无「查询」按钮/在线词典节）
    ("02", "dict_rule",        nav_b4_02,
     ("字典查询", "输入单词开始查询", "在线词典", "词典规则", "暂无词典规则"),
     ("字典",),
     ("退出阅读", "自动翻页"), None),
    # 03 文件管理（file_manage_screen）：顶栏筛选框 hint「筛选 · 文件管理」
    # + root 面包屑 + 空态「当前目录为空」为屏独有；AND 任务词 文件/目录/私有
    # （私有文件夹行/文案证明停在文件管理语境）
    ("03", "file_manage",      nav_b4_03,
     ("筛选 · 文件管理", "root", "当前目录为空", "加载文件"),
     ("文件", "目录", "私有"),
     ("退出阅读", "自动翻页"), None),
    # 04 关于页（about_screen，标题「关于」）：「更新日志」行副标题含
    # 「版本 <v>」为任务断言词；「开发人员/检查更新/开源许可/免责声明」
    # 为屏独有行
    ("04", "about",            nav_b4_04,
     ("关于", "开发人员", "更新日志", "检查更新", "开源许可", "免责声明"),
     ("版本",),
     ("退出阅读", "自动翻页"), None),
]


def main() -> int:
    # global 声明必须在函数内首次使用 DEV/OUT_DIR/EXPECT_VERSION 之前，
    # 否则 SyntaxError: name used prior to global declaration
    global DEV, OUT_DIR, EXPECT_VERSION
    ap = argparse.ArgumentParser(
        description="我方 1:1 对比批量截图采集（批 1 16 屏 + 批 2 10 屏 + "
                    "批 3 11 屏 + 批 4 长尾深页 4 屏）")
    ap.add_argument("--device", default=DEFAULT_DEVICE,
                    help=f"adb 设备（默认 {DEFAULT_DEVICE}）")
    ap.add_argument("--only", default="",
                    help="只跑指定屏，逗号分隔：批 1 用编号（01,03,06，07 含 07/07b），"
                         "批 2/批 3/批 4 用全名 key（01_discover,08_source_manage,"
                         "01_mine,04_appearance,01_txt_toc_rule），可混用")
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

    # 批 1/批 2/批 3 编号数字重叠（01/02/03/06-12 等），按 key 归属拆分：
    # 批 1 用纯数字编号（01..16/07b），批 2/批 3 用全名 key
    # （01_discover / 01_mine 等，短名互不冲突）
    B1_NUMS = {s[0] for s in SCREENS}
    B2_KEYS = {f"{n}_{m}" for n, m, *_ in SCREENS_B2}
    B3_KEYS = {f"{n}_{m}" for n, m, *_ in SCREENS_B3}
    B4_KEYS = {f"{n}_{m}" for n, m, *_ in SCREENS_B4}
    want_b1 = {t for t in want if t in B1_NUMS}
    want_b2 = {t for t in want if t in B2_KEYS}
    want_b3 = {t for t in want if t in B3_KEYS}
    want_b4 = {t for t in want if t in B4_KEYS}

    rec(f"设备：{DEV}；adb：{ADB}")
    if not want:
        rec("目标：批 1 全 16 屏 + 批 2 全 10 屏 + 批 3 全 11 屏 + 批 4 全 4 屏")
    else:
        rec(f"目标：--only {','.join(sorted(want))}"
            f"（批 1：{','.join(sorted(want_b1)) or '无'}；"
            f"批 2：{','.join(sorted(want_b2)) or '无'}；"
            f"批 3：{','.join(sorted(want_b3)) or '无'}；"
            f"批 4：{','.join(sorted(want_b4)) or '无'}）")

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

    # 批 3（我的与设置）：文件名 = key.png（01_mine.png 等），
    # 与批 1/批 2 同目录不同名，互不覆盖
    for num, name, nav, kws, and_kws, neg_kws, post in SCREENS_B3:
        key = f"{num}_{name}"
        if want and key not in want_b3:
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

    # 批 4（长尾深页）：文件名 = key.png（01_txt_toc_rule.png 等），
    # 与批 1-3 同目录不同名，互不覆盖；每屏导航自带 _to_mine 冷启动复位
    for num, name, nav, kws, and_kws, neg_kws, post in SCREENS_B4:
        key = f"{num}_{name}"
        if want and key not in want_b4:
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
