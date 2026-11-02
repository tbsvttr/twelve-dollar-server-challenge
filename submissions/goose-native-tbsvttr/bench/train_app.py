#!/usr/bin/env python3
"""Build-only application PGO driver. No challenge seed or tokens are read.

Create disposable, independently generated exact-schema SQLite databases and
exercise the real HTTP server. This records compiler branch feedback, never a
throughput score. The production executable has no training hooks or fixtures.
"""
import argparse
import base64
from collections import Counter
import hashlib
import hmac
import json
import os
from pathlib import Path
import random
import signal
import socket
import sqlite3
import subprocess
import tempfile
import time


SECRET = "goose-build-only-synthetic-secret"
SCHEMA = """
CREATE TABLE users(id INTEGER PRIMARY KEY,username TEXT NOT NULL UNIQUE,created_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')));
CREATE TABLE posts(id INTEGER PRIMARY KEY,user_id INTEGER NOT NULL REFERENCES users(id),body TEXT NOT NULL CHECK(length(body) BETWEEN 1 AND 500),created_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')));
CREATE TABLE likes(user_id INTEGER NOT NULL REFERENCES users(id),post_id INTEGER NOT NULL REFERENCES posts(id),created_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')),PRIMARY KEY(user_id,post_id));
CREATE INDEX posts_created_at_id_idx ON posts(created_at DESC,id DESC);
CREATE INDEX posts_user_id_idx ON posts(user_id);
CREATE INDEX likes_post_id_idx ON likes(post_id);
"""
TEXTS = (
    "A freshly generated post for native compiler training.",
    "Quotes: \"hello\"; slash: \\; new line:\n\ttab.",
    "Unicode: café Ελληνικά 中文 😀. Independent synthetic data.",
    "a" * 15 + "\"" + "b" * 16 + "\\" + "c" * 32,
    "x" * 240,
)


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def authorization(user=1, name="synthetic-user-1", header=None, payload=None):
    encode = lambda value: base64.urlsafe_b64encode(value.encode()).rstrip(b"=").decode()
    head = header if header is not None else compact({"alg": "HS256", "typ": "JWT"})
    body = payload if payload is not None else compact({"sub": str(user), "username": name, "exp": 4102444800})
    message = encode(head) + "." + encode(body)
    signature = base64.urlsafe_b64encode(hmac.new(SECRET.encode(), message.encode(), hashlib.sha256).digest()).rstrip(b"=").decode()
    return "Bearer " + message + "." + signature


def fixture(path, sparse=False, empty=False):
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    db.executemany("INSERT INTO users(id,username) VALUES(?,?)", [(n, f"synthetic-user-{n}") for n in range(1, 257)])
    size = 0 if empty else 8192
    ids = [n * (37 if sparse else 1) for n in range(1, size + 1)]
    # Equal timestamps plus the required id tie-breaker exercise dense and
    # sparse feeds deterministically, independently of any benchmark fixture.
    db.executemany("INSERT INTO posts(id,user_id,body,created_at) VALUES(?,?,?,?)",
                   [(post, n % 256 + 1, TEXTS[n % len(TEXTS)], "2024-03-17T12:34:56.789Z")
                    for n, post in enumerate(ids)])
    db.executemany("INSERT INTO likes(user_id,post_id) VALUES(?,?)",
                   [((n + offset * 19) % 256 + 1, post)
                    for n, post in enumerate(ids) for offset in range(4)])
    db.commit()
    if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
        raise RuntimeError("synthetic fixture integrity failed")
    db.close()
    return ids


class Connection:
    def __init__(self, port):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=20)
        self.pending = b""

    def close(self):
        self.socket.close()

    def response(self):
        while b"\r\n\r\n" not in self.pending:
            data = self.socket.recv(65536)
            if not data:
                raise RuntimeError("server closed before response headers")
            self.pending += data
        header, self.pending = self.pending.split(b"\r\n\r\n", 1)
        lines = header.split(b"\r\n")
        status = int(lines[0].split()[1])
        headers = dict(line.split(b":", 1) for line in lines[1:])
        length = next((int(value) for key, value in headers.items() if key.lower() == b"content-length"), None)
        if length is None:
            raise RuntimeError("training response lacks Content-Length")
        while len(self.pending) < length:
            data = self.socket.recv(65536)
            if not data:
                raise RuntimeError("server closed before response body")
            self.pending += data
        body, self.pending = self.pending[:length], self.pending[length:]
        return status, json.loads(body)

    def batch(self, requests, counts):
        wire = []
        for label, method, path, body, auth, expected in requests:
            data = body if isinstance(body, bytes) else body.encode()
            headers = [f"{method} {path} HTTP/1.1", "Host: localhost", "Connection: keep-alive",
                       "Content-Type: application/json", f"Content-Length: {len(data)}"]
            if auth is not None:
                headers.append("Authorization: " + auth)
            wire.append("\r\n".join(headers).encode() + b"\r\n\r\n" + data)
        self.socket.sendall(b"".join(wire))
        for label, method, path, body, auth, expected in requests:
            status, result = self.response()
            accepted = expected if isinstance(expected, tuple) else (expected,)
            if status not in accepted:
                raise RuntimeError(f"training {label}: expected {accepted}, got {status}: {result!r}")
            counts[f"{label}:{status}"] += 1


def diagnostics(auth):
    expired = authorization(payload='{"sub":"1","username":"synthetic","exp":1}')
    invalid_claims = authorization(payload='{"sub":"1","exp":4102444800}')
    wrong_alg = authorization(header='{"alg":"HS512"}')
    malformed_header = authorization(header='{"alg":"HS256","bad":[1,]}')
    escaped = authorization(name='synthetic 😀 "author"')
    rows = [
        ("health", "GET", "/health", "", None, 200),
        ("query-route", "GET", "/feed?build=synthetic", "", None, 200),
        ("missing-post", "GET", "/posts/999999999", "", None, 404),
        ("bad-id", "GET", "/posts/0", "", None, 400),
        ("bad-id", "GET", "/posts/not-an-integer", "", None, 400),
        ("route-error", "GET", "/posts/1/extra", "", None, 404),
        ("route-error", "DELETE", "/posts/1", "", None, 404),
        ("missing-auth", "POST", "/posts", '{"body":"ignored"}', None, 401),
        ("invalid-auth", "POST", "/posts", '{"body":"ignored"}', "Bearer malformed", 401),
        ("expired-auth", "POST", "/posts", '{"body":"ignored"}', expired, 401),
        ("claims-error", "POST", "/posts", '{"body":"ignored"}', invalid_claims, 401),
        ("algorithm-error", "POST", "/posts", '{"body":"ignored"}', wrong_alg, 401),
        ("jwt-json-error", "POST", "/posts", '{"body":"ignored"}', malformed_header, 401),
        ("json-error", "POST", "/posts", '{"body":', auth, 400),
        ("json-error", "POST", "/posts", '{"body":"x","ignored":[1,]}', auth, 400),
        ("body-required", "POST", "/posts", '{}', auth, 400),
        ("body-required", "POST", "/posts", '{"body":null}', auth, 400),
        ("body-required", "POST", "/posts", '{"body":"  \\n\\t"}', auth, 400),
        ("body-too-long", "POST", "/posts", compact({"body": "x" * 501}), auth, 400),
        ("utf8-error", "POST", "/posts", b'{"body":"\xff"}', auth, 400),
        ("bad-like-id", "POST", "/posts/0/like", "", auth, 400),
        ("missing-like-post", "POST", "/posts/999999999/like", "", auth, 404),
        ("create-escaped", "POST", "/posts", '{"bo\\u0064y":" hi \\ud83d\\ude00 \\"quoted\\" "}', escaped, 201),
        ("create-nested", "POST", "/posts", '{"ignored":{"a":[false,null,{},3e4]},"body":"nested"}', auth, 201),
        ("create-controls", "POST", "/posts", compact({"body": "controls:" + "".join(chr(n) for n in range(32)) + ":end"}), auth, 201),
        ("create-max-unicode", "POST", "/posts", compact({"body": "😀" * 500}), auth, 201),
    ]
    return rows


def train(binary, directory, phase, requests):
    db = directory / f"{phase}.db"
    ids = fixture(db, sparse=phase == "sparse", empty=phase == "empty")
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    log_path = directory / f"{phase}.log"
    counts = Counter()
    auth = authorization()
    with log_path.open("wb") as log:
        server = subprocess.Popen([str(binary)], env=dict(os.environ, HOST="127.0.0.1", PORT=str(port),
                                  SQLITE_PATH=str(db), JWT_SECRET=SECRET, GOOSE_IO_BACKEND="epoll"),
                                  stdout=log, stderr=log)
        connection = None
        try:
            for _ in range(200):
                if server.poll() is not None:
                    raise RuntimeError("instrumented server exited before readiness")
                try:
                    connection = Connection(port)
                    connection.batch([("readiness", "GET", "/health", "", None, 200)], counts)
                    break
                except (OSError, RuntimeError):
                    if connection:
                        connection.close()
                    connection = None
                    time.sleep(.05)
            if connection is None:
                raise RuntimeError("instrumented server never became ready")
            if phase != "empty":
                generator = random.Random(0xA8F314)
                for start in range(0, requests, 32):
                    batch = []
                    for n in range(start, min(start + 32, requests)):
                        choice = generator.randrange(100)
                        post = ids[generator.randrange(len(ids))]
                        if choice < 48:
                            request = ("feed", "GET", "/feed", "", None, 200)
                        elif choice < 91:
                            request = ("post", "GET", f"/posts/{post}", "", None, 200)
                        elif choice < 98:
                            request = ("like", "POST", f"/posts/{post}/like", "", auth, (200, 201))
                        else:
                            request = ("create", "POST", "/posts", compact({"body": TEXTS[n % len(TEXTS)]}), auth, 201)
                        batch.append(request)
                    connection.batch(batch, counts)
                connection.batch(diagnostics(auth), counts)
            else:
                connection.batch([("empty-feed", "GET", "/feed", "", None, 200),
                                  ("missing-post", "GET", "/posts/1", "", None, 404)], counts)
            connection.close()
            connection = None
            # All responses have been read, hence all preceding writes committed.
            # This delay only settles the socket. The helper synchronizes the
            # profile dump on the main thread at its next epoll poll boundary.
            time.sleep(.05)
            server.send_signal(signal.SIGUSR1)
            code = server.wait(timeout=20)
            if code != 0:
                raise RuntimeError(f"instrumented server profile exit was {code}")
        except BaseException:
            if server.poll() is None:
                server.kill()
                server.wait(timeout=5)
            raise
        finally:
            if connection:
                connection.close()
    with sqlite3.connect(db) as check:
        integrity = check.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError("synthetic training database integrity failed after writes")
        posts, likes = (check.execute(f"SELECT count(*) FROM {table}").fetchone()[0] for table in ("posts", "likes"))
    return dict(phase=phase, requests=sum(counts.values()), counts=dict(sorted(counts.items())),
                database_integrity=integrity, final_posts=posts, final_likes=likes,
                server_exit_code=code, server_log=log_path.read_text(),
                initial_fixture="independent synthetic exact-schema data; no benchmark seed read")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="app-pgo-training-", dir=binary.parent.parent / ".build") as folder:
        directory = Path(folder)
        phases = [train(binary, directory, "dense", 16384),
                  train(binary, directory, "sparse", 512),
                  train(binary, directory, "empty", 0)]
    result = dict(purpose="build-only PGO feedback; no throughput measurement", synthetic_fixture_only=True,
                  challenge_seed_read=False, production_training_hooks=False,
                  instrumented_binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  trainer_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  phases=phases, requests=sum(phase["requests"] for phase in phases),
                  elapsed_s=round(time.monotonic() - started, 3), training_databases_removed=True)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
