#!/usr/bin/env python3
"""合成 DV Profile 5 基础层测试图 → 10-bit limited i420 raw(供 x265 编码)。

P5 的像素语义是 IPTPQc2(ICtCp 的前身):基础层没有常规 YCbCr,解码端把 luma
当 I(强度)、chroma 当 Pt/Qc 处理。为让「未走 DV 路径时画面可辨识地错」、
「走了 DV 路径(RPU 校正)后可辨识地对」,本脚本把 BT.2020 线性 RGB 测试图
经 PQ OETF 编进 IPT 空间再落成 i420 码流:

  RGB(BT.2020 linear) → LMS(BT.2020 2nd order) → PQ OETF(逐分量) → IPT 矩阵
  I  → Y 平面(limited 64..1023 中的 64..940)
  Pt/Qc → Cb/Cr 平面(512 ± 448,4:2:0 下采样取均值)

测试图内容(按行三段):
  上半:8 条 BT.2020 原色/白/灰条(200 nit);
  中带:灰阶斜坡(0..1000 nit,PQ 均匀,随帧平移 → 相邻帧内容不同);
  下带:4 个肤色块 + 深灰(120 nit)。

Dolby 白(10000 nit)为满量纲 1.0。参照 spike dvsrc/gen_p5_yuv.py(numpy 版)
整理为纯 Python(唯一依赖 = 标准库),数学一致;颜色种类有限,按唯一 RGB
缓存编码结果,避免逐像素 3x3 矩阵乘法。
"""
import struct
import sys

# 256x144:与 generate_corpus.sh 其余语料同尺寸红线(控制仓体积);24 帧 = 1s @24fps。
W, H, N = 256, 144, 24

# BT.2020 → LMS(SMPTE RP 431-2 二阶)及其逆(IPTPQc2 规范附表)。
LMS2RGB = [
    [3.06441879, -2.16597676, 0.10155818],
    [-0.65612108, 1.78554118, -0.12943749],
    [0.01736321, -0.04725154, 1.03004253],
]


def mat_inv(m):
    a, b, c = m[0]
    d, e, f = m[1]
    g, h, i = m[2]
    A = e * i - f * h
    B = -(d * i - f * g)
    C = d * h - e * g
    det = a * A + b * B + c * C
    return [
        [A / det, -(b * i - c * h) / det, (b * f - c * e) / det],
        [B / det, (a * i - c * g) / det, -(a * f - c * d) / det],
        [C / det, -(a * h - b * g) / det, (a * e - b * d) / det],
    ]


RGB2LMS = mat_inv(LMS2RGB)
# IPT 变换矩阵(PQ 域 LMS' → I/P/Q)。
LMS2IPT = [
    [0.4000, 0.4000, 0.2000],
    [4.4550, -4.8510, 0.3960],
    [0.8056, 0.3572, -1.1628],
]

# PQ(OETF)常数,ITU-R BT.2100。
M1, M2 = 2610 / 16384, 2523 / 4096 * 128
C1, C2, C3 = 3424 / 4096, 2413 / 4096 * 32, 2392 / 4096 * 32


def pq_oetf(y: float) -> float:
    y = min(1.0, max(0.0, y))
    p = y ** M1
    return ((C1 + C2 * p) / (1 + C3 * p)) ** M2


def mat_vec(m, v):
    return [m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2] for i in range(3)]


def to_ipt_codes(rgb):
    """BT.2020 线性 RGB → (Y_code, Cb_code, Cr_code)(10-bit limited)。"""
    lms = mat_vec(RGB2LMS, rgb)
    pq = [pq_oetf(x) for x in lms]
    ipt = mat_vec(LMS2IPT, pq)
    y = 64 + 876 * min(1.0, max(0.0, ipt[0]))
    cb = 512 + 896 * min(0.5, max(-0.5, ipt[1]))
    cr = 512 + 896 * min(0.5, max(-0.5, ipt[2]))
    return y, cb, cr


def pattern(t):
    """第 t 帧的 BT.2020 线性 RGB 图(H×W×3,单位 = 满量纲,Dolby 白 = 1.0)。"""
    nit = 1 / 10000.0
    # 行区间(偶数对齐,便于 4:2:0 降采样)
    y1, y2, y3 = H // 2, (H * 3 // 4) // 2 * 2, H // 2 * 2
    img = [[[0.0] * 3 for _ in range(W)] for _ in range(H)]
    bars = [(1, 1, 1), (1, 1, 0), (0, 1, 1), (0, 1, 0),
            (1, 0, 1), (1, 0, 0), (0, 0, 1), (.18, .18, .18)]
    bw = W // 8
    for i, b in enumerate(bars):
        r, g, bl = (x * 200 * nit for x in b)
        for y in range(0, y1):
            for x in range(i * bw, (i + 1) * bw):
                img[y][x] = [r, g, bl]
    # 灰阶斜坡(随时间平移):0..1000 nit 的 PQ 均匀
    for x in range(W):
        v = ((x + t * 8) % W / W) ** 2.4 * 1000 * nit
        for y in range(y1, y2):
            img[y][x] = [v, v, v]
    skins = [(.45, .31, .23), (.80, .60, .48), (.60, .42, .33), (.30, .20, .15)]
    sw = W // 4
    for i, s in enumerate(skins):
        r, g, bl = (x * 120 * nit for x in s)
        for y in range(y2, y3):
            for x in range(i * sw, (i + 1) * sw):
                img[y][x] = [r, g, bl]
    return img


def encode_frame(img):
    # 唯一颜色缓存:整图只有几十种 RGB,避免逐像素矩阵乘。
    cache = {}
    y_codes = [[0] * W for _ in range(H)]
    cb_codes = [[0] * (W // 2) for _ in range(H // 2)]
    cr_codes = [[0] * (W // 2) for _ in range(H // 2)]
    for y in range(H):
        row = img[y]
        for x in range(W):
            key = tuple(row[x])
            codes = cache.get(key)
            if codes is None:
                codes = to_ipt_codes(key)
                cache[key] = codes
            y_codes[y][x] = codes[0]
    # 4:2:0:2×2 均值下采样
    for cy in range(H // 2):
        for cx in range(W // 2):
            scb = scr = 0.0
            for dy in (0, 1):
                for dx in (0, 1):
                    key = tuple(img[cy * 2 + dy][cx * 2 + dx])
                    codes = cache.get(key)
                    if codes is None:
                        codes = to_ipt_codes(key)
                        cache[key] = codes
                    scb += codes[1]
                    scr += codes[2]
            cb_codes[cy][cx] = scb / 4
            cr_codes[cy][cx] = scr / 4
    out = bytearray()
    for y in range(H):
        for x in range(W):
            out += struct.pack("<H", int(round(y_codes[y][x])))
    for plane in (cb_codes, cr_codes):
        for row in plane:
            for v in row:
                out += struct.pack("<H", int(round(v)))
    return bytes(out)


def main():
    if len(sys.argv) != 2:
        sys.exit(f"用法: {sys.argv[0]} <out.yuv>(10-bit limited i420,{W}x{H}x{N}帧)")
    with open(sys.argv[1], "wb") as f:
        for t in range(N):
            f.write(encode_frame(pattern(t)))
    print(f"P5 基础层 raw 完成: {sys.argv[1]}({W}x{H}x{N} 帧,IPTPQc2 编码)")


if __name__ == "__main__":
    main()
