#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 StockScope App 图标(1024x1024 PNG,纯标准库,无第三方依赖)。
主题:深色背景 + 红涨绿跌 K 线蜡烛图 + 上升趋势线,契合股票 App 定位。
用法: python tools/generate_icon.py
输出: StockScope/Assets.xcassets/AppIcon.appiconset/AppIcon.png
"""
import os
import struct
import zlib

W = H = 1024
OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "StockScope", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png",
)

# ---------- 画布 ----------
px = [[0, 0, 0] for _ in range(W * H)]


def set_px(x, y, rgb):
    if 0 <= x < W and 0 <= y < H:
        px[y * W + x] = rgb


def blend(dst, src, a):
    return [int(dst[i] * (1 - a) + src[i] * a) for i in range(3)]


# ---------- 背景:垂直渐变 #0B0F1A -> #151A2D ----------
TOP = (11, 15, 26)
BOT = (21, 26, 45)
for y in range(H):
    t = y / (H - 1)
    c = [int(TOP[i] * (1 - t) + BOT[i] * t) for i in range(3)]
    for x in range(W):
        px[y * W + x] = c

# ---------- 径向高光(中心偏上,增加质感) ----------
cx, cy, cr = W * 0.5, H * 0.36, W * 0.75
for y in range(H):
    for x in range(W):
        d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
        if d < cr:
            a = (1 - d / cr) ** 2 * 0.10
            px[y * W + x] = blend(px[y * W + x], (120, 150, 220), a)

# ---------- 工具函数 ----------
def line(x0, y0, x1, y1, rgb, thick=1):
    """Bresenham 直线(带厚度)"""
    x0, y0, x1, y1 = int(x0), int(y0), int(x1), int(y1)
    dx = abs(x1 - x0)
    dy = -abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx + dy
    while True:
        for t in range(-(thick // 2), thick - thick // 2):
            for tt in range(-(thick // 2), thick - thick // 2):
                set_px(x0 + t, y0 + tt, rgb)
        if x0 == x1 and y0 == y1:
            break
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x0 += sx
        if e2 <= dx:
            err += dx
            y0 += sy


def rect(x0, y0, x1, y1, rgb):
    for y in range(int(y0), int(y1) + 1):
        for x in range(int(x0), int(x1) + 1):
            set_px(x, y, rgb)


# ---------- 圆角裁剪蒙版 ----------
def rounded_mask(x, y, radius):
    """返回 (x,y) 是否在圆角矩形内(圆角半径 radius)"""
    if radius <= 0:
        return True
    if (radius <= x < W - radius) or (radius <= y < H - radius):
        return True
    # 四个角
    corners = [
        (radius, radius), (W - 1 - radius, radius),
        (radius, H - 1 - radius), (W - 1 - radius, H - 1 - radius),
    ]
    for ccx, ccy in corners:
        if (x - ccx) ** 2 + (y - ccy) ** 2 <= radius ** 2:
            return True
    return False

RAD = 230
for y in range(H):
    for x in range(W):
        if not rounded_mask(x, y, RAD):
            px[y * W + x] = [0, 0, 0]  # 透明由 alpha 通道控制,这里先标黑

# ---------- K 线蜡烛(红涨绿跌) ----------
RED = (255, 92, 92)
GREEN = (74, 222, 128)
UP = (255, 255, 255)

# 蜡烛数据: (x_center, open_y, close_y, high_y, low_y, 涨跌)
candles = [
    (230, 700, 620, 585, 720, 1),    # 涨
    (340, 620, 650, 660, 570, -1),   # 跌
    (450, 650, 540, 505, 680, 1),    # 涨
    (560, 540, 585, 610, 500, -1),   # 跌
    (670, 585, 430, 400, 610, 1),    # 涨
    (780, 430, 330, 300, 460, 1),    # 涨
]
CW = 46  # 蜡烛体半宽

for cx_, oy, cy_, hy, ly, up in candles:
    color = RED if up > 0 else GREEN
    # 影线
    line(cx_, hy, cx_, ly, color, thick=12)
    # 实体(实体最小高度避免空心)
    top, bot = min(oy, cy_), max(oy, cy_)
    if bot - top < 18:
        bot = top + 18
    rect(cx_ - CW, top, cx_ + CW, bot, color)

# 基准虚线
for x in range(150, 874, 26):
    line(x, 720, x + 13, 720, (154, 164, 178), thick=6)

# 上升趋势线(白色粗线,贯穿最新价)
line(150, 660, 874, 300, UP, thick=16)
# 趋势线箭头
line(874, 300, 820, 285, UP, thick=12)
line(874, 300, 852, 246, UP, thick=12)

# 当前价标签圆点
for r in (34, 22):
    for y in range(300 - r, 300 + r + 1):
        for x in range(874 - r, 874 + r + 1):
            if (x - 874) ** 2 + (y - 300) ** 2 <= r ** 2:
                set_px(x, y, RED)

# ---------- 写入 PNG ----------
raw = bytearray()
for y in range(H):
    raw.append(0)  # filter: None
    for x in range(W):
        r, g, b = px[y * W + x]
        a = 0 if (r == 0 and g == 0 and b == 0 and not rounded_mask(x, y, RAD)) else 255
        raw += struct.pack("BBBB", r, g, b, a)


def chunk(tag, data):
    c = struct.pack(">I", len(data)) + tag + data
    return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
png += chunk(b"IEND", b"")

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "wb") as f:
    f.write(png)
print("OK ->", OUT, os.path.getsize(OUT), "bytes")
