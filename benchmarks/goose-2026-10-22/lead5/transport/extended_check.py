import os,socket,struct,subprocess,time

class Client:
    def __init__(self):
        self.s=socket.create_connection(('127.0.0.1',19099),2)
        self.s.settimeout(5)
        self.pending=b''
    def send(self,data): self.s.sendall(data)
    def response(self):
        while b'\r\n\r\n' not in self.pending:
            got=self.s.recv(65536)
            assert got, 'EOF in header'
            self.pending+=got
        h,self.pending=self.pending.split(b'\r\n\r\n',1)
        length=int([x for x in h.split(b'\r\n') if x.lower().startswith(b'content-length:')][0].split(b':')[1])
        chunks=[];remaining=length
        while remaining:
            if self.pending:
                got,self.pending=self.pending[:remaining],self.pending[remaining:]
            else: got=self.s.recv(min(remaining,65536))
            assert got,'EOF in body'
            chunks.append(got);remaining-=len(got)
        return int(h.split(b' ')[1]),b''.join(chunks)
    def close(self): self.s.close()

p=subprocess.Popen(['/tmp/transport-fixture'])
try:
    for _ in range(100):
        try: c=Client();c.close();break
        except OSError:time.sleep(.02)
    else:raise RuntimeError('fixture failed to start')
    # Parse a close header before any body fragment arrives.
    for version in (b'HTTP/1.1',b'HTTP/1.0'):
        c=Client();body=b'a'*65571
        c.send(b'POST / '+version+b'\r\nConnection: close\r\nContent-Length: 65571\r\n\r\n')
        time.sleep(.02)
        c.send(body[:13]);time.sleep(.01);c.send(body[13:3000]);c.send(body[3000:])
        assert c.response()==(200,body)
        assert c.s.recv(1)==b'';c.close()
    c=Client()
    c.send(b'POST / HTTP/1.1\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n')
    time.sleep(.02)
    c.send(b'1001\r\n'+b'a'*31);time.sleep(.01)
    c.send(b'a'*(4097-31)+b'\r\n2000\r\n'+b'b'*8192+b'\r\n0\r\nT: x\r\n\r\n')
    assert c.response()==(200,b'a'*4097+b'b'*8192)
    assert c.s.recv(1)==b'';c.close()
    for content_length in (b'1048577',b'18446744073709551615',b'999999999999999999999999999'):
        c=Client()
        c.send(b'POST / HTTP/1.1\r\nContent-Length: '+content_length+b'\r\n\r\n')
        assert c.response()[0]==413
        assert c.s.recv(1)==b'';c.close()
    # A blocked send plus queued input crosses the cancellation high-water mark.
    c=Client();c.send(b'GET /large HTTP/1.1\r\n\r\n');time.sleep(.03)
    body=b'p'*120000
    c.send(b'POST / HTTP/1.1\r\nContent-Length: 120000\r\n\r\n'+body)
    time.sleep(.03)
    assert c.response()==(200,b'x'*8000000)
    assert c.response()==(200,body)
    c.send(b'GET / HTTP/1.1\r\n\r\n'*100)
    for _ in range(100):assert c.response()==(200,b'')
    c.close()
    # Reuse slots after resets while receives and large sends may be in flight.
    for _ in range(32):
        c=Client();c.send(b'GET /large HTTP/1.1\r\n\r\n')
        c.s.setsockopt(socket.SOL_SOCKET,socket.SO_LINGER,struct.pack('ii',1,0));c.close()
        time.sleep(.001)
    c=Client();c.send(b'POST /fail HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc')
    assert c.response()==(500,b'{"error":"internal server error"}');c.close()
    # net_close must cancel an accept, timer, idle receives and partial inputs.
    idle=[Client() for _ in range(24)]
    for c in idle[:12]:c.send(b'POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\na')
    c=Client();c.send(b'GET /stop HTTP/1.1\r\n\r\n')
    assert p.wait(timeout=5)==0
    c.close()
    for c in idle:c.close()
    print('PASS: fixed/chunked fragmented close, HTTP1.0 close, blocked-send input cancellation/rearm, pipeline, resets/slot reuse, exact failed-commit500, explicit net_close with pending accept/timer/receives')
finally:
    if p.poll() is None:p.terminate();p.wait(timeout=5)
