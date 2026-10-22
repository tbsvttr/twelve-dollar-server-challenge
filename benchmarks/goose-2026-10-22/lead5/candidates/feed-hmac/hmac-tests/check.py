"""Differential crypto checks against frozen one-shot db.c and Python HMAC."""
import base64
import ctypes as c
import hashlib
import hmac
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
libs = [c.CDLL(str(ROOT / name)) for name in ('reference.so', 'candidate.so')]
for lib in libs:
    lib.test_auth.argtypes = [c.c_void_p, c.c_int64, c.c_void_p, c.c_int64,
                             c.c_void_p, c.POINTER(c.c_int64), c.c_void_p, c.POINTER(c.c_int64)]
    lib.test_auth.restype = c.c_int
new = libs[1]
new.test_fail.argtypes = [c.c_uint]
checks = []


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=')


def signed(key, header=b'{"alg":"HS256","typ":"JWT"}', payload=b'{"sub":"1","username":"user","exp":2147483647}'):
    message = b64(header) + b'.' + b64(payload)
    return message + b'.' + b64(hmac.digest(key, message, 'sha256'))


def run(lib, token, key, token_length=None, key_length=None):
    header, payload = c.create_string_buffer(16384), c.create_string_buffer(16384)
    nh, np = c.c_int64(), c.c_int64()
    result = lib.test_auth(token, len(token) if token_length is None else token_length,
                           key, len(key) if key_length is None else key_length,
                           header, c.byref(nh), payload, c.byref(np))
    return result, header.raw[:nh.value], payload.raw[:np.value]


def check(label, condition):
    if not condition:
        raise AssertionError(label)
    checks.append(label)


# Exercise registration failure before a successful first initialization.
key_a, key_b = b'first-key', b'other-key'
token_a, token_b = signed(key_a), signed(key_b)
new.test_fail(64)
check('exit-cleanup registration failure rejects and leaves no key', run(new, token_a, key_a)[0] == 0 and not new.test_has_key())

for bit, name in [(1, 'algorithm-fetch'), (2, 'context-allocation'), (4, 'key-allocation')]:
    new.test_forget()
    new.test_fail(bit)
    check(name + ' failure rejects', run(new, token_a, key_a)[0] == 0)
    check(name + ' recovery succeeds', run(new, token_a, key_a)[0] == 1)

for bit, name in [(2, 'context-allocation'), (4, 'key-allocation'), (8, 'new-key-initialization')]:
    check(name + ' establish original key', run(new, token_a, key_a)[0] == 1)
    new.test_fail(bit)
    check(name + ' changed-key failure rejects', run(new, token_b, key_b)[0] == 0)
    check(name + ' old key still correct', run(new, token_a, key_a)[0] == 1)
    check(name + ' changed-key retry correct', run(new, token_b, key_b)[0] == 1)

for bit, name in [(8, 'same-key-reset'), (16, 'update'), (32, 'final')]:
    check(name + ' establish key', run(new, token_a, key_a)[0] == 1)
    new.test_fail(bit)
    check(name + ' failure rejects and discards state', run(new, token_a, key_a)[0] == 0 and not new.test_has_key())
    check(name + ' recovery succeeds', run(new, token_a, key_a)[0] == 1)

keys = [b'', b'a', b'b', b'\0', bytes(range(32)), bytes(range(64)), bytes(range(65)),
        b'z' * 4096, b'\0' * 1048576]
payloads = [b'{"sub":"1","username":"user","exp":2147483647}',
            '{"sub":"23","username":"雪\\\"☃","exp":2147483647}'.encode(),
            b'x' * 10000, b'\x00\x01\xff']
for i, key in enumerate(keys + list(reversed(keys)) + [b'a', b'a', b'b', b'a']):
    for j, payload in enumerate(payloads):
        token = signed(key, payload=payload)
        expected = (1, b'{"alg":"HS256","typ":"JWT"}', payload)
        results = [run(lib, token, key) for lib in libs]
        check(f'valid repeated/changed/binary key {i}, payload {j}', results == [expected, expected])

key = b'final-shared-key'
token = signed(key)
malformed = [b'', b'.', b'..', b'...', b'a.b.c', token + b'.', b'.' + token,
             token.replace(b'.', b'=', 1), token[:-1], token + b'=',
             token[:-2] + b'!!', token[:-1] + bytes([token[-1] ^ 1]),
             signed(key, header=b''), signed(key, payload=b''),
             signed(key, header=b'non-json header'), b'a' * 16385]
for i, value in enumerate(malformed):
    check(f'malformed token differential {i}', run(libs[0], value, key) == run(new, value, key))
check('wrong secret rejects', run(new, token, b'wrong')[0] == 0)
check('bad signature does not poison reuse', run(new, token, key)[0] == 1)
for length in [-1, 1048577]:
    check(f'out-of-range secret length {length}', run(libs[0], token, key, key_length=length) == run(new, token, key, key_length=length))
for length in [-1, 16385]:
    check(f'out-of-range token length {length}', run(libs[0], token, key, token_length=length) == run(new, token, key, token_length=length))
# The old API differentiates NULL,0 from a non-NULL empty key; retain that too.
check('NULL empty key differential', run(libs[0], signed(b''), None, key_length=0) == run(new, signed(b''), None, key_length=0))
new.test_forget()
output = {'passed_all': True, 'passed': len(checks), 'checks': checks,
          'oracle': 'Frozen selected one-shot db.c plus Python hashlib/HMAC SHA-256',
          'scope': 'Crypto adapter only; Goose JSON algorithm/expiry/claim checks are exercised by full API gates.',
          'candidate_db_sha256': hashlib.sha256((ROOT.parent/'source/db.c').read_bytes()).hexdigest(),
          'reference_db_sha256': hashlib.sha256((ROOT.parent.parent/'combined-like-bound/source/db.c').read_bytes()).hexdigest()}
print(json.dumps(output, indent=2))
