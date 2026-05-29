# Reproducing DistriProc's Results

This document is for artifact evaluation. The paper's headline result — that
fixed sequential prefetch *increases* post-restore TTFR for memory-heavy
workloads (~85% on PyTorch ResNet-18), and that the adaptive controller
recovers most of it — is **specific to the Linux 6.18.7 kernel**. Read the
"Kernel sensitivity" note below before running.

## 1. Canonical environment

All numbers in the paper were produced on:

- **Kernel:** Linux 6.18.7
- **CRIU:** 4.2
- **CPU:** AMD Ryzen 7 7735HS, 15 GB RAM, x86_64, 4 KiB pages
- **PyTorch:** CPU build (no CUDA)
- **Transport:** TCP over loopback (127.0.0.1)
- **Commit:** `97caf28`

## 2. Kernel sensitivity (read this first)

The fixed-prefetch regression is a property of the interaction between the
loopback page-fault path and TCP congestion behavior, both kernel-dependent.
On **Linux 7.0.x** the PyTorch regression shrinks from ~85% to within
run-to-run noise, while the memory-light `test_loop` speedup (~21–23×) is
unchanged. Plausible 7.0-series causes: the reworked swap-in path (swap-table
"unified swapin"), batched large-folio fault/reclaim, and Accurate ECN
(RFC 9768) enabled by default.

**Consequence:** to reproduce the paper you must run on a 6.18.x kernel. Do not
attempt to reproduce on 7.0.x — the effect is genuinely absent there. A VM is
**not** recommended: virtio/netns overhead distorts the loopback TCP-congestion
timing the result depends on. Build and boot the kernel on bare metal.

## 3. Build and boot Linux 6.18.7 (bare metal)

On the evaluation host (Arch shown; adapt for other distros):

```bash
curl -O https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.7.tar.xz
tar xf linux-6.18.7.tar.xz && cd linux-6.18.7

# Reuse the host's current kernel config as a base
zcat /proc/config.gz > .config        # or copy /boot/config-$(uname -r)
make olddefconfig

make -j"$(nproc)"
sudo make modules_install
sudo make install                     # installs vmlinuz + System.map to /boot

# Initramfs + bootloader (Arch / GRUB)
sudo mkinitcpio -k 6.18.7 -g /boot/initramfs-6.18.7.img   # if not auto-generated
sudo grub-mkconfig -o /boot/grub/grub.cfg

# Reboot, select 6.18.7 in GRUB, then confirm:
uname -r        # expect 6.18.7
```

A different `6.18.x` patch level is acceptable if it reproduces the regression;
`.7` is the exact paper build.

## 4. Install dependencies

```bash
sudo pacman -S criu redis            # criu provides the pycriu Python module
pip install matplotlib
pip install --index-url https://download.pytorch.org/whl/cpu torch torchvision
```

There is **no** `pip install criu` / `pip install pycriu` package — pycriu ships
with the CRIU distribution package. `pycriu` 4.2 also needs the pure-Python
protobuf backend on protobuf 6.x; `eval/run_bench_env.sh` sets
`PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python` and the page server
(`src/criu_page_server.py`) carries a `FieldDescriptor.label` compatibility
shim.

## 5. Run

```bash
make all                              # build lazy_handler

# Confirmation pilot (PyTorch only, expect ~85% prefetch regression on 6.18.7)
sudo bash eval/run_bench_env.sh \
  --workloads pytorch \
  --modes full,lazy,lazy-prefetch,lazy-adaptive \
  --iterations 3 \
  --output-dir eval/results/pilot

# Full paper matrix (3 workloads × 4 modes × 5 iterations)
sudo bash eval/run_bench_env.sh --iterations 5

# Report + figures
make report
make figures
```

`eval/run_bench_env.sh` runs `eval/bench.sh` as root with the invoking user's
CPU-torch venv and `pycriu` on `PYTHONPATH` and the protobuf backend set. Prefer
it over invoking `eval/bench.sh` under bare `sudo`.

## 6. Threshold ablation (optional)

The adaptive controller's duplicate-rate thresholds are runtime-tunable via
`DISTRIPROC_DUP_DISABLE_PCT` and `DISTRIPROC_DUP_HALVE_PCT`. Sweep them with:

```bash
sudo bash eval/ablation_thresholds.sh   # 5 disable/halve pairs × n=5 on PyTorch
```

This must run on 6.18.x: on a kernel where the regression is absent there is
nothing for any threshold to recover.

## 6b. Cross-host RTT sensitivity (optional)

To test whether the paradox survives off zero-latency loopback, inject RTT on
the loopback TCP path with `tc netem` and re-run the PyTorch matrix at several
delays:

```bash
sudo bash eval/crosshost_netem.sh   # one-way delays 0/250/500/1000 us, n=10
```

This adds latency only to IP traffic on `lo` (the CRIU control socket is
AF_UNIX and unaffected; `full` restore has no page server and is the zero-RTT
reference). The script always removes the netem qdisc on exit. Results land in
`eval/results/crosshost/results-crosshost.csv` with an `rtt_us` column. This is
emulated latency on one host; a true two-machine run remains future work.

## 7. Outputs

- `eval/results/results.csv` — raw per-iteration data
- `eval/results/logs/` — per-run handler logs (controller decisions)
- `eval/results/report.md` — aggregated tables
- `eval/results/figures/` — paper figures (PDF + PNG)
