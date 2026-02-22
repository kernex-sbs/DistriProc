import asyncio
import struct
import sys

HOST = '127.0.0.1'
PORT = 9999
PAGE_SIZE = 4096

async def handle_client(reader, writer):
    addr = writer.get_extra_info('peername')
    print(f"Connected by {addr}")

    response_queue = asyncio.Queue()

    async def write_loop():
        try:
            while True:
                item = await response_queue.get()
                if item is None:
                    break
                response, fill_char = item
                writer.write(response)
                await writer.drain()
                print(f"Sent {len(response)} bytes (filled with {fill_char})")
        except ConnectionError:
            pass

    writer_task = asyncio.create_task(write_loop())

    try:
        while True:
            try:
                # Expecting 8 bytes (uint64_t) representing the page index or address
                data = await reader.readexactly(8)
            except asyncio.IncompleteReadError:
                break
            
            page_idx = struct.unpack('Q', data)[0]
            print(f"Request for page index: {page_idx}")

            # Generate a recognizable pattern
            # For example, fill with a byte value derived from the page index
            # Let's use (page_idx + 1) % 255 to verify we got the right page request
            fill_char = (page_idx + 1) % 255
            response = bytes([fill_char]) * PAGE_SIZE

            await response_queue.put((response, fill_char))

    except ConnectionResetError:
        print("Connection reset by peer")
    finally:
        await response_queue.put(None)
        await writer_task
        writer.close()
        await writer.wait_closed()
        print("Connection closed")

async def main():
    server = await asyncio.start_server(
        handle_client, HOST, PORT)

    addrs = ', '.join(str(sock.getsockname()) for sock in server.sockets)
    print(f"Page Server listening on {addrs}")

    async with server:
        await server.serve_forever()

if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nServer shutting down.")
