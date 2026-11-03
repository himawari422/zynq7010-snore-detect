#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
snore_mon.py — 读取 领航者 ZYNQ7010 呼噜声前端的串口输出

用法:
    python snore_mon.py COM7 5            # 读 5 秒，打印原始行 + 统计
    python snore_mon.py COM7 30 --csv x.csv

串口帧格式（来自 uart_report.v，v2 带包络与调试字段，v4 带页面回显）：
    F0012 P01F4 A0033 E02A1 S9 C0E R2 G0
    F = 帧号, P = 帧内峰值, A = 帧内平均绝对值 (十六进制, 满量程 0x7FFF)
    E = 响度包络, C = 当前 burst 内原始超阈帧数（MIN_ON 判的就是它）, R = 已积累节律次数
    S = 判据状态位 (十六进制):
        bit0 = 响度包络超过门限
        bit1 = 已连续超阈够长（一次有效声事件）
        bit2 = 判定为鼾声
        bit3 = 已进入节律链
    G = 页面回显 (可缺省，老固件没有):
        bit3    = 当前页 0 实时 / 1 报告
        bit2..0 = 已收到的合法串口命令数（3 位循环）
"""
import sys
import time
import re
import argparse
import os

import serial

# 兼容 v1（只有 F/P/A/S）、v2（多了 E/C/R）与 v4（多了 G）三种帧
LINE_RE = re.compile(
    r"F([0-9A-Fa-f]{4})\s+P([0-9A-Fa-f]{4})\s+A([0-9A-Fa-f]{4})"
    r"(?:\s+E([0-9A-Fa-f]{4}))?(?:\s+S([0-9A-Fa-f]))?"
    r"(?:\s+C([0-9A-Fa-f]{2}))?(?:\s+R([0-9A-Fa-f]))?"
    r"(?:\s+G([0-9A-Fa-f]))?"
)

BIT_NAMES = ["响", "持续", "鼾声", "节律"]


def collect(port, seconds, baud=115200):
    ser = serial.Serial(port, baud, timeout=0.1)
    ser.reset_input_buffer()
    buf = b""
    t0 = time.time()
    while time.time() - t0 < seconds:
        buf += ser.read(512)
    ser.close()
    return buf


def parse(buf):
    rows = []
    for m in LINE_RE.finditer(buf.decode("ascii", "replace")):
        g = [int(x, 16) if x else 0 for x in m.groups()]
        # g = [frame, P, A, E, S, C, R, G]
        rows.append(tuple(g))
    return rows


def stats(vals):
    if not vals:
        return None
    s = sorted(vals)
    n = len(s)
    return {
        "n": n, "min": s[0], "p50": s[n // 2],
        "p90": s[int(n * 0.9)], "p99": s[min(n - 1, int(n * 0.99))],
        "max": s[-1], "mean": round(sum(s) / n, 1),
    }


def bits_str(st):
    if st == 0:
        return "-"
    return "|".join(BIT_NAMES[i] for i in range(4) if st >> i & 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port", nargs="?", default="COM7")
    ap.add_argument("seconds", nargs="?", type=float, default=5.0)
    ap.add_argument("--csv", default=None, help="把解析到的帧追加写入 csv")
    args = ap.parse_args()

    print(f"[*] 打开 {args.port} @115200，采集 {args.seconds} 秒 ...")
    buf = collect(args.port, args.seconds)
    rows = parse(buf)

    print(f"[*] 收到 {len(buf)} 字节，解析到 {len(rows)} 帧")
    if not rows:
        print("[!] 没有解析到任何合法帧。")
        print("    前 300 字节原始内容 (repr):")
        print("   ", buf[:300])
        return 2

    print("\n前 5 帧 / 后 3 帧:")
    for r in rows[:5] + rows[-3:]:
        print(f"    F{r[0]:04X}  P={r[1]:5d}  A={r[2]:5d}  E={r[3]:5d}"
              f"  S={r[4]:X} {bits_str(r[4]):<10} C={r[5]:3d}  R={r[6]}"
              f"  G={r[7]:X} ({'报告页' if r[7] >> 3 & 1 else '实时页'})")

    frames = [r[0] for r in rows]
    gaps = sum(1 for i in range(1, len(frames))
               if frames[i] != (frames[i - 1] + 1) % 0x10000)
    print(f"\n帧号连续性: 跳变 {gaps} 次 / {len(frames)-1} 个间隔"
          f"  -> {'正常' if gaps == 0 else '有丢帧'}")

    sp, sa = stats([r[1] for r in rows]), stats([r[2] for r in rows])
    se = stats([r[3] for r in rows])
    print("\n峰值 P 统计: " + "  ".join(f"{k}={v}" for k, v in sp.items()))
    print("均值 A 统计: " + "  ".join(f"{k}={v}" for k, v in sa.items()))
    print("包络 E 统计: " + "  ".join(f"{k}={v}" for k, v in se.items()))

    #---- 判据统计 ----
    n_det = 0
    prev = 0
    for r in rows:
        if (r[4] >> 2) & 1 and not (prev >> 2) & 1:
            n_det += 1
        prev = r[4]
    n_evt = sum(1 for r in rows if (r[4] >> 1) & 1)
    n_loud = sum(1 for r in rows if r[4] & 1)
    print("\n判据统计:")
    print(f"    响度超阈帧 : {n_loud:4d} / {len(rows)}  ({100.0*n_loud/len(rows):.0f}%)")
    print(f"    持续事件帧 : {n_evt:4d} / {len(rows)}")
    print(f"    最长 burst : {max(r[5] for r in rows):4d} 帧"
          f"   最大节律 : {max(r[6] for r in rows)}")
    print(f"    鼾声判决次数: {n_det} 次")
    if n_det:
        print("    >>> 本次采集判定为鼾声 <<<")

    # 页面状态（v4 固件才有 G 字段，老固件这里是 0）
    g_last = rows[-1][7]
    pages = {r[7] >> 3 & 1 for r in rows}
    print(f"    页面（末帧）: {'报告页' if g_last >> 3 & 1 else '实时页'}"
          f"   采集中出现过: {len(pages)} 种")
    print(f"    串口命令计数: {g_last & 0x7}（0 表示期间没收到过电脑下发的命令）")

    if args.csv:
        new = not os.path.exists(args.csv)
        with open(args.csv, "a", encoding="utf-8") as f:
            if new:
                f.write("frame,P,A,E,S,C,R\n")
            for r in rows:
                f.write(",".join(str(x) for x in r) + "\n")
        print(f"\n[*] 已追加 {len(rows)} 帧到 {args.csv}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
