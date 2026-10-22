"""Prepare or publish the requested single, verified Goose entry using gh CLI."""
import argparse
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
VIEW = HERE / 'current-view'
OUT = VIEW / 'publication'
REPO = 'arjaythedev/twelve-dollar-server-challenge'
BASE = 'https://github.com/tbsvttr/twelve-dollar-server-challenge/blob/benchmark-2026-10-22/benchmarks'
MAIN = f'https://github.com/{REPO}/issues/7#issuecomment-6292218419'


def gh(*args, raw=False):
    result = subprocess.run(['gh', *args], check=True, capture_output=True, text=True).stdout
    return result if raw else json.loads(result)


def read(path):
    return json.loads(path.read_text())


def save(name, value):
    path = OUT / name
    path.write_text(json.dumps(value, indent=2) + '\n')
    return path


def digest(body):
    return hashlib.sha256(body.encode()).hexdigest()


class Tables(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tables = 0
        self.rows = []
        self.row = None
        self.cell = None

    def handle_starttag(self, tag, attrs):
        if tag == 'table':
            self.tables += 1
        elif tag == 'tr':
            self.row = []
        elif tag in ('td', 'th'):
            self.cell = ''

    def handle_data(self, data):
        if self.cell is not None:
            self.cell += data

    def handle_endtag(self, tag):
        if tag in ('td', 'th') and self.cell is not None:
            self.row.append(self.cell)
            self.cell = None
        elif tag == 'tr' and self.row is not None:
            self.rows.append(self.row)
            self.row = None


def prepare():
    assert gh('api', 'user')['login'] == 'tbsvttr'
    rows = read(VIEW / 'visible-rows.json')
    goose = [r for r in rows if r.get('pr') == 143]
    assert len(goose) == 1 and goose[0]['requirements_status'] == 'PASS'
    g = goose[0]
    body = (VIEW / 'issue-comment.md').read_text()
    save('6292218419-payload.json', {'body': body})
    for cid in (6292218419, 6343585262):
        old = gh('api', f'repos/{REPO}/issues/comments/{cid}')
        assert old['user']['login'] == 'tbsvttr'
        save(f'{cid}-before.json', old)
    notice = (f'The [main comparison table]({MAIN}) now contains **one current Goose entry: PASS under the documented local protocol**. '
              f'A complete new stock-wrk batch (3×15s, 2s warmups, one server CPU / 2 GiB / no swap) measured '
              f'**{g["successful_rps"]:,.2f} successful req/s**, p99 **{g["p99_ms"]:.3f} ms**, RSS **{g["rss_mib"]:.2f} MiB**, '
              'with **zero HTTP and socket errors in all three trials**. Fresh 42/42 API, dynamic live-data and committed SQLite checks passed. '
              f'[All six Goose/Rust trials and provenance]({BASE}/goose-2026-10-22/recheck-3x15-2026-10-22/measurements.json).\n\n'
              f'[CSV]({BASE}/2026-10-22/comparison.csv) and [HTML]({BASE}/2026-10-22/comparison.html) show the same single Goose result. '
              f'Every previous measurement and error counter remains in the [full record history]({BASE}/2026-10-22/comparison-rows.json); '
              'no individual trial was replaced. PASS describes local ARM64 Docker/wrk runtime conditions. '
              'Official x86-64 droplet/k6 conditions remain unverified; the stable ≥5% comparative target remains unmet.\n')
    save('6343585262-payload.json', {'body': notice})
    pr = gh('pr', 'view', '143', '--repo', REPO, '--json', 'body,headRefOid')
    save('pr-before.json', pr)
    prefix = pr['body'].split('\n\nTen matched 45-second trials', 1)[0]
    assert prefix.startswith('Add a Goose implementation') and 'compiler bootstrap' in prefix
    text = prefix + ('\n\nThe complete new stock-wrk 3×15-second recheck (2-second warmups; one server CPU / 2 GiB / no swap) '
            f'passed the local comparison requirements: **{g["successful_rps"]:,.2f} median successful req/s**, '
            f'p99 {g["p99_ms"]:.3f} ms and {g["rss_mib"]:.2f} MiB RSS, with **zero HTTP/socket errors in all three trials**. '
            'Fresh 42/42 API, dynamic data and committed SQLite checks passed. The source and production binary are unchanged. '
            f'The [main table]({MAIN}), [CSV]({BASE}/2026-10-22/comparison.csv) and '
            f'[HTML]({BASE}/2026-10-22/comparison.html) contain exactly one current Goose entry.\n\n'
            f'[All six new Goose/Rust trials]({BASE}/goose-2026-10-22/recheck-3x15-2026-10-22/measurements.json) and '
            f'[all previous records]({BASE}/2026-10-22/comparison-rows.json) preserve every attempt, including the earlier timeout counters. '
            f'The [longer corrected-driver confirmation]({BASE}/goose-2026-10-22/lead5/holdout-hmac/RESULT.md) remains historical evidence; '
            'the stable ≥5% comparative target remains unmet.\n\n'
            '**Scope:** PASS confirms the documented local runtime protocol. ARM64 Docker/wrk with CPU affinity does not '
            'reproduce the official x86-64 droplet/k6 conditions without affinity; official capacity and full build-budget compliance remain unverified.\n\n'
            'Only `submissions/goose-native-tbsvttr/` is added. Dependencies and source are pinned; no production source changed for this recheck.\n')
    (OUT / 'pr-body.md').write_text(text)
    payload = save('markdown-payload.json', {'text': body, 'mode': 'gfm', 'context': REPO})
    preview = gh('api', '--method', 'POST', 'markdown', '--input', str(payload), raw=True)
    parser = Tables()
    parser.feed(preview)
    goose_rows = [r for r in parser.rows[1:] if 'goose' in r[0].lower()]
    assert parser.tables == 1 and len(parser.rows) == 127
    assert all(len(r) == 10 for r in parser.rows)
    assert len(goose_rows) == 1 and 'PASS' in goose_rows[0][1]
    save('github-preview-proof.json', {'tables': 1, 'rows': 126, 'columns': 10,
         'goose_rows': 1, 'goose_conditions': 'PASS', 'body_sha256': digest(body)})
    print('Prepared existing-comment edits and PR description; GitHub rendered one 126-row table with one Goose PASS.')


def publish(commit):
    assert re.fullmatch(r'[0-9a-f]{40}', commit)
    audit = read(HERE / 'recheck-audit.json')
    assert audit['passed_all'] is True
    records = []
    for cid in (6292218419, 6343585262):
        endpoint = f'repos/{REPO}/issues/comments/{cid}'
        desired = read(OUT / f'{cid}-payload.json')['body']
        old = read(OUT / f'{cid}-before.json')
        current = gh('api', endpoint)
        assert current['body'] in (old['body'], desired), 'Concurrent edit requires reconciliation.'
        assert current['user']['login'] == 'tbsvttr'
        if current['body'] != desired:
            gh('api', '--method', 'PATCH', endpoint, '--input', str(OUT / f'{cid}-payload.json'))
        checked = gh('api', endpoint)
        assert checked['body'] == desired and checked['user']['login'] == 'tbsvttr'
        assert checked.get('performed_via_github_app') is None
        save(f'{cid}-after.json', checked)
        records.append({'url': checked['html_url'], 'body_sha256': digest(desired),
                        'author': 'tbsvttr', 'performed_via_github_app': None})
    before = read(OUT / 'pr-before.json')
    desired = (OUT / 'pr-body.md').read_text()
    current = gh('pr', 'view', '143', '--repo', REPO, '--json', 'body,headRefOid')
    assert current['headRefOid'] == before['headRefOid']
    assert current['body'] in (before['body'], desired)
    if current['body'] != desired:
        gh('pr', 'edit', '143', '--repo', REPO, '--body-file', str(OUT / 'pr-body.md'), raw=True)
    checked = gh('pr', 'view', '143', '--repo', REPO, '--json', 'body,headRefOid')
    assert checked == dict(body=desired, headRefOid=before['headRefOid'])
    record = dict(artifact_commit=commit, method='gh CLI', new_comments=0,
                  comments=records, new_trials=6, complete_new_batches=1,
                  visible_rows=126, visible_goose_rows=1, goose_status='PASS',
                  old_127_records_unchanged=True, official_conditions='UNVERIFIED')
    save('publication-record.json', record)
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--publish', metavar='ARTIFACT_COMMIT')
    args = parser.parse_args()
    OUT.mkdir(exist_ok=True)
    publish(args.publish) if args.publish else prepare()
