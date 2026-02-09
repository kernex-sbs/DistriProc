import socket
import struct
import sys

HOST = '127.0.0.1'
PORT = 9999
PAGE_SIZE = 4096

def handle_client(conn, addr):
    print(f"Connected by {addr}")
    try:
        while True:
            # Expecting 8 bytes (uint64_t) representing the page index or address
            data = conn.recv(8)
            if not data:
                break

            if len(data) != 8:
                print(f"Received incomplete request: {len(data)} bytes")
                break

            # Unpack the page index (though for this PoC we might just ignore it and return a pattern)
            page_idx = struct.unpack('Q', data)[0]
            print(f"Request for page index: {page_idx}")

            # Generate a recognizable pattern
            # For example, fill with a byte value derived from the page index
            # Let's use (page_idx + 1) % 255 to verify we got the right page request
            fill_char = (page_idx + 1) % 255
            response = bytes([fill_char]) * PAGE_SIZE

            conn.sendall(response)
            print(f"Sent {len(response)} bytes (filled with {fill_char})")

    except ConnectionResetError:
        print("Connection reset by peer")
    finally:
        conn.close()
        print("Connection closed")

def main():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((HOST, PORT))
        s.listen()
        print(f"Page Server listening on {HOST}:{PORT}")

        while True:
            conn, addr = s.accept()
            handle_client(conn, addr)

if __name__ == '__main__':
    main()
