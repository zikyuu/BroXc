"""Builds the 1024x1024 app icon from a rendered icon picture (rounded corners, soft shadow, white margin).
Usage: python3 design/make_app_icon.py path/to/icon.png
iOS adds the rounded corners itself, so the output is a full-bleed square with no transparency."""
import sys, json, os
from collections import deque
import numpy as np
from PIL import Image

src = Image.open(sys.argv[1]).convert("RGB")
a = np.array(src).astype(int)
h, w, _ = a.shape
# the white margin and shadow around the rounded square: everything connected to the corners that is near white or light grey
light = (a.min(axis=2) > 225)
seen = np.zeros((h, w), bool); q = deque()
for x in range(w):
    for y in (0, h - 1):
        if light[y, x]: seen[y, x] = True; q.append((y, x))
for y in range(h):
    for x in (0, w - 1):
        if light[y, x] and not seen[y, x]: seen[y, x] = True; q.append((y, x))
while q:
    y, x = q.popleft()
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        ny, nx = y + dy, x + dx
        if 0 <= ny < h and 0 <= nx < w and light[ny, nx] and not seen[ny, nx]: seen[ny, nx] = True; q.append((ny, nx))
ys, xs = np.nonzero(~seen)
box = (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)
icon = src.crop(box)
side = max(icon.size)
# fill the corners the rounding left empty with the paper colour sampled just inside the edge, so the square is full-bleed
paper = tuple(int(v) for v in np.median(np.array(icon)[icon.height // 2 - 20: icon.height // 2 + 20, 6:14].reshape(-1, 3), axis=0))
canvas = Image.new("RGB", (side, side), paper)
canvas.paste(icon, ((side - icon.width) // 2, (side - icon.height) // 2))
mask = Image.fromarray((~seen[box[1]:box[3], box[0]:box[2]]).astype(np.uint8) * 255)
canvas.paste(icon, ((side - icon.width) // 2, (side - icon.height) // 2), mask)
out = canvas.resize((1024, 1024), Image.LANCZOS)
dest = "ios/ExpenseTracker/ExpenseTracker/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
out.save(dest); out.save("design/app-icon-1024.png")
print("saved", dest, "paper", paper)
