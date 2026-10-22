import socket,subprocess,time
p=subprocess.Popen(['/tmp/transport-fixture'])
try:
  for _ in range(100):
    try: s=socket.create_connection(('127.0.0.1',19099),.2);break
    except OSError: time.sleep(.02)
  else: raise RuntimeError('did not start')
  s.settimeout(3)
  pending=b''
  def response(sock=s):
    global pending
    while b'\r\n\r\n' not in pending: pending+=sock.recv(65536)
    h,pending=pending.split(b'\r\n\r\n',1)
    length=int([x for x in h.split(b'\r\n') if x.lower().startswith(b'content-length:')][0].split(b':')[1])
    while len(pending)<length:
      got=sock.recv(65536)
      assert got, 'early EOF'
      pending+=got
    body,pending=pending[:length],pending[length:]
    return int(h.split(b' ')[1]),body
  s.sendall(b'POST /echo?x=y HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhe')
  time.sleep(.03)
  s.sendall(b'lloGET / HTTP/1.1\r\nHost: x\r\n\r\n')
  assert response()==(200,b'hello')
  assert response()==(200,b'')
  s.sendall(b'POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3;foo=bar\r\nabc\r\n2\r\nde\r\n0\r\nX-Trailer: yes\r\n\r\nGET / HTTP/1.1\r\n\r\n')
  assert response()==(200,b'abcde')
  assert response()==(200,b'')
  payload=b'z'*900000
  s.sendall(b'POST / HTTP/1.1\r\nContent-Length: 900000\r\n\r\n'+payload)
  assert response()==(200,payload)
  pipeline=b'GET / HTTP/1.1\r\nHost: x\r\nX-Padding: '+b'a'*80+b'\r\n\r\n'
  s.sendall(pipeline*200)
  for _ in range(200): assert response()==(200,b'')
  s.sendall(b'GET /fail HTTP/1.1\r\n\r\n')
  assert response()==(500,b'{"error":"internal server error"}')
  s.sendall(b'GET /large HTTP/1.1\r\n\r\nGET / HTTP/1.1\r\n\r\n')
  time.sleep(.1)
  assert response()==(200,b'x'*8000000)
  assert response()==(200,b'')
  s.close(); pending=b''
  s=socket.create_connection(('127.0.0.1',19099),.2); s.settimeout(3)
  s.sendall(b'POST / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\nxx')
  assert response(s)[0]==400
  assert s.recv(1)==b''
  s.close();pending=b''
  s=socket.create_connection(('127.0.0.1',19099),.2);s.settimeout(3)
  s.sendall(b'POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\ntestGET / HTTP/1.1\r\n\r\n')
  s.shutdown(socket.SHUT_WR)
  assert response(s)==(200,b'test')
  assert response(s)==(200,b'')
  assert s.recv(1)==b''
  print('PASS: fragmented bodies, 900k body across many reads, 200-request pipeline, keepalive, pipelining, chunked trailers, commit failure, large partial writes, ambiguous framing rejection, peer half-close')
finally:
  p.terminate();p.wait()
