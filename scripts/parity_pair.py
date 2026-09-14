# -*- coding: utf-8 -*-
"""截图一比一比对工具：配对拼图 + 差分热图 + 缺失清单（供"截图一比一比对"工作流使用）。

两侧截图目录均按同一命名约定 ``<两位序号>_<英文短名>.png`` 存放（同序号=同屏），
且来自同一模拟器实例、分辨率一致（如 1080x1920）。

用法::

    python scripts/parity_pair.py --ref docs/parity_shots/ref_20260913 \
        --ours docs/parity_shots/ours_2.0.256 [--out 输出目录] [--no-diff]

产物（默认输出到 ``docs/parity_shots/pairs_<当日日期>/``）::

    <屏名>_pair.png   左 REF、右 OURS 水平拼接：中间 8px 白色分隔线，
                      顶部各 40px 黑底白字标签条（REF: <文件名> / OURS: <文件名>）
    <屏名>_diff.png   灰度差 3 倍放大伪彩热图（黑=无差异，越亮差异越大；--no-diff 时不生成）
    INDEX.md          清单表：屏名 | ref | ours | pair | diff占比 | 尺寸是否一致，
                      并附"参考有我方无 / 我方有参考无 / 读取失败"三类缺失记录

差异占比定义：两侧按较小宽高居中裁剪对齐后，灰度差值 > 24 的像素占总像素百分比，
逐屏打印到 stdout（两侧同图时 ≈ 0%）。尺寸不一致、读取失败的屏会在 INDEX 中标注。
"""
from __future__ import annotations

import argparse
import sys
from datetime import datetime
from pathlib import Path

# Windows 控制台默认 GBK，强制 UTF-8 输出，避免中文/特殊字符打印崩溃
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

from PIL import Image, ImageChops, ImageDraw  # noqa: E402

# ---- 常量（与截图比对工作流约定一致）----
DIVIDER_W = 8        # 拼接中央白色分隔线宽度（px）
LABEL_H = 40         # 顶部标签条高度（px）
DIFF_THRESHOLD = 24  # 灰度差值判异阈值（>24 计为差异像素）
DIFF_SCALE = 3       # 差分热图放大倍数
STAMP = datetime.now().strftime("%Y%m%d")
ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = ROOT / "docs" / "parity_shots" / f"pairs_{STAMP}"


def _collect_png(dir_path: Path) -> dict[str, Path]:
    """收集目录下全部 .png，按文件名（不含扩展名）建索引；同 stem 后者覆盖前者。"""
    files: dict[str, Path] = {}
    for p in sorted(dir_path.iterdir()):
        if p.is_file() and p.suffix.lower() == ".png":
            files[p.stem] = p
    return files


def _load(path: Path) -> Image.Image:
    """打开图像并立即读入像素，坏文件尽早抛错。"""
    im = Image.open(path)
    im.load()
    return im


def _center_crop(im: Image.Image, w: int, h: int) -> Image.Image:
    """按目标宽高对图像做居中裁剪（两侧尺寸不一致时对齐用）。"""
    x = (im.width - w) // 2
    y = (im.height - h) // 2
    return im.crop((x, y, x + w, y + h))


def align_pair(ref: Image.Image, ours: Image.Image) -> tuple[Image.Image, Image.Image, bool]:
    """两侧尺寸不一致时按较小宽高居中裁剪对齐，返回（ref、ours、是否一致）。"""
    if ref.size == ours.size:
        return ref, ours, True
    w, h = min(ref.width, ours.width), min(ref.height, ours.height)
    return _center_crop(ref, w, h), _center_crop(ours, w, h), False


def make_pair(ref: Image.Image, ours: Image.Image, ref_name: str, ours_name: str) -> Image.Image:
    """左 REF、右 OURS 水平拼接：中间 8px 白线，顶部 40px 黑底白字标签条。

    标签文字使用 PIL 默认位图字体（仅支持英文；文件名本身即英文短名，可正常渲染）。
    """
    # 尺寸不一致时先按较小宽高居中裁剪，保证左右并排可比
    ref, ours, same = align_pair(ref, ours)
    h = ref.height
    w_ref, w_ours = ref.width, ours.width

    # 顶部标签条：左半 "REF: <文件名>"、右半 "OURS: <文件名>"，黑底白字
    top = Image.new("RGB", (w_ref + DIVIDER_W + w_ours, LABEL_H), "white")
    left_bar = Image.new("RGB", (w_ref, LABEL_H), "black")
    right_bar = Image.new("RGB", (w_ours, LABEL_H), "black")
    ImageDraw.Draw(left_bar).text((8, (LABEL_H - 12) // 2), f"REF: {ref_name}", fill="white")
    ImageDraw.Draw(right_bar).text((8, (LABEL_H - 12) // 2), f"OURS: {ours_name}", fill="white")
    top.paste(left_bar, (0, 0))
    top.paste(right_bar, (w_ref + DIVIDER_W, 0))

    # 画布整体白底，中间 8px 留白即白色分隔线
    canvas = Image.new("RGB", (w_ref + DIVIDER_W + w_ours, LABEL_H + h), "white")
    canvas.paste(top, (0, 0))
    canvas.paste(ref.convert("RGB"), (0, LABEL_H))
    canvas.paste(ours.convert("RGB"), (w_ref + DIVIDER_W, LABEL_H))
    return canvas


def make_diff_heatmap(ref: Image.Image, ours: Image.Image) -> Image.Image:
    """灰度差分 3 倍放大伪彩热图：黑=无差异，越亮差异越大。

    尺寸不一致时先按较小宽高居中裁剪对齐（align_pair），再逐像素灰度差；
    不能依赖 ImageChops.difference 的隐式对齐——它对尺寸不一致的输入是
    按"较小图贴到较大图左上角"裁剪，与居中裁剪语义不一致，会导致热图错位。
    """
    ref, ours, _ = align_pair(ref, ours)
    diff = ImageChops.difference(ref.convert("L"), ours.convert("L"))
    # 放大 3 倍（NEAREST 保留原始差值强度，肉眼更易判读）
    return diff.resize((diff.width * DIFF_SCALE, diff.height * DIFF_SCALE), Image.NEAREST)


def diff_percent(ref: Image.Image, ours: Image.Image) -> float:
    """差异像素占比：灰度差值 > DIFF_THRESHOLD 的像素百分比（按对齐后较小宽高计）。"""
    w, h = min(ref.width, ours.width), min(ref.height, ours.height)
    a = _center_crop(ref, w, h).convert("L")
    b = _center_crop(ours, w, h).convert("L")
    diff = ImageChops.difference(a, b)
    hist = diff.histogram()
    total = w * h
    diff_px = sum(hist[DIFF_THRESHOLD + 1:])  # 阈值"大于"24，即 25..255
    return 100.0 * diff_px / total if total else 0.0


def _esc(s: str) -> str:
    """Markdown 表格单元格转义。"""
    return s.replace("|", "\\|").replace("\n", " ")


def _size_note(ref: Image.Image, ours: Image.Image) -> str:
    """INDEX「尺寸是否一致」列的取值。"""
    if ref.size == ours.size:
        return "一致"
    return f"不一致（ref {ref.width}x{ref.height} vs ours {ours.width}x{ours.height}，已居中裁剪）"


def run(ref_dir: Path, ours_dir: Path, out_dir: Path, do_diff: bool) -> int:
    """主流程：配对拼图 → 差分热图（可选）→ 缺失清单 + INDEX.md。"""
    for d in (ref_dir, ours_dir):
        if not d.is_dir():
            print(f"[错误] 目录不存在: {d}")
            return 1
    out_dir.mkdir(parents=True, exist_ok=True)

    ref_files = _collect_png(ref_dir)
    ours_files = _collect_png(ours_dir)
    only_ref = sorted(set(ref_files) - set(ours_files))   # 参考有、我方无
    only_ours = sorted(set(ours_files) - set(ref_files))  # 我方有、参考无
    common = sorted(set(ref_files) & set(ours_files))

    print(f"[配对] 参考侧 {len(ref_files)} 张，我方侧 {len(ours_files)} 张，"
          f"共同 {len(common)} 屏；输出目录: {out_dir}")
    if only_ref:
        print(f"[缺失] 参考有、我方无（{len(only_ref)}）: {', '.join(only_ref)}")
    if only_ours:
        print(f"[缺失] 我方有、参考无（{len(only_ours)}）: {', '.join(only_ours)}")

    rows: list[dict[str, str]] = []
    load_errors: list[str] = []
    for stem in common:
        try:
            a = _load(ref_files[stem])
            b = _load(ours_files[stem])
        except Exception as e:  # 读取失败：跳过本屏并记录，不影响其余屏
            load_errors.append(f"{stem}: {e.__class__.__name__}")
            print(f"[跳过] {stem} 图像读取失败: {e}")
            rows.append({"screen": stem, "ref": ref_files[stem].name,
                         "ours": ours_files[stem].name,
                         "pair": "读取失败（跳过）", "pct": "—", "size": "—"})
            continue

        # 1) 配对拼图
        pair_path = out_dir / f"{stem}_pair.png"
        make_pair(a, b, ref_files[stem].name, ours_files[stem].name).save(pair_path, "PNG")

        # 2) 差分热图 + 差异占比（默认开启，--no-diff 关闭）
        size_note = _size_note(a, b)
        if do_diff:
            make_diff_heatmap(a, b).save(out_dir / f"{stem}_diff.png", "PNG")
            pct = diff_percent(a, b)
            pct_str = f"{pct:.2f}%"
            print(f"[差分] {stem}: 差异像素占比 {pct_str}（阈值 >{DIFF_THRESHOLD}）"
                  + (f"；{size_note}" if size_note != "一致" else ""))
        else:
            pct_str = "—"
            print(f"[配对] {stem}: {pair_path.name}"
                  + (f"；{size_note}" if size_note != "一致" else ""))
        rows.append({"screen": stem, "ref": ref_files[stem].name,
                     "ours": ours_files[stem].name,
                     "pair": _esc(pair_path.name), "pct": pct_str, "size": size_note})

    # 缺失侧同样进清单，便于工作流一眼看全
    for stem in only_ref:
        rows.append({"screen": stem, "ref": ref_files[stem].name,
                     "ours": "—（缺失）", "pair": "—", "pct": "—", "size": "—"})
    for stem in only_ours:
        rows.append({"screen": stem, "ref": "—（缺失）",
                     "ours": ours_files[stem].name, "pair": "—", "pct": "—", "size": "—"})

    _write_index(out_dir, ref_dir, ours_dir, rows, only_ref, only_ours, load_errors, do_diff)
    print(f"[完成] 配对 {len(common)} 屏 -> {out_dir}（INDEX.md 已生成）")
    return 0


def _write_index(out_dir: Path, ref_dir: Path, ours_dir: Path,
                 rows: list[dict[str, str]], only_ref: list[str], only_ours: list[str],
                 load_errors: list[str], do_diff: bool) -> None:
    """生成 INDEX.md：缺失侧清单 + 配对/差分总表。"""
    lines = [
        "# 截图一比一比对清单",
        "",
        f"- 生成时间: {STAMP}",
        f"- 参考目录: `{ref_dir}`",
        f"- 我方目录: `{ours_dir}`",
        f"- 差异阈值: 灰度差 > {DIFF_THRESHOLD}；热图放大 {DIFF_SCALE} 倍"
        + ("" if do_diff else "（本次 --no-diff，未生成热图）"),
        f"- 参考有、我方无（{len(only_ref)}）: {', '.join(only_ref) if only_ref else '无'}",
        f"- 我方有、参考无（{len(only_ours)}）: {', '.join(only_ours) if only_ours else '无'}",
    ]
    if load_errors:
        lines.append(f"- 读取失败（{len(load_errors)}）: " + "; ".join(load_errors))
    lines += [
        "",
        "| 屏名 | ref | ours | pair | diff占比 | 尺寸是否一致 |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for r in sorted(rows, key=lambda r: r["screen"]):
        lines.append(f"| {r['screen']} | {r['ref']} | {r['ours']} | {r['pair']} "
                     f"| {r['pct']} | {r['size']} |")
    (out_dir / "INDEX.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="截图一比一比对工具（配对拼图 + 差分热图 + 缺失清单）",
    )
    parser.add_argument("--ref", type=Path, required=True,
                        help="参考截图目录（如 docs/parity_shots/ref_20260913）")
    parser.add_argument("--ours", type=Path, required=True,
                        help="我方截图目录（如 docs/parity_shots/ours_2.0.256）")
    parser.add_argument("--out", type=Path, default=None,
                        help=f"输出目录（默认 {DEFAULT_OUT}）")
    parser.add_argument("--no-diff", action="store_true",
                        help="不生成差分热图与差异占比（默认生成）")
    args = parser.parse_args()

    out_dir = args.out if args.out is not None else DEFAULT_OUT
    return run(args.ref, args.ours, out_dir, do_diff=not args.no_diff)


if __name__ == "__main__":
    sys.exit(main())
