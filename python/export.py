"""
Turn bnn_params.npz (float thresholds) into hardware-ready integer data,
Write the .mem files that Verilog will read.
"""
from pathlib import Path
import numpy as np
from torchvision import datasets

ROOT = Path(__file__).resolve().parent.parent
MEM_DIR = ROOT / "data" / "mem"
THR_BITS = 11      # signed: -1024..1023, enough for +/-784
N_EXPORT = 1000    # test images written to .mem files


# load data
def load_test_set():
    ds = datasets.MNIST(str(ROOT / "data"), train=False, download=True)
    pix = ds.data.numpy().reshape(len(ds), -1)
    X = np.where(pix >= 128, 1, -1).astype(np.int32)  # same as pixel/255 > 0.5
    return X, ds.targets.numpy()


# float reference (initial values)
def float_reference(p, X):
    a = X.astype(np.int32)
    i = 0
    while f"thr{i}" in p:
        x = a @ p[f"W{i}"].T.astype(np.int32)
        bit = np.where(p[f"flip{i}"], x <= p[f"thr{i}"], x >= p[f"thr{i}"])
        a = np.where(bit, 1, -1).astype(np.int32)
        i += 1
    x = a @ p[f"W{i}"].T.astype(np.int32)
    scores = p["gamma"] * (x - p["mu"]) / np.sqrt(p["var"] + p["eps"]) + p["beta"]
    return scores.argmax(1), x


# integer-only conversion
def to_integer_params(p):
    """x >= t  with integer x  -->  x >= ceil(t).
    x <= t  --> -x >= -floor(t): negate that neuron's weights and the
    comparison is always 'x >= T', so hardware needs no flip flag."""
    q = {}
    i = 0
    while f"thr{i}" in p:
        W = p[f"W{i}"].astype(np.int32).copy()
        t, flip = p[f"thr{i}"], p[f"flip{i}"]
        T = np.where(flip, -np.floor(t), np.ceil(t)).astype(np.int64)
        W[flip] *= -1
        q[f"W{i}"] = W
        q[f"T{i}"] = np.clip(T, -(1 << (THR_BITS - 1)), (1 << (THR_BITS - 1)) - 1)
        i += 1
    q[f"W{i}"] = p[f"W{i}"].astype(np.int32)  # last layer: weights only
    return q


def integer_inference(q, X):
    a = X.astype(np.int32)
    i = 0
    while f"T{i}" in q:
        x = a @ q[f"W{i}"].T
        a = np.where(x >= q[f"T{i}"], 1, -1).astype(np.int32)
        i += 1
    return a @ q[f"W{i}"].T        # raw class sums, no BN


# .mem writers
def bits_line(row):                  # +1 -> '1', -1 -> '0'
    return "".join("1" if v > 0 else "0" for v in row)


def write_mem(name, lines):
    MEM_DIR.mkdir(parents=True, exist_ok=True)
    (MEM_DIR / name).write_text("\n".join(lines) + "\n")


def main():
    p = dict(np.load(ROOT / "bnn_params.npz"))
    X, Y = load_test_set()

    ref_pred, _ = float_reference(p, X)
    q = to_integer_params(p)
    raw = integer_inference(q, X)
    raw_pred = raw.argmax(1)

    print(f"Float reference accuracy        : {100 * (ref_pred == Y).mean():.2f}%")
    print(f"Raw-sum argmax accuracy (no BN) : {100 * (raw_pred == Y).mean():.2f}%")
    print(f"Agreement raw-sum vs float ref  : {100 * (raw_pred == ref_pred).mean():.2f}%")
    print("  ^ if this is ~100%, the last layer needs no BN in hardware.")
    print("  ^ if it is lower, we need per-class integer offsets.")

    # hidden layers must match the float version exactly to check activations
    a_f = X.astype(np.int32)
    a_i = X.astype(np.int32)
    for i in range(2):
        xf = a_f @ p[f"W{i}"].T.astype(np.int32)
        bf = np.where(p[f"flip{i}"], xf <= p[f"thr{i}"], xf >= p[f"thr{i}"])
        a_f = np.where(bf, 1, -1).astype(np.int32)
        xi = a_i @ q[f"W{i}"].T
        a_i = np.where(xi >= q[f"T{i}"], 1, -1).astype(np.int32)
        print(f"Hidden layer {i} activations identical: {np.array_equal(a_f, a_i)}")

    # weights: one line per neuron, one bit per input
    for i in range(3):
        write_mem(f"W{i}.mem", [bits_line(r) for r in q[f"W{i}"]])
    # thresholds: two's complement hex, one per neuron
    mask = (1 << THR_BITS) - 1
    hex_w = (THR_BITS + 3) // 4
    for i in range(2):
        write_mem(f"T{i}.mem", [format(int(t) & mask, f"0{hex_w}x") for t in q[f"T{i}"]])
    # test vectors + expected outputs from the integer model
    write_mem("test_images.mem", [bits_line(x) for x in X[:N_EXPORT]])
    write_mem("test_labels.mem", [format(int(y), "x") for y in Y[:N_EXPORT]])
    write_mem("expected_pred.mem", [format(int(c), "x") for c in raw_pred[:N_EXPORT]])
    print(f"\nWrote .mem files to {MEM_DIR}")


if __name__ == "__main__":
    main()