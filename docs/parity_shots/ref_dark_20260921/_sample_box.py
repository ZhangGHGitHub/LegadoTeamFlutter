from PIL import Image

im = Image.open("07_ref_transparent_dark_search_graybg.png").convert("RGB")
W, H = im.size
print("size", (W, H))

def sample(x, y, label):
    print(f"{label:22s} ({x:4d},{y:4d}) = {im.getpixel((x, y))}")

# box interior grid, skip hint rect [128,268]-[328,308]
xs = [50, 80, 100, 350, 400, 450, 500, 550, 600, 650, 670]
ys = [250, 270, 290, 310, 330]
vals = []
for y in ys:
    for x in xs:
        if 128 <= x <= 328 and 268 <= y <= 308:
            continue
        p = im.getpixel((x, y))
        vals.append(p)
        print(f"box ({x:4d},{y:4d}) = {p}")

import statistics
allch = [c for p in vals for c in p]
print("box n =", len(vals))
print("box min", min(allch), "max", max(allch), "mean", round(statistics.mean(allch), 2))
uniq = {}
for p in vals:
    uniq[p] = uniq.get(p, 0) + 1
print("distinct:", sorted(uniq.items(), key=lambda kv: -kv[1]))

print()
sample(360, 60, "topbar mid")
sample(360, 180, "title row")
sample(360, 440, "history row")
sample(360, 700, "below content")
sample(60, 60, "back icon")
# hint text color check
hx, hy = 150, 288
print("hint area", (hx, hy), im.getpixel((hx, hy)))
