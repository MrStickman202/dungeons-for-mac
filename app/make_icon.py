import struct, io, math
from PIL import Image, ImageDraw, ImageFilter

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# tile (macOS-style rounded square inside the 1024 canvas)
m, r = 100, 186
tile = Image.new("RGBA", (S, S), (0, 0, 0, 0))
grad = Image.new("RGBA", (S, S))
gd = ImageDraw.Draw(grad)
top, bot = (34, 24, 68), (10, 38, 52)
for y in range(S):
    t = y / (S - 1)
    gd.line([(0, y), (S, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,))

# stone bricks
bricks = Image.new("RGBA", (S, S), (0, 0, 0, 0))
bd = ImageDraw.Draw(bricks)
bh, bw = 72, 144
for row in range(0, S // bh + 1):
    y = row * bh
    bd.line([(0, y), (S, y)], fill=(255, 255, 255, 18), width=4)
    off = (bw // 2) if row % 2 else 0
    for x in range(-bw, S + bw, bw):
        bd.line([(x + off, y), (x + off, y + bh)], fill=(255, 255, 255, 18), width=4)
grad = Image.alpha_composite(grad, bricks)

# torch glow
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gl = ImageDraw.Draw(glow)
for i in range(60, 0, -1):
    rad = 9 * i
    a = int(4 + 120 * (1 - i / 60) ** 2)
    gl.ellipse([S / 2 - rad, S / 2 - rad + 40, S / 2 + rad, S / 2 + rad + 40], fill=(255, 140, 40, min(a, 140)))
glow = glow.filter(ImageFilter.GaussianBlur(40))
grad = Image.alpha_composite(grad, glow)

mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([m, m, S - m, S - m], radius=r, fill=255)
tile.paste(grad, (0, 0), mask)

# pixel sword, 16x16 grid (original design)
P = {
    'o': (40, 30, 30, 255),     # outline
    'w': (236, 242, 248, 255),  # blade light
    's': (168, 184, 204, 255),  # blade shade
    'g': (246, 190, 64, 255),   # gold
    'G': (190, 120, 30, 255),   # gold shade
    'b': (120, 72, 40, 255),    # grip
    'B': (82, 48, 28, 255),     # grip shade
}
cells = {}
for k in range(9):                       # blade, tip at top-right
    cells[(14 - k, 1 + k)] = 'w'
    cells[(15 - k, 1 + k)] = 's'
cells[(15, 0)] = 'w'
for (x, y) in [(2, 8), (3, 9), (4, 10), (6, 12), (7, 13)]:   # cross-guard
    cells[(x, y)] = 'g'
cells[(5, 11)] = 'G'
cells[(4, 12)] = 'b'; cells[(3, 13)] = 'B'                # grip
cells[(2, 14)] = 'g'; cells[(1, 15)] = 'G'                # pommel
grid = [['.'] * 16 for _ in range(16)]
for (x, y), c in cells.items():
    grid[y][x] = c
for y in range(16):
    for x in range(16):
        if grid[y][x] == '.' and any(0 <= x + dx < 16 and 0 <= y + dy < 16 and grid[y + dy][x + dx] not in '.o'
                                     for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
            grid[y][x] = 'o'
grid = [''.join(r) for r in grid]
cell = 36
ox = oy = (S - 16 * cell) // 2
sword = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(sword)
for yy, row in enumerate(grid):
    for xx, ch in enumerate(row):
        if ch in P:
            x0, y0 = ox + xx * cell, oy + yy * cell
            sd.rectangle([x0, y0, x0 + cell - 1, y0 + cell - 1], fill=P[ch])
# soft shadow
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow.paste((0, 0, 0, 150), (18, 26), sword.split()[3])
shadow = shadow.filter(ImageFilter.GaussianBlur(14))
tile = Image.alpha_composite(tile, Image.composite(shadow, Image.new("RGBA", (S, S), (0, 0, 0, 0)), mask))
tile = Image.alpha_composite(tile, sword)

# sparkles
sp = ImageDraw.Draw(tile)
for (x, y, s) in [(300, 260, 16), (720, 700, 12), (790, 560, 10), (260, 640, 10)]:
    sp.rectangle([x - s, y - s // 3, x + s, y + s // 3], fill=(255, 220, 140, 200))
    sp.rectangle([x - s // 3, y - s, x + s // 3, y + s], fill=(255, 220, 140, 200))

img = Image.alpha_composite(img, tile)
img.save("AppIcon-1024.png")

def png(size):
    b = io.BytesIO()
    img.resize((size, size), Image.LANCZOS).save(b, "PNG")
    return b.getvalue()

entries = [(b'icp4', 16), (b'icp5', 32), (b'icp6', 64), (b'ic07', 128), (b'ic08', 256),
           (b'ic09', 512), (b'ic10', 1024), (b'ic11', 32), (b'ic12', 64), (b'ic13', 256), (b'ic14', 512)]
body = b''.join(t + struct.pack('>I', 8 + len(d)) + d for t, d in ((t, png(s)) for t, s in entries))
open("AppIcon.icns", "wb").write(b'icns' + struct.pack('>I', 8 + len(body)) + body)
print("ok", len(body))
