"""Throwaway WebSocket relay for the `ws` research engine (app-ws.patch). Never part of am.

usage: python3 -I wsrelay.py <listen port> <daemon port> <log file>

Accepts WebSocket connections on localhost:<listen port>. Each text message (an engine report)
is POSTed to http://localhost:<daemon port>/report with the page's Origin, as the page's own
fetch would, so the daemon (status, idle rules, play) works as with the stock page. Firefox
then makes one long-lived connection instead of one HTTP request per report. Logs one JSON line
a minute: connections, messages, POSTs that failed.
"""
import asyncio, base64, datetime, hashlib, http.client, json, struct, sys, time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
listen_port, daemon_port, log_path = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
stats = {"conns": 0, "msgs": 0, "post_fail": 0, "last_status": None}


def post(body):
    try:
        c = http.client.HTTPConnection("localhost", daemon_port, timeout=5)
        c.request("POST", "/report", body=body, headers={
            "Origin": f"http://localhost:{daemon_port}", "Content-Type": "text/plain;charset=UTF-8"})
        r = c.getresponse()
        r.read()
        stats["last_status"] = r.status
        if r.status >= 300:
            stats["post_fail"] += 1
        c.close()
    except OSError:
        stats["post_fail"] += 1


async def handle(reader, writer):
    try:
        req = await reader.readuntil(b"\r\n\r\n")
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError):
        writer.close()
        return
    headers = {}
    for line in req.decode("latin1").split("\r\n")[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    key = headers.get("sec-websocket-key")
    if not key:
        writer.close()
        return
    accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
    await writer.drain()
    stats["conns"] += 1
    try:
        while True:
            h = await reader.readexactly(2)
            op, n = h[0] & 0x0F, h[1] & 0x7F
            if n == 126:
                n = struct.unpack(">H", await reader.readexactly(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", await reader.readexactly(8))[0]
            mask = await reader.readexactly(4) if h[1] & 0x80 else b"\0\0\0\0"
            data = bytearray(await reader.readexactly(n))
            for i in range(n):
                data[i] ^= mask[i % 4]
            if op == 8:  # close
                break
            if op == 9:  # ping -> pong
                writer.write(bytes([0x8A, len(data)]) + bytes(data))
                await writer.drain()
            elif op in (0, 1):  # text (reports are small: one unfragmented frame)
                stats["msgs"] += 1
                post(bytes(data))
    except (asyncio.IncompleteReadError, ConnectionError):
        pass
    writer.close()


async def logger():
    while True:
        await asyncio.sleep(60 - time.time() % 60)
        with open(log_path, "a") as f:
            f.write(json.dumps({"wall": datetime.datetime.now().strftime("%H:%M:%S"), **stats}) + "\n")


async def main():
    server = await asyncio.start_server(handle, "localhost", listen_port)
    asyncio.create_task(logger())
    async with server:
        await server.serve_forever()


asyncio.run(main())
