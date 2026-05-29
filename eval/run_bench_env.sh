#!/bin/bash
# eval/run_bench_env.sh — Run bench.sh as root with the invoking user's
# Python environment (venv torch + system pycriu) made visible, plus the
# protobuf pure-Python shim that pycriu 4.2 needs on protobuf 6.x.
#
# Usage:  sudo bash eval/run_bench_env.sh [bench.sh args...]
# Example: sudo bash eval/run_bench_env.sh --iterations 5

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (criu requires it)"
    exit 1
fi

# Pick the venv: DISTRIPROC_VENV override > venv-cpu (CPU torch, matches
# paper's no-GPU loopback setup) > venv. A CUDA torch build bloats the
# checkpoint image and masks the prefetch-congestion paradox, so CPU torch
# is preferred for reproducing the paper.
VENV_DIR="${DISTRIPROC_VENV:-}"
if [ -z "$VENV_DIR" ]; then
    if [ -d "$ROOT_DIR/venv-cpu" ]; then
        VENV_DIR="$ROOT_DIR/venv-cpu"
    else
        VENV_DIR="$ROOT_DIR/venv"
    fi
fi
echo "Using venv: $VENV_DIR"

if [ -n "${SUDO_USER:-}" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    # Add .local first so the chosen venv (prepended after) takes priority;
    # otherwise a CUDA torch in ~/.local would shadow the CPU venv.
    for u_site in "$USER_HOME"/.local/lib/python*/site-packages; do
        [ -d "$u_site" ] && export PYTHONPATH="${u_site}${PYTHONPATH:+:$PYTHONPATH}"
    done
    for venv_site in "$VENV_DIR"/lib/python*/site-packages; do
        [ -d "$venv_site" ] && export PYTHONPATH="${venv_site}${PYTHONPATH:+:$PYTHONPATH}"
    done
fi

# pycriu 4.2's pb2dict.py relies on FieldDescriptor.label (removed in
# protobuf 6.x C/upb backend); force pure-Python so the shim in
# criu_page_server.py can restore it.
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

echo "PYTHONPATH=$PYTHONPATH"
python3 -c "import torch; print('torch', torch.__version__)" 2>&1 || true
python3 -c "from pycriu import images; print('pycriu OK')" 2>&1 || true

exec bash "$ROOT_DIR/eval/bench.sh" "$@"
