#!/usr/bin/env python3
"""Gera o icone do app. Requer Pillow: python3 tool/make_icon.py

Saidas em assets/icon/:
  icon.png             quadrado cheio, usado no iOS e no Android antigo
  icon_foreground.png  so o desenho, com fundo transparente, para o icone adaptativo do Android
Depois rode: dart run flutter_launcher_icons
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

S = 4096  # desenha grande e reduz, para as bordas ficarem suaves
OUT = Path(__file__).resolve().parent.parent / "assets" / "icon"
BG_TOP, BG_BOTTOM = (23, 31, 46), (11, 15, 22)
TILE, TILE_LIVE = (38, 52, 76), (46, 66, 100)
ACCENT, ACCENT_DARK = (76, 154, 255), (28, 82, 170)
LIVE = (62, 207, 142)


def gradient(size, top, bottom):
    img = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        img.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img.resize((size, size))


def motif(scale=1.0):
    """O desenho: mural 2x2 com uma lente no centro e o ponto de ao vivo."""
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    c = S / 2
    half = S * 0.335 * scale
    gap = S * 0.030 * scale
    r = S * 0.060 * scale
    for ix in (0, 1):
        for iy in (0, 1):
            x0 = c - half if ix == 0 else c + gap / 2
            x1 = c - gap / 2 if ix == 0 else c + half
            y0 = c - half if iy == 0 else c + gap / 2
            y1 = c - gap / 2 if iy == 0 else c + half
            d.rounded_rectangle([x0, y0, x1, y1], radius=r, fill=TILE_LIVE if (ix, iy) == (0, 0) else TILE)
    # ponto de "ao vivo" no primeiro quadro
    dot = S * 0.034 * scale
    dx, dy = c - half + S * 0.075 * scale, c - half + S * 0.075 * scale
    d.ellipse([dx - dot, dy - dot, dx + dot, dy + dot], fill=LIVE)
    # lente: anel escuro que separa do mural, aro claro, vidro azul e reflexo
    for radius, color in ((0.250, (11, 15, 22)), (0.218, (230, 233, 238)), (0.178, (16, 22, 33))):
        rr = S * radius * scale
        d.ellipse([c - rr, c - rr, c + rr, c + rr], fill=color)
    glass = S * 0.140 * scale
    lens = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(lens)
    steps = 60
    for i in range(steps):
        t = i / (steps - 1)
        rr = glass * (1 - t * 0.85)
        col = tuple(round(ACCENT_DARK[k] + (ACCENT[k] - ACCENT_DARK[k]) * t) for k in range(3))
        ox, oy = -glass * 0.18 * t, -glass * 0.18 * t
        ld.ellipse([c - rr + ox, c - rr + oy, c + rr + ox, c + rr + oy], fill=col + (255,))
    layer.alpha_composite(lens)
    hl = S * 0.030 * scale
    hx, hy = c - glass * 0.42, c - glass * 0.42
    d = ImageDraw.Draw(layer)
    d.ellipse([hx - hl, hy - hl, hx + hl, hy + hl], fill=(255, 255, 255, 235))
    return layer


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    full = gradient(S, BG_TOP, BG_BOTTOM).convert("RGBA")
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.alpha_composite(motif())
    blurred = shadow.split()[3].filter(ImageFilter.GaussianBlur(S * 0.02))
    dark = Image.new("RGBA", (S, S), (0, 0, 0, 120))
    full.paste(dark, (0, int(S * 0.012)), blurred)
    full.alpha_composite(motif())
    full.convert("RGB").resize((1024, 1024), Image.LANCZOS).save(OUT / "icon.png")
    # no icone adaptativo o Android recorta as bordas: o desenho fica na zona segura central
    motif(scale=0.70).resize((1024, 1024), Image.LANCZOS).save(OUT / "icon_foreground.png")
    print("icones gerados em", OUT)


if __name__ == "__main__":
    main()
