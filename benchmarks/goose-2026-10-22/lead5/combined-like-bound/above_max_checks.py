"""Correctness fixture for the ordered, open-ended likes scan; not load.

The selected twenty posts have non-ID timestamp order, omitted IDs inside the
selected range, and hundreds of likes above its maximum. Run only in the
coordinated correctness window, as bench in the pinned candidate image.
"""
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def main():
    app = Path('/suite/sources/prgoose')
    result = dict(purpose='above-maximum and omitted-ID likes correctness; not throughput',
                  image_id=os.environ['EXPERIMENT_IMAGE_ID'], uid=os.getuid(), checks=[],
                  app_goose_sha256=hashlib.sha256((app / 'app.goose').read_bytes()).hexdigest())
    selected = [n for n in range(800005, 800029) if n not in (800010, 800015, 800020, 800025)]
    posts = [(n, 1, 'range boundary diagnostic ' + str(n),
              f'2099-02-03T00:00:{(selected.index(n) * 7) % 20:02d}.000Z'
              if n in selected else '2000-01-01T00:00:00.000Z')
             for n in range(800001, 800041)]
    posts.append((900000, 1, 'far above the selected ID range', '2000-01-01T00:00:00.000Z'))
    likes = [(user, n) for i, n in enumerate(selected) for user in range(1, i % 5 + 1)]
    # Omitted IDs in the selected range and every ID above it have 64 likes.
    other = [n for n in range(min(selected), 800041) if n not in selected]
    likes += [(user, n) for n in other for user in range(1, 65)]
    likes += [(user, 900000) for user in range(1, 65)]
    select = ('SELECT p.id,p.body,p.created_at,u.username,(SELECT count(*) FROM likes l WHERE l.post_id=p.id) '
              'FROM posts p JOIN users u ON u.id=p.user_id')
    with tempfile.TemporaryDirectory(prefix='goose-above-max-') as directory:
        database = Path(directory) / 'feed.db'
        shutil.copyfile('/evidence/seed/feed.db', database)
        db = sqlite3.connect(database)
        db.executemany('INSERT INTO posts(id,user_id,body,created_at) VALUES(?,?,?,?)', posts)
        db.executemany('INSERT INTO likes(user_id,post_id) VALUES(?,?)', likes)
        db.commit()
        keys = ('id', 'body', 'created_at', 'author', 'like_count')
        expected = [dict(zip(keys, row)) for row in db.execute(select + ' ORDER BY p.created_at DESC,p.id DESC LIMIT 20')]
        above = dict(zip(keys, db.execute(select + ' WHERE p.id=800040').fetchone()))
        omitted = dict(zip(keys, db.execute(select + ' WHERE p.id=800010').fetchone()))
        db.close()
        result['fixture'] = dict(posts=posts, likes=likes, selected_ids_by_timestamp=[p['id'] for p in expected],
                                 selected_min=min(selected), selected_max=max(selected),
                                 above_max_like_rows=sum(n > max(selected) for _, n in likes),
                                 initial_expected_feed=json.loads(compact({'posts': expected})))
        now = int(time.time())
        encode = lambda value: base64.urlsafe_b64encode(value.encode()).rstrip(b'=').decode()
        unsigned = encode('{"alg":"HS256","typ":"JWT"}') + '.' + encode(compact(dict(sub='200', username='boundary-author', exp=now + 3600)))
        signature = base64.urlsafe_b64encode(hmac.new(b'twelve-dollar-challenge', unsigned.encode(), hashlib.sha256).digest()).rstrip(b'=').decode()
        auth = 'Bearer ' + unsigned + '.' + signature
        env = dict(os.environ, HOST='127.0.0.1', PORT='24119', SQLITE_PATH=str(database), JWT_SECRET='twelve-dollar-challenge')
        log = tempfile.TemporaryFile(mode='w+')
        server = None
        try:
            server = subprocess.Popen(['bash', str(app / 'start.sh')], cwd=app, env=env,
                                      stdout=log, stderr=log, start_new_session=True)
            base = 'http://127.0.0.1:24119'
            for _ in range(200):
                if server.poll() is not None:
                    raise RuntimeError('server exited before readiness')
                try:
                    with urllib.request.urlopen(base + '/health', timeout=1):
                        break
                except OSError:
                    time.sleep(.05)
            else:
                raise TimeoutError('health readiness')

            def check(label, method, path, status, body):
                request = urllib.request.Request(base + path, method=method,
                                                 headers={'Authorization': auth})
                try:
                    response = urllib.request.urlopen(request, timeout=5)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    actual_status, actual_body = response.status, response.read().decode()
                passed = actual_status == status and actual_body == compact(body)
                result['checks'].append(dict(check=label, method=method, path=path,
                    expected_status=status, expected_body=compact(body), actual_status=actual_status,
                    actual_body=actual_body, passed=passed))

            check('range feed excludes above-maximum and omitted-ID likes', 'GET', '/feed', 200, {'posts': expected})
            check('above-maximum post has its independent 64 likes', 'GET', '/posts/800040', 200, {'post': above})
            check('omitted in-range post has its independent 64 likes', 'GET', '/posts/800010', 200, {'post': omitted})
            top = expected[0]
            check('selected post can receive a new live like', 'POST', f'/posts/{top["id"]}/like', 201,
                  dict(liked=True, already_liked=False, post_id=top['id']))
            top['like_count'] += 1
            check('next feed contains the selected post live count', 'GET', '/feed', 200, {'posts': expected})
            check('selected post repeat like is idempotent', 'POST', f'/posts/{top["id"]}/like', 200,
                  dict(liked=True, already_liked=True, post_id=top['id']))
            check('an above-maximum post can receive a live like', 'POST', '/posts/800040/like', 201,
                  dict(liked=True, already_liked=False, post_id=800040))
            above['like_count'] += 1
            check('above-maximum count updates independently', 'GET', '/posts/800040', 200, {'post': above})
            check('outside-range like never changes selected counts', 'GET', '/feed', 200, {'posts': expected})
        except Exception as error:
            result['error'] = repr(error)
        finally:
            if server is not None and server.poll() is None:
                os.killpg(server.pid, signal.SIGTERM)
                server.wait(timeout=8)
            log.seek(0)
            result['server_log'] = log.read()
            log.close()
        with sqlite3.connect(database) as db:
            result['database_integrity_after'] = db.execute('PRAGMA integrity_check').fetchone()[0]
    result['passed'] = sum(row['passed'] for row in result['checks'])
    result['failed'] = sum(not row['passed'] for row in result['checks'])
    result['runtime_backend_verified'] = 'Goose native transport: epoll' in result.get('server_log', '')
    result['passed_all'] = (len(result['checks']) == 9 and result['failed'] == 0 and 'error' not in result
                            and result['database_integrity_after'] == 'ok' and result['runtime_backend_verified'])
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result['passed_all'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
