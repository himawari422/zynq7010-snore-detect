#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
calib.py — 呼噜声检测前端的阈值标定工具

它会依次采集三个场景（安静 / 说话 / 鼾声），统计 peak 与 mean_abs 的分位数，
然后直接算出 alarm_ctrl 的三个门限 TH_LV1/2/3 建议值，并给出十六进制字面量。

用法（最常用）：
    python calib.py COM7                 # 三段各 20 秒，按提示切换场景
    python calib.py COM7 --d 15,15,20    # 自定义三段时长
    python calib.py COM7 --no-prompt     # 不等待回车，直接连采三段
    python calib.py COM7 --patch         # 直接把建议值写回 rtl/snore_top.v

门限定义（见 rtl/alarm_ctrl.v）：
    peak > TH_LV1 -> LED1 亮        （"有声音"）
    peak > TH_LV2 -> LED2 亮 + 连续 4 帧触发蜂鸣器（"疑似鼾声"）
    peak > TH_LV3 -> LED3 亮        （"很响"）
"""
import argparse
import math
import os
import re
import sys
import time

import serial

LINE_RE = re.compile(r"F([0-9A-Fa-f]{4})\s+P([0-9A-Fa-f]{4})\s+A([0-9A-Fa-f]{4})")

HERE = os.path.dirname(os.path.abspath(__file__))
TOP_V = os.path.join(HERE, "..", "rtl", "snore_top.v")


# ----------------------------------------------------------------------
def capture(port, seconds, baud=115200):
    ser = serial.Serial(port, baud, timeout=0.1)
    ser.reset_input_buffer()
    buf = b""
    t0 = time.time()
    while time.time() - t0 < seconds:
        buf += ser.read(2048)
    ser.close()
    text = buf.decode("ascii", "replace")
    return [(int(a, 16), int(b, 16), int(c, 16)) for a, b, c in LINE_RE.findall(text)]


def pct(vals, p):
    if not vals:
        return 0
    s = sorted(vals)
    return s[min(len(s) - 1, int(len(s) * p))]


def summarize(rows):
    p = [r[1] for r in rows]
    a = [r[2] for r in rows]
    return {
        "n": len(rows),
        "P_p50": pct(p, 0.50), "P_p90": pct(p, 0.90), "P_p99": pct(p, 0.99), "P_max": pct(p, 1.0),
        "A_p50": pct(a, 0.50), "A_p90": pct(a, 0.90), "A_p99": pct(a, 0.99),
    }


def phase(name, port, secs, no_prompt, hint):
    print(f"\n===== {name} ({secs:.0f}s) =====")
    print(f"  要求：{hint}")
    if not no_prompt:
        try:
            input("  准备好了按回车开始 ...")
        except EOFError:
            pass
    print("  采集中", end="", flush=True)
    rows = capture(port, secs)
    print(" 完成")
    st = summarize(rows)
    print(f"  帧数={st['n']}  P50={st['P_p50']} P90={st['P_p90']} "
          f"P99={st['P_p99']} Pmax={st['P_max']}  |  A50={st['A_p50']} A90={st['A_p90']}")
    return st


def suggest(noise, voice, snore):
    base = max(noise["P_p99"], 8, noise["P_max"])
    sig = max(snore["P_p50"], snore["P_p90"])

    if sig <= base * 1.5:
        return None, base, sig

    lv1 = int(round(base * 1.5))
    lv2 = int(round(math.sqrt(base * sig)))          # 几何中点：对数尺度上的正中间
    lv3 = int(round(sig * 2.0))

    lv1 = max(lv1, 8)
    lv2 = max(lv2, lv1 + 8)
    lv3 = max(lv3, lv2 + 8)
    return (lv1, lv2, lv3), base, sig


def patch_top(lv1, lv2, lv3, path=TOP_V):
    if not os.path.exists(path):
        print(f"[!] 找不到 {path}，跳过回写")
        return False
    src = open(path, encoding="utf-8").read()
    out = re.sub(r"(\.TH_LV1\s*\(\s*)16'd\d+", r"\g<1>16'd%d" % lv1, src)
    out = re.sub(r"(\.TH_LV2\s*\(\s*)16'd\d+", r"\g<1>16'd%d" % lv2, out)
    out = re.sub(r"(\.TH_LV3\s*\(\s*)16'd\d+", r"\g<1>16'd%d" % lv3, out)
    open(path, "w", encoding="utf-8").write(out)
    print(f"[*] 已把 TH_LV1/2/3 = {lv1}/{lv2}/{lv3} 写回 {os.path.normpath(path)}")
    print("    重新生成比特流：")
    print("    vivado -mode batch -source scripts/build.tcl -tclargs <输出目录> impl")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port", nargs="?", default="COM7")
    ap.add_argument("--d", default="20,20,20", help="三段采集秒数，如 15,15,20")
    ap.add_argument("--no-prompt", action="store_true", help="不等待回车，连续采三段")
    ap.add_argument("--patch", action="store_true", help="把建议门限写回 rtl/snore_top.v")
    args = ap.parse_args()

    secs = [float(x) for x in args.d.split(",")]
    if len(secs) != 3:
        print("[!] --d 需要三个数，例如 --d 15,15,20")
        return 1

    print("=" * 62)
    print(" 呼噜声前端阈值标定")
    print(" 端口 %s  |  三段时长 %s 秒" % (args.port, secs))
    print("=" * 62)

    noise = phase("场景 1/3  安静房间", args.port, secs[0], args.no_prompt,
                  "人不要说话、不要动，空调风扇照常")
    voice = phase("场景 2/3  正常说话", args.port, secs[1], args.no_prompt,
                  "离麦克风 0.5~1m，用平常音量说话")
    snore = phase("场景 3/3  鼾声", args.port, secs[2], args.no_prompt,
                  "放鼾声录音或真人打鼾，麦克风距离 0.5~1m")

    total = noise["n"] + voice["n"] + snore["n"]
    if total == 0:
        print("\n[!] 一帧都没收到：先确认 bit 已下载、跳线在 PL 侧、串口 115200。")
        return 2

    res, base, sig = suggest(noise, voice, snore)
    print("\n" + "=" * 62)
    print(" 标定结果")
    print("=" * 62)
    print(f"  底噪上沿  base = {base:>6d}   (安静场景 P99)")
    print(f"  鼾声典型  sig  = {sig:>6d}   (鼾声场景 P50)")
    print(f"  信噪比    SNR  = {20*math.log10(max(sig,1)/max(base,1)):.1f} dB")
    print(f"  说话/底噪      = {voice['P_p50']/max(base,1):.1f} 倍")

    if res is None:
        print("\n[!] 鼾声没有明显高于底噪，暂不建议改门限。")
        print("    常见原因：麦克风没接好 / SEL 接错 / 声音太远 / 3V 没供上。")
        print(f"    现有门限保持 100 / 400 / 1200 即可先用着。")
        return 3

    lv1, lv2, lv3 = res
    print(f"\n  建议门限（十进制 / 十六进制）：")
    print(f"    TH_LV1 = {lv1:<6d} (0x{lv1:04X})   peak 超过它 -> LED1")
    print(f"    TH_LV2 = {lv2:<6d} (0x{lv2:04X})   peak 超过它 -> LED2 + 蜂鸣器")
    print(f"    TH_LV3 = {lv3:<6d} (0x{lv3:04X})   peak 超过它 -> LED3")
    print(f"\n  按这个设置，安静时不会误报，说话大约点亮 LED2，"
          f"鼾声点亮 LED3。")

    if args.patch:
        print()
        patch_top(lv1, lv2, lv3)
    else:
        print("\n  要自动写回源码，加 --patch 再跑一次。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
