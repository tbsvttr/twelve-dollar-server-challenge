"""Publish the corrected main list and update the existing notice using gh."""
import hashlib
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / 'publication'
OUT.mkdir(exist_ok=True)
REPO = 'arjaythedev/twelve-dollar-server-challenge'
REF = '643a55e26853341feac6fbcb168ad4c9a909ee9d'
BASE = f'https://github.com/tbsvttr/twelve-dollar-server-challenge/blob/{REF}/benchmarks'
OVERVIEW = f'https://github.com/{REPO}/issues/7#issuecomment-6292218419'
PR = f'https://github.com/{REPO}/pull/143'


def save(name, value):
    (OUT / name).write_text(json.dumps(value, indent=2) + '\n')


def gh(*args):
    p = subprocess.run(['gh', *args], capture_output=True, text=True, check=True)
    return json.loads(p.stdout)


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


login = gh('api', 'user')['login']
assert login == 'tbsvttr'
desired = json.loads((HERE / 'issue-comment.json').read_text())['body']
before = json.loads(Path('/private/tmp/goose-list-current-20261022.json').read_text())
endpoint = f'repos/{REPO}/issues/comments/6292218419'
current = gh('api', endpoint)
save('main-list-before.json', current)
assert current['user']['login'] == login
assert current['body'] in [before['body'], desired], 'The overview changed externally; reconcile before editing.'
assert len(desired) < 65536
assert '| #143 ' in desired and 'Coverage: 120 ' in desired
save('main-list-payload.json', {'body': desired})
if current['body'] != desired:
    gh('api', '--method', 'PATCH', endpoint, '--input', str(OUT / 'main-list-payload.json'))
after = gh('api', endpoint)
save('main-list-after.json', after)
assert after['body'] == desired and after['user']['login'] == login
assert after.get('performed_via_github_app') is None

notice = f'''Goose is now included in the actual main comparison as **PR #143 / outcome 120**: [main issue list]({OVERVIEW}), [all-outcome CSV]({BASE}/2026-10-22/comparison.csv), [filterable HTML]({BASE}/2026-10-22/comparison.html), [report]({BASE}/2026-10-22/report.md).

The matching ranking protocol (stock wrk, 3×15 seconds, one server CPU / 2 GiB / no swap) measured Goose at **117,565.71 successful req/s**, p99 **22.060 ms**, RSS **15.26 MiB**, zero HTTP errors and **38 reported wrk timeouts**. It appears in the diagnostic results with no clean rank. The fresh unchanged Rust #82 control measured 106,162.00 req/s with 34 reported wrk timeouts; its earlier ranked value remains untouched. [All six attempts and provenance]({BASE}/goose-2026-10-22/ranking-3x15-2026-10-22/measurements.json).

**All 119 previous outcome measurements and both historical measured revisions are preserved.** The [separate corrected-driver 10×45-second confirmation]({BASE}/goose-2026-10-22/lead5/holdout-hmac/RESULT.md) remains separate: +13.72% paired point estimate, +1.85% one-sided 95% lower bound, stable ≥5% target unmet. [Implementation PR]({PR}); its Ubuntu 24.04 install/build/API CI passed.'''
endpoint = f'repos/{REPO}/issues/comments/6343585262'
old_notice = gh('api', endpoint)
save('notice-before.json', old_notice)
assert old_notice['user']['login'] == login
save('notice-payload.json', {'body': notice})
if old_notice['body'] != notice:
    gh('api', '--method', 'PATCH', endpoint, '--input', str(OUT / 'notice-payload.json'))
checked_notice = gh('api', endpoint)
save('notice-after.json', checked_notice)
assert checked_notice['body'] == notice and checked_notice['user']['login'] == login
assert checked_notice.get('performed_via_github_app') is None

pr = gh('pr', 'view', '143', '--repo', REPO, '--json', 'body,headRefOid,statusCheckRollup,url')
save('pr-before.json', pr)
assert pr['headRefOid'] == '1454fa62e7c4e273d978b7ad93a492148079edae'
assert pr['statusCheckRollup'] and all(c.get('conclusion') == 'SUCCESS' for c in pr['statusCheckRollup'])
body = pr['body'].replace(
    'Clean compiler bootstrap at that limit and native x86-64 execution are not yet verified; the upstream workflow can check the latter.',
    'The upstream Ubuntu 24.04 install/build/API workflow also passed on x86-64. Clean compiler bootstrap within the one-CPU/2-GiB budget remains unverified.')
marker = '**Main comparison entry:**'
if marker not in body:
    body += (f'\n\n{marker} [The main list]({OVERVIEW}) and [CSV]({BASE}/2026-10-22/comparison.csv) '
             'now include PR143 as outcome 120. The original stock-wrk 3×15-second protocol measured '
             '117,565.71 successful req/s, p99 22.060 ms and 15.26 MiB RSS. All official/dynamic/database checks passed; '
             '38 reported wrk timeouts make this a diagnostic result with no clean rank. '
             'Every prior measurement remains preserved. The longer corrected-driver confirmation above remains separate.\n')
(OUT / 'pr-body.md').write_text(body)
if body != pr['body']:
    subprocess.run(['gh', 'pr', 'edit', '143', '--repo', REPO, '--body-file', str(OUT / 'pr-body.md')],
                   check=True, capture_output=True, text=True)
verified_pr = gh('pr', 'view', '143', '--repo', REPO, '--json', 'body,headRefOid,statusCheckRollup,url')
save('pr-after.json', verified_pr)
assert verified_pr['body'] == body and verified_pr['headRefOid'] == pr['headRefOid']

record = dict(published_at=datetime.now(timezone.utc).isoformat(),
    method='Authenticated gh CLI; existing comments edited, no new notification posted',
    main_list_url=after['html_url'], notice_url=checked_notice['html_url'], pr_url=verified_pr['url'],
    artifact_commit=REF, csv_url=BASE + '/2026-10-22/comparison.csv',
    html_url=BASE + '/2026-10-22/comparison.html',
    main_list_body_sha256=sha(desired), previous_body_sha256=sha(before['body']),
    outcome_count=120, previous_outcomes_preserved=119, historical_measured_rows_preserved=2,
    ranked=98, diagnostic=8, unmeasured=14, goose_successful_rps=117565.71,
    goose_timeouts=38, goose_rank=None, independent_audit_checks=100,
    corrected_driver_holdout_pooled=False, ci='SUCCESS', connector_attribution=None)
save('publication-record.json', record)
print(json.dumps(record, indent=2))
