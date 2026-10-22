#!/usr/bin/env python3
"""Independent NumPy golden model that reads the SAME .mem files the RTL reads.
Use it to confirm the files themselves (before blaming the hardware) and to
dump per-image raw scores for debugging a mismatch.   usage: verify_mem.py [mem_dir]"""
import sys, pathlib, numpy as np
d = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).parent.parent / "mem")

def bits(path):   # char i (leftmost = 0) -> input i ; '1' -> +1, '0' -> -1
    return np.array([[1 if c == '1' else -1 for c in l.strip()] for l in open(path) if l.strip()], np.int32)
def thr(path):    # 11-bit signed two's complement hex
    v = np.array([int(l, 16) for l in open(path) if l.strip()]); return np.where(v >= 1024, v - 2048, v)
def hexcol(path): return np.array([int(l, 16) for l in open(path) if l.strip()])

W0, W1, W2 = (bits(d / f"W{i}.mem") for i in range(3))
T0, T1 = thr(d / "T0.mem"), thr(d / "T1.mem")
X = bits(d / "test_images.mem")                      # +1 = pixel>=128
exp, lbl = hexcol(d / "expected_pred.mem"), hexcol(d / "test_labels.mem")

a = np.where(X @ W0.T >= T0, 1, -1)
a = np.where(a @ W1.T >= T1, 1, -1)
raw = a @ W2.T                                       # raw sums, no thresholds
pred = raw.argmax(1)                                 # lowest index on ties

srt = np.sort(raw, 1)
ties = np.flatnonzero(srt[:, -1] == srt[:, -2])
print(f"shapes: W0{W0.shape} W1{W1.shape} W2{W2.shape} T0{T0.shape} T1{T1.shape} X{X.shape}")
print(f"match expected_pred : {(pred == exp).sum()} / {len(exp)}")
print(f"accuracy vs labels  : {100 * (pred == lbl).mean():.1f} %")
print(f"images with tied top score (tie-break matters): {ties.tolist()}")
