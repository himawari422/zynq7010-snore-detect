#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
plot_snore.py —— 实时读取串口上报的帧统计并画曲线

串口每行格式（PL 端 uart_report.v 输出，十六进制）：
    F0012 P01F4 A0033
      |     |     +-- A: 一帧(32ms)内 |pcm| 的平均值
      |     +-------- P: 一帧内 |pcm| 的峰值
      +-------------- F: 帧序号

依赖：
    pip install pyserial matplotlib

用法：
    python plot_snore.py --port COM3
    python plot_snore.py --port COM3 --save rec.csv
"""
import argparse
import re
import sys
import time
from collections import deque

try:
    import serial
except ImportError:
    print("缺少 pyserial，请先执行： pip install pyserial")
    sys.exit(1)

try:
    import matplotlib
    import matplotlib.pyplot as plt
except ImportError:
    print("缺少 matplotlib，请先执行： pip install matplotlib")
    sys.exit(1)

LINE_RE = re.compile(r"^F([0-9A-Fa-f]{4})\s+P([0-9A-Fa-f]{4})\s+A([0-9A-Fa-f]{4})\s*$")

N_KEEP = 500          # 保留最近 500 帧 = 16 秒
FRAME_S = 0.032       # 帧长


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM3")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--save", default=None, help="把原始数据存成 CSV")
    args = ap.parse_args()

    ser = serial.Serial(args.port, args.baud, timeout=1)
    print(f"已打开 {args.port} @ {args.baud}，按 Ctrl+C 退出")

    fcsv = open(args.save, "w", encoding="utf-8") if args.save else None
    if fcsv:
        fcsv.write("frame,peak,mean_abs\n")

    frames = deque(maxlen=N_KEEP)
    peaks = deque(maxlen=N_KEEP)
    means = deque(maxlen=N_KEEP)

    plt.ion()
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 6), sharex=True)
    fig.canvas.manager.set_window_title("呼噜声检测 — 实时监视")
    (l1,) = ax1.plot([], [], lw=1.0, color="#c0392b")
    (l2,) = ax2.plot([], [], lw=1.0, color="#2c3e50")
    ax1.set_ylabel("峰值 peak")
    ax2.set_ylabel("均值 mean_abs")
    ax2.set_xlabel("帧 (32ms/帧)")
    ax1.grid(alpha=0.3)
    ax2.grid(alpha=0.3)

    raw = b""
    n_ok = 0
    t0 = time.time()

    try:
        while True:
            raw += ser.read(256)
            while b"\n" in raw:
                line, raw = raw.split(b"\n", 1)
                txt = line.decode("ascii", errors="ignore").strip()
                m = LINE_RE.match(txt)
                if not m:
                    continue
                f, p, a = (int(g, 16) for g in m.groups())
                n_ok += 1
                frames.append(f)
                peaks.append(p)
                means.append(a)
                if fcsv:
                    fcsv.write(f"{f},{p},{a}\n")

            if n_ok and n_ok % 8 == 0:
                l1.set_data(range(len(peaks)), list(peaks))
                l2.set_data(range(len(means)), list(means))
                ax1.relim()
                ax1.autoscale_view()
                ax2.relim()
                ax2.autoscale_view()
                dt = time.time() - t0
                print(f"\r帧 {frames[-1]:5d} | 峰值 {peaks[-1]:6d} | 均值 {means[-1]:5d} "
                      f"| 有效 {n_ok} 行 | {n_ok/max(dt,1e-6):5.1f} 帧/秒", end="")
                fig.canvas.draw_idle()
                fig.canvas.flush_events()
                n_ok = 0
                t0 = time.time()
    except KeyboardInterrupt:
        print("\n退出")
    finally:
        if fcsv:
            fcsv.close()
            print(f"已保存 {args.save}")


if __name__ == "__main__":
    main()
