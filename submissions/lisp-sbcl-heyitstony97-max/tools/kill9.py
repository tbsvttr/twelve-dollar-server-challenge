#!/usr/bin/env python3
"""kill -9 durability: 8 writers POST /posts and POST /posts/:id/like against a loaded server; every
201/200 answer is an acknowledgement (the server answers only after COMMIT). SIGKILL the server at a
random moment, start it again on the same database, and check that EVERY acknowledged post and like is
there. Usage: kill9.py <server-start-cmd...>   (env: SQLITE_PATH, JWT_SECRET, PORT, HOST)"""
import http.client, json, os, random, signal, subprocess, sys, threading, time

PORT = int(os.environ.get("PORT", "3850"))
TOKENS = json.load(open(os.path.join(os.path.dirname(__file__), "../../../seed/tokens.json")))
acked_posts = {}   # id -> body
acked_likes = set()  # (post, user idx)
lock = threading.Lock()
stop = threading.Event()


def start():
    p = subprocess.Popen(sys.argv[1:], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        try:
            c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=1)
            c.request("GET", "/health")
            if c.getresponse().status == 200:
                return p
        except Exception:
            time.sleep(0.2)
    raise SystemExit("server did not start")


def writer(k):
    tok = TOKENS[k]["token"]
    h = {"Authorization": "Bearer " + tok, "Content-Type": "application/json"}
    n = 0
    c = None
    while not stop.is_set():
        try:
            if c is None:
                c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=3)
            n += 1
            body = "k9-%d-%d-%d" % (os.getpid(), k, n)
            c.request("POST", "/posts", json.dumps({"body": body}), h)
            r = c.getresponse(); d = r.read()
            if r.status == 201:
                pid = json.loads(d)["post"]["id"]
                with lock:
                    acked_posts[pid] = body
                c.request("POST", "/posts/%d/like" % pid, headers=h)
                r2 = c.getresponse(); r2.read()
                if r2.status in (200, 201):
                    with lock:
                        acked_likes.add((pid, TOKENS[k]["id"]))
        except Exception:
            c = None
            time.sleep(0.01)


def main():
    srv = start()
    ts = [threading.Thread(target=writer, args=(k,), daemon=True) for k in range(8)]
    for t in ts:
        t.start()
    time.sleep(2.0 + random.random() * 3)
    srv.send_signal(signal.SIGKILL); srv.wait()
    stop.set()
    time.sleep(0.3)
    with lock:
        posts = dict(acked_posts); likes = set(acked_likes)
    print("acked before kill -9: %d posts, %d likes" % (len(posts), len(likes)))
    srv = start()
    miss = 0
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
    for pid, body in posts.items():
        c.request("GET", "/posts/%d" % pid)
        r = c.getresponse(); d = r.read()
        if r.status != 200 or json.loads(d)["post"]["body"] != body:
            miss += 1
    # likes: the like_count of each liked post must be >= 1
    lmiss = 0
    for pid, uid in likes:
        c.request("GET", "/posts/%d" % pid)
        r = c.getresponse(); d = r.read()
        if r.status != 200 or json.loads(d)["post"]["like_count"] < 1:
            lmiss += 1
    srv.send_signal(signal.SIGTERM)
    print("after restart: missing posts %d, missing likes %d" % (miss, lmiss))
    print("KILL9 OK" if miss == 0 and lmiss == 0 and len(posts) > 100 else "KILL9 FAIL")
    sys.exit(0 if miss == 0 and lmiss == 0 and len(posts) > 100 else 1)


main()
