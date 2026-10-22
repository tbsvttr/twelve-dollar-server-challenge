"""Supplemental API correctness diagnostics, explicitly not a throughput run.

Run inside the pinned Goose image as its ordinary bench user with this
directory mounted read-only at /evidence. Every database change is disposable.
"""
import base64
import contextlib
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

SECRET = 'twelve-dollar-challenge'
IMAGE_ID = os.environ['EXPERIMENT_IMAGE_ID']
APP = Path('/suite/sources/prgoose')


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def token(claims, alg='HS256'):
    encode = lambda data: base64.urlsafe_b64encode(data).rstrip(b'=').decode()
    text = encode(compact({'alg': alg, 'typ': 'JWT'}).encode()) + '.' + encode(compact(claims).encode())
    return text + '.' + encode(hmac.new(SECRET.encode(), text.encode(), hashlib.sha256).digest())


def main():
    result = dict(purpose='supplemental API correctness diagnostics; not ranking or throughput',
                  image_id=IMAGE_ID, uid=os.getuid(), source_app_sha256=hashlib.sha256((APP / 'app.goose').read_bytes()).hexdigest(),
                  seed_sha256=hashlib.sha256(Path('/evidence/seed/feed.db').read_bytes()).hexdigest(),
                  recorded_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), checks=[], fixture={})
    server = None
    with tempfile.TemporaryDirectory(prefix='goose-edge-') as name:
        directory = Path(name)
        db = directory / 'feed.db'
        shutil.copyfile('/evidence/seed/feed.db', db)
        # The newest posts deliberately have sparse IDs and a timestamp order
        # that differs from ID order, exercising the general-query fallback.
        posts = [(10000001 + i * 1000, 1, f'sparse diagnostic {i} café "quoted"',
                  f'2099-01-01T00:00:{(i * 7) % 20:02d}.000Z') for i in range(20)]
        likes = [(user, row[0]) for i, row in enumerate(posts) for user in range(1, i % 7 + 1)]
        post_sql = 'INSERT INTO posts(id,user_id,body,created_at) VALUES(?,?,?,?)'
        like_sql = 'INSERT INTO likes(user_id,post_id) VALUES(?,?)'
        select = ('SELECT p.id,p.body,p.created_at,u.username,(SELECT count(*) FROM likes l WHERE l.post_id=p.id) '
                  'FROM posts p JOIN users u ON u.id=p.user_id ORDER BY p.created_at DESC,p.id DESC LIMIT 20')
        with contextlib.closing(sqlite3.connect(db)) as connection:
            connection.executemany(post_sql, posts)
            connection.executemany(like_sql, likes)
            connection.commit()
            expected_posts = [dict(zip(('id', 'body', 'created_at', 'author', 'like_count'), row))
                              for row in connection.execute(select)]
            stored_user_name = connection.execute('SELECT username FROM users WHERE id=19').fetchone()[0]
        result['fixture'] = dict(post_sql=post_sql, post_parameters=posts, like_sql=like_sql,
                                 like_parameters=likes, oracle_query=select,
                                 expected_initial_feed=json.loads(compact({'posts': expected_posts})),
                                 stored_user_name=stored_user_name,
                                 sparse_id_span=max(row[0] for row in posts) - min(row[0] for row in posts))
        env = dict(os.environ, SQLITE_PATH=str(db), JWT_SECRET=SECRET, HOST='127.0.0.1', PORT='24117')
        log = tempfile.TemporaryFile(mode='w+')
        try:
            server = subprocess.Popen(['bash', str(APP / 'start.sh')], cwd=APP, env=env,
                                      stdout=log, stderr=log, start_new_session=True)
            base = 'http://127.0.0.1:24117'
            deadline = time.monotonic() + 20
            while True:
                if server.poll() is not None:
                    raise RuntimeError('server exited during startup')
                try:
                    with urllib.request.urlopen(base + '/health', timeout=1) as response:
                        if response.status == 200:
                            break
                except OSError:
                    if time.monotonic() > deadline:
                        raise TimeoutError('health readiness')
                    time.sleep(.05)
            now = int(time.time())
            claims = dict(sub='19', username='diagnostic_author', iat=now, exp=now + 3600)
            good = 'Bearer ' + token(claims)

            def request(label, method, path, expected_status, expected=None, body=None, authorization=None, validate=None):
                headers = {}
                if authorization is not None:
                    headers['Authorization'] = authorization
                data = None if body is None else compact(body).encode()
                if data is not None:
                    headers['Content-Type'] = 'application/json'
                req = urllib.request.Request(base + path, data=data, method=method, headers=headers)
                try:
                    response = urllib.request.urlopen(req, timeout=5)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    status, actual = response.status, response.read().decode()
                parsed = json.loads(actual)
                if validate:
                    expected = validate(parsed)
                expected_text = compact(expected)
                passed = status == expected_status and actual == expected_text
                result['checks'].append(dict(check=label, request=dict(method=method, path=path,
                    body=body, authorization=authorization), expected_status=expected_status,
                    expected_body=expected_text, actual_status=status, actual_body=actual, passed=passed))
                return parsed

            request('sparse newest IDs preserve timestamp order and distinct live counts', 'GET', '/feed', 200,
                    {'posts': expected_posts})
            top = expected_posts[0]
            request('new live like on sparse post', 'POST', f'/posts/{top["id"]}/like', 201,
                    dict(liked=True, already_liked=False, post_id=top['id']), authorization=good)
            top['like_count'] += 1
            request('sparse fallback feed observes live like', 'GET', '/feed', 200, {'posts': expected_posts})
            request('sparse post observes live like', 'GET', f'/posts/{top["id"]}', 200, {'post': top})
            request('repeat sparse like remains idempotent', 'POST', f'/posts/{top["id"]}/like', 200,
                    dict(liked=True, already_liked=True, post_id=top['id']), authorization=good)

            def created_expected(text):
                def validate(value):
                    actual = value.get('post', {})
                    return {'post': dict(id=actual.get('id'), body=text, created_at=actual.get('created_at'),
                                         author=claims['username'], like_count=0)}
                return validate

            body500 = '😀' * 500
            created = request('500 Unicode scalar body is accepted', 'POST', '/posts', 201,
                              body={'body': body500}, authorization=good, validate=created_expected(body500))
            stored = json.loads(compact(created))
            stored['post']['author'] = stored_user_name
            request('500 Unicode scalar post reads exactly using stored author', 'GET', f'/posts/{created["post"]["id"]}', 200, stored)
            request('501 Unicode scalars are rejected', 'POST', '/posts', 400,
                    {'error': 'body must be at most 500 characters'}, body={'body': '😀' * 501}, authorization=good)
            trimmed = 'é\u0301😀 inner space'
            request('Unicode edge whitespace trims without changing inner characters', 'POST', '/posts', 201,
                    body={'body': '\u00a0\ufeff\u2003\t' + trimmed + '\r\u3000\u202f'}, authorization=good,
                    validate=created_expected(trimmed))
            request('all Unicode whitespace is empty', 'POST', '/posts', 400,
                    {'error': 'body is required'}, body={'body': '\u00a0\ufeff\u2003\t\r\u3000\u202f'}, authorization=good)
            for identifier in ('0', '-1', 'abc', '1.5'):
                request('authenticated invalid like ID ' + identifier, 'POST', f'/posts/{identifier}/like', 400,
                        {'error': 'invalid post id'}, authorization=good)
            request('authentication precedes invalid ID', 'POST', '/posts/abc/like', 401,
                    {'error': 'missing bearer token'})
            request('nested route is unknown before auth', 'POST', '/posts/1/nested/like', 404,
                    {'error': 'not found'})
            variants = [
                ('wrong signed algorithm', claims, 'HS384', 'invalid or expired token'),
                ('expired token', dict(claims, exp=now - 1), 'HS256', 'invalid or expired token'),
                ('missing expiration', {k: v for k, v in claims.items() if k != 'exp'}, 'HS256', 'invalid or expired token'),
                ('numeric subject', dict(claims, sub=19), 'HS256', 'invalid token payload'),
                ('zero subject', dict(claims, sub='0'), 'HS256', 'invalid token payload'),
                ('negative subject', dict(claims, sub='-1'), 'HS256', 'invalid token payload'),
                ('numeric username', dict(claims, username=42), 'HS256', 'invalid token payload'),
                ('missing username', {k: v for k, v in claims.items() if k != 'username'}, 'HS256', 'invalid token payload'),
            ]
            for label, payload, alg, error in variants:
                request(label, 'POST', '/posts', 401, {'error': error}, body={'body': 'must not insert'},
                        authorization='Bearer ' + token(payload, alg))
            request('malformed JWT segments', 'POST', '/posts', 401, {'error': 'invalid or expired token'},
                    body={'body': 'must not insert'}, authorization='Bearer abc.def.ghi.extra')
        except Exception as error:
            result['error'] = repr(error)
        finally:
            if server is not None and server.poll() is None:
                os.killpg(server.pid, signal.SIGTERM)
                server.wait(timeout=8)
            log.seek(0)
            result['server_log'] = log.read()
            log.close()
        with contextlib.closing(sqlite3.connect(db)) as connection:
            result['database_after'] = dict(integrity=connection.execute('PRAGMA integrity_check').fetchone()[0],
                                            sparse_post_like_count=connection.execute('SELECT count(*) FROM likes WHERE post_id=?',
                                                                                     (expected_posts[0]['id'],)).fetchone()[0])
    result['passed_all'] = bool(result['checks']) and all(row['passed'] for row in result['checks']) and 'error' not in result
    result['passed'] = sum(row['passed'] for row in result['checks'])
    result['failed'] = sum(not row['passed'] for row in result['checks'])
    result['diagnostic_harness_correction'] = ('The first draft expected a GET author to equal the token username '
        'after deliberately changing that username. The corrected oracle follows SPEC: create echoes the token '
        'username while GET reads users.username. The server source and image were unchanged.')
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result['passed_all'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
