"""Tiles the frames android/tools/render-motion.sh captured into one contact sheet per signature motion, like the rows
of board 07 (and iOS/Tools/motion-sheets.py): each frame cropped to where the motion happens, side by side,
captioned with its moment.

    python3 -I android/tools/motion-sheets.py <out-dir>
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

out = sys.argv[1]
frames = os.path.join(out, "frames")

# Crops are in dp on the "PagePixel" emulator (1080 x 2400 px at 420 dpi: 411 x 914 dp): (x, y, width, height);
# a negative y counts from the bottom, "mid+N" from the middle. Widths past the screen are clipped.
SCALE = 420 / 160
SHEETS = {
    "1-pulse": ((105, 44, 200, 200), [
        ("motion-pulse-quiet@3", "quiet · still"),
        ("motion-pulse-working@2", "working · breathe (in)"),
        ("motion-pulse-working@4", "working · breathe (out)"),
        ("motion-pulse-waiting1@1.2", "1 waiting · ripple"),
        ("motion-pulse-waiting3@1.2", "3 waiting · faster, capped"),
        ("motion-pulse-waiting3@2.0", "3 waiting · +0.8 s"),
    ]),
    "1b-exhale": ((0, 0, 411, 300), [
        ("motion-pulse-exhale@0", "last item clears · 0 ms"),
        ("motion-pulse-exhale@0.3", "300 ms · turning"),
        ("motion-pulse-exhale@0.8", "800 ms · teal, exhaling"),
        ("motion-pulse-exhale@1.6", "1.6 s · settled"),
    ]),
    "2-final-approach": ((0, 0, 411, 760), [
        ("motion-approach@0", "0 ms · leaves pulse"),
        ("motion-approach@0.09", "90 ms"),
        ("motion-approach@0.18", "180 ms · contrail"),
        ("motion-approach@0.36", "360 ms · lands"),
        ("motion-approach@0.52", "520 ms · settles, glow off"),
    ]),
    "3-receipt-thread": ((0, 75, 411, 200), [
        ("motion-receipt-arm@0.6", "0-1.2 s · armed"),
        ("motion-receipt-sending@0.3", "sending"),
        ("motion-receipt-sent@0.8", "relay · sent"),
        ("motion-receipt-typed@0.45", "Mac · typed"),
        ("motion-receipt-verified@0.95", "screen · verified"),
        ("motion-receipt-failed@0.06", "failed · snaps back"),
        ("motion-receipt-failed@0.6", "failed · in words"),
        ("motion-receipt-fold@1.2", "fold · 1.2 s"),
        ("motion-receipt-fold@1.45", "drift into Settled"),
    ]),
    "3b-receipt-sheet": ((0, -520, 411, 520), [
        ("motion-receipt-sheet@0.95", "sheet · verified"),
    ]),
    "4-hold-ring": ((16, "mid-170", 379, 340), [
        ("motion-hold@0", "0 ms"),
        ("motion-hold@0.36", "300 ms · ring appears"),
        ("motion-hold@0.9", "900 ms · ticks"),
        ("motion-hold@1.5", "1.5 s · fingerprint"),
        ("motion-hold-burst@0.15", "passed · burst"),
        ("motion-hold-burst@0.4", "burst · 400 ms"),
    ]),
    "5-dusk-dawn-sky": ((0, 0, 411, 780), [
        ("sky@3", "working sky"),
        ("motion-dusk@0.7", "cutoff · dusk falls"),
        ("motion-dusk@3", "paused · horizon only"),
        ("motion-dawn@0.6", "power · dawn rises"),
        ("motion-dawn@1.2", "dawn · stars relight"),
        ("motion-dawn@2.4", "dawn · settling"),
    ]),
    "5b-dusk-dawn-horizon": ((0, 0, 411, 300), [
        ("now-working@3", "working"),
        ("motion-dusk-now@0.8", "cutoff · dusk falls"),
        ("motion-dusk-now@3", "paused · band holds"),
        ("motion-dawn-now@0.9", "power · dawn"),
        ("motion-dawn-now@1.8", "dawn · settling"),
    ]),
    "5c-return-brief": ((0, 20, 411, 340), [
        ("motion-brief@0", "Brief opens · 0 ms"),
        ("motion-brief@0.6", "sunrise rising"),
        ("motion-brief@1.2", "1.2 s"),
        ("motion-brief@2.6", "holds"),
    ]),
}


def font(size):
    for path in ("/System/Library/Fonts/SFNSMono.ttf", "/System/Library/Fonts/Menlo.ttc"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def crop(img, box):
    x, y, w, h = box
    hp = img.height / SCALE
    w = min(w, img.width / SCALE - x)
    if isinstance(y, str):
        y = hp / 2 + float(y[3:] or 0)
    elif y < 0:
        y = hp + y
    y = max(0, min(y, hp - h))
    return img.crop((int(x * SCALE), int(y * SCALE), int((x + w) * SCALE), int((y + h) * SCALE)))


made = []
for name, (box, items) in SHEETS.items():
    tiles = []
    for stem, label in items:
        path = os.path.join(frames, stem + ".png")
        if not os.path.exists(path):
            continue
        tiles.append((crop(Image.open(path).convert("RGB"), box), label))
    if not tiles:
        continue
    th = 520 if box[3] <= 400 else 900
    tiles = [(t.resize((int(t.width * th / t.height), th), Image.LANCZOS), l) for t, l in tiles]
    pad, cap = 24, 54
    width = sum(t.width for t, _ in tiles) + pad * (len(tiles) + 1)
    sheet = Image.new("RGB", (width, th + cap + pad * 2), (7, 9, 13))
    draw = ImageDraw.Draw(sheet)
    x = pad
    for t, label in tiles:
        sheet.paste(t, (x, pad))
        draw.rounded_rectangle((x - 1, pad - 1, x + t.width, pad + th), radius=18, outline=(40, 44, 52), width=2)
        draw.text((x + 4, pad + th + 14), label, fill=(170, 178, 190), font=font(24))
        x += t.width + pad
    dest = os.path.join(out, name + ".png")
    sheet.save(dest)
    made.append(dest)
print("\n".join(made))
