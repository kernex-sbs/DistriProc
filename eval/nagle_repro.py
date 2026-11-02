# Standalone Nagle x delayed-ACK repro for the page-server protocol. No root.
# Usage: python3 eval/nagle_repro.py               (loopback, both ends here)
#        python3 eval/nagle_repro.py serve PORT    (server host; serves forever)
#        python3 eval/nagle_repro.py HOST PORT     (client host, against a server)
# Mimics criu_page_server.handle_client (8B req -> 4096B sendall) and the
# handler's batch fetch (n separate 8B sends, then n page recvs). In two-host
# mode the client's first byte tells the server whether to set TCP_NODELAY.
import socket, struct, threading, time, sys
PAGE = b"\x00" * 4096
def recv_exact(c, n):
    b = b""
    while len(b) < n:
        x = c.recv(n - len(b))
        if not x: return None
        b += x
    return b
def handle(c, nodelay):
    if nodelay is None: nodelay = recv_exact(c, 1) == b"1"
    if nodelay: c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    while recv_exact(c, 8) is not None:
        c.sendall(PAGE)
    c.close()
def serve_once(s, nodelay):
    handle(s.accept()[0], nodelay)
def run(addr, srv_nd, cli_nd, n, batches=200):
    if addr is None:
        s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen()
        threading.Thread(target=serve_once, args=(s, srv_nd), daemon=True).start()
        addr = s.getsockname()
    c = socket.create_connection(addr)
    if cli_nd: c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    if len(sys.argv) == 3: c.sendall(b"1" if srv_nd else b"0")
    ts = []
    for _ in range(batches):
        t = time.perf_counter()
        for i in range(n): c.send(struct.pack("Q", i * 4096))
        recv_exact(c, 4096 * n)
        ts.append(time.perf_counter() - t)
    c.close(); ts.sort()
    return ts[len(ts)//2] * 1e6, ts[int(len(ts)*.95)] * 1e6, n * batches / sum(ts)
if sys.argv[1:2] == ["serve"]:
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", int(sys.argv[2]))); s.listen()
    while True:
        threading.Thread(target=handle, args=(s.accept()[0], None), daemon=True).start()
addr = (sys.argv[1], int(sys.argv[2])) if len(sys.argv) == 3 else None
for n in (1, 8, 32):
    for sn, cn in ((0, 0), (1, 0), (0, 1), (1, 1)):
        med, p95, pps = run(addr, sn, cn, n)
        print(f"n={n:2d} server_nd={sn} client_nd={cn} batch median {med:8.0f}us p95 {p95:8.0f}us -> {pps:8.0f} pages/s")
