"""Publish explicitly scoped condition labels using gh; preserve all metrics."""
import collections
import hashlib
import json
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / 'conditions-publication'
OUT.mkdir(exist_ok=True)
REPO = 'arjaythedev/twelve-dollar-server-challenge'


def gh(*args):
    return json.loads(subprocess.run(['gh', *args], check=True, capture_output=True, text=True).stdout)


def save(name, value):
    (OUT / name).write_text(json.dumps(value, indent=2) + '\n')


def update(comment_id, body):
    endpoint = f'repos/{REPO}/issues/comments/{comment_id}'
    old = gh('api', endpoint)
    assert old['user']['login'] == 'tbsvttr'
    save(f'{comment_id}-before.json', old)
    save(f'{comment_id}-payload.json', {'body': body})
    if old['body'] != body:
        gh('api', '--method', 'PATCH', endpoint, '--input', str(OUT / f'{comment_id}-payload.json'))
    checked = gh('api', endpoint)
    assert checked['body'] == body and checked['user']['login'] == 'tbsvttr'
    assert checked.get('performed_via_github_app') is None
    save(f'{comment_id}-after.json', checked)
    return checked


assert gh('api', 'user')['login'] == 'tbsvttr'
body = (HERE / 'issue-comment.md').read_text()
before = json.loads(Path('/private/tmp/goose-conditions-before-20261022.json').read_text())
live = gh('api', f'repos/{REPO}/issues/comments/6292218419')
assert live['body'] in [before['body'], body], 'Overview changed externally; reconcile first.'
main = update(6292218419, body)
notice = gh('api', f'repos/{REPO}/issues/comments/6343585262')['body']
paragraph = ('**Conditions are now explicit per row:** PASS confirms only the documented local runtime protocol; '
             'FAIL gives its observed cause; UNVERIFIED means missing applicable evidence; OTHER PROTOCOL identifies '
             'the 10×45s corrected-driver references. The Goose stock 3×15s row is FAIL because of 38 reported timeouts; '
             'its longer row is OTHER PROTOCOL. The original x86-64 droplet/k6 conditions were not reproduced by '
             'these ARM64 Docker/wrk runs with CPU affinity, and full source-rule/build-budget compliance is not certified.')
if paragraph not in notice:
    first, separator, rest = notice.partition('\n\n')
    assert separator
    notice = first + '\n\n' + paragraph + '\n\n' + rest
checked_notice = update(6343585262, notice)
pr = gh('pr', 'view', '143', '--repo', REPO, '--json', 'body,headRefOid')
text = pr['body']
if '**Requirement status:**' not in text:
    text += ('\n\n**Requirement status:** The table explicitly labels recorded local conditions: the 3×15s Goose row '
             'is FAIL (38 reported wrk timeouts); the 10×45s row is DIFFERENT_PROTOCOL. PASS elsewhere means only '
             'the documented local runtime checks. Original x86-64 droplet/k6 conditions without CPU affinity '
             'were not reproduced by the local ARM64 Docker/wrk experiments. Full challenge-rule compliance and '
             'source-build resource limits remain unverified.\n')
(OUT / 'pr-body.md').write_text(text)
if text != pr['body']:
    subprocess.run(['gh', 'pr', 'edit', '143', '--repo', REPO, '--body-file', str(OUT / 'pr-body.md')],
                   check=True, capture_output=True, text=True)
verified_pr = gh('pr', 'view', '143', '--repo', REPO, '--json', 'body,headRefOid')
assert verified_pr['body'] == text and verified_pr['headRefOid'] == pr['headRefOid']
rows = json.loads((HERE / 'rows.json').read_text())
record = dict(issue_comment_url=main['html_url'], notice_url=checked_notice['html_url'],
    row_count=len(rows), local_conditions_counts=dict(collections.Counter(r['requirements_status'] for r in rows)),
    official_conditions_status='UNVERIFIED for all 127; original benchmark not reproduced',
    metrics_and_source_records_unchanged=True, body_sha256=hashlib.sha256(body.encode()).hexdigest(),
    conditions_audit_checks=859, new_benchmarks=0, new_comments=0, method='gh CLI',
    artifact_commit='bb2f2def4f6c2e2ef2eb1262f406a754b5757844')
save('publication-record.json', record)
print(json.dumps(record, indent=2))
