#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
snore_test.py — 带时间同步提示的分段鼾声测试

解决的问题：
    之前是「发一句开始，然后盲采 20 秒」——你不知道什么时候开始采、
    每一段该持续多久、发完声音什么时候结束，采回来的数据混在一起，
    判据失效时也分不清是"没检出"还是"根本没录到"。

这个脚本的做法：
    1. 分 6 段依次进行，每段开始时在屏幕上提示「现在该做什么」；
    2. 整段倒计时在屏幕上实时刷新，你随时知道还剩几秒；
    3. 正式测试前先做一次「音量预检」：你放 6 秒鼾声录音，
       脚本量一下包络峰值，声音太小就当场提示你调音量重试；
    4. 每段结束立刻打印这一段的统计，并和"预期"对比。

鼾声刺激由你自己播放（手机外放最方便），脚本只负责计时和判定。
全程只输出 ASCII 符号，中文提示在 GBK / UTF-8 控制台下都能正常显示。

用法：
    python snore_test.py COM7                # 完整测试，约 106 秒
    python snore_test.py COM7 --fast         # 缩短版
    python snore_test.py COM7 --skip-check   # 跳过音量预检

依赖：pyserial
"""
import argparse
import math
import re
import sys
import threading
import time

try:
    import serial
except ImportError:
    print("[!] 缺少 pyserial，请先执行: pip install pyserial")
    sys.exit(1)

# ---------------------------------------------------------------------------
# 串口帧：F0012 P01F4 A0033 E02A1 S9 C0E R2 G0
#   G 字段是 v4 固件才有的（页号 + 命令计数），老固件没有，这里做成可选
# ---------------------------------------------------------------------------
FRAME_RE = re.compile(
    r"F([0-9A-Fa-f]{4})\s+P([0-9A-Fa-f]{4})\s+A([0-9A-Fa-f]{4})"
    r"\s+E([0-9A-Fa-f]{4})\s+S([0-9A-Fa-f])\s+C([0-9A-Fa-f]{2})\s+R([0-9A-Fa-f])"
    r"(?:\s+G([0-9A-Fa-f]))?"
)

BIT_NAMES = ["响", "持续", "鼾声", "节律"]

# key, 名称, 标准时长, 提示语, 预期是否有鼾声判决
SEGMENTS_FULL = [
    ("prep",   "准备",      6,  "什么都不用做。确认下面的倒计时在走，说明串口通了。", 0),
    ("quiet",  "基线安静",  15, "保持安静。不要说话、不要碰桌子、不要移动麦克风。", 0),
    ("speech", "正常说话",  15, "用平常音量连续说话（念一段文字最好），中间可以有停顿。", 0),
    ("clap",   "拍手/敲桌", 10, "每隔 1 秒拍一次手，或者用笔敲桌子。声音要脆。", 0),
    ("snore",  "鼾声刺激",  48, "现在开始播放你的鼾声录音：外放、音量最大，"
                                "麦克风离喇叭 10~15cm，全程不要停。", 1),
    ("quiet2", "收尾安静",  10, "停止播放，保持安静。", 0),
]

SEGMENTS_FAST = [
    ("prep",   "准备",      4,  "什么都不用做，确认倒计时在走。", 0),
    ("quiet",  "基线安静",  8,  "保持安静，不要说话。", 0),
    ("speech", "正常说话",  8,  "连续说几句话。", 0),
    ("clap",   "拍手/敲桌", 6,  "每隔 1 秒拍一次手。", 0),
    ("snore",  "鼾声刺激",  30, "播放你的鼾声录音：外放、最大音量、麦克风靠近。", 1),
    ("quiet2", "收尾安静",  6,  "停止播放，保持安静。", 0),
]

# 判据里的响度门限（与 snore_judge.v / snore_top.v 的 TH 保持一致），用于提示
#   2026-10-28 实测标定后从 400 改到 525，这里必须同步，否则提示文字会误导调参
TH_RTL = 525


# ---------------------------------------------------------------------------
# 串口读取线程
# ---------------------------------------------------------------------------
class Reader(threading.Thread):
    def __init__(self, port, baud):
        super().__init__(daemon=True)
        self.ser = serial.Serial(port, baud, timeout=0.2)
        self.ser.reset_input_buffer()
        self.rows = []                 # (t_wall, frame, P, A, E, S, C, R)
        self.lock = threading.Lock()
        self.stop_flag = False

    def run(self):
        while not self.stop_flag:
            try:
                line = self.ser.readline().decode("ascii", "replace")
            except Exception:                               # noqa: BLE001
                break
            m = FRAME_RE.search(line)
            if not m:
                continue
            # G 字段在老固件里不存在，groups() 对应位置是 None，按 0 处理
            rec = (time.time(),) + tuple(int(g, 16) if g else 0 for g in m.groups())
            with self.lock:
                self.rows.append(rec)

    def snapshot(self):
        with self.lock:
            return list(self.rows)

    def close(self):
        self.stop_flag = True
        try:
            self.ser.close()
        except Exception:                                   # noqa: BLE001
            pass


# ---------------------------------------------------------------------------
# 统计
# ---------------------------------------------------------------------------
def pct(vals, q):
    if not vals:
        return 0
    s = sorted(vals)
    i = min(len(s) - 1, max(0, int(round(q * (len(s) - 1)))))
    return s[i]


def analyse(rows):
    if not rows:
        return None
    P = [r[2] for r in rows]
    E = [r[4] for r in rows]
    S = [r[5] for r in rows]
    C = [r[6] for r in rows]
    R = [r[7] for r in rows]

    det = 0
    prev = 0
    for s in S:
        if (s >> 2) & 1 and not (prev >> 2) & 1:
            det += 1
        prev = s

    return {
        "n": len(rows),
        "p50": pct(P, 0.50), "p90": pct(P, 0.90), "pmax": max(P),
        "e50": pct(E, 0.50), "e99": pct(E, 0.99), "emax": max(E),
        "loud": sum(1 for s in S if s & 1) / len(S),
        "sust": sum(1 for s in S if (s >> 1) & 1) / len(S),
        "crun": max(C), "rmax": max(R), "det": det,
    }


def bar(frac, width=24):
    """只用 ASCII，避免 GBK 控制台下 UnicodeEncodeError"""
    n = int(round(frac * width))
    return "#" * n + "." * (width - n)


def countdown(t_end):
    """在屏幕同一行刷新倒计时，只在秒数变化时重画"""
    last = None
    prefix = "    剩余 "
    while True:
        left = t_end - time.time()
        if left <= 0:
            break
        s = int(math.ceil(left))
        if s != last:
            sys.stdout.write("\r" + prefix + "%2ds  " % s)
            sys.stdout.flush()
            last = s
        time.sleep(0.1)
    sys.stdout.write("\r" + " " * (len(prefix) + 8) + "\r")
    sys.stdout.flush()


def gain_check(rd, tries=2, dur=6.0, target=600):
    """
    音量预检：你放一段鼾声，脚本量一下包络峰值够不够。
    目的是避免跑完 48 秒才发现刺激太弱、数据全是无效的。
    """
    for i in range(1, tries + 1):
        print()
        print(" " + "-" * 58)
        print("  音量预检 %d/%d" % (i, tries))
        print(" " + "-" * 58)
        print("  请现在开始播放你的鼾声录音：外放、音量最大，")
        print("  麦克风正对喇叭，距离 10~15cm。保持 %d 秒。" % int(dur))
        print(" " + "-" * 58)
        t0 = time.time()
        t_end = t0 + dur
        countdown(t_end)

        snap = [r for r in rd.snapshot() if r[0] >= t0]
        if not snap:
            print("  这段时间没收到任何帧，检查串口是否还连着")
            return False
        emax = max(r[4] for r in snap)
        print("  测到包络最大值 %d（门限 %d，希望 >= %d）" % (emax, TH_RTL, target))
        if emax >= target:
            print("  [OK] 音量够用，继续往下走。后面正式测试时请保持播放不要停。")
            return True
        print("  [NG] 太小了。请把音量调到最大，并确认是外放不是耳机；")
        print("       麦克风正对喇叭，再靠近一点。")
        if i < tries:
            print("       我会再测一次，请把音量调大后继续播放 ...")

    print()
    print("  [!] 两次都偏小。后面鼾声段很可能判不出来，但仍会把流程跑完，")
    print("      方便你看其它几段的表现。")
    return False


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port", nargs="?", default="COM7")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--fast", action="store_true", help="缩短版测试")
    ap.add_argument("--skip-check", action="store_true", help="跳过音量预检")
    ap.add_argument("--only", default=None,
                    help="只跑指定段，逗号分隔（quiet/speech/clap/snore）")
    ap.add_argument("--csv", default="snore_test.csv")
    args = ap.parse_args()

    segs = SEGMENTS_FAST if args.fast else SEGMENTS_FULL
    if args.only:
        want = {k.strip() for k in args.only.split(",") if k.strip()}
        segs = [s for s in segs if s[0] in want]
        if not segs:
            print("[!] --only 里没有匹配的段：%s" % args.only)
            return 2
        # 只跑部分段时，csv 里就没有完整对照数据了，换个名字免得
        # 覆盖掉上一次完整测试的结果，也免得 调参.bat 误用
        if args.csv == "snore_test.csv":
            args.csv = "snore_only.csv"
            print("[!] 只跑部分段，明细另存为 snore_only.csv（不要用它调参）")
    total = sum(s[2] for s in segs)

    print("=" * 62)
    print(" 呼噜声检测 —— 分段测试")
    print("=" * 62)
    print(" 串口   : %s @ %d" % (args.port, args.baud))
    print(" 总时长 : 约 %d 秒，共 %d 段" % (total, len(segs)))
    print(" 提示   : 全程不需要敲键盘，跟着屏幕上的提示做就行")
    print("=" * 62)

    try:
        rd = Reader(args.port, args.baud)
    except serial.SerialException as e:
        print("[!] 打不开串口 %s" % args.port)
        print("    %s" % e)
        try:
            from serial.tools import list_ports
            avail = [p.device for p in list_ports.comports()]
            print("    当前可用的串口: %s"
                  % (", ".join(avail) if avail else "(一个都没有)"))
        except Exception:                               # noqa: BLE001
            pass
        print("    检查：1) 板子的 USB 线插在 UART 口（不是 JTAG 口）")
        print("          2) 设备管理器 -> 端口(COM 和 LPT) 看实际编号")
        print("          3) 没有出现新串口，说明 USB 转串口驱动没装好")
        print("    换端口重跑：  python snore_test.py COM5")
        return 2

    rd.start()
    time.sleep(0.5)
    if not rd.snapshot():
        print("[!] 0.5 秒内没收到任何合法帧。")
        print("    检查：1) 板子是否已下载 bit（断电后要重新下载）")
        print("          2) P5 跳线是否在 PL 侧")
        print("          3) 串口号是否正确（设备管理器里看）")
        rd.close()
        return 2

    results = []

    # ---- 音量预检（只在需要鼾声段时做）----
    if not args.skip_check and any(s[0] == "snore" for s in segs):
        gain_check(rd)

    t_start_all = time.time()

    for k, (key, name, dur, hint, expect) in enumerate(segs, 1):
        t0 = time.time()
        t_end = t0 + dur

        print()
        print("-" * 62)
        print(" 第 %d/%d 段    【 %s 】  %d 秒" % (k, len(segs), name, dur))
        print("-" * 62)
        print(" 请你：%s" % hint)
        print("-" * 62)

        # ---- 倒计时 + 本段实时判决计数 ----
        last_s = None
        last_det = -1
        while True:
            left = t_end - time.time()
            if left <= 0:
                break
            snap = [r for r in rd.snapshot() if r[0] >= t0]
            d = sum(1 for i in range(1, len(snap))
                    if (snap[i][5] >> 2) & 1 and not (snap[i - 1][5] >> 2) & 1)
            s_now = int(math.ceil(left))
            # 只在秒数或判决数变化时重画，否则同一个数会被反复写出去
            if s_now != last_s or d != last_det:
                msg = "    剩余 %2ds  %s" % (s_now, ("* 判决 %d 次 " % d) if d else "")
                sys.stdout.write("\r" + msg + " " * 12)
                sys.stdout.flush()
                last_s, last_det = s_now, d
            time.sleep(0.1)

        sys.stdout.write("\r" + " " * 44 + "\r")
        sys.stdout.flush()

        snap = [r for r in rd.snapshot() if t0 <= r[0] < t_end]
        st = analyse(snap)
        results.append((key, name, expect, st))

        if st is None:
            print("    本段没有收到任何帧")
            continue

        print("    帧数 %4d   P: p50=%5d p90=%5d max=%5d   E: p99=%5d max=%5d"
              % (st['n'], st['p50'], st['p90'], st['pmax'], st['e99'], st['emax']))
        print("    超阈 %s %3.0f%%   持续 %3.0f%%   burst最长 %3d 帧  节律最大 %d"
              % (bar(st['loud']), st['loud'] * 100, st['sust'] * 100,
                 st['crun'], st['rmax']))
        verdict = "[OK] 符合预期" if (st["det"] > 0) == bool(expect) else "[NG] 不符合预期"
        print("    鼾声判决 %d 次  ->  %s" % (st["det"], verdict))

    # ---- 总结 ----
    print()
    print("=" * 62)
    print(" 汇总")
    print("=" * 62)
    print(" %-12s%-10s%-8s%-8s%-8s%s" % ("段", "预期", "判决", "超阈%", "E_max", "结论"))
    print(" " + "-" * 58)
    ok = 0
    for key, name, expect, st in results:
        if st is None:
            print(" %-12s%-10s%-8s%-8s%-8s无数据" % (name, "?", "-", "-", "-"))
            continue
        got = st["det"] > 0
        good = got == bool(expect)
        ok += 1 if good else 0
        print(" %-12s%-10s%-8d%3.0f%%    %-8d%s"
              % (name, "检测" if expect else "不检测", st["det"],
                 st["loud"] * 100, st["emax"], "[OK]" if good else "[NG]"))
    print(" " + "-" * 58)
    print(" 符合预期 %d/%d" % (ok, len(results)))

    # ---- 门限建议 ----
    d = {k: st for k, _, _, st in results}
    q, sn = d.get("quiet"), d.get("snore")
    if q and sn and sn["e99"] > 0:
        base = max(1, q["e99"])
        stim = max(sn["p90"], base * 4)
        sug = int(round(math.sqrt(base * stim)))
        print()
        print(" 门限建议：安静段包络 p99 = %d，鼾声段包络 p99 = %d" % (base, sn["e99"]))
        print("           两者几何平均约 %d（当前 RTL 里 TH = %d）" % (sug, TH_RTL))
        if sug > 800:
            print("           -> 实测响度偏大，TH=%d 可能偏松，说话段容易误报" % TH_RTL)
        elif sug < 300:
            print("           -> 实测响度偏小，TH=%d 可能偏紧，鼾声都进不来" % TH_RTL)
        print("           要重新定标就双击 调参.bat，它会把参数组合一次算完")

    # ---- 刺激响度自检 ----
    if sn and sn["e99"] < 600:
        print()
        print(" [!] 鼾声段响度明显不足（包络 p99 只有 %d，门限是 %d）"
              % (sn["e99"], TH_RTL))
        print("     这一次的『没检测到』不能说明判据有问题，是刺激太弱。请：")
        print("       1) 把播放音量调到最大，确认是外放（不是耳机）")
        print("       2) 麦克风离喇叭 10~15cm，正对着喇叭")
        print("       3) 重跑本测试")

    # ---- 存 CSV ----
    if args.csv:
        rows = rd.snapshot()
        bounds = []
        t = t_start_all
        for key, name, dur, _, _ in segs:
            bounds.append((t, t + dur, key))
            t += dur
        with open(args.csv, "w", encoding="utf-8") as f:
            f.write("t,seg,frame,P,A,E,S,C,R,G\n")
            for r in rows:
                seg = ""
                for a, b, kk in bounds:
                    if a <= r[0] < b:
                        seg = kk
                        break
                f.write("%.3f,%s,%d,%d,%d,%d,%d,%d,%d,%d\n"
                        % (r[0] - t_start_all, seg, r[1], r[2], r[3],
                           r[4], r[5], r[6], r[7], r[8]))
        print()
        print(" 明细已存: %s" % args.csv)

    rd.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
