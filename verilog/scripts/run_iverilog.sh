#!/usr/bin/env bash
# Quick open-source sanity run (same RTL + TB as Vivado). Run from anywhere.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/mem"
iverilog -g2012 -o /tmp/bnn_sim "$ROOT"/rtl/bnn_layer.v "$ROOT"/rtl/bnn_top.v "$ROOT"/sim/tb_bnn_top.v
vvp /tmp/bnn_sim
