#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
auto_test.py — 无人值守的分段测试（电脑自己当"声源"）

和 snore_test.py 的区别：
    snore_test.py 需要你亲手播放、亲手说话、亲手拍手，脚本只负责计时；
    auto_test.py 由电脑自己产生全部刺激，你只要确认板子上电、串口通，
    然后等 100 秒拿结果。适合"改完 RTL 快速回归"。

六段刺激的来源：
    准备     无声
    基线安静  无声
    正常说话  共振峰合成的音节性语声（F0 约 115Hz，音节率约 4.2Hz，
             每段音节随机换元音），专门用来压判据的"够长"和"有节律"两条
    拍手     1Hz 的宽带瞬态（25ms 衰减噪声），每一下只占 1 帧左右，
             远不到 MIN_ON=8 帧，正常应该一次都不判
    鼾声      scripts/snore_stim.wav 原样播放（48 秒，正好一段）
    收尾安静  无声

限制：合成语声的频谱结构和真人不同，它只能证明"这类音节性声音不会误判"，
      不能替代真人复测。真要较真，用 测试.bat 自己念一段更稳。

用法：
    python auto_test.py COM7                 # 完整 102 秒
    python auto_test.py COM7 --fast          # 缩短版，约 60 秒
    python auto_test.py COM7 --skip-phys     # 跳过音量预检
    python auto_test.py COM7 --keep-wav      # 保留生成的刺激音频，方便试听

依赖：pyserial、numpy（合成刺激用）
"""
import argparse
import os
import struct
import sys
import tempfile
import threading
import time
import wave

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from snore_test import FRAME_RE, Reader, TH_RTL, analyse, bar   # noqa: E402

try:
    import winsound
except ImportError:                                            # 非 Windows
    print("[!] 这个脚本用 winsound 播放刺激，只能在 Windows 上跑")
    sys.exit(1)

HERE = os.path.dirname(os.path.abspath(__file__))
SNORE_WAV = os.path.join(HERE, "snore_stim.wav")
SR = 44100

SEGS_FULL = [
    ("prep",   "准备",      4,  None,   0),
    ("quiet",  "基线安静",  15, None,   0),
    ("speech", "合成说话",  15, "speech", 0),
    ("clap",   "拍手 1Hz",  10, "clap", 0),
    ("snore",  "鼾声录音",  48, "snore", 1),
    ("quiet2", "收尾安静",  10, None,   0),
]

SEGS_FAST = [
    ("prep",   "准备",      3,  None,   0),
    ("quiet",  "基线安静",  8,  None,   0),
    ("speech", "合成说话",  10, "speech", 0),
    ("clap",   "拍手 1Hz",  6,  "clap", 0),
    ("snore",  "鼾声录音",  30, "snore", 1),
    ("quiet2", "收尾安静",  6,  None,   0),
]


# ---------------------------------------------------------------------------
# 刺激合成
# ---------------------------------------------------------------------------
def write_wav(path, data):
    """data: float32 [-1,1] 单声道，写 16bit PCM"""
    pcm = np.clip(data, -1.0, 1.0)
    pcm = (pcm * 32767.0).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def formant_shape(x, formants):
    """频域上叠几个高斯峰，模拟共振峰。formants = [(f, bw, gain), ...]"""
    spec = np.fft.rfft(x)
    freqs = np.fft.rfftfreq(len(x), 1.0 / SR)
    h = np.zeros_like(freqs)
    for f, bw, g in formants:
        h += g * np.exp(-0.5 * ((freqs - f) / (bw / 2.355)) ** 2)
    return np.fft.irfft(spec * h, n=len(x))


def vowel_syllable(dur, f0, formants, rng):
    """一个音节：带抖动基频的谐波源 + 共振峰 + 音节包络"""
    n = int(dur * SR)
    t = np.arange(n) / SR
    # 基频轻微下滑，避免听起来像电音
    f0_t = f0 * (1.0 - 0.10 * t / max(dur, 1e-3))
    phase = 2 * np.pi * np.cumsum(f0_t) / SR
    src = np.zeros(n)
    for k in range(1, 26):                      # 25 次谐波，够到 2.8kHz
        if f0 * k > 4000:
            break
        src += np.sin(k * phase + rng.uniform(0, 2 * np.pi)) / k ** 1.1
    src += 0.25 * rng.normal(0, 1, n)           # 一点气声
    y = formant_shape(src, formants)
    # 音节包络：25ms 起振 + 90ms 释放，尾巴不拖
    env = np.ones(n)
    a = min(int(0.025 * SR), n)
    r = min(int(0.09 * SR), n)
    env[:a] = np.linspace(0, 1, a) ** 1.5
    env[-r:] *= np.linspace(1, 0, r) ** 2
    return y * env


def make_speech(dur=15.0, seed=7):
    """音节性语声：音节率约 4.2Hz，音节之间留 40~110ms 间隙"""
    rng = np.random.default_rng(seed)
    out = np.zeros(int(dur * SR))
    pos = 0
    vowels = [
        [(650, 180, 1.0), (1100, 200, 0.55), (2500, 300, 0.25)],   # a
        [(400, 150, 1.0), (1900, 250, 0.45), (2600, 350, 0.20)],   # e
        [(300, 130, 1.0), (2200, 280, 0.40), (3000, 400, 0.15)],   # i
        [(500, 160, 1.0), (900, 200, 0.60), (2400, 320, 0.25)],    # o
        [(350, 140, 1.0), (1300, 220, 0.50), (2300, 300, 0.22)],   # u
    ]
    while pos < len(out):
        d = rng.uniform(0.16, 0.26)
        n = int(d * SR)
        f0 = rng.uniform(105, 135)
        syl = vowel_syllable(d, f0, vowels[rng.integers(0, len(vowels))], rng)
        end = min(pos + n, len(out))
        out[pos:end] += syl[:end - pos]
        pos = end + int(rng.uniform(0.04, 0.11) * SR)     # 音节间停顿
    # 谱倾斜，靠近自然语音的 -6dB/oct
    out = formant_shape(out, [(0, 400, 1.0), (500, 800, 0.35), (1500, 2000, 0.12)])
    out /= np.max(np.abs(out)) + 1e-9
    return out * 0.85


def make_clap():
    """25ms 衰减的宽带瞬态，模拟拍手/敲桌"""
    rng = np.random.default_rng(11)
    n = int(0.025 * SR)
    t = np.arange(n) / SR
    y = rng.normal(0, 1, n) * np.exp(-t / 0.006)
    y = formant_shape(y, [(2500, 3000, 1.0), (6000, 3000, 0.4)])
    y /= np.max(np.abs(y)) + 1e-9
    # 前 3ms 加个轻声启动，避免数字硬切
    lead = int(0.003 * SR)
    return np.concatenate([np.zeros(lead), y * 0.95])


def read_wav(path):
    with wave.open(path, "rb") as w:
        d = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64)
        if w.getnchannels() > 1:
            d = d.reshape(-1, w.getnchannels()).mean(axis=1)
    return d / 32768.0


def loudify(x, drive=3.0):
    """
    响度压缩：先把整体推上去，再用 tanh 软限幅压住峰值。

    为什么要它：笔记本扬声器的实际声压有限。原版 snore_stim.wav 峰值 0.73、
    RMS 只有 0.25（约 9dB 峰均比），外放到麦克风那里时，一个 2 秒的鼾声
    burst 只有四分之一左右的帧能越过 TH，而判据要求"够长"再"有节律"，
    结果就是节律永远连不到 3 次 —— 这不代表判据错，是刺激不够响。

    drive=3 大约能把 RMS 抬 7~8dB，峰值仍然压到 1.0 以内不削顶。
    波形包络（2 秒响 / 2 秒静）完全保留，所以判据看到的时间结构不变。
    """
    y = np.tanh(drive * x) / np.tanh(drive)
    return y / (np.max(np.abs(y)) + 1e-9) * 0.99


# ---------------------------------------------------------------------------
# 播放
# ---------------------------------------------------------------------------
def play_file(path):
    winsound.PlaySound(path, winsound.SND_FILENAME | winsound.SND_ASYNC)


def stop_all():
    winsound.PlaySound(None, winsound.SND_PURGE)


class Stim:
    """在一段内按时间表播放，结束自动停"""

    def __init__(self, kind, dur, wavs):
        self.kind = kind
        self.dur = dur
        self.wavs = wavs
        self.t0 = None
        self.thread = None
        self.alive = True

    def start(self):
        self.t0 = time.time()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        if self.kind is None:
            return
        if self.kind == "snore":
            play_file(self.wavs["snore"])
            time.sleep(min(self.dur, 48.0))
            stop_all()
        elif self.kind == "speech":
            play_file(self.wavs["speech"])
            time.sleep(self.dur)
            stop_all()
        elif self.kind == "clap":
            i = 0
            while self.alive and (time.time() - self.t0) < self.dur - 0.1:
                play_file(self.wavs["clap"])
                i += 1
                time.sleep(max(0.0, self.t0 + i * 1.0 - time.time()))

    def stop(self):
        self.alive = False
        if self.kind is not None:
            stop_all()


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port", nargs="?", default="COM7")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--fast", action="store_true")
    ap.add_argument("--skip-phys", action="store_true", help="跳过音量预检")
    ap.add_argument("--only", default=None,
                    help="只跑指定段，逗号分隔（quiet/speech/clap/snore/quiet2）")
    ap.add_argument("--gain", type=float, default=1.0,
                    help="鼾声刺激的响度压缩倍数，默认 1.0 原样播放；"
                         "外放声压不够时用 2~4 再跑一次")
    ap.add_argument("--csv", default="auto_test.csv")
    ap.add_argument("--keep-wav", action="store_true")
    args = ap.parse_args()

    segs = SEGS_FAST if args.fast else SEGS_FULL
    if args.only:
        want = {k.strip() for k in args.only.split(",") if k.strip()}
        segs = [s for s in segs if s[0] in want]
        if not segs:
            print("[!] --only 里没有匹配的段：%s" % args.only)
            return 2
        # 只跑部分段时另存，别覆盖上一次完整测试的明细
        if args.csv == "auto_test.csv":
            args.csv = "auto_only.csv"

    if not os.path.exists(SNORE_WAV):
        print("[!] 找不到 %s" % SNORE_WAV)
        return 2

    tmp = tempfile.mkdtemp(prefix="snore_stim_")
    wavs = {"snore": SNORE_WAV}
    print("=" * 62)
    print(" 呼噜声检测 —— 自动分段测试（电脑自己当声源）")
    print("=" * 62)
    print(" 串口   : %s @ %d" % (args.port, args.baud))
    print(" 总时长 : 约 %d 秒" % sum(s[2] for s in segs))
    print(" 生成刺激音频 ...")

    if abs(args.gain - 1.0) > 1e-6:
        sn = loudify(read_wav(SNORE_WAV), args.gain)
        p = os.path.join(tmp, "snore_loud.wav")
        write_wav(p, sn)
        wavs["snore"] = p
        print(" 鼾声刺激：响度压缩 %.1fx -> %s" % (args.gain, p))
        print("           峰值 %.2f  RMS %.3f（原版 RMS %.3f）"
              % (np.max(np.abs(sn)), np.sqrt(np.mean(sn ** 2)),
                 np.sqrt(np.mean(read_wav(SNORE_WAV) ** 2))))

    if any(s[3] == "speech" for s in segs):
        write_wav(os.path.join(tmp, "speech.wav"), make_speech(
            next(s[2] for s in segs if s[3] == "speech") + 1.0))
        wavs["speech"] = os.path.join(tmp, "speech.wav")
    if any(s[3] == "clap" for s in segs):
        write_wav(os.path.join(tmp, "clap.wav"), make_clap())
        wavs["clap"] = os.path.join(tmp, "clap.wav")

    print(" 完成 -> %s" % tmp)
    print("=" * 62)

    try:
        rd = Reader(args.port, args.baud)
    except Exception as e:                                     # noqa: BLE001
        print("[!] 打不开串口 %s: %s" % (args.port, e))
        return 2
    rd.start()
    time.sleep(0.5)
    if not rd.snapshot():
        print("[!] 收不到遥测帧，先确认板子已下载比特流、串口没被占用")
        rd.close()
        return 2

    # ---- 音量预检：放 5 秒鼾声，看麦克风听不听得到 ----
    if not args.skip_phys:
        print()
        print(" 音量预检：播放 5 秒鼾声录音 ...")
        play_file(wavs["snore"])
        t0 = time.time()
        while time.time() - t0 < 5.0:
            time.sleep(0.1)
        stop_all()
        # 包络每帧衰减 1/16，从几千掉到门限以下要 1 秒多。
        # 预检完不等够，尾巴会拖进"准备"段，把它染成十几个百分点的超阈，
        # 看起来像误判，其实是上一段的声音还没散完。
        time.sleep(1.8)
        snap = [r for r in rd.snapshot() if r[0] >= t0]
        emax = max((r[4] for r in snap), default=0)
        pmax = max((r[2] for r in snap), default=0)
        print("   收到 %d 帧，峰值 %d，包络最大 %d（门限 %d）"
              % (len(snap), pmax, emax, TH_RTL))
        if emax < 600:
            print("   [NG] 声音太弱，麦克风可能没听到外放。请调大系统音量、")
            print("        让喇叭对着麦克风，然后重跑；也可以 --skip-phys 硬跑。")
            rd.close()
            return 3
        print("   [OK] 音量够用")

    results = []
    t_start_all = time.time()

    for k, (key, name, dur, kind, expect) in enumerate(segs, 1):
        t0 = time.time()
        t_end = t0 + dur
        print()
        print("-" * 62)
        print(" 第 %d/%d 段  【%s】 %d 秒   刺激：%s"
              % (k, len(segs), name, dur, kind or "无"))
        print("-" * 62)

        stim = Stim(kind, dur, wavs)
        stim.start()

        last_s, last_det = None, -1
        while True:
            left = t_end - time.time()
            if left <= 0:
                break
            snap = [r for r in rd.snapshot() if r[0] >= t0]
            d = sum(1 for i in range(1, len(snap))
                    if (snap[i][5] >> 2) & 1 and not (snap[i - 1][5] >> 2) & 1)
            s_now = int(left) + 1
            if s_now != last_s or d != last_det:
                sys.stdout.write("\r    剩余 %2ds %s"
                                 % (s_now, ("  判决 %d 次" % d) if d else ""))
                sys.stdout.flush()
                last_s, last_det = s_now, d
            time.sleep(0.1)
        stim.stop()
        sys.stdout.write("\r" + " " * 40 + "\r")

        snap = [r for r in rd.snapshot() if t0 <= r[0] < t_end]
        st = analyse(snap)
        results.append((key, name, expect, st))
        if st is None:
            print("    本段没有帧")
            continue
        print("    帧数 %4d   P: p50=%5d p90=%5d max=%5d   E: p99=%5d max=%5d"
              % (st['n'], st['p50'], st['p90'], st['pmax'], st['e99'], st['emax']))
        print("    超阈 %s %3.0f%%   持续 %3.0f%%   burst最长 %3d 帧  节律最大 %d"
              % (bar(st['loud']), st['loud'] * 100, st['sust'] * 100,
                 st['crun'], st['rmax']))
        ok = (st["det"] > 0) == bool(expect)
        print("    判决 %d 次  ->  %s" % (st["det"], "[OK]" if ok else "[NG]"))

    # ---- 汇总 ----
    print()
    print("=" * 62)
    print(" 汇总")
    print("=" * 62)
    print(" %-12s%-9s%-7s%-8s%-7s%s"
          % ("段", "预期", "判决", "超阈%", "E_max", "结论"))
    print(" " + "-" * 58)
    ok = 0
    for key, name, expect, st in results:
        if st is None:
            print(" %-12s%-9s%-7s%-8s%-7s无数据" % (name, "?", "-", "-", "-"))
            continue
        good = (st["det"] > 0) == bool(expect)
        ok += 1 if good else 0
        print(" %-12s%-9s%-7d%3.0f%%     %-7d%s"
              % (name, "检测" if expect else "不检测", st["det"],
                 st["loud"] * 100, st["emax"], "[OK]" if good else "[NG]"))
    print(" " + "-" * 58)
    print(" 符合预期 %d/%d" % (ok, len(results)))

    sp = next((st for k, _, _, st in results if k == "speech"), None)
    cl = next((st for k, _, _, st in results if k == "clap"), None)
    if sp:
        print()
        print(" 说话段细看：最长的连续超阈只有 %d 帧（够长门限 MIN_ON = 8 帧），"
              % sp["crun"])
        print("             节律计数 %d（要求连续 3 次间隔落在 288ms~3s）"
              % sp["rmax"])
    if cl:
        print(" 拍手段细看：最长 burst %d 帧，节律计数 %d"
              % (cl["crun"], cl["rmax"]))

    # ---- CSV ----
    if args.csv:
        rows = rd.snapshot()
        bounds = []
        t = t_start_all
        for key, name, dur, kind, expect in segs:
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

    if not args.keep_wav:
        for k in ("speech", "clap", "snore"):
            p = wavs.get(k)
            if p and os.path.dirname(p) == tmp:
                try:
                    os.remove(p)
                except OSError:
                    pass
        try:
            os.rmdir(tmp)
        except OSError:
            pass
    else:
        print(" 刺激音频保留在: %s" % tmp)

    rd.close()
    return 0 if ok == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
