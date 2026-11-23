import socket, sys, time
port = int(sys.argv[1])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', port))
s.listen(5)
s.settimeout(20)
print('LISTEN', port, flush=True)
try:
    c, a = s.accept()
    print('ACCEPT from', a, flush=True)
    c.settimeout(5)
    try:
        data = c.recv(4096)
        print('DATA', data[:400], flush=True)
    except Exception as e:
        print('RECV_ERR', e, flush=True)
    c.sendall(b'HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nHELLO')
    time.sleep(1)
except Exception as e:
    print('ACCEPT_TIMEOUT_OR_ERR', e, flush=True)
