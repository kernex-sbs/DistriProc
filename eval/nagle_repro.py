# Standalone Nagle x delayed-ACK repro for the page-server protocol. No root.
# Usage: python3 eval/nagle_repro.py
# Mimics criu_page_server.handle_client (8B req -> 4096B sendall) and the
# handler's batch fetch (n separate 8B sends, then n page recvs).
import socket, struct, threading, time, sys
PAGE = b"\x00" * 4096
def recv_exact(c, n):
    b = b""
    while len(b) < n:
        x = c.recv(n - len(b))
        if not x: return None
        b += x
    return b
def serve(s, nodelay):
    c, _ = s.accept()
    if nodelay: c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    while recv_exact(c, 8) is not None:
        c.sendall(PAGE)
def run(srv_nd, cli_nd, n, batches=200):
    s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen()
    threading.Thread(target=serve, args=(s, srv_nd), daemon=True).start()
    c = socket.create_connection(s.getsockname())
    if cli_nd: c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    ts = []
    for _ in range(batches):
        t = time.perf_counter()
        for i in range(n): c.send(struct.pack("Q", i * 4096))
        recv_exact(c, 4096 * n)
        ts.append(time.perf_counter() - t)
    c.close(); ts.sort()
    return ts[len(ts)//2] * 1e6, ts[int(len(ts)*.95)] * 1e6, n * batches / sum(ts)
for n in (1, 8, 32):
    for sn, cn in ((0, 0), (1, 0), (0, 1), (1, 1)):
        med, p95, pps = run(sn, cn, n)
        print(f"n={n:2d} server_nd={sn} client_nd={cn} batch median {med:8.0f}us p95 {p95:8.0f}us -> {pps:8.0f} pages/s")
