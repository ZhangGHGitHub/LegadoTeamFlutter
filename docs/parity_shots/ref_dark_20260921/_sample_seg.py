from PIL import Image
import statistics

im = Image.open("08_ref_transparent_dark_appearance_graybg.png").convert("RGB")
print("size", im.size)

def line(label, pts):
    vals = [im.getpixel(p) for p in pts]
    allch = [c for p in vals for c in p]
    uniq = {}
    for p in vals:
        uniq[p] = uniq.get(p, 0) + 1
    print(f"{label}: n={len(vals)} min={min(allch)} max={max(allch)} mean={round(statistics.mean(allch),2)} distinct={sorted(uniq.items(), key=lambda kv:-kv[1])[:6]}")
    for p, v in zip(pts, vals):
        print("   ", p, v)

# seg1 跟随系统 [32,1064][274,1160] center x=153 full-height x[80,226]; label x128-242 y1092-1132
line("seg1-follow(unselected)", [(100, 1075), (153, 1070), (226, 1075), (100, 1149), (153, 1155), (226, 1149)])
# seg2 浅色 [278,1064][481,1160] center 379; label x383-441
line("seg2-light(unselected)", [(340, 1075), (379, 1070), (420, 1075), (340, 1149), (379, 1155), (420, 1149)])
# seg3 深色 selected [485,1064][688,1160] center 586; label x590-648
line("seg3-dark(selected)", [(545, 1075), (586, 1070), (630, 1075), (545, 1149), (586, 1155), (630, 1149)])
# gaps between segments
line("gaps", [(276, 1112), (483, 1112)])
# page bg
line("page-bg", [(360, 400), (660, 600), (60, 700), (660, 1000)])
# banner card [64,840][560,920]
line("banner-card", [(550, 850), (550, 910), (72, 850), (550, 880), (72, 910)])
