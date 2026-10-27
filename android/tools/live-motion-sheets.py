"""Cuts the live demo recording (android/tools/live-motion.sh) into filmstrips: every frame between two times, at a
fixed step, cropped to where the motion happens and captioned with the video's own clock.

    python3 -I android/tools/live-motion-sheets.py <live.mp4> <out-dir> [name start end step crop-y crop-h] ...

With no strips given it cuts an overview strip (one frame a second) for finding the moments.
"""
import os
import sys

import cv2
from PIL import Image, ImageDraw, ImageFont

video, out = sys.argv[1], sys.argv[2]
SCALE = 420 / 160
cap = cv2.VideoCapture(video)
fps = cap.get(cv2.CAP_PROP_FPS) or 30
count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
frames = []
stamps = []
while True:
    ok, f = cap.read()
    if not ok:
        break
    frames.append(f)
    # screenrecord writes variable-rate video (a frame only when the screen changes): the decoder's own timestamps are the truth.
    stamps.append(cap.get(cv2.CAP_PROP_POS_MSEC) / 1000)
print(f"{len(frames)} frames over {stamps[-1] if stamps else 0:.1f} s")


def frame_at(t):
    # The frame on screen at t: the last one shown at or before it.
    i = max([k for k, s in enumerate(stamps) if s <= t + 1e-6] or [0])
    return Image.fromarray(cv2.cvtColor(frames[i], cv2.COLOR_BGR2RGB)), stamps[i]


def font(size):
    for path in ("/System/Library/Fonts/SFNSMono.ttf", "/System/Library/Fonts/Menlo.ttc"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def strip(name, start, end, step, y, h):
    tiles = []
    t = start
    while t <= end + 1e-9:
        img, shown = frame_at(t)
        s = img.width / 1080
        crop = img.crop((0, int(y * SCALE * s), img.width, int((y + h) * SCALE * s)))
        tiles.append((crop, f"{t:.2f} s (frame {shown:.2f})"))
        t += step
    th = 520 if h <= 400 else 900
    tiles = [(c.resize((int(c.width * th / c.height), th), Image.LANCZOS), l) for c, l in tiles]
    pad, capg = 16, 44
    width = sum(c.width for c, _ in tiles) + pad * (len(tiles) + 1)
    sheet = Image.new("RGB", (width, th + capg + pad * 2), (7, 9, 13))
    d = ImageDraw.Draw(sheet)
    x = pad
    for c, l in tiles:
        sheet.paste(c, (x, pad))
        d.text((x + 4, pad + th + 10), l, fill=(170, 178, 190), font=font(22))
        x += c.width + pad
    dest = os.path.join(out, f"live-{name}.png")
    sheet.save(dest)
    print(dest)


args = sys.argv[3:]
if not args:
    total = stamps[-1] if stamps else 0
    strip("overview", 0, total - 0.1, 1.0, 0, 914)
else:
    for i in range(0, len(args), 6):
        n, a, b, st, y, h = args[i:i + 6]
        strip(n, float(a), float(b), float(st), float(y), float(h))
