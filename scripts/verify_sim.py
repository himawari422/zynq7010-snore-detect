#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_sim.py —— 仿真自检：读 pcm_out.txt，验证 CIC 链路对不对

需要：numpy

检查三项硬指标：
  1) 峰值频率 300Hz        —— testbench 里注入的正弦频率
  2) 幅度 ≈ 17880          —— 0.6 × 满量程(29800)
  3) 直流 ≈ 0              —— 说明 0/1 -> ±1 映射和 CIC 增益都对

注意：这里不用 FFT 峰值直接取幅度。FFT 只有 31.25Hz 一个 bin，
      300Hz 落在 bin 之间时 Hann 窗会有最多 1.42dB(约15%) 的栅栏损失，
      容易把"设计正确"误判成"幅度不对"。
      改用任意频点 DFT 扫描（Goertzel 思想），幅度估算是精确的。

跑法：
  python scripts/verify_sim.py sim_out/pcm_out.txt
"""
import sys
import numpy as np

FS    = 16000.0     # 设计目标采样率
F_EXP = 300.0       # testbench 注入频率
A_EXP = 17880.0     # 期望幅度 = 0.6 * (125^4 >> 13)
TOL_F = 2.0         # 频率允许误差 Hz
TOL_A = 0.03        # 幅度允许相对误差


def dft_at(x, f, fs):
    """在任意频点 f 上做一次 DFT，返回复数投影"""
    n = np.arange(x.size)
    return np.sum(x * np.exp(-2j * np.pi * f * n / fs))


def main(path):
    x = np.loadtxt(path, dtype=np.float64)
    if x.size < 256:
        print(f"[FAIL] 采样点太少：{x.size}")
        return 1

    x = x[x.size // 8:]                 # 丢掉前 1/8（CIC 建立时间）
    N = x.size
    dc = x.mean()
    x = x - dc                          # 去直流，避免影响幅度估计

    # ---- 粗定位：FFT ----
    X = np.abs(np.fft.rfft(x))
    k = int(np.argmax(X[1:]) + 1)
    f0 = k * FS / N

    # ---- 精定位：在 f0 附近做细扫描 ----
    grid = np.linspace(max(f0 - FS / N, 1.0), f0 + FS / N, 4001)
    mags = np.array([abs(dft_at(x, f, FS)) for f in grid])
    f_pk = grid[int(np.argmax(mags))]
    amp = 2.0 * mags.max() / N

    print(f"样本数      : {N}")
    print(f"直流分量    : {dc:9.1f}      （应接近 0；明显偏离说明 PDM 占空比不是 50%）")
    print(f"峰值频率    : {f_pk:9.3f} Hz （期望 {F_EXP:.1f} Hz）")
    print(f"幅度        : {amp:9.1f}     （期望 {A_EXP:.0f}）")

    ok = True
    if abs(f_pk - F_EXP) > TOL_F:
        print("[FAIL] 频率偏差超限")
        ok = False
    if abs(amp - A_EXP) / A_EXP > TOL_A:
        print("[FAIL] 幅度偏差超限")
        ok = False

    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    p = sys.argv[1] if len(sys.argv) > 1 else "pcm_out.txt"
    sys.exit(main(p))
