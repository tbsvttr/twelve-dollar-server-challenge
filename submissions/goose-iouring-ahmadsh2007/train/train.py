#!/usr/bin/env python3
"""PGO training for build.sh: runs the instrumented server on a synthetic database of its own
(never the challenge seed) and drives the load test's request mix through it, plus the error
paths the test suite checks. Build time only; nothing here ships in bin/server.

    python3 train/train.py bin/server
"""
import base64, hashlib, hmac, json, os, random, signal, socket, sqlite3, subprocess, sys
import tempfile, threading, time

SCHEMA = """
CREATE TABLE users (
  id          INTEGER PRIMARY KEY,
  username    TEXT NOT NULL UNIQUE,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE TABLE posts (
  id          INTEGER PRIMARY KEY,
  user_id     INTEGER NOT NULL REFERENCES users(id),
  body        TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500),
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE TABLE likes (
  user_id     INTEGER NOT NULL REFERENCES users(id),
  post_id     INTEGER NOT NULL REFERENCES posts(id),
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (user_id, post_id)
);
CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);
CREATE INDEX posts_user_id_idx       ON posts (user_id);
CREATE INDEX likes_post_id_idx       ON likes (post_id);
"""

SECRET = b"pgo-training-secret"
WORDS = ("alpha beta gamma delta river stone cloud paper light quick slow green tiny vast "
         "query index cache page tree root leaf node byte word line loop").split()
NUSERS, NPOSTS, NLIKES = 5000, 40000, 160000


def make_db(path):
    rnd = random.Random(7)
    db = sqlite3.connect(path)
    db.executescript("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;" + SCHEMA)
    db.executemany("INSERT INTO users (id, username, created_at) VALUES (?, ?, ?)",
                   ((i, f"trainee_{rnd.choice(WORDS)}_{i}", "2024-01-01T00:00:00.000Z")
                    for i in range(1, NUSERS + 1)))
    t = 1704067200.0
    posts = []
    for i in range(1, NPOSTS + 1):
        t += rnd.uniform(0, 60)
        n = rnd.randint(3, 40)
        body = " ".join(rnd.choice(WORDS) for _ in range(n)).capitalize() + rnd.choice(".!?")
        if i % 997 == 0:
            body += ' "quoted" \\ back\tslash é✓'
        ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % rnd.randint(0, 999)
        posts.append((i, rnd.randint(1, NUSERS), body, ts))
    db.executemany("INSERT INTO posts (id, user_id, body, created_at) VALUES (?, ?, ?, ?)", posts)
    likes = set()
    while len(likes) < NLIKES:
        likes.add((rnd.randint(1, NUSERS), rnd.randint(1, NPOSTS)))
    db.executemany("INSERT INTO likes (user_id, post_id) VALUES (?, ?)", sorted(likes))
    db.commit()
    db.execute("PRAGMA journal_mode=WAL")
    db.close()


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def token(sub, name, exp_delta=3600, alg="HS256", payload=None):
    head = b64(json.dumps({"alg": alg, "typ": "JWT"}, separators=(",", ":")).encode())
    now = int(time.time())
    body = payload if payload is not None else {"sub": str(sub), "username": name,
                                                "iat": now, "exp": now + exp_delta}
    pl = b64(json.dumps(body, separators=(",", ":")).encode())
    sig = b64(hmac.new(SECRET, f"{head}.{pl}".encode(), hashlib.sha256).digest())
    return f"{head}.{pl}.{sig}"


class Client:
    def __init__(self, port):
        self.port = port
        self.s = None
        self.buf = b""

    def req(self, method, path, auth=None, body=None):
        if self.s is None:
            self.s = socket.create_connection(("127.0.0.1", self.port))
            self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        h = f"{method} {path} HTTP/1.1\r\nHost: train\r\nUser-Agent: train\r\n"
        if auth:
            h += f"Authorization: {auth}\r\n"
        data = b""
        if body is not None:
            data = body.encode() if isinstance(body, str) else body
            h += f"Content-Type: application/json\r\nContent-Length: {len(data)}\r\n"
        self.s.sendall(h.encode() + b"\r\n" + data)
        while b"\r\n\r\n" not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                self.s = None
                self.buf = b""
                return 0, b""
            self.buf += chunk
        head, _, rest = self.buf.partition(b"\r\n\r\n")
        status = int(head[9:12])
        n = 0
        for line in head.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                n = int(line.split(b":")[1])
        while len(rest) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                break
            rest += chunk
        self.buf = rest[n:]
        return status, rest[:n]


def worker(port, seed, count, errors):
    rnd = random.Random(seed)
    c = Client(port)
    ids = []
    for _ in range(count):
        uid = rnd.randint(1, NUSERS)
        tok = "Bearer " + token(uid, f"trainee_{uid}")
        r = rnd.random()
        if r < 0.44 or not ids:
            st, body = c.req("GET", "/feed")
            ids = [int(x) for x in body.split(b'"id":')[1:] for x in [x.split(b",")[0]]] or ids
        elif r < 0.88:
            c.req("GET", f"/posts/{rnd.choice(ids)}")
        elif r < 0.95:
            c.req("POST", f"/posts/{rnd.choice(ids)}/like", tok, "")
        elif r < 0.965:
            c.req("POST", "/posts", tok, json.dumps({"body": f"trainee {uid} says hi {rnd.random()}"}))
        else:
            k = rnd.randint(0, 15)
            if k == 0: c.req("GET", "/health")
            elif k == 1: c.req("GET", "/nope")
            elif k == 2: c.req("GET", f"/posts/{rnd.choice(['0', '-1', 'abc', '1.5'])}")
            elif k == 3: c.req("GET", "/posts/999999999")
            elif k == 4: c.req("POST", "/posts", None, '{"body":"x"}')
            elif k == 5: c.req("POST", "/posts", "Basic abc", '{"body":"x"}')
            elif k == 6: c.req("POST", "/posts", "Bearer abc", '{"body":"x"}')
            elif k == 7: c.req("POST", "/posts", "Bearer " + tok[7:-4] + "AAAA", '{"body":"x"}')
            elif k == 8: c.req("POST", "/posts", "Bearer " + token(uid, "x", -3600), '{"body":"x"}')
            elif k == 9: c.req("POST", "/posts", "Bearer " + token(0, "x", payload={"sub": "abc", "username": "x", "exp": int(time.time()) + 99}), '{"body":"x"}')
            elif k == 10: c.req("POST", "/posts", tok, rnd.choice(['{"body":""}', '{"body":"   "}', '{"body":123}', '{}', '{bad json']))
            elif k == 11: c.req("POST", "/posts", tok, json.dumps({"body": "a" * 501}))
            elif k == 12: c.req("POST", "/posts", tok, '{"body":"  t\\u00e9st \\"q\\" \\ud83d\\ude00 ✓ ", "x":[1,{"y":null}]}')
            elif k == 13: c.req("POST", "/posts/abc/like", tok, "")
            elif k == 14: c.req("POST", "/posts/999999999/like", tok, "")
            else: c.req("GET", "/feed?x=1")


def main():
    server = os.path.abspath(sys.argv[1])
    tmp = tempfile.mkdtemp(prefix="goose-train-")
    path = os.path.join(tmp, "train.db")
    make_db(path)
    port = 20000 + os.getpid() % 20000
    env = dict(os.environ, SQLITE_PATH=path, JWT_SECRET=SECRET.decode(), HOST="127.0.0.1", PORT=str(port))
    p = subprocess.Popen([server], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(200):
            try:
                if Client(port).req("GET", "/health")[0] == 200:
                    break
            except OSError:
                time.sleep(0.05)
        threads = [threading.Thread(target=worker, args=(port, i, 4000, None)) for i in range(8)]
        t0 = time.time()
        for t in threads: t.start()
        for t in threads: t.join()
        print(f"trained: {8 * 4000} requests in {time.time() - t0:.1f} s", file=sys.stderr)
    finally:
        p.send_signal(signal.SIGTERM)  # the instrumented build's handler exits so the profile is written
        p.wait(timeout=30)
        for f in os.listdir(tmp):
            os.unlink(os.path.join(tmp, f))
        os.rmdir(tmp)


if __name__ == "__main__":
    main()
