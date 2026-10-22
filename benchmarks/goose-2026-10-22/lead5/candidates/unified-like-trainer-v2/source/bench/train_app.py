#!/usr/bin/env python3
"""STAGED synthetic trainer v2; not used by any current build or measurement.

Create disposable, independently generated exact-schema SQLite databases and
exercise the real HTTP server. This records compiler branch feedback, never a
throughput score. The production executable has no training hooks or fixtures.
"""
import argparse
import base64
from collections import Counter
from datetime import datetime, timedelta, timezone
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
DENSE_POSTS = 131072
SPARSE_POSTS = 8192
DENSE_REQUESTS = 32768
SPARSE_REQUESTS = 1024
RECENT_TARGET_PERCENT = 80
USER_COUNT = 256
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


def fixture(path, sparse=False, empty=False, dense_posts=DENSE_POSTS):
    db = sqlite3.connect(path)
    db.execute("PRAGMA foreign_keys=ON")
    db.executescript(SCHEMA)
    db.executemany("INSERT INTO users(id,username) VALUES(?,?)",
                   ((n, f"synthetic-user-{n}") for n in range(1, USER_COUNT + 1)))
    size = 0 if empty else SPARSE_POSTS if sparse else dense_posts
    ids = [n * (37 if sparse else 1) for n in range(1, size + 1)]
    # Independent dates increase with IDs; groups of 16 also exercise equal-
    # timestamp ordering. Every HTTP-created post is newer than this seed.
    base = datetime(2023, 1, 11, 6, 0, 0, tzinfo=timezone.utc)
    def rows():
        for n, post in enumerate(ids):
            stamp = (base + timedelta(milliseconds=(n // 16) * 73)).isoformat(timespec="milliseconds").replace("+00:00", "Z")
            yield post, n % USER_COUNT + 1, TEXTS[n % len(TEXTS)], stamp
    db.executemany("INSERT INTO posts(id,user_id,body,created_at) VALUES(?,?,?,?)",
                   rows())
    # Variable independent cardinalities train zero/nonzero count paths.
    # Generator input bounds fixture construction memory on larger datasets.
    db.executemany("INSERT INTO likes(user_id,post_id) VALUES(?,?)",
                   (((n * 13 + offset * 17) % USER_COUNT + 1, post)
                    for n, post in enumerate(ids) for offset in range(n % 11)))
    db.commit()
    if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
        raise RuntimeError("synthetic fixture integrity failed")
    metadata = dict(seed_posts=len(ids), seed_likes=db.execute("SELECT count(*) FROM likes").fetchone()[0],
                    database_bytes=path.stat().st_size, page_count=db.execute("PRAGMA page_count").fetchone()[0],
                    page_size=db.execute("PRAGMA page_size").fetchone()[0],
                    ids_sparse=sparse, users=USER_COUNT,
                    independent_timestamp_base=base.isoformat(),
                    nominal_runtime_cache_kib=int(os.environ.get("GOOSE_SQLITE_CACHE_KIB", "8192")))
    if not sparse and not empty and metadata["database_bytes"] <= 8 * 1024 * 1024:
        raise RuntimeError("dense synthetic fixture must exceed the 8 MiB cache setting")
    db.close()
    return ids, metadata


class Workload:
    """Feed-driven hot IDs plus a declared uniform seed tail for broad pages."""
    def __init__(self, ids):
        self.ids = ids
        self.recent = []
        self.created = set()
        self.feed_created = set()
        self.targets = Counter()
        self.feed_updates = 0
        self.created_liked_feed_observations = 0
        self.auth = [authorization(user=n, name=f"synthetic-user-{n}")
                     for n in range(1, USER_COUNT + 1)]
        self.auth_subject_by_token = {token: str(n) for n, token in enumerate(self.auth, 1)}
        self.auth_subject_counts = Counter()

    def observe(self, request, status, result):
        label, method, path, body, auth, expected = request
        if method == "POST" and status in (200, 201) and auth in self.auth_subject_by_token:
            self.auth_subject_counts[self.auth_subject_by_token[auth]] += 1
        if method == "POST" and path == "/posts" and status == 201:
            self.created.add(int(result["post"]["id"]))
        if method == "GET" and path.split("?", 1)[0] == "/feed" and status == 200:
            posts = result["posts"]
            latest = [int(post["id"]) for post in posts]
            if latest:
                self.recent = latest
            self.feed_created.update(post for post in latest if post in self.created)
            self.created_liked_feed_observations += sum(
                int(post["id"]) in self.created and int(post["like_count"]) > 0 for post in posts)
            self.feed_updates += 1

    def target(self, generator, route):
        recent = bool(self.recent) and generator.randrange(100) < RECENT_TARGET_PERCENT
        choices = self.recent if recent else self.ids
        post = choices[generator.randrange(len(choices))]
        source = "recent" if recent else "seed"
        kind = "created" if post in self.created else "original"
        self.targets[f"{route}:{source}:{kind}"] += 1
        return post

    def request(self, generator, n):
        # Match route proportions, not benchmark fixture contents/payloads.
        choice = generator.randrange(217)
        if choice < 100:
            return ("feed", "GET", "/feed", "", None, 200)
        if choice < 200:
            post = self.target(generator, "post")
            return ("post", "GET", f"/posts/{post}", "", None, 200)
        auth = self.auth[generator.randrange(len(self.auth))]
        if choice < 215:
            post = self.target(generator, "like")
            return ("like", "POST", f"/posts/{post}/like", "", auth, (200, 201))
        return ("create", "POST", "/posts", compact({"body": TEXTS[n % len(TEXTS)]}), auth, 201)


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

    def batch(self, requests, counts, workload=None):
        wire = []
        for label, method, path, body, auth, expected in requests:
            data = body if isinstance(body, bytes) else body.encode()
            headers = [f"{method} {path} HTTP/1.1", "Host: localhost", "Connection: keep-alive",
                       "Content-Type: application/json", f"Content-Length: {len(data)}"]
            if auth is not None:
                headers.append("Authorization: " + auth)
            wire.append("\r\n".join(headers).encode() + b"\r\n\r\n" + data)
        self.socket.sendall(b"".join(wire))
        results = []
        for request in requests:
            label, method, path, body, auth, expected = request
            status, result = self.response()
            accepted = expected if isinstance(expected, tuple) else (expected,)
            if status not in accepted:
                raise RuntimeError(f"training {label}: expected {accepted}, got {status}: {result!r}")
            counts[f"{label}:{status}"] += 1
            if workload is not None:
                workload.observe(request, status, result)
            results.append(result)
        return results


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


def train(binary, directory, phase, requests, dense_posts=DENSE_POSTS):
    db = directory / f"{phase}.db"
    ids, fixture_metadata = fixture(db, sparse=phase == "sparse", empty=phase == "empty",
                                    dense_posts=dense_posts)
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    log_path = directory / f"{phase}.log"
    counts = Counter()
    auth = authorization()
    workload = Workload(ids)
    fresh_probe_id = None
    main_coverage = {}
    fresh_probe_like_count_verified = None
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
                # Bootstrap exclusively from the real HTTP feed response.
                connection.batch([("initial-feed", "GET", "/feed", "", None, 200)], counts, workload)
                generator = random.Random(0xA8F314)
                for start in range(0, requests, 32):
                    batch = [workload.request(generator, n)
                             for n in range(start, min(start + 32, requests))]
                    connection.batch(batch, counts, workload)
                main_coverage = dict(target_counts=dict(sorted(workload.targets.items())),
                    created_posts_seen_in_feed=len(workload.feed_created),
                    created_liked_feed_observations=workload.created_liked_feed_observations,
                    successful_standard_auth_subject_counts=dict(sorted(workload.auth_subject_counts.items())),
                    successful_standard_auth_subject_count=len(workload.auth_subject_counts))
                # Deterministically cover both fresh-like insertion and duplicate
                # handling on a post first obtained from a live feed response.
                made = connection.batch([("probe-create", "POST", "/posts",
                    compact({"body": "Independent fresh-post profile probe."}), auth, 201)], counts, workload)[0]
                fresh_probe_id = int(made["post"]["id"])
                connection.batch([("probe-feed", "GET", "/feed", "", None, 200)], counts, workload)
                if fresh_probe_id not in workload.recent:
                    raise RuntimeError("new synthetic probe post was absent from the live feed")
                probe_results = connection.batch([
                    ("probe-new-like", "POST", f"/posts/{fresh_probe_id}/like", "", auth, 201),
                    ("probe-duplicate-like", "POST", f"/posts/{fresh_probe_id}/like", "", auth, 200),
                    ("probe-post", "GET", f"/posts/{fresh_probe_id}", "", None, 200),
                    ("probe-updated-feed", "GET", "/feed", "", None, 200)], counts, workload)
                fresh_feed_post = next((post for post in probe_results[3]["posts"]
                                        if int(post["id"]) == fresh_probe_id), None)
                if (probe_results[2]["post"]["like_count"] != 1 or
                        fresh_feed_post is None or fresh_feed_post["like_count"] != 1):
                    raise RuntimeError("fresh/duplicate like probe did not produce a live post/feed count of one")
                fresh_probe_like_count_verified = True
                if phase == "dense" and (not workload.targets["like:recent:created"] or
                                          not main_coverage["created_liked_feed_observations"]):
                    raise RuntimeError("main synthetic workload did not observe likes on feed-discovered created posts")
                connection.batch(diagnostics(auth), counts, workload)
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
                fixture=fixture_metadata, main_requested_requests=requests,
                target_counts=dict(sorted(workload.targets.items())),
                feed_updates=workload.feed_updates, created_posts_observed=len(workload.created),
                created_posts_seen_in_feed=len(workload.feed_created), fresh_probe_id=fresh_probe_id,
                main_profile_coverage=main_coverage,
                created_liked_feed_observations=workload.created_liked_feed_observations,
                fresh_probe_like_count_verified=fresh_probe_like_count_verified,
                successful_standard_auth_subject_counts=dict(sorted(workload.auth_subject_counts.items())),
                successful_standard_auth_subject_count=len(workload.auth_subject_counts),
                database_integrity=integrity, final_posts=posts, final_likes=likes,
                server_exit_code=code, server_log=log_path.read_text(),
                initial_fixture="independent synthetic exact-schema data; no benchmark seed read")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--dense-posts", type=int, default=DENSE_POSTS)
    parser.add_argument("--dense-requests", type=int, default=DENSE_REQUESTS)
    parser.add_argument("--sparse-requests", type=int, default=SPARSE_REQUESTS)
    args = parser.parse_args()
    if args.dense_posts < 65536 or args.dense_requests < 8192 or args.sparse_requests < 512:
        parser.error("Require >=65536 dense posts, >=8192 dense requests and >=512 sparse requests")
    binary = args.binary.resolve(strict=True)
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="app-pgo-training-", dir=binary.parent.parent / ".build") as folder:
        directory = Path(folder)
        phases = [train(binary, directory, "dense", args.dense_requests, args.dense_posts),
                  train(binary, directory, "sparse", args.sparse_requests, args.dense_posts),
                  train(binary, directory, "empty", 0)]
    result = dict(purpose="build-only PGO feedback; no throughput measurement", synthetic_fixture_only=True,
                  challenge_seed_read=False, production_training_hooks=False,
                  trainer_variant="staged-v2-large-fixture-live-feed-targets",
                  workload_configuration=dict(dense_posts=args.dense_posts, sparse_posts=SPARSE_POSTS,
                      dense_requests=args.dense_requests, sparse_requests=args.sparse_requests,
                      route_weights=dict(feed=100, post=100, like=15, create=2),
                      recent_target_percent=RECENT_TARGET_PERCENT,
                      seed_target_percent=100 - RECENT_TARGET_PERCENT, users=USER_COUNT,
                      feed_ids_source="only parsed live HTTP feed responses; create responses label new IDs for diagnostics",
                      fixture_source="independent generators and local constants; no challenge database, tokens, or golden payloads"),
                  instrumented_binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  trainer_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  phases=phases, requests=sum(phase["requests"] for phase in phases),
                  elapsed_s=round(time.monotonic() - started, 3), training_databases_removed=True)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
