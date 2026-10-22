"""Publish the deduplicated current-implementation view via authenticated gh."""
import argparse
import json
from pathlib import Path
import re

from publish_recheck import Tables, digest, gh

HERE = Path(__file__).resolve().parent
VIEW = HERE / 'current-only-view'
OUT = VIEW / 'publication'
REPO = 'arjaythedev/twelve-dollar-server-challenge'
MAIN = f'https://github.com/{REPO}/issues/7#issuecomment-6292218419'
BASE = 'https://github.com/tbsvttr/twelve-dollar-server-challenge/blob/benchmark-2026-10-22/benchmarks'


def read(path):
    return json.loads(path.read_text())


def save(name, value):
    path = OUT / name
    path.write_text(json.dumps(value, indent=2) + '\n')
    return path


def prepare():
    assert gh('api', 'user')['login'] == 'tbsvttr'
    audit = read(VIEW / 'current-only-audit.json')
    assert audit['passed'] is True and audit['checks_passed'] == audit['checks']
    body = (VIEW / 'issue-comment.md').read_text()
    save('6292218419-payload.json', {'body': body})
    for cid in (6292218419, 6343585262):
        old = gh('api', f'repos/{REPO}/issues/comments/{cid}')
        assert old['user']['login'] == 'tbsvttr'
        save(f'{cid}-before.json', old)
    notice = (f'The [main comparison table]({MAIN}) now shows **118 implementations, each exactly once**. '
              'Repeated control/confirmation runs and previous source revisions are removed from the main view and '
              f'preserved unchanged in [all 129 measurement records]({BASE}/2026-10-22/comparison-rows.json). '
              f'[CSV]({BASE}/2026-10-22/comparison.csv) and [HTML]({BASE}/2026-10-22/comparison.html) use the same 118 rows.\n\n'
              'Rust #82 replaces the older #19 revision and appears once, using the complete fresh stock-wrk recheck '
              'measured alongside Goose: 102,683.76 req/s. Goose appears once at 113,483.58 req/s. Both have zero '
              'HTTP/socket errors across all three trials. The unchanged c-iouring folder inherited by #121 is '
              'represented under its original #112 submission; #121\'s distinct c-libco implementation remains. '
              'Selection follows current source revisions and complete batches, without choosing the highest throughput.\n\n'
              'Condition labels and error counters remain explicit. PASS covers the recorded local runtime protocol '
              '(one server CPU / 2 GiB / no swap, stock wrk 3×15s), while official x86-64 droplet/k6 conditions remain '
              f'unverified. [View audit]({BASE}/2026-10-22/current-only-audit.json). No new benchmarks or source changes.\n')
    save('6343585262-payload.json', {'body': notice})
    pr = gh('pr', 'view', '143', '--repo', REPO, '--json', 'body,headRefOid')
    save('pr-before.json', pr)
    old = 'contain exactly one current Goose entry.'
    new = ('contain one current result for each of the 118 implementations, including one Goose entry and one '
           'Rust #82 entry. Earlier revisions and repeated controls remain in the linked record history.')
    assert old in pr['body']
    (OUT / 'pr-body.md').write_text(pr['body'].replace(old, new, 1))
    payload = save('markdown-payload.json', {'text': body, 'mode': 'gfm', 'context': REPO})
    parser = Tables()
    parser.feed(gh('api', '--method', 'POST', 'markdown', '--input', str(payload), raw=True))
    assert parser.tables == 1 and len(parser.rows) == 119
    assert all(len(row) == 10 for row in parser.rows)
    for prefix in ('#82 ', '#143 '):
        found = [row for row in parser.rows[1:] if row[0].startswith(prefix)]
        assert len(found) == 1 and 'PASS' in found[0][1]
    save('github-preview-proof.json', dict(tables=1, rows=118, columns=10,
         rust82_rows=1, goose_rows=1, body_sha256=digest(body)))
    print('Prepared updates; GitHub renders one 118-row table, one Rust82 row and one Goose row.')


def publish(commit):
    assert re.fullmatch(r'[0-9a-f]{40}', commit)
    audit = read(VIEW / 'current-only-audit.json')
    assert audit['passed'] is True and audit['checks_passed'] == audit['checks']
    results = []
    for cid in (6292218419, 6343585262):
        endpoint = f'repos/{REPO}/issues/comments/{cid}'
        desired = read(OUT / f'{cid}-payload.json')['body']
        old = read(OUT / f'{cid}-before.json')
        current = gh('api', endpoint)
        assert current['user']['login'] == 'tbsvttr'
        assert current['body'] in (old['body'], desired), 'Concurrent edit needs reconciliation.'
        if current['body'] != desired:
            gh('api', '--method', 'PATCH', endpoint, '--input', str(OUT / f'{cid}-payload.json'))
        checked = gh('api', endpoint)
        assert checked['body'] == desired and checked['user']['login'] == 'tbsvttr'
        assert checked.get('performed_via_github_app') is None
        save(f'{cid}-after.json', checked)
        results.append(dict(url=checked['html_url'], body_sha256=digest(desired),
                            author='tbsvttr', performed_via_github_app=None))
    before = read(OUT / 'pr-before.json')
    desired = (OUT / 'pr-body.md').read_text()
    pr = gh('pr', 'view', '143', '--repo', REPO, '--json', 'body,headRefOid')
    assert pr['headRefOid'] == before['headRefOid'] and pr['body'] in (before['body'], desired)
    if pr['body'] != desired:
        gh('pr', 'edit', '143', '--repo', REPO, '--body-file', str(OUT / 'pr-body.md'), raw=True)
    checked = gh('pr', 'view', '143', '--repo', REPO, '--json', 'body,headRefOid')
    assert checked == dict(body=desired, headRefOid=before['headRefOid'])
    record = dict(artifact_commit=commit, method='gh CLI', new_comments=0, new_benchmarks=0,
                  visible_rows=118, unique_implementations=118, rust82_rows=1, goose_rows=1,
                  all_129_records_unchanged=True, comments=results)
    save('publication-record.json', record)
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--publish', metavar='ARTIFACT_COMMIT')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    publish(args.publish) if args.publish else prepare()
