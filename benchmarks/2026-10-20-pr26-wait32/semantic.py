"""Supplement the official fixture tests with a fresh unpredictable round-trip.

This does not replace or modify the 42 official checks. It checks that an
implementation responds to new data rather than only the supplied fixtures.
"""
import base64
import hashlib
import hmac
import json
import secrets
import sys
import time
import urllib.request


def main():
    base = sys.argv[1].rstrip('/')
    now = int(time.time())
    encode = lambda value: base64.urlsafe_b64encode(value).rstrip(b'=').decode()
    header = encode(b'{"alg":"HS256","typ":"JWT"}')
    payload = encode(json.dumps({'sub': '1', 'username': 'golden_ember_1',
                                 'iat': now, 'exp': now + 3600}, separators=(',', ':')).encode())
    signed = f'{header}.{payload}'
    signature = encode(hmac.new(b'twelve-dollar-challenge', signed.encode(), hashlib.sha256).digest())
    token = f'{signed}.{signature}'
    checks = []

    def request(method, path, body=None):
        headers = {'Authorization': 'Bearer ' + token}
        data = None
        if body is not None:
            headers['Content-Type'] = 'application/json'
            data = json.dumps(body, ensure_ascii=False).encode()
        with urllib.request.urlopen(urllib.request.Request(base + path, data=data,
                                    method=method, headers=headers), timeout=10) as response:
            return response.status, json.load(response)

    def check(label, condition):
        checks.append({'check': label, 'passed': bool(condition)})
        if not condition:
            raise AssertionError(label)

    try:
        body = 'dynamic ' + secrets.token_hex(18) + ' café ✓ <&> "quoted"'
        status, created = request('POST', '/posts', {'body': '  ' + body + '  '})
        post = created.get('post', {})
        check('fresh unpredictable post is created and trimmed',
              status == 201 and post.get('body') == body and isinstance(post.get('id'), int)
              and post.get('author') == 'golden_ember_1' and post.get('like_count') == 0)
        identifier = post['id']
        status, fetched = request('GET', f'/posts/{identifier}')
        check('created post reads back exactly', status == 200 and fetched.get('post') == post)
        status, liked = request('POST', f'/posts/{identifier}/like')
        check('new post can be liked', status == 201 and liked ==
              {'liked': True, 'already_liked': False, 'post_id': identifier})
        status, liked = request('POST', f'/posts/{identifier}/like')
        check('repeat like is idempotent', status == 200 and liked ==
              {'liked': True, 'already_liked': True, 'post_id': identifier})
        post['like_count'] = 1
        status, fetched = request('GET', f'/posts/{identifier}')
        check('fresh like count reads back', status == 200 and fetched.get('post') == post)
        status, feed = request('GET', '/feed')
        check('fresh post and like count appear in feed',
              status == 200 and len(feed.get('posts', [])) == 20 and feed['posts'][0] == post)
        result = {'passed_all': True, 'checks': checks}
    except Exception as error:
        result = {'passed_all': False, 'checks': checks, 'error': str(error)}
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result['passed_all'] else 1


if __name__ == '__main__':
    sys.exit(main())
