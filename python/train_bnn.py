"""
Train a Binarized Neural Network (BNN) on MNIST, then export it in an
FPGA-friendly form and check it against an integer-only reference model.

Network: 784 -> 256 -> 256 -> 10, fully connected
  - weights binarized to {-1, +1}
  - hidden activations binarized to {-1, +1}
  - input pixels thresholded to {-1, +1}  (so layer 1 is also XNOR-popcount)
  - BatchNorm after every linear layer (no bias: BN makes it redundant)

Usage:  python train_bnn.py
Needs:  torch, torchvision, numpy
"""
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torchvision import datasets, transforms

SIZES = (784, 256, 256, 10)
EPOCHS = 30
BATCH = 128
LR = 1e-3
PIXEL_THRESH = 0.5
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"


# ---------------------------------------------------------------- BNN pieces
class SignSTE(torch.autograd.Function):
    """Forward: sign(x) with sign(0)=+1.  Backward: straight-through
    estimator, gradient passes only where |x| <= 1 (hard-tanh derivative)."""

    @staticmethod
    def forward(ctx, x):
        ctx.save_for_backward(x)
        return torch.where(x >= 0, torch.ones_like(x), -torch.ones_like(x))

    @staticmethod
    def backward(ctx, grad_out):
        (x,) = ctx.saved_tensors
        return grad_out * (x.abs() <= 1).to(grad_out.dtype)


class BinaryLinear(nn.Linear):
    """Keeps real-valued latent weights for the optimizer, but uses
    sign(weights) in the forward pass."""

    def __init__(self, in_f, out_f):
        super().__init__(in_f, out_f, bias=False)

    def forward(self, x):
        return F.linear(x, SignSTE.apply(self.weight))


class BNN(nn.Module):
    def __init__(self, sizes=SIZES):
        super().__init__()
        self.fcs = nn.ModuleList(BinaryLinear(i, o) for i, o in zip(sizes[:-1], sizes[1:]))
        self.bns = nn.ModuleList(nn.BatchNorm1d(o) for o in sizes[1:])

    def forward(self, x):
        last = len(self.fcs) - 1
        for i, (fc, bn) in enumerate(zip(self.fcs, self.bns)):
            x = bn(fc(x))
            if i < last:                    # hidden layers: binarize activation
                x = SignSTE.apply(x)
        return x                            # final layer: BN output = class scores


# ---------------------------------------------------------------------- data
def binarize_input(t):                      # t: (1,28,28) in [0,1]
    return ((t > PIXEL_THRESH).float() * 2 - 1).view(-1)   # {-1,+1}, flat 784


def get_loaders():
    tf = transforms.Compose([transforms.ToTensor(), transforms.Lambda(binarize_input)])
    tr = datasets.MNIST("./data", train=True, download=True, transform=tf)
    te = datasets.MNIST("./data", train=False, download=True, transform=tf)
    return (torch.utils.data.DataLoader(tr, BATCH, shuffle=True),
            torch.utils.data.DataLoader(te, 1000))


# ------------------------------------------------------------ train / evaluate
@torch.no_grad()
def evaluate(model, loader):
    model.eval()
    correct = 0
    for x, y in loader:
        x, y = x.to(DEVICE), y.to(DEVICE)
        correct += (model(x).argmax(1) == y).sum().item()
    return 100.0 * correct / len(loader.dataset)


def train():
    train_loader, test_loader = get_loaders()
    model = BNN().to(DEVICE)
    opt = torch.optim.Adam(model.parameters(), lr=LR)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, EPOCHS)
    best = 0.0

    for ep in range(1, EPOCHS + 1):
        model.train()
        for x, y in train_loader:
            x, y = x.to(DEVICE), y.to(DEVICE)
            loss = F.cross_entropy(model(x), y)
            opt.zero_grad()
            loss.backward()
            opt.step()
            with torch.no_grad():           # keep latent weights in [-1, 1]
                for fc in model.fcs:
                    fc.weight.clamp_(-1, 1)
        sched.step()
        acc = evaluate(model, test_loader)
        if acc > best:
            best = acc
            torch.save(model.state_dict(), "bnn_best.pt")
        print(f"epoch {ep:2d}  loss {loss.item():.3f}  test acc {acc:.2f}%  (best {best:.2f}%)")

    model.load_state_dict(torch.load("bnn_best.pt", map_location=DEVICE))
    return model, test_loader


# -------------------------------------------------------------------- export
@torch.no_grad()
def export(model, path="bnn_params.npz"):
    """
    - W{i}: binary weights as int8 in {-1,+1}, shape (out, in)
    - hidden layers: BN folded into an integer-compare threshold + a flip flag
        BN(x) >= 0   <=>   x >= t   if gamma > 0
                           x <= t   if gamma < 0
        with t = mu - beta * sqrt(var + eps) / gamma
    - last layer: raw BN params (gamma, beta, mu, var, eps) so you can study
      how to approximate the scaling in hardware
    """
    out = {}
    n = len(model.fcs)
    for i, (fc, bn) in enumerate(zip(model.fcs, model.bns)):
        W = torch.where(fc.weight >= 0, 1, -1).to(torch.int8).cpu().numpy()
        g = bn.weight.cpu().numpy().astype(np.float64)
        b = bn.bias.cpu().numpy().astype(np.float64)
        mu = bn.running_mean.cpu().numpy().astype(np.float64)
        var = bn.running_var.cpu().numpy().astype(np.float64)
        out[f"W{i}"] = W
        if i < n - 1:
            std = np.sqrt(var + bn.eps)
            out[f"thr{i}"] = mu - b * std / g          # float threshold
            out[f"flip{i}"] = (g < 0)                   # True -> use x <= t
        else:
            out.update(gamma=g, beta=b, mu=mu, var=var, eps=np.float64(bn.eps))
    np.savez(path, **out)
    print(f"saved {path}")
    return out


# ------------------------------------------- integer-style reference inference
def reference_inference(p, X):
    """X: (N,784) array of {-1,+1}.  Uses only integer MACs and threshold
    compares for the hidden layers.  For +/-1 values,
        sum(a*w) = 2*popcount(XNOR(a_bit, w_bit)) - n_inputs,
    This is a bit-exact with an XNOR-popcount datapath."""
    a = X.astype(np.int32)
    i = 0
    while f"thr{i}" in p:
        x = a @ p[f"W{i}"].T.astype(np.int32)          # integer pre-activation
        t, flip = p[f"thr{i}"], p[f"flip{i}"]
        bit = np.where(flip, x <= t, x >= t)
        a = np.where(bit, 1, -1).astype(np.int32)
        i += 1
    x = a @ p[f"W{i}"].T.astype(np.int32)              # last layer
    scores = p["gamma"] * (x - p["mu"]) / np.sqrt(p["var"] + p["eps"]) + p["beta"]
    return scores.argmax(1)


def check_reference(model, params, test_loader):
    xs, ys = [], []
    for x, y in test_loader:
        xs.append(x.numpy()); ys.append(y.numpy())
    X, Y = np.concatenate(xs), np.concatenate(ys)
    with torch.no_grad():
        model.eval()
        torch_pred = model(torch.from_numpy(X).to(DEVICE)).argmax(1).cpu().numpy()
    ref_pred = reference_inference(params, X)
    print(f"PyTorch acc   : {100 * (torch_pred == Y).mean():.2f}%")
    print(f"Integer ref   : {100 * (ref_pred == Y).mean():.2f}%")
    print(f"Prediction agreement: {100 * (torch_pred == ref_pred).mean():.2f}%")


if __name__ == "__main__":
    model, test_loader = train()
    params = export(model)
    check_reference(model, params, test_loader)
