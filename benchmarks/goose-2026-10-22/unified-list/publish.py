"""Publish the authorized unified view without changing any measurement."""
import hashlib
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / 'publication'
OUT.mkdir(exist_ok=True)
REPO = 'arjaythedev/twelve-dollar-server-challenge'
REF = 'd153e9a0348e74e5527f6692ee22aca18cc60980'


def gh(*args):
    return json.loads(subprocess.run(['gh', *args], check=True, capture_output=True, text=True).stdout)


def save(name, value):
    (OUT / name).write_text(json.dumps(value, indent=2) + '\n')


def patch_comment(comment_id, body):
    endpoint = f'repos/{REPO}/issues/comments/{comment_id}'
    current = gh('api', endpoint)
    save(f'comment-{comment_id}-before.json', current)
    assert current['user']['login'] == 'tbsvttr'
    payload = f'comment-{comment_id}-payload.json'
    save(payload, {'body': body})
    if current['body'] != body:
        gh('api', '--method', 'PATCH', endpoint, '--input', str(OUT / payload))
    checked = gh('api', endpoint)
    assert checked['body'] == body and checked['user']['login'] == 'tbsvttr'
    assert checked.get('performed_via_github_app') is None
    save(f'comment-{comment_id}-after.json', checked)
    return checked


assert gh('api', 'user')['login'] == 'tbsvttr'
body = (HERE / 'issue-comment.md').read_text()
snapshot = json.loads(Path('/private/tmp/goose-unified-current-20261022.json').read_text())
current = gh('api', f'repos/{REPO}/issues/comments/6292218419')
assert current['body'] in [snapshot['body'], body], 'Overview changed externally; reconcile first.'
assert body.count('<!-- row:') == 127 and len(body) < 65536
main = patch_comment(6292218419, body)

notice = gh('api', f'repos/{REPO}/issues/comments/6343585262')['body']
old_start = 'Goose is now included in the actual main comparison as **PR #143 / outcome 120**:'
new_start = ('All measurements now appear in **one unified table**, sorted by successful req/s, '
             'with role, status, errors and protocol shown in the same columns. '
             'It contains all 120 current outcomes plus seven historical/control/confirmation rows. '
             'Goose PR #143 is placed alongside the other throughput results:')
assert old_start in notice or new_start in notice
notice = notice.replace(old_start, new_start)
notice = notice.replace('643a55e26853341feac6fbcb168ad4c9a909ee9d', REF)
checked_notice = patch_comment(6343585262, notice)

pr = gh('pr', 'view', '143', '--repo', REPO, '--json', 'body,headRefOid,statusCheckRollup')
save('pr-before.json', pr)
assert pr['headRefOid'] == '1454fa62e7c4e273d978b7ad93a492148079edae'
pr_body = pr['body'].replace('643a55e26853341feac6fbcb168ad4c9a909ee9d', REF)
old_phrase = '**Main comparison entry:**'
new_phrase = '**Unified comparison table:**'
pr_body = pr_body.replace(old_phrase, new_phrase)
sentence = 'All 127 current, historical, control and confirmation rows share one throughput-sorted table with explicit status and protocol columns.'
if sentence not in pr_body:
    pr_body += '\n\n' + sentence + '\n'
(OUT / 'pr-body.md').write_text(pr_body)
if pr_body != pr['body']:
    subprocess.run(['gh', 'pr', 'edit', '143', '--repo', REPO, '--body-file', str(OUT / 'pr-body.md')],
                   check=True, capture_output=True, text=True)
pr_after = gh('pr', 'view', '143', '--repo', REPO, '--json', 'body,headRefOid,statusCheckRollup')
save('pr-after.json', pr_after)
assert pr_after['body'] == pr_body and pr_after['headRefOid'] == pr['headRefOid']

record = dict(published_at=datetime.now(timezone.utc).isoformat(), artifact_commit=REF,
    issue_comment_url=main['html_url'], notice_url=checked_notice['html_url'],
    csv_url=f'https://github.com/tbsvttr/twelve-dollar-server-challenge/blob/{REF}/benchmarks/2026-10-22/comparison.csv',
    html_url=f'https://github.com/tbsvttr/twelve-dollar-server-challenge/blob/{REF}/benchmarks/2026-10-22/comparison.html',
    measurement_tables=1, displayed_rows=127, current_outcomes=120,
    historical_measured_revisions=2, short_controls=2, confirmation_rows=3,
    unchanged_clean_ranks=98, audit_checks=569, new_measurements_run=0,
    new_comments_posted=0, method='Authenticated gh CLI', connector_attribution=None,
    body_sha256=hashlib.sha256(body.encode()).hexdigest())
save('publication-record.json', record)
print(json.dumps(record, indent=2))
