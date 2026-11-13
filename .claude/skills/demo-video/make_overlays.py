#!/usr/bin/env python3
"""Render demo-video overlays as transparent 1920x1080 PNGs.

This Mac's ffmpeg is built without the drawtext filter, so captions, the
"sped up" badge and the end card are drawn with Pillow and laid over the
video with ffmpeg's overlay filter.

    python3 make_overlays.py caption "Describe an effect. ConjureIDE builds it." out.png
    python3 make_overlays.py prompt  "Build a lo-fi tape echo ..." out.png
    python3 make_overlays.py badge   "Sped up 12x" out.png
    python3 make_overlays.py endcard out.png --icon assets/app-icon.png \
        --title ConjureIDE --line "Free and open source" --url conjuredsp.com/ide
"""
import argparse
import textwrap

from PIL import Image, ImageDraw, ImageFont

W, H = 1920, 1080
FONT = "/System/Library/Fonts/SFNS.ttf"

# Brand palette (assets/palette.md)
NAVY = (13, 15, 26)
CYAN = (0, 229, 255)
PINK = (255, 79, 216)
PURPLE = (176, 110, 255)
WHITE = (255, 255, 255)


def font(size, weight="Bold"):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


def text_size(draw, text, f):
    box = draw.textbbox((0, 0), text, font=f)
    return box[2] - box[0], box[3] - box[1], box[1]


def pill(draw, box, fill, outline=None, radius=24, width=3):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def caption(text, out, size=52, bottom=64, max_chars=48):
    """White bold text on a dark pill, bottom-centre, with a thin cyan edge."""
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    f = font(size)
    lines = textwrap.wrap(text, max_chars) or [text]
    line_h = int(size * 1.25)
    widths = [text_size(d, ln, f)[0] for ln in lines]
    pad_x, pad_y = 40, 22
    box_w = max(widths) + 2 * pad_x
    box_h = line_h * len(lines) + 2 * pad_y - (line_h - size)
    x0 = (W - box_w) // 2
    y0 = H - bottom - box_h
    pill(d, (x0, y0, x0 + box_w, y0 + box_h), fill=NAVY + (225,), outline=CYAN + (170,))
    y = y0 + pad_y
    for ln, w in zip(lines, widths):
        _, _, top = text_size(d, ln, f)
        d.text(((W - w) // 2, y - top), ln, font=f, fill=WHITE)
        y += line_h
    img.save(out)


def prompt(text, out, size=40, bottom=64, max_chars=64):
    """The typed request, shown as a quote so it stays readable when the
    terminal text on screen is small."""
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    f = font(size, "Medium")
    label_f = font(26, "Semibold")
    lines = textwrap.wrap(f"“{text}”", max_chars)
    line_h = int(size * 1.3)
    widths = [text_size(d, ln, f)[0] for ln in lines]
    label = "YOU TYPE"
    lw, lh, ltop = text_size(d, label, label_f)
    pad_x, pad_y = 40, 22
    box_w = max(max(widths), lw) + 2 * pad_x
    box_h = lh + 18 + line_h * len(lines) + 2 * pad_y - (line_h - size)
    x0 = (W - box_w) // 2
    y0 = H - bottom - box_h
    pill(d, (x0, y0, x0 + box_w, y0 + box_h), fill=NAVY + (230,), outline=PINK + (190,))
    d.text((x0 + pad_x, y0 + pad_y - ltop), label, font=label_f, fill=PINK)
    y = y0 + pad_y + lh + 18
    for ln in lines:
        _, _, top = text_size(d, ln, f)
        d.text((x0 + pad_x, y - top), ln, font=f, fill=WHITE)
        y += line_h
    img.save(out)


def badge(text, out, size=34, margin=40):
    """Small magenta pill in the top-right corner, e.g. 'Sped up 12x'."""
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    f = font(size)
    label = "▶▶  " + text
    w, h, top = text_size(d, label, f)
    pad_x, pad_y = 26, 14
    x1 = W - margin
    x0 = x1 - w - 2 * pad_x
    y0 = margin
    pill(d, (x0, y0, x1, y0 + h + 2 * pad_y), fill=PINK + (235,), radius=20)
    d.text((x0 + pad_x, y0 + pad_y - top), label, font=f, fill=WHITE)
    img.save(out)


def endcard(out, icon, title, line, url):
    img = Image.new("RGBA", (W, H), NAVY + (255,))
    d = ImageDraw.Draw(img)
    # Soft radial-ish glow behind the icon
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for i, r in enumerate(range(420, 0, -12)):
        a = int(40 * (1 - r / 420) ** 1.5)
        gd.ellipse((W // 2 - r, 330 - r, W // 2 + r, 330 + r), fill=PURPLE + (a,))
    img = Image.alpha_composite(img, glow)
    d = ImageDraw.Draw(img)
    ic = Image.open(icon).convert("RGBA").resize((340, 340), Image.LANCZOS)
    img.alpha_composite(ic, ((W - 340) // 2, 160))
    tf, lf, uf = font(112, "Heavy"), font(48, "Medium"), font(52, "Semibold")
    y = 545
    for txt, f, col, gap in ((title, tf, WHITE, 40), (line, lf, (200, 205, 225), 34), (url, uf, CYAN, 0)):
        w, h, top = text_size(d, txt, f)
        d.text(((W - w) // 2, y - top), txt, font=f, fill=col)
        y += h + gap
    img.convert("RGB").save(out)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("caption", "prompt", "badge"):
        s = sub.add_parser(name)
        s.add_argument("text")
        s.add_argument("out")
    e = sub.add_parser("endcard")
    e.add_argument("out")
    e.add_argument("--icon", required=True)
    e.add_argument("--title", default="ConjureIDE")
    e.add_argument("--line", default="Free and open source")
    e.add_argument("--url", default="conjuredsp.com/ide")
    a = p.parse_args()
    if a.cmd == "caption":
        caption(a.text, a.out)
    elif a.cmd == "prompt":
        prompt(a.text, a.out)
    elif a.cmd == "badge":
        badge(a.text, a.out)
    else:
        endcard(a.out, a.icon, a.title, a.line, a.url)


if __name__ == "__main__":
    main()
