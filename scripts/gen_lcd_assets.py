#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_lcd_assets.py — 生成 LCD 显示用的字库与文本层 Verilog

为什么用脚本生成而不是手写：
    8x16 点阵如果手工敲十六进制，一个字写错就是屏幕上多一个麻点，
    而且改文案（比如把 "SNORE DETECT" 改成别的）要重新算几十个数。
    这里用 PIL 从系统等宽字体渲染，改字只需改下面的 TEXT 表。

产出：
    rtl/font_rom.v     — 8x16 ASCII 点阵，function 形式，综合成 LUT
    rtl/text_layer.v   — 静态文字层：屏幕坐标 -> 字符码

用法：
    python scripts/gen_lcd_assets.py
"""
import os

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.join(HERE, "..", "rtl")

FONT_PATH = "C:/Windows/Fonts/consolab.ttf"   # 粗体：小屏上 1px 细笔画像虚影，粗体清楚得多
FONT_SIZE = 17
FONT_OFF = (0, 0)          # 在 8x16 单元内的绘制偏移

GLYPH_W, GLYPH_H = 8, 16


# ---------------------------------------------------------------------------
# 屏幕布局（单位：字符单元，每个 8x16 像素）
#   800 / 8 = 100 列，480 / 16 = 30 行
# ---------------------------------------------------------------------------
TEXT = [
    (2,  1,  "SNORE  DETECT"),
    (84, 1,  "ATK-4384"),
    (82, 4,  "LOUD"),
    (82, 6,  "LONG"),
    (82, 8,  "RHYTHM"),
    (82, 17, "CNT"),
    (82, 19, "ENV"),
    (82, 21, "RHY"),
    (2,  28, "TH 525   MIN 8   GAP 9   SHIFT 4   WIN 20S"),
]

# ---------------------------------------------------------------------------
# 报告页（按 key[0] 切换）
#
#   三档建议各占两行，分别放在 17/18、20/21、23/24 行。
#   显示时把行号加上 3*level 再查表 —— 于是不管哪一档，
#   最终都落在屏幕上同一个位置（17/18 行），位置不会随等级上下跳。
# ---------------------------------------------------------------------------
TEXT_REPORT = [
    (2,  1,  "SNORE  REPORT"),
    (84, 1,  "ATK-4384"),

    (8,  4,  "EVENTS"),
    (8,  7,  "RATE /H"),
    (8,  10, "SNORE %"),
    (8,  13, "SILENCE"),
    (8,  15, "LEVEL"),

    # level = 0  （轻微）
    (6,  19, "MILD: KEEP A REGULAR SLEEP SCHEDULE."),
    (6,  20, "AVOID ALCOHOL BEFORE BEDTIME."),
    # level = 1  （中等）
    (6,  22, "MODERATE: TRY SLEEPING ON YOUR SIDE."),
    (6,  23, "KEEP THE ROOM HUMID, AVOID ALCOHOL."),
    # level = 2  （偏重）
    (6,  25, "HEAVY: CONSIDER A SLEEP STUDY CONSULT."),
    (6,  26, "AVOID ALCOHOL, KEEP THE ROOM HUMID."),

    (2,  27, "SCREENING ONLY - NOT A MEDICAL DIAGNOSIS."),
]

# 出现过的所有字符都要有字形
CHARSET = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:-=./%()+,"


def render_glyph(ch):
    """把一个字符渲染成 16 字节（每字节一行，bit7=最左像素）"""
    font = ImageFont.truetype(FONT_PATH, FONT_SIZE)
    im = Image.new("1", (GLYPH_W, GLYPH_H), 0)
    ImageDraw.Draw(im).text(FONT_OFF, ch, font=font, fill=1)
    px = im.load()
    rows = []
    for y in range(GLYPH_H):
        v = 0
        for x in range(GLYPH_W):
            if px[x, y]:
                v |= 1 << (7 - x)
        rows.append(v)
    return rows


def gen_font():
    lines = [
        "//=============================================================================",
        "// font_rom.v  —  8x16 ASCII 点阵（由 scripts/gen_lcd_assets.py 自动生成，勿手改）",
        "//",
        "//   接口刻意做成 function 形式而不是 RAM：",
        "//     需要的是\"任意坐标随时取一个字节\"，用组合逻辑查表最直接，",
        "//     综合成 LUT 后约 100 个 LUT6，比开一块 BRAM 更省事（也省一次读延迟）。",
        "//",
        "//   bits[7] 是最左边的像素，bits[0] 是最右边。",
        "//=============================================================================",
        "`timescale 1ns / 1ps",
        "",
        "module font_rom (",
        "    input  wire [7:0] ch,      // ASCII 字符码",
        "    input  wire [3:0] row,     // 0~15 行",
        "    output wire [7:0] bits     // 该行的 8 个像素",
        ");",
        "",
        "    reg [127:0] g;",
        "",
        "    always @(*) begin",
        "        case (ch)",
    ]
    for ch in CHARSET:
        rows = render_glyph(ch)
        val = 0
        for i, r in enumerate(rows):
            val |= r << (i * 8)          # row0 放在最低字节
        lines.append("            8'h%02X: g = 128'h%032X;  // '%s'"
                     % (ord(ch), val, ch if ch != " " else "space"))
    lines += [
        "            default: g = 128'd0;",
        "        endcase",
        "    end",
        "",
        "    // row*8 就是该行在 128 位常量里的起始位",
        "    assign bits = g[({row, 3'b000}) +: 8];",
        "",
        "endmodule",
        "",
    ]
    path = os.path.join(RTL, "font_rom.v")
    open(path, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
    return path


def gen_text_layer(mod_name, text_list, out_name, note=""):
    cells = {}
    for col0, row, s in text_list:
        for i, ch in enumerate(s):
            cells[(row, col0 + i)] = ord(ch)

    lines = [
        "//=============================================================================",
        "// %s  —  静态文字层（由 scripts/gen_lcd_assets.py 自动生成，勿手改）" % out_name,
        "//",
        "//   输入字符单元坐标（col 0~99，row 0~29），输出该单元要显示的字符码。",
        "//   没写字的地方一律返回空格，字库里空格是全零，画出来就是背景。",
        "//",
        "//   只存\"有字的格子\"，所以综合出来是一堆比较器，约 %d 个单元。" % len(cells),
    ]
    if note:
        lines += ["//", "//   " + note]
    lines += [
        "//=============================================================================",
        "`timescale 1ns / 1ps",
        "",
        "module %s (" % mod_name,
        "    input  wire [6:0] col,     // 0~99",
        "    input  wire [4:0] row,     // 0~29",
        "    output reg  [7:0] ch",
        ");",
        "",
        "    always @(*) begin",
        "        ch = 8'h20;             // 默认空格",
        "        case ({row, col})",
    ]
    for (row, col), c in sorted(cells.items()):
        key = (row << 7) | col
        lines.append("            12'd%-5d: ch = 8'h%02X;  // '%s'"
                     % (key, c, chr(c) if chr(c) != " " else "space"))
    lines += [
        "            default: ch = 8'h20;",
        "        endcase",
        "    end",
        "",
        "endmodule",
        "",
    ]
    path = os.path.join(RTL, out_name)
    open(path, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
    return path, len(cells)


if __name__ == "__main__":
    p1 = gen_font()
    p2, n = gen_text_layer("text_layer", TEXT, "text_layer.v")
    p3, m = gen_text_layer(
        "text_layer_report", TEXT_REPORT, "text_layer_report.v",
        note="建议文案三档分别放在 17/18、20/21、23/24 行，显示时按 level 加行偏移取用。")
    print("[OK] %s" % p1)
    print("[OK] %s  (%d 个字符单元)" % (p2, n))
    print("[OK] %s  (%d 个字符单元)" % (p3, m))

    # 顺手把标题打出来，肉眼确认字形没糊
    print("\n预览 \"SNORE\":")
    for r in range(16):
        line = ""
        for ch in "SNORE":
            rows = render_glyph(ch)
            line += "".join("#" if rows[r] & (1 << (7 - x)) else "." for x in range(8))
        print("  " + line)
