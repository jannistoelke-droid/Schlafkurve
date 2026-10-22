"""Renders App/Assets.xcassets/AppIcon.appiconset/AppIcon.png (1024x1024, no alpha).
Motif: crescent moon above a sleep-depth wave on the night background.
Run: python scripts/make-app-icon.py"""
import math
import pathlib
from PIL import Image, ImageDraw, ImageFilter

S = 1024
SCALE = 4  # supersampling for smooth edges
W = S * SCALE
OUT = pathlib.Path(__file__).resolve().parent.parent / "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

top, bottom = (24, 30, 72), (11, 16, 32)
img = Image.new("RGB", (W, W))
px = ImageDraw.Draw(img)
for y in range(W):
    f = y / (W - 1)
    px.line([(0, y), (W, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * f) for i in range(3)))

# glow behind the moon
glow = Image.new("L", (W, W), 0)
gd = ImageDraw.Draw(glow)
cx, cy, r = int(W * 0.60), int(W * 0.34), int(W * 0.17)
gd.ellipse([cx - r * 1.6, cy - r * 1.6, cx + r * 1.6, cy + r * 1.6], fill=70)
glow = glow.filter(ImageFilter.GaussianBlur(W * 0.05))
img.paste(Image.new("RGB", (W, W), (136, 152, 255)), mask=glow)

# crescent moon = disc minus offset disc
moon = Image.new("L", (W, W), 0)
md = ImageDraw.Draw(moon)
md.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
ox, oy = int(r * 0.55), int(-r * 0.30)
md.ellipse([cx - r + ox, cy - r + oy, cx + r + ox, cy + r + oy], fill=0)
img.paste(Image.new("RGB", (W, W), (232, 236, 248)), mask=moon)

# sleep-depth wave (awake high, deep low) with stage-coloured fill
d = ImageDraw.Draw(img)
def wave_y(x):
    t = x / W
    return W * (0.70 + 0.09 * math.sin(t * math.pi * 3.2 + 0.6) + 0.03 * math.sin(t * math.pi * 9.0))
pts = [(x, wave_y(x)) for x in range(0, W + 1, 8)]
fill_mask = Image.new("L", (W, W), 0)
ImageDraw.Draw(fill_mask).polygon(pts + [(W, W), (0, W)], fill=255)
fill = Image.new("RGB", (W, W))
fd = ImageDraw.Draw(fill)
c1, c2 = (100, 181, 246), (57, 73, 171)
for y in range(W):
    f = min(max((y - W * 0.6) / (W * 0.4), 0), 1)
    fd.line([(0, y), (W, y)], fill=tuple(int(c1[i] + (c2[i] - c1[i]) * f) for i in range(3)))
fill_mask = fill_mask.point(lambda v: int(v * 0.55))
img.paste(fill, mask=fill_mask)
lw = W * 0.018
d.line(pts, fill=(232, 236, 248), width=int(lw))
for x, y in pts:  # round caps at every vertex hide the seams between segments
    d.ellipse([x - lw / 2, y - lw / 2, x + lw / 2, y + lw / 2], fill=(232, 236, 248))

# stars
for sx, sy, sr in [(0.22, 0.22, 0.010), (0.33, 0.12, 0.006), (0.15, 0.42, 0.007), (0.84, 0.16, 0.007), (0.40, 0.36, 0.005)]:
    x, y, rr = sx * W, sy * W, sr * W
    d.ellipse([x - rr, y - rr, x + rr, y + rr], fill=(232, 236, 248))

img = img.resize((S, S), Image.LANCZOS)
img.save(OUT, "PNG")
print("wrote", OUT)
