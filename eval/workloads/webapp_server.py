#!/usr/bin/env python3
"""Web-app workload for DistriProc benchmarks: a Python HTTP service.

Each GET /customer/<id> runs an indexed SQL query against an in-memory
SQLite database, aggregates the rows in Python against cached product
objects (an ORM-style identity map), and renders a Jinja2 template. This is
the shape of a typical Python serverless function: interpreter, library
code and a mixed small-object/B-tree heap, nothing like PyTorch's large
contiguous tensors or Redis's hash table.

Lifecycle: build the data, warm one request, listen, write the ready file,
then serve until killed. --unix-socket serves over AF_UNIX (default in the
harness, so probe traffic is not shaped by netem on lo); --port over TCP.

Usage:
    webapp_server.py --ready-file F (--unix-socket PATH | --port N)
        [--customers 50000] [--orders 1500000]
"""

import argparse
import os
import random
import socket
import socketserver
import sqlite3
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

import jinja2

PAGE = jinja2.Template("""<!doctype html>
<html><head><title>{{ c.name }}</title></head><body>
<h1>{{ c.name }} ({{ c.city }})</h1>
<table>
<tr><th>order</th><th>product</th><th>category</th><th>qty</th><th>total</th></tr>
{% for o in orders %}<tr><td>{{ o.id }}</td><td>{{ o.product }}</td>
<td>{{ o.category }}</td><td>{{ o.qty }}</td><td>{{ "%.2f"|format(o.total) }}</td></tr>
{% endfor %}</table>
<h2>By category</h2><ul>
{% for cat, amt in by_cat %}<li>{{ cat }}: {{ "%.2f"|format(amt) }}</li>{% endfor %}
</ul><p>{{ orders|length }} orders, {{ "%.2f"|format(grand) }} total</p>
</body></html>
""")

CITIES = ["Pune", "Lyon", "Osaka", "Quito", "Perth", "Tartu", "Accra", "Hanoi"]
CATEGORIES = [f"cat-{i:02d}" for i in range(40)]


def build(customers, orders, products=20000):
    rnd = random.Random(1)
    db = sqlite3.connect(":memory:", check_same_thread=False)
    db.executescript("""
        CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT, city TEXT);
        CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT, category TEXT, price REAL);
        CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER,
                             product_id INTEGER, qty INTEGER, note TEXT);
    """)
    db.executemany("INSERT INTO customers VALUES (?,?,?)",
                   ((i, f"customer-{i:06d}", rnd.choice(CITIES)) for i in range(customers)))
    db.executemany("INSERT INTO products VALUES (?,?,?,?)",
                   ((i, f"product-{i:05d}", rnd.choice(CATEGORIES), rnd.uniform(1, 500))
                    for i in range(products)))
    db.executemany("INSERT INTO orders VALUES (?,?,?,?,?)",
                   ((i, rnd.randrange(customers), rnd.randrange(products), rnd.randint(1, 9),
                     "n" * rnd.randint(0, 40)) for i in range(orders)))
    db.execute("CREATE INDEX orders_by_customer ON orders(customer_id)")
    db.commit()
    # Identity map: Python objects the request path reads instead of joining.
    prods = {pid: {"name": n, "category": c, "price": p}
             for pid, n, c, p in db.execute("SELECT * FROM products")}
    custs = {cid: {"name": n, "city": city}
             for cid, n, city in db.execute("SELECT * FROM customers")}
    return db, prods, custs


def make_handler(db, prods, custs):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"  # keep-alive: one connection per probe

        def do_GET(self):
            parts = self.path.strip("/").split("/")
            if len(parts) != 2 or parts[0] != "customer" or not parts[1].isdigit() \
                    or int(parts[1]) not in custs:
                self.send_error(404)
                return
            cid = int(parts[1])
            rows = db.execute("SELECT id, product_id, qty FROM orders WHERE customer_id = ?",
                              (cid,)).fetchall()
            orders, by_cat = [], {}
            for oid, pid, qty in rows:
                p = prods[pid]
                total = qty * p["price"]
                by_cat[p["category"]] = by_cat.get(p["category"], 0.0) + total
                orders.append({"id": oid, "product": p["name"], "category": p["category"],
                               "qty": qty, "total": total})
            body = PAGE.render(c=custs[cid], orders=orders, by_cat=sorted(by_cat.items()),
                               grand=sum(by_cat.values())).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    return Handler


class UnixHTTPServer(HTTPServer):
    address_family = socket.AF_UNIX

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)  # skip HTTPServer's getfqdn
        self.server_name, self.server_port = "localhost", 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ready-file", required=True)
    ap.add_argument("--unix-socket")
    ap.add_argument("--port", type=int)
    ap.add_argument("--customers", type=int, default=50000)
    ap.add_argument("--orders", type=int, default=1500000)
    args = ap.parse_args()
    if bool(args.unix_socket) == bool(args.port):
        sys.exit("need exactly one of --unix-socket, --port")

    db, prods, custs = build(args.customers, args.orders)
    handler = make_handler(db, prods, custs)
    if args.unix_socket:
        if os.path.exists(args.unix_socket):
            os.unlink(args.unix_socket)
        srv = UnixHTTPServer(args.unix_socket, handler)
    else:
        # Headers and body go out as two writes; with Nagle on, the body
        # waits for the client's delayed ACK (~40 ms per request).
        handler.disable_nagle_algorithm = True
        srv = HTTPServer(("127.0.0.1", args.port), handler)
    with open(args.ready_file, "w") as f:
        f.write(str(os.getpid()))
    srv.serve_forever()


if __name__ == "__main__":
    main()
