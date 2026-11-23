#!/usr/bin/env python3
"""批40 验收：不响应 mock（接受连接后挂起，用于验证超时上界）。"""
import socket, sys, time, threading
port = int(sys.argv[1]) if len(sys.argv) > 1 else 18083
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", port))
srv.listen(50)
print(f"blackhole listening on {port}", flush=True)
def handle(c):
    try:
        c.settimeout(300)
        try:
            c.recv(65536)
        except Exception:
            pass
        time.sleep(300)
    finally:
        try: c.close()
        except Exception: pass
while True:
    conn, _ = srv.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
