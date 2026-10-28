"""Tiles the frames iOS/Tools/render-motion.sh captured into one contact sheet
per signature motion, like the rows of board 07: each frame cropped to where
the motion happens, side by side, captioned with its moment.

    python3 -I iOS/Tools/motion-sheets.py <out-dir>
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

out = sys.argv[1]
frames = os.path.join(out, "frames")

# Crops are in points at @3x: (x, y, width, height); a negative y counts from
# the bottom, "mid+N" from the middle. Now's column is 382 pt wide on the
# "Page Render" simulator (an iPhone Duo: 466 x 678 pt with the status bar
# down the right); widths past the screen are clipped.
SCALE = 3.0
SHEETS = {
    "1-pulse": ((90, 58, 200, 200), [
        ("motion-pulse-quiet@3", "quiet · still"),
        ("motion-pulse-working@2", "working · breathe (in)"),
        ("motion-pulse-working@4", "working · breathe (out)"),
        ("motion-pulse-waiting1@1.2", "1 waiting · ripple"),
        ("motion-pulse-waiting3@1.2", "3 waiting · faster, capped"),
        ("motion-pulse-waiting3@2.0", "3 waiting · +0.8 s"),
    ]),
    "1b-exhale": ((0, 0, 382, 300), [
        ("motion-pulse-exhale@0", "last item clears · 0 ms"),
        ("motion-pulse-exhale@0.3", "300 ms · turning"),
        ("motion-pulse-exhale@0.8", "800 ms · teal, exhaling"),
        ("motion-pulse-exhale@1.6", "1.6 s · settled"),
    ]),
    "2-final-approach": ((0, 0, 382, 678), [
        ("motion-approach@0", "0 ms · leaves pulse"),
        ("motion-approach@0.09", "90 ms"),
        ("motion-approach@0.18", "180 ms · contrail"),
        ("motion-approach@0.36", "360 ms · lands"),
        ("motion-approach@0.52", "520 ms · settles, glow off"),
    ]),
    "3-receipt-thread": ((0, 236, 382, 172), [
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
    "4-hold-ring": ((16, "mid-150", 350, 300), [
        ("motion-hold@0", "0 ms"),
        ("motion-hold@0.36", "300 ms · ring appears"),
        ("motion-hold@0.9", "900 ms · ticks"),
        ("motion-hold@1.5", "1.5 s · Face ID"),
        ("motion-hold-burst@0.15", "passed · burst"),
        ("motion-hold-burst@0.4", "burst · 400 ms"),
    ]),
    "5-dusk-dawn-lanes": ((0, 0, 382, 560), [
        ("lanes@3", "working lanes"),
        ("motion-dusk@0.7", "cutoff · dusk falls"),
        ("motion-dusk@3", "paused · horizon only"),
        ("motion-dawn@0.6", "power · dawn rises"),
        ("motion-dawn@1.2", "dawn · lanes relight"),
        ("motion-dawn@2.4", "dawn · settling"),
    ]),
    "5b-dusk-dawn-horizon": ((0, 0, 382, 300), [
        ("now-working@3", "working"),
        ("motion-dusk-now@0.8", "cutoff · dusk falls"),
        ("motion-dusk-now@3", "paused · band holds"),
        ("motion-dawn-now@0.9", "power · dawn"),
        ("motion-dawn-now@1.8", "dawn · settling"),
    ]),
    "5c-return-brief": ((0, 50, 382, 300), [
        ("motion-brief@0", "Brief opens · 0 ms"),
        ("motion-brief@0.6", "sunrise rising"),
        ("motion-brief@1.2", "1.2 s"),
        ("motion-brief@2.6", "holds"),
    ]),
    # In flight: the section scrolled to the top (the strip, then the first card).
    "6a-inflight-enter": ((0, 20, 394, 506), [
        ("motion-inflight-enter@0.0", "0 ms · rises"),
        ("motion-inflight-enter@0.35", "350 ms · arcs sweep"),
        ("motion-inflight-enter@0.7", "700 ms"),
        ("motion-inflight-enter@1.4", "settled · breathing"),
        ("motion-inflight-enter@3.0", "glint, comet"),
    ]),
    "6b-inflight-advance": ((0, 20, 394, 506), [
        ("motion-inflight-advance@1.4", "3/5"),
        ("motion-inflight-advance@2.0", "4/5 · flare, new step"),
        ("motion-inflight-advance@2.2", "spring"),
        ("motion-inflight-advance@2.5", "timeline moves down"),
        ("motion-inflight-advance@3.6", "settled"),
    ]),
    "6c-inflight-complete": ((0, 20, 394, 506), [
        ("motion-inflight-complete@1.4", "1/4 running"),
        ("motion-inflight-complete@2.2", "done · springs closed"),
        ("motion-inflight-complete@2.5", "✓ done · pulse"),
        ("motion-inflight-complete@3.75", "folds away"),
        ("motion-inflight-complete@4.5", "gone"),
    ]),
    "6d-inflight-vanish-stuck": ((0, 20, 394, 506), [
        ("motion-inflight-vanish@1.4", "before"),
        ("motion-inflight-vanish@2.2", "no status · just leaves"),
        ("motion-inflight-stuck@1.4", "stuck · still"),
        ("motion-inflight-stuck@3.6", "still · amber"),
    ]),
    # The rest of Now: the Runway and the Horizon's words at the top, the chips and Settled further down.
    "7a-now-enter": ((0, 200, 394, 220), [
        ("motion-now-enter@0.0", "0 ms · the line starts"),
        ("motion-now-enter@0.2", "200 ms · markers pop"),
        ("motion-now-enter@0.5", "500 ms"),
        ("motion-now-enter@1.4", "drawn · NOW breathes"),
    ]),
    "7b-now-chips": ((0, 130, 394, 200), [
        ("motion-now-enter-low@0.0", "0 ms · from 0"),
        ("motion-now-enter-low@0.2", "200 ms · counting"),
        ("motion-now-enter-low@0.5", "500 ms · ✓ draws"),
        ("motion-now-enter-low@1.0", "counted"),
    ]),
    "7c-now-change": ((0, 220, 394, 200), [
        ("motion-now-change@1.4", "2 need you"),
        ("motion-now-change@2.2", "3 · cutoff glides"),
        ("motion-now-change@2.5", "glide"),
        ("motion-now-change@3.0", "settled"),
    ]),
    "7d-now-settled": ((0, 280, 394, 260), [
        ("motion-now-change-low@1.4", "before"),
        ("motion-now-change-low@2.2", "a receipt lands"),
        ("motion-now-change-low@2.5", "✓ draws"),
        ("motion-now-change-low@3.0", "settled"),
    ]),
    "7e-now-runway": ((0, 300, 394, 120), [
        ("motion-now-runway@1.4", "reset 01:12, now"),
        ("motion-now-runway@2.2", "reaches now · flash"),
        ("motion-now-runway@2.5", "the next pops in"),
        ("motion-now-runway@3.0", "settled"),
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
    scale = SCALE
    x, y, w, h = box
    hp = img.height / scale
    w = min(w, img.width / scale - x)
    if isinstance(y, str):
        y = hp / 2 + float(y[3:] or 0)
    elif y < 0:
        y = hp + y
    y = max(0, min(y, hp - h))
    return img.crop((int(x * scale), int(y * scale), int((x + w) * scale), int((y + h) * scale)))


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
