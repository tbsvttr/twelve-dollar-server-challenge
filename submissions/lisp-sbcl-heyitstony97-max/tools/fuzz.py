#!/usr/bin/env python3
"""Malformed-request fuzz gate. usage: fuzz.py PORT SERVER_PID  (JWT_SECRET must match the server)."""
import base64, hashlib, hmac, json, os, random, socket, sys, time
port, pid = int(sys.argv[1]), int(sys.argv[2])
SECRET = os.environ.get("JWT_SECRET", "twelve-dollar-challenge").encode()
rnd = random.Random(12345)
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=")

def tok(payload):
    h = b64(b'{"alg":"HS256","typ":"JWT"}'); p = b64(json.dumps(payload).encode())
    return h + b"." + p + b"." + b64(hmac.new(SECRET, h + b"." + p, hashlib.sha256).digest())

T = tok({"sub": "1", "username": "golden_ember_1", "exp": 4102444800})

def req(method, path, body=None, auth=True, extra=b""):
    b = body if body is not None else b""
    h = method.encode() + b" " + path + b" HTTP/1.1\r\nHost: x\r\n"
    if auth: h += b"Authorization: Bearer " + T + b"\r\n"
    if body is not None: h += b"Content-Type: application/json\r\nContent-Length: " + str(len(b)).encode() + b"\r\n"
    return h + extra + b"\r\n" + b

shapes = [req("GET", b"/health", auth=False), req("GET", b"/feed", auth=False), req("GET", b"/posts/5", auth=False),
          req("POST", b"/posts", b'{"body":"fuzz"}'), req("POST", b"/posts/5/like", b""),
          req("POST", b"/posts", b'{"body":"a\\u00e9\\n\\"q"}')]
cases = []
for s in shapes:
    for i in range(len(s)): cases.append(s[:i])                 # truncation at every offset
    for i in range(len(s)):                                     # byte flip at every offset
        m = bytearray(s); m[i] = rnd.randrange(256); cases.append(bytes(m))
    for _ in range(3000):                                       # random multi-byte mutations
        m = bytearray(s)
        for _ in range(rnd.randint(1, 6)): m[rnd.randrange(len(m))] = rnd.randrange(256)
        cases.append(bytes(m))
for cl in [b"abc", b"-1", b"-99999999999", b"99999999999999999999999", b"4294967296", b"1000000", b"", b" ", b"0x10", b"5, 5", b"+3", b"13"]:
    cases.append(b"POST /posts HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer " + T + b"\r\nContent-Length: " + cl + b"\r\n\r\n{\"body\":\"x\"}")
cases += [b"GET /feed HTTP/1.1\r\nHost x\r\n\r\n", b"GET /feed HTTP/1.1\r\nnocolon\r\n\r\n", b"\r\n\r\n", b"\r\n", b"\n\n",
          b"GET /feed HTTP/1.1\r\nX: " + b"a" * 65536 + b"\r\n\r\n", b"GET /feed HTTP/1.1\r\n" + b"X: y\r\n" * 12000 + b"\r\n",
          b"GET " + b"/a" * 40000 + b" HTTP/1.1\r\n\r\n", b"G", b"\x00" * 100, b"GET\r\n\r\n", b"GET  HTTP/1.1\r\n\r\n"]
H, P, S = T.split(b".")
badtoks = [b"", b"x", b"a.b", b"a.b.c.d", b"...", b"!!!.@@@.###", H + b"." + P, H + b"." + P + b".", H + b"." + P + b"." + S + b"A" * 5000,
           H + b"." + P + b"." + S[:-3], b"=." * 3, H + b".%%%." + S, b"\xff\xfe." + P + b"." + S, S + b"." + P + b"." + H,
           b".".join([H, b64(b"{bad"), S]), b".".join([H, b64(b'{"sub":"x","exp":"y"}'), S]), b".".join([H, b64(b"[]"), S])]
for _ in range(300):
    n = rnd.randint(1, 400)
    badtoks.append(base64.urlsafe_b64encode(os.urandom(n)) + b"." + os.urandom(rnd.randint(0, 30)).hex().encode() + b"." + b64(os.urandom(32)))
for t in badtoks:
    for path in (b"/posts", b"/posts/5/like"):
        cases.append(b"POST " + path + b" HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer " + t + b"\r\nContent-Length: 2\r\n\r\n{}")
    cases.append(b"POST /posts HTTP/1.1\r\nHost: x\r\nAuthorization: " + t + b"\r\nContent-Length: 2\r\n\r\n{}")
ids = [b"abc", b"-1", b"0", b"99999999999999999999999999", b"9223372036854775808", b"1e3", b"5/6", b"%00", b"", b"5?x=1", b"\xff", b"0" * 5000, b"1.5", b" 5"]
for i in ids:
    cases.append(req("GET", b"/posts/" + i, auth=False)); cases.append(req("POST", b"/posts/" + i + b"/like", b""))
    cases.append(req("POST", b"/posts/" + i + b"/like", b"", auth=False))
for body in [b"", b"{", b"[]", b'{"body":', b'{"body":"' + b"a" * 100000 + b'"}', b'{"body":"\\u"}', b'{"body":"\\ud800"}', b'{"body":"\\x"}',
             b'{"body":5}', b'{"body":null}', b'{"body":"' + bytes(range(256)) + b'"}', b'{"body":"\xff\xfe"}', b'\x00' * 50, b'{"body":"' + b"\\" * 999 + b'"}']:
    cases.append(req("POST", b"/posts", body))
print("cases:", len(cases), flush=True); assert len(cases) >= 20000, len(cases)

def alive():
    try: os.kill(pid, 0); return True
    except OSError: return False

bad = 0; stat = {}
def send(c):
    global bad
    s = socket.create_connection(("127.0.0.1", port), timeout=0.06)
    try:
        try: s.sendall(c)
        except OSError: return
        try: s.shutdown(socket.SHUT_WR)
        except OSError: pass
        buf = b""
        try:
            while len(buf) < 70000:
                d = s.recv(65536)
                if not d: break
                buf += d
        except (socket.timeout, OSError): pass     # server waiting for more bytes on a truncated request: acceptable
        for line in buf.split(b"HTTP/1.1 ")[1:]:
            code = line[:3]; stat[code] = stat.get(code, 0) + 1
            if code[:1] == b"5": bad += 1; print("5xx for", c[:100], code)
    finally: s.close()

t0 = time.time()
for n, c in enumerate(cases):
    send(c)
    if n % 500 == 0 and not alive(): print("SERVER DIED near case", n, c[:80]); sys.exit(1)
if not alive(): print("SERVER DIED"); sys.exit(1)
s = socket.create_connection(("127.0.0.1", port), timeout=5); s.sendall(req("GET", b"/health", auth=False)); r = s.recv(200)
if not r.startswith(b"HTTP/1.1 200"): print("health after fuzz:", r); sys.exit(1)
print("status counts:", {k.decode("latin1"): v for k, v in sorted(stat.items())}, "5xx:", bad, "secs: %.0f" % (time.time() - t0))
sys.exit(1 if bad else 0)
