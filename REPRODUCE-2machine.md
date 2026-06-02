# Reproduce: Real Two-Machine Cross-Host Validation

This validates the RTT crossover (paper §V-H) on **real hardware over a wired LAN**,
instead of the `netem`-emulated sweep. The page server runs on a second machine (B); the
restore + `lazy_handler` + PyTorch workload run on the primary machine (A), exactly as in
the loopback runs, so TTFR stays directly comparable. Only the transport changes.

```
  A (primary, Ryzen)                 wired LAN                B (second machine)
  criu restore --lazy-pages   <----  TCP :9999  ---->  criu_page_server.py (0.0.0.0)
  lazy_handler --address B
  pytorch workload
```

B's weaker CPU / lack of GPU does not matter: there is no inference on B, and the page
server is I/O-light. B does **not** need PyTorch.

## Prerequisites

**On B (second machine):**
1. Clone the repo: `git clone <repo> ~/DistriProc` (note the path → `REMOTE_ROOT`).
2. Install CRIU + pycriu so `from pycriu import images` works:
   ```
   pip install --user criu protobuf
   PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python python3 -c 'from pycriu import images; print("ok")'
   ```
   If pycriu lives in `~/.local/...`, pass that path as `B_PYTHONPATH`.
3. Open the firewall for the page-server port from A:
   ```
   sudo firewall-cmd --add-port=9999/tcp        # or: sudo ufw allow from <A_IP> to any port 9999
   ```

**On A (primary):**
4. Passwordless ssh **as root** to B (the script runs under sudo):
   ```
   sudo ssh-keygen -t ed25519           # if root has no key
   sudo ssh-copy-id user@<B_LAN_IP>
   sudo ssh user@<B_LAN_IP> true        # must succeed non-interactively
   ```
5. `rsync` present on both (it is, on most distros).
6. The same `venv-cpu` + pycriu setup used for the loopback runs (see `REPRODUCE.md`).

## Run

One command on A (root):

```bash
sudo PAGE_SERVER_SSH=user@192.168.1.50 \
     PAGE_SERVER_HOST=192.168.1.50 \
     REMOTE_ROOT=/home/user/DistriProc \
     B_PYTHONPATH=/home/user/.local/lib/python3.13/site-packages \
     ITERS=20 \
     bash eval/crosshost_2machine.sh
```

- `PAGE_SERVER_SSH` — ssh target for B.
- `PAGE_SERVER_HOST` — B's LAN IP (defaults to the host part of `PAGE_SERVER_SSH`).
- `REMOTE_ROOT` — repo path on B.
- `B_PYTHONPATH` — only if pycriu is not on B's default path.
- `ITERS` — iterations per mode (use 20 to match the loopback CIs; 10 is fine for a first look).

The script auto-measures the LAN RTT (`ping`) and writes it into every CSV row. It runs the
PyTorch matrix for `lazy`, `lazy-prefetch`, `lazy-adaptive` (full restore is RTT-independent,
so it is not re-run here).

## Output to paste back

```
eval/results/crosshost-2machine/results.csv          # per-iteration TTFR + rtt_us column
eval/results/crosshost-2machine/*_handler.log        # controller decisions per run
```

Paste the CSV (or the per-mode mean ± 95% CI and the measured RTT). I will then:
- add a "Real two-machine validation" subsection + compact table to §V,
- compare the real-LAN TTFRs to the `netem` prediction at the same RTT,
- if they agree, state the emulation is validated and soften the §V-H / Limitations
  "emulated only" caveat,
- update the abstract/contributions one clause: crossover confirmed on real hardware.

## Sanity checks before a full run

```bash
# from A, confirm you can reach B's page-server port once it is up (during a run):
python3 -c "import socket; socket.create_connection(('192.168.1.50',9999),2); print('reachable')"
# confirm RTT is what you expect (wired LAN is usually 100-500 us):
ping -c 20 192.168.1.50 | tail -1
```

A wired-LAN RTT of ~100–500 µs lands at or just above the crossover band (100–150 µs), so
this run directly tests the most contested region of the paper.
