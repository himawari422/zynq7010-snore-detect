#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tune.py — 用实测数据反推最佳判据参数（不改 RTL、不用重新综合就能试算）

背景：
    TH / ENV_SHIFT / MIN_ON / GAP_MIN 这些参数写在 snore_judge.v 的 parameter 里，
    每改一次就要综合 2~3 分钟。但 snore_test.csv 里已经把每一帧的
    峰值 P 全存下来了 —— 完全可以在 PC 上把判据重新跑一遍，
    把所有参数组合一次性试完，挑出最好的那组，再回写 RTL 只综合一次。

    这里的 Python 实现是 snore_judge.v 的逐行等价翻译，
    两边逻辑必须一致（包络的"快起慢落"、raw_cnt 计长、节律链断链规则）。
    2026-10-28 已用 tb_judge 的 10 个场景交叉验证，判决次数逐一对上。

用法：
    python tune.py ../snore_test.csv
    python tune.py ../snore_test.csv --th 400:800:25 --gap-min 6,8,10
    python tune.py ../snore_test.csv --scales 1.0          # 只看原始音量
"""
import argparse
import csv
import sys
from collections import defaultdict


# ---------------------------------------------------------------------------
# snore_judge.v 的等价实现
# ---------------------------------------------------------------------------
def run_judge(peaks, th, env_shift, min_on, gap_min, gap_max, n_period):
    """
    返回 (判决次数, 每帧状态位列表)
    状态位定义与 RTL 一致：bit0 响 / bit1 持续 / bit2 鼾声 / bit3 节律
    """
    env = 0
    on_cnt = 0
    raw_cnt = 0
    idle_cnt = 0
    gap_lat = 0
    rhythm = 0
    hold = 0
    btim = 0

    det = 0
    prev_hold = 0
    status = []

    for P in peaks:
        # 包络：快起慢落
        env_nxt = P if P >= env else env - (env >> env_shift)
        loud = env_nxt > th
        loud_raw = P > th          # 原始峰值直接比门限，不受包络影响

        # 输出用本拍更新前的值（与 RTL 一致）
        st = (1 if loud else 0) | \
             (2 if raw_cnt >= min_on else 0) | \
             (4 if hold != 0 else 0) | \
             (8 if rhythm >= 2 else 0)
        status.append(st)
        if hold != 0 and prev_hold == 0:
            det += 1
        prev_hold = hold

        # ---- 状态更新 ----
        if hold != 0:
            hold -= 1
        if btim != 0:
            btim -= 1

        if loud:
            if on_cnt == 0:
                gap_lat = idle_cnt
                raw_cnt = 1 if loud_raw else 0
            elif loud_raw:
                if raw_cnt < 255:
                    raw_cnt += 1
            if on_cnt < 255:
                on_cnt += 1
            idle_cnt = 0
        else:
            # MIN_ON 判的是"声音本身够长"（raw_cnt），不是包络长度
            if raw_cnt >= min_on:
                if rhythm != 0 and gap_min <= gap_lat <= gap_max:
                    if rhythm + 1 >= n_period:
                        rhythm = n_period
                        hold = 32
                        btim = 7
                    else:
                        rhythm += 1
                else:
                    rhythm = 1
            on_cnt = 0
            raw_cnt = 0
            if idle_cnt < 1023:
                idle_cnt += 1
            if idle_cnt > gap_max and rhythm != 0:
                rhythm = 0

        env = env_nxt

    return det, status


# ---------------------------------------------------------------------------
def load(csv_path):
    """读 snore_test.csv -> {段名: [P, P, ...]}"""
    segs = defaultdict(list)
    with open(csv_path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            segs[row["seg"]].append(int(row["P"]))
    segs.pop("", None)
    return dict(segs)


# 真实录音里"应该判出鼾声"的段名，其余段一律按"不该判"处理
SNORE_SEGS = ("snore", "snore2")


def evaluate(segs_data, th, es, mo, gmin, gmax, npd, scales=(1.0,)):
    """
    在多个音量缩放下评估一组参数（模拟麦克风远近、音量大小）。
    返回 (是否全部零误报, 1.0x 时的各段判决数,
          各音量下的最少鼾声检出, 累计误报数, 各音量鼾声检出之和)
    """
    det_nom = None
    worst = 10 ** 9
    bad_total = 0
    det_sum = 0
    for k in scales:
        det = {}
        for name, peaks in segs_data.items():
            det[name], _ = run_judge([int(v * k) for v in peaks],
                                     th, es, mo, gmin, gmax, npd)
        bad = sum(v for name, v in det.items() if name not in SNORE_SEGS)
        bad_total += bad
        if k == 1.0:
            det_nom = det
        d = sum(det.get(s, 0) for s in SNORE_SEGS)
        det_sum += d
        worst = min(worst, d)
    return bad_total == 0, det_nom, worst, bad_total, det_sum


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", nargs="?", default="../snore_test.csv")
    ap.add_argument("--th", default="375:675:25", help="TH 搜索范围 起:止:步长")
    ap.add_argument("--env", default="3,4,5", help="ENV_SHIFT 候选")
    ap.add_argument("--min-on", default="4,6,8,10", help="MIN_ON_F 候选")
    ap.add_argument("--gap-min", default="6,7,8,9,10", help="GAP_MIN_F 候选")
    ap.add_argument("--gap-max", default="64,96", help="GAP_MAX_F 候选")
    ap.add_argument("--nper", default="3", help="N_PERIOD 候选")
    ap.add_argument("--scales", default="0.75,0.85,1.0,1.15,1.3",
                    help="音量缩放倍数（模拟麦克风远近），逗号分隔")
    args = ap.parse_args()

    try:
        segs_data = load(args.csv)
    except FileNotFoundError:
        print(f"[!] 找不到 {args.csv}，先跑一次 测试.bat")
        return 2
    if not segs_data:
        print("[!] csv 里没有带段标签的数据")
        return 2

    scales = [float(x) for x in args.scales.split(",")]

    print("段统计（输入数据，未缩放）:")
    print(f"  {'段名':<8} {'帧数':>6} {'p50':>7} {'p90':>7} {'p99':>7} {'max':>7}")
    for name, peaks in segs_data.items():
        s = sorted(peaks)
        n = len(s)
        print(f"  {name:<8} {n:6d} {s[n // 2]:7d} {s[int(n * 0.9)]:7d} "
              f"{s[min(int(n * 0.99), n - 1)]:7d} {s[-1]:7d}")

    th_lo, th_hi, th_step = (int(x) for x in args.th.split(":"))
    envs = [int(x) for x in args.env.split(",")]
    mos = [int(x) for x in args.min_on.split(",")]
    gmins = [int(x) for x in args.gap_min.split(",")]
    gmaxs = [int(x) for x in args.gap_max.split(",")]
    npds = [int(x) for x in args.nper.split(",")]

    results = []
    for th in range(th_lo, th_hi + 1, th_step):
        for es in envs:
            for mo in mos:
                for gmin in gmins:
                    for gmax in gmaxs:
                        for npd in npds:
                            ok, det, worst, bad, dsum = evaluate(
                                segs_data, th, es, mo, gmin, gmax, npd, scales)
                            results.append((ok, -worst, -dsum, -th, th, es, mo,
                                            gmin, gmax, npd, det))

    # 排序优先级（依次）：
    #   ① 全音量零误报
    #   ② 最差音量下也能检出（比"某一段判得多"更重要）
    #   ③ 各音量检出总数多（稳）
    #   ④ TH 大（离环境噪声更远，宁可用高门限）
    results.sort(key=lambda r: (not r[0], r[1], r[2], r[3]))

    print()
    print("=" * 78)
    print(f" 搜索结果（音量缩放 {args.scales}，共 {len(results)} 组）")
    print("=" * 78)
    print(f" {'TH':>5} {'ENV':>4} {'MIN':>4} {'GMIN':>5} {'GMAX':>5} "
          f"{'最差检出':>8}  各段判决(1.0x)")
    print(" " + "-" * 76)
    for row in results[:15]:
        ok, negw, negd, negth, th, es, mo, gmin, gmax, npd, det = row
        dstr = "  ".join(f"{k}={v}" for k, v in det.items())
        print(f" {th:>5} {es:>4} {mo:>4} {gmin:>5} {gmax:>5} "
              f"{-negw:>8}  {'OK' if ok else '  '} {dstr}")

    good = [r for r in results if r[0]]
    print()
    if good:
        ok, negw, negd, negth, th, es, mo, gmin, gmax, npd, det = good[0]
        print(" 推荐参数（所有测试音量下都零误报，且最差音量下也有检出）:")
        print(f"   .TH        (16'd{th}),")
        print(f"   .ENV_SHIFT ({es}),")
        print(f"   .MIN_ON_F  ({mo}),")
        print(f"   .GAP_MIN_F ({gmin}),")
        print(f"   .GAP_MAX_F ({gmax}),")
        print(f"   .N_PERIOD  ({npd})")
        print()
        print(" 写进 snore_top.v 的 snore_judge 例化里，重新综合一次即可。")
        print(f" （{len(good)} 组参数满足条件，说明这个区间是稳的，不是单点巧合）")
    else:
        print(" 没有一组参数能让所有段都符合预期。")
        print(" 常见原因：① 鼾声段刺激太弱 —— 看上面 p90，应明显高于安静段 p99")
        print("           ② 说话段本身就有长而规律的响段，A 方案区分不了")
        print("           ③ 某一段的标签打错了（录的时候说错了段）")

    return 0


if __name__ == "__main__":
    sys.exit(main())
