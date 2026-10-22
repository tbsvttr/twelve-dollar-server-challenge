"""Bounded correctness diagnostics for the one-pass parser and JSON primitive.

Run as bench in a pinned candidate image, mounted read-only at /evidence:
  python3 /evidence/tuning_api_checks.py IMAGE_ID
This is not a load test and contains no throughput measurements.
"""
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def sign(header, payload):
    encode = lambda value: base64.urlsafe_b64encode(value.encode()).rstrip(b'=').decode()
    text = encode(header) + '.' + encode(payload)
    signature = base64.urlsafe_b64encode(hmac.new(b'twelve-dollar-challenge', text.encode(), hashlib.sha256).digest()).rstrip(b'=').decode()
    return 'Bearer ' + text + '.' + signature


def main():
    app = Path(os.environ.get('GOOSE_TEST_APP', '/suite/sources/prgoose'))
    result = dict(purpose='bounded parser/JSON correctness diagnostics; not throughput or ranking',
                  image_id=sys.argv[1], uid=os.getuid(), checks=[],
                  app_goose_sha256=hashlib.sha256((app / 'app.goose').read_bytes()).hexdigest())
    server = None
    with tempfile.TemporaryDirectory(prefix='goose-tuning-api-') as directory:
        db = Path(directory) / 'feed.db'
        shutil.copyfile('/evidence/seed/feed.db', db)
        log = tempfile.TemporaryFile(mode='w+')
        try:
            env = dict(os.environ, HOST='127.0.0.1', PORT='24118', SQLITE_PATH=str(db),
                       JWT_SECRET='twelve-dollar-challenge')
            server = subprocess.Popen(['bash', str(app / 'start.sh')], cwd=app, env=env,
                                      stdout=log, stderr=log, start_new_session=True)
            base = 'http://127.0.0.1:24118'
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
            now = int(time.time())
            header = '{"alg":"HS256","typ":"JWT"}'
            claims = compact(dict(sub='19', username='parser author', exp=now + 3600))
            auth = sign(header, claims)

            def check(label, raw_body, expected_status, expected_error=None, authorization=auth,
                      expected_body=None, expected_author='parser author'):
                request = urllib.request.Request(base + '/posts', method='POST', data=raw_body.encode(),
                          headers={'Authorization': authorization, 'Content-Type': 'application/json'})
                try:
                    response = urllib.request.urlopen(request, timeout=5)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    status, body = response.status, response.read().decode()
                value = json.loads(body)
                if expected_error:
                    expected = {'error': expected_error}
                else:
                    post = value.get('post', {})
                    expected = {'post': dict(id=post.get('id'), body=expected_body,
                         created_at=post.get('created_at'), author=expected_author, like_count=0)}
                passed = status == expected_status and body == compact(expected)
                result['checks'].append(dict(check=label, request_body=raw_body, authorization=authorization,
                    expected_status=expected_status, expected_body=compact(expected), actual_status=status,
                    actual_body=body, passed=passed))

            nested = '{"array":[false,null,{},[],1,-2.25,3e4,{"a":"escaped\\\\value"}]}'
            escaped_header = '{"a\\u006cg":"H\\u0053256","unknown":' + nested + '}'
            escaped_payload = ('{"s\\u0075b":"\\u0031\\u0039","user\\u006eame":"escaped \\ud83d\\ude00 \\"quote\\"",'
                               '"exp":' + str(now + 3600) + ',"unknown":' + nested + '}')
            check('escaped claim names, subject and username', '{"body":"escaped claims"}', 201,
                  authorization=sign(escaped_header, escaped_payload), expected_body='escaped claims',
                  expected_author='escaped 😀 "quote"')
            check('unknown nested JWT values are fully parsed', '{"body":"nested claims"}', 201,
                  authorization=sign(header, claims[:-1] + ',"ignored":' + nested + '}'), expected_body='nested claims')
            check('malformed unknown JWT value is rejected', '{"body":"must not insert"}', 401,
                  'invalid or expired token', authorization=sign(header, claims[:-1] + ',"ignored":[1,]}'))
            check('trailing JWT garbage is rejected', '{"body":"must not insert"}', 401,
                  'invalid or expired token', authorization=sign(header, claims + ' true'))
            check('malformed unknown header field is rejected', '{"body":"must not insert"}', 401,
                  'invalid or expired token', authorization=sign('{"alg":"HS256","ignored":[1,]}', claims))
            check('escaped request member name and value', '{"bo\\u0064y":"hello \\ud83d\\ude00 \\"quote\\""}',
                  201, expected_body='hello 😀 "quote"')
            check('valid nested request fields are skipped', '{"ignored":' + nested + ',"body":"nested body"}',
                  201, expected_body='nested body')
            check('malformed nested request fields are rejected', '{"body":"must not insert","ignored":[1,]}',
                  400, 'malformed JSON body')
            check('trailing request garbage is rejected', '{"body":"must not insert"} false',
                  400, 'malformed JSON body')
            check('unescaped control character is rejected', '{"body":"bad\x01string"}', 400, 'malformed JSON body')
            for text in ('null', 'true', '[1,"x",{}]'):
                check('valid non-object request has no body: ' + text, text, 400, 'body is required')
            controls = 'controls:' + ''.join(chr(i) for i in range(32)) + ':end'
            check('every JSON control escape round-trips', compact({'body': controls}), 201, expected_body=controls)
            for boundary in (15, 16, 31, 32):
                text = 'a' * boundary + '"\\\n' + 'é😀' + 'z' * (33 - boundary)
                check('JSON escapes cross SIMD boundary ' + str(boundary), compact({'body': text}),
                      201, expected_body=text)
        except Exception as error:
            result['error'] = repr(error)
        finally:
            if server is not None and server.poll() is None:
                os.killpg(server.pid, signal.SIGTERM)
                server.wait(timeout=8)
            log.seek(0)
            result['server_log'] = log.read()
            log.close()
    result['passed'] = sum(row['passed'] for row in result['checks'])
    result['failed'] = sum(not row['passed'] for row in result['checks'])
    result['passed_all'] = bool(result['checks']) and result['failed'] == 0 and 'error' not in result
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result['passed_all'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
