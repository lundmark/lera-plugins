#!/usr/bin/env python3
"""Build original geometric pixel card fronts/back; no desktop game artwork is copied."""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1] / "images" / "playing"
GLYPHS = {
    "hearts": ("0110110", "1111111", "1111111", "0111110", "0011100", "0001000"),
    "diamonds": ("0001000", "0011100", "0111110", "1111111", "0111110", "0011100", "0001000"),
    "spades": ("0001000", "0011100", "0111110", "1111111", "1111111", "0101010", "0001000"),
    "clubs": ("0011100", "0011100", "1111111", "1111111", "0111110", "0001000", "0011100"),
}
FONT = ImageFont.load_default()
COLORS = {"hearts": "#c34645", "diamonds": "#c34645", "spades": "#223950", "clubs": "#223950"}


def glyph(draw, suit, x, y, scale, color):
    for row, line in enumerate(GLYPHS[suit]):
        for column, bit in enumerate(line):
            if bit == "1":
                left, top = x + column * scale, y + row * scale
                draw.rectangle((left, top, left + scale - 1, top + scale - 1), fill=color)


def base():
    image = Image.new("RGB", (64, 96), "#193c35")
    draw = ImageDraw.Draw(image)
    draw.rectangle((1, 1, 62, 94), fill="#efe9d5", outline="#bdac78", width=2)
    draw.rectangle((4, 4, 59, 91), outline="#d6c9a4")
    return image, draw


def front(suit, rank):
    image, draw = base()
    color = COLORS[suit]
    label = {11: "J", 12: "Q", 13: "K", 14: "A"}.get(rank, str(rank))
    draw.text((7, 5), label, font=FONT, fill=color)
    draw.text((45, 78), label, font=FONT, fill=color)
    glyph(draw, suit, 7, 17, 1, color)
    glyph(draw, suit, 49, 68, 1, color)
    if rank <= 10:
        columns = 1 if rank <= 3 else 2
        rows = (rank + columns - 1) // columns
        for index in range(rank):
            x = 25 if columns == 1 else 17 + (index % columns) * 19
            y = 29 + (index // columns) * max(9, 42 // max(1, rows - 1))
            glyph(draw, suit, x, y, 2 if rank <= 4 else 1, color)
    else:
        draw.rectangle((15, 29, 48, 65), outline=color, width=2)
        glyph(draw, suit, 21, 39, 3, color)
        draw.text((28, 27), label, font=FONT, fill=color)
    return image


def back():
    image, draw = base()
    draw.rectangle((5, 5, 58, 90), fill="#233951")
    for y in range(9, 88, 8):
        for x in range(9, 56, 8):
            draw.rectangle((x, y, x + 2, y + 2), fill="#5a8494")
    draw.rectangle((18, 31, 45, 64), fill="#d4b563", outline="#efe9d5", width=2)
    draw.text((28, 40), "B", font=FONT, fill="#233951")
    return image


def build():
    ROOT.mkdir(parents=True, exist_ok=True)
    for suit in GLYPHS:
        for rank in range(2, 15):
            front(suit, rank).resize((128, 192), Image.Resampling.NEAREST).save(ROOT / f"{suit}_{rank}.png")
    back().resize((128, 192), Image.Resampling.NEAREST).save(ROOT / "back.png")
    print("Built 52 original fronts and one back")


if __name__ == "__main__":
    build()
