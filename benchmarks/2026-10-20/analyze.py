"""Generate a complete coverage report from the pinned current benchmark evidence.

Missing measurements remain explicit. Only three clean, matching 15-second
trials following matching correctness checks enter the throughput ranking.
No historical dependency counts or benchmark measurements are reused.
"""
import argparse
import collections
import csv
import hashlib
import html
import json
import math
import statistics
from pathlib import Path

from run import ROOT, build_records, read, save

DATE = '2026-10-20'
REQUIRED_TRIALS = {1, 2, 3}
SOCKET_KEYS = ('connect', 'read', 'write', 'timeout')
METRIC_KEYS = ('rps', 'successful_rps', 'p50_ms', 'p95_ms', 'p99_ms', 'rss_mib', 'cpu_percent')
PENDING = {'not_built', 'building', 'delegated', 'not_verified', 'not_measured', 'incomplete_measurements', 'stale_build'}


def identifier(row):
    return str(row.get('case_id', row.get('id', row['pr'])))


def current_records(records, candidate, build, shared):
    return [record for record in records
            if identifier(record) == identifier(candidate)
            and record.get('commit') == candidate.get('commit')
            and record.get('image_id') == build.get('image_id')
            and record.get('shared_hashes') == shared]


def reason(record):
    return str(record.get('reason') or record.get('error') or record.get('source_error')
               or record.get('exclusion_reason') or '')


def finite_number(value):
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def invalid_trial(record):
    """Validate the complete input before attaching any aggregate measurements."""
    for key in ('duration_s', *METRIC_KEYS):
        if key not in record:
            return f'Missing {key} in measured output.'
        if not finite_number(record[key]) or record[key] < 0:
            return f'{key} must be a finite, nonnegative number.'
    if record['duration_s'] == 0 or record['rss_mib'] == 0:
        return 'Measured duration and service RSS must be positive.'
    if type(record.get('http_errors')) is not int or record['http_errors'] < 0:
        return 'HTTP error count must be a nonnegative integer.'
    socket = record.get('socket_errors')
    if (not isinstance(socket, dict) or any(type(socket.get(key)) is not int
            or socket[key] < 0 for key in SOCKET_KEYS)):
        return 'Every socket error count must be a nonnegative integer.'
    if type(record.get('database_valid')) is not bool:
        return 'Missing boolean database-validation result.'
    configuration = record.get('configuration')
    if (record.get('valid_duration') is not True or not 14.5 <= record['duration_s'] <= 17
            or not isinstance(configuration, dict)
            or configuration.get('measurement_seconds') != 15
            or configuration.get('threads') != 2
            or configuration.get('connections') != 64
            or configuration.get('warmup_seconds') != 2):
        return 'Trial must use a valid 15-second duration, two threads, 64 connections and two-second warm-up.'
    return None


def summarize(candidate, build, verification, measurements, shared):
    row = {key: candidate.get(key) for key in
           ('pr', 'id', 'case_id', 'title', 'url', 'folder', 'commit', 'source_url',
            'source_sha256', 'archive_sha256', 'app_loc', 'own_loc', 'nginx', 'eligible')}
    row['case_id'] = identifier(candidate)
    row['eligible'] = candidate.get('eligible', True)
    row['build_status'] = build.get('status', build.get('state', 'not_built'))
    row['build_exit_code'] = build.get('exit_code')
    row['build_elapsed_s'] = build.get('elapsed_s')
    row['build_log'] = 'logs/build-pr' + identifier(candidate) + '.log'
    row['runtime_setup'] = build.get('runtime_setup')
    row['build_adapter'] = build.get('build_adapter')
    row['image_id'] = build.get('image_id')
    row['status'], row['reason'] = 'not_built', 'No build attempt recorded.'
    row['rank'] = None
    row['ranked'] = False
    row['trials_recorded'] = 0
    if candidate.get('status') != 'prepared':
        row.update(status=candidate.get('status', 'source_failed'),
                   reason=reason(candidate) or 'Submitted build.sh/start.sh are missing; no application adapter was invented.')
        return row
    if row['build_status'] == 'unsupported_architecture':
        row.update(status='unsupported_architecture', reason=reason(build))
        return row
    if not build:
        return row
    if (build.get('exit_code') == 124 and build.get('build_deadline_extension')
            and 'elapsed_s' not in build['build_deadline_extension']):
        row.update(status='building', reason='A bounded build continuation is in progress after the initial local deadline.')
        return row
    if build.get('exit_code') != 0:
        row.update(status=row['build_status'] if row['build_status'] != 'built' else 'build_failed',
                   reason=reason(build) or f"Build did not succeed (exit {build.get('exit_code')}); see build log.")
        return row
    if build.get('commit') != candidate.get('commit'):
        row.update(status='stale_build', reason='Build revision does not match the pinned source.')
        return row
    verifications = current_records(verification, candidate, build, shared)
    if not verifications:
        row.update(status='not_verified', reason='No correctness run matches this source, image and shared fixture set.')
        return row
    verified = verifications[-1]
    row['tests_passed'], row['tests_failed'] = verified.get('passed'), verified.get('failed')
    row['official_passed_all'] = verified.get('official_passed_all', False)
    row['semantic_passed_all'] = verified.get('semantic', {}).get('passed_all')
    row['verification_log'] = 'logs/verify-' + row['case_id'] + '-1.log'
    if verified.get('error'):
        row.update(status='runtime_failed', reason=reason(verified))
        return row
    if not verified.get('official_passed_all'):
        row.update(status='test_failed', reason=f"Official checks: {verified.get('passed')}/42 passed, {verified.get('failed')} failed.")
        return row
    if not verified.get('semantic', {}).get('passed_all'):
        row.update(status='semantic_test_failed', reason=reason(verified.get('semantic', {})) or 'Dynamic round-trip checks failed.')
        return row
    if not verified.get('passed_all'):
        database = next((value['database_after'] for value in verified.get('final', [])
                         if 'database_after' in value), {})
        row['database_after_verification'] = database
        row.update(status='database_check_failed', reason=(
            'Official and dynamic API checks passed, but the post-shutdown committed-write/integrity '
            f"check failed: initial posts={database.get('initial_post_count')}, "
            f"final posts={database.get('post_count')}, SQLite quick_check={database.get('integrity')}."))
        if row['case_id'] == '79' and (ROOT / 'durability-pr79.json').exists():
            row['reason'] += ' An independent live reader also confirms uncommitted acknowledged writes; see durability-pr79.json.'
        return row
    matching = current_records(measurements, candidate, build, shared)
    # The latest attempt per trial is authoritative; repeats never multiply samples.
    trials = {run['trial']: run for run in matching if run.get('trial') in REQUIRED_TRIALS}
    row['trials_recorded'] = len(trials)
    row['trial_errors'] = {trial: run['error'] for trial, run in trials.items() if run.get('error')}
    if not trials:
        row.update(status='not_measured', reason='Correctness passed; throughput has not run.')
        return row
    if set(trials) != REQUIRED_TRIALS:
        row.update(status='incomplete_measurements', reason=f'{len(trials)}/3 matching measured trials recorded.')
        return row
    runs = [trials[trial] for trial in sorted(trials)]
    if any(run.get('error') for run in runs):
        row.update(status='measurement_failed', reason='; '.join(f"Trial {trial}: {error}" for trial, error in row['trial_errors'].items()))
        return row
    unfinished = [run['trial'] for run in runs if run.get('completed') is not True]
    if unfinished:
        row.update(status='incomplete_measurements',
                   reason='Unfinished measured attempt(s): ' + ', '.join(map(str, unfinished)) + '. A completed retry is required.')
        return row
    for run in runs:
        issue = invalid_trial(run)
        if issue:
            row.update(status='invalid_measurements', reason=f'Trial {run["trial"]}: {issue}')
            return row
    for key in METRIC_KEYS:
        row[key] = statistics.median(run[key] for run in runs)
    row['rps_min'] = min(run['successful_rps'] for run in runs)
    row['rps_max'] = max(run['successful_rps'] for run in runs)
    row['http_errors'] = sum(run.get('http_errors', 0) for run in runs)
    row['socket_errors'] = {key: sum(run.get('socket_errors', {}).get(key, 0) for run in runs) for key in SOCKET_KEYS}
    row['database_valid'] = all(run.get('database_valid', False) for run in runs)
    if row['eligible'] and not row['database_valid']:
        row.update(status='database_check_failed', reason='At least one measured run failed SQLite integrity or committed-write validation.')
    elif row['http_errors'] or any(row['socket_errors'].values()):
        row.update(status='measured_with_errors', reason='All three trials completed, with HTTP/socket errors. Measurements are diagnostic and excluded from ranking.')
    elif not row['eligible']:
        row.update(status='ineligible_reference', reason='Custom memory store (#21); measured for reference and excluded from SQLite ranking.')
    else:
        row.update(status='measured', reason='', ranked=True)
    return row


def number(value, digits=0):
    return '—' if value is None else f'{value:,.{digits}f}'


def cell(value):
    return str(value or '—').replace('|', '\\|').replace('\n', ' ')


def link(row, source=False):
    label = row.get('folder') or row.get('title') or row['case_id']
    return f"[#{row['pr']}]({row['url']}) [{cell(label)}]({row.get('source_url') or row['url']})" if source else f"[#{row['pr']}]({row['url']}) `{row['case_id']}`"


def report(summary):
    rows, excluded = summary['rows'], summary['excluded']
    ranked = sorted((row for row in rows if row['ranked']), key=lambda row: row['rank'])
    diagnostic = [row for row in rows if row.get('successful_rps') is not None and not row['ranked']]
    unmeasured = [row for row in rows if row.get('successful_rps') is None]
    counts = summary['counts']
    lines = [f'**Current all-submission benchmark — {DATE}.**', '',
             f"This refresh of [issue #7](https://github.com/arjaythedev/twelve-dollar-server-challenge/issues/7) accounts for **{counts['snapshot_prs']} PRs** in the frozen API snapshot: **{counts['submission_prs']} current submission PRs / {counts['candidates']} implementations**, plus {counts['excluded_prs']} excluded PRs. Multi-implementation PRs have separate case IDs. All revisions and source hashes are retained in `manifest.json`; every outcome is listed below.", '',
             "The creator's follow-up, [I Asked Expert Programmers to Max Out a $12 Server](https://www.youtube.com/watch?v=QGWKCaglSBI) (2026-10-13), revisits the original [challenge video](https://www.youtube.com/watch?v=sQXFhh_PiG4). Its description reports 64,000 concurrent users against a 14,050-user baseline on the 1-vCPU/2-GB server. Those capacity figures use a different workload and machine; they are context for this refresh, not scores inferred from the local measurements below.", '',
             f"**Coverage:** {counts['ranked']} clean implementations ranked; {counts['diagnostic']} measured diagnostic/reference rows; {counts['unmeasured']} implementations without a complete valid measurement. **Run coverage {'complete' if summary['complete'] else 'in progress'}**. State counts: " + ', '.join(f'{key}={value}' for key, value in sorted(counts['states'].items())) + '.', '',
             '**Common conditions.** Native Linux ARM64 containers on the recorded local host; one server CPU (CPU 0), 2 GiB RAM with no container swap, and 65,535 file descriptors. Every server receives the same Docker-default seccomp policy with only the three io_uring system calls additionally allowed; the exact profile and hash are retained. The load generator runs separately on CPUs 1–2 with two CPUs. All tests and measured trials run sequentially. `wrk -t2 -c64`, three 15-second trials after a two-second warm-up, fresh process and seeded database for each trial, deterministic shuffled order per round. The submitted `start.sh` is used. Nginx is included in the service budget and RSS where selected from the submitted configuration.', '',
             '**Build and runtime adapters.** Submitted application, build and start scripts were not edited. Recorded [setup helpers](runtime-scripts/) preserve submitted version/commit pins where available and select verified native ARM64 assets; [build/image provenance](build-status.json) records the exact results. V #69/#70 retain the pinned V/VC/TCC and GC commits, with the native GC object configured for `USE_MMAP` alongside `USE_MUNMAP` ([GC helper](runtime-scripts/vlang-gc-config-arm64.sh), [provenance](build-status-41-90.json)). Their compiler bootstrap reached **4.16 GiB** with a **6 GiB build allowance** ([resource audit](vlang-build-resources.json)); all measured servers retain the common **2 GiB runtime limit**. #85 uses Temurin **25.0.4.1+1** within its documented Java 21+ range because its unchanged compact-header startup flag is unavailable in the installer’s JDK 21 default ([adapter](runtime-scripts/pr85.sh), [repair provenance](repair85-status.json)).', '',
             '**Validation and workload.** Each measured image passed the 42 official API checks and a separate dynamic create/read/feed/like round-trip before measurement. Pinned source files are verified inside the measured image at startup. The inherited mixed request logic remains unchanged: 100 feed reads : 100 single-post reads : 15 likes : 2 creates, without think time. IDs start at seeded post **500000** and update only when a feed body begins with the exact compact prefix `{"posts":[` and IDs match `"id":` immediately followed by digits. Unrecognized response formats retain the existing IDs. SQLite quick-check and committed post growth are checked after every run; #21 is an explicitly ineligible memory-store reference. The Lua completion callback only adds p95 reporting to stock wrk.', '',
             '**Reading the table.** Values are medians of three runs; range is min–max successful req/s. RSS is summed service-process RSS sampled after load before shutdown, including Nginx where used; it is not peak or container memory and shared pages may be counted more than once. CPU includes live service-process work and CPU from waited/reaped children; 100% means one full server CPU. p95/p99 are medians of per-run histogram percentiles. Errors are totals over measured trials; warm-ups are excluded. A clean row requires zero HTTP and socket errors.', '',
             '**wrk timeout accounting.** The [verified load binary](wrk-binary-provenance.json) is Ubuntu ARM64 wrk **4.1.0-4build2**. Its reported `timeout` counter counts completed responses whose recorded latency falls outside the default **two-second histogram range**. Those completions remain in request totals and req/s, while their latency samples are omitted from the reported maximum and percentiles ([package/source analysis](diagnostics-wrk-timeouts.json), [completion accounting](https://github.com/wg/wrk/blob/4.1.0/src/wrk.c#L307-L322)). Successful req/s subtracts only the recorded HTTP-error rate; successful over-limit completions remain included. HTTP and timeout counters can overlap. Diagnostic p95/p99 values therefore omit these over-limit samples. The declared clean-ranking rule still requires zero HTTP and wrk socket-error counters across all three trials. Unfinished requests at test end do not automatically increment this timeout counter.', '',
             '**Ranking.** Ordered by successful HTTP responses per second. App/Own LOC are fresh physical source-line counts including blanks/comments, with runtime application and support roles reviewed in the [LOC audit](loc-audit.json) and [per-file inventories](source-inventories/). Own LOC also includes authored support files; recognizable vendored forks, generated code and lockfiles are excluded. Role classification remains heuristic. No dependency count or composite score is carried forward from older revisions: current resolved production dependency graphs have not been uniformly audited. There is no imputation or redistribution of the previous score weights.', '',
             '| Rank | PR / implementation / pinned source | HTTP | Successful req/s ↑ | Range | p95 ms | p99 ms | RSS MiB | CPU % | App / Own LOC |',
             '|---:|---|---|---:|---:|---:|---:|---:|---:|---:|']
    for row in ranked:
        lines.append(f"| {row['rank']} | {link(row, True)} | {'Nginx + app' if row['nginx'] else 'Direct'} | {number(row['successful_rps'])} | {number(row['rps_min'])}–{number(row['rps_max'])} | {number(row['p95_ms'], 3)} | {number(row['p99_ms'], 3)} | {number(row['rss_mib'], 2)} | {number(row['cpu_percent'], 1)} | {number(row['app_loc'])} / {number(row['own_loc'])} |")
    if not ranked:
        lines.append('| — | No complete clean measurements yet | — | — | — | — | — | — | — | — |')
    lines += ['', '**Measured reference or diagnostic rows.**', '',
              '| Case | Implementation | Status | Successful req/s | p99 ms | RSS MiB | HTTP errors | Socket errors C/R/W/T |',
              '|---|---|---|---:|---:|---:|---:|---|']
    for row in sorted(diagnostic, key=lambda row: row.get('successful_rps', 0), reverse=True):
        lines.append(f"| {link(row)} | {cell(row['folder'])} | {row['status']} | {number(row.get('successful_rps'))} | {number(row.get('p99_ms'), 3)} | {number(row.get('rss_mib'), 2)} | {row.get('http_errors', '—')} | {'/'.join(str(row.get('socket_errors', {}).get(key, '—')) for key in SOCKET_KEYS)} |")
    if not diagnostic:
        lines.append('| — | None | — | — | — | — | — | — |')
    diagnostic_notes = []
    if (ROOT / 'diagnostics-pr103.json').exists():
        diagnostic_notes.append('[#103 trial 1](diagnostics-pr103.json) recorded 30 non-2xx/3xx responses and 30 socket timeouts; overlap between these separate counters is unknown. Its SQLite EXCLUSIVE locking, 16-connection pool and five-second busy timeout suggest possible lock contention.')
    if (ROOT / 'diagnostics-pr119.json').exists():
        diagnostic_notes.append('[#119 trial 1](diagnostics-pr119.json) recorded 20,215 non-2xx/3xx responses and zero socket errors; its source suggests a possible race between fresh feed IDs and a stale reader snapshot.')
    if diagnostic_notes:
        lines += ['', '**Retained error diagnostics.** ' + ' '.join(diagnostic_notes) + ' These causes are source-supported hypotheses. Exact response statuses and the route breakdown were not observed.']
    if (ROOT / 'diagnostics-pr36.json').exists():
        lines += ['', '[#36 trial 2 diagnostics](diagnostics-pr36.json) retain **zero HTTP errors and one socket timeout**. A fully occupied ten-connection pool with waiting borrowers, 98.74% CPU usage and 42,504 DEBUG log lines provide load context only. The timeout’s cause and affected route remain unknown; no request-level trace establishes a causal link.']
    if (ROOT / 'diagnostics-pr47.json').exists():
        lines += ['', '[#47 trial 2 diagnostics](diagnostics-pr47.json) retain **zero HTTP errors and one socket timeout**; the affected route and cause remain unknown.']
    if (ROOT / 'diagnostics-pr94.json').exists():
        lines += ['', '[#94 trial 2 diagnostics](diagnostics-pr94.json) retain **zero HTTP errors and 63 socket timeouts** with an empty server log. Their timing and cause remain unknown.']
    if (ROOT / 'diagnostics-pr16.json').exists():
        lines += ['', '[#16 trial 3 diagnostics](diagnostics-pr16.json) retain **zero HTTP errors and 64 socket timeouts** after two clean trials. The server log is empty; timeout timing and cause remain unknown.']
    if (ROOT / 'diagnostics-pr124.json').exists():
        lines += ['', '[#124 trial 3 diagnostics](diagnostics-pr124.json) retain **zero HTTP errors and 64 socket timeouts** after two clean trials. The startup-only server log does not establish their timing or cause.']
    lines += ['', '**Build, runtime and test outcomes without a valid three-trial result.** Full diagnostics are retained in `logs/` and `server-logs/`. A platform/toolchain failure is an outcome for this local setup, not a statement that the submission cannot run on the official x86-64 host.', '',
              '| Case | Implementation | Status | Official checks | Reason / evidence |',
              '|---|---|---|---|---|']
    for row in sorted(unmeasured, key=lambda row: (row['pr'], row['case_id'])):
        tests = f"{row['tests_passed']}/42" if row.get('tests_passed') is not None else 'not run'
        detail = row['reason'][:1500]
        evidence = row.get('verification_log') or row.get('build_log')
        if not evidence or not (ROOT / evidence).is_file() or (ROOT / evidence).stat().st_size == 0:
            evidence = 'build-status.json' if row['status'] in ('unsupported_architecture', 'build_failed') else 'manifest.json'
        lines.append(f"| {link(row)} | {cell(row['folder'])} | {row['status']} | {tests} | {cell(detail)} ([evidence]({evidence})) |")
    if not unmeasured:
        lines.append('| — | None | — | — | — |')
    lines += ['', '**Excluded PRs in the snapshot.** Closed unmerged submissions and contributions without a server implementation are accounted for here.', '',
              '| PR | Title | Reason |', '|---|---|---|']
    for row in excluded:
        lines.append(f"| [#{row['pr']}]({row['url']}) | {cell(row['title'])} | {cell(reason(row))} |")
    lines += ['', '**Scope.** This extends the previous common-condition local comparison; it does not determine the challenge’s official maximum users. The [official scoring procedure](https://github.com/arjaythedev/twelve-dollar-server-challenge#scoring) uses a five-minute k6 hold and latency/error thresholds on the organizer’s Ubuntu x86-64 droplet. ARM64 results with 64 active connections cannot establish that capacity. Small differences may be run-to-run variation.', '',
              '**Artifacts and reproduction.** `comparison.csv`, `trials.csv`, `summary.json` and the filterable `comparison.html` are generated from raw evidence by `python3 analyze.py`. `python3 run.py verify` then `python3 run.py bench` reproduce validation and measurement after the pinned images have been built. Source archives, inventories, per-file hashes, exact image IDs, complete command output, database checks, and `environment-*.json` preserve the evidence. Build shards are merged without silently replacing duplicate case IDs.', '',
              '```text', 'python3 run.py verify', 'python3 run.py bench', 'python3 analyze.py --strict', '```', '']
    return '\n'.join(lines)


def interactive(summary):
    columns = [('rank', 'Rank'), ('case_id', 'Case'), ('folder', 'Implementation'),
               ('status', 'Status'), ('successful_rps', 'Successful req/s'), ('p95_ms', 'p95 ms'),
               ('p99_ms', 'p99 ms'), ('rss_mib', 'RSS MiB'), ('cpu_percent', 'CPU %'),
               ('app_loc', 'App LOC'), ('own_loc', 'Own LOC'), ('reason', 'Reason')]
    values = json.dumps(summary['rows'], ensure_ascii=False).replace('<', '\\u003c')
    return '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Current server benchmark — 2026-10-20</title><style>
body{font:15px system-ui,sans-serif;margin:2rem;color:#172b36;background:#f7fafc}h1{font-size:1.5rem}p{max-width:85ch;line-height:1.5}input,select{font:inherit;padding:.5rem;border:1px solid #a9bcc7;border-radius:5px;margin:0 .8rem 1rem 0}table{border-collapse:collapse;background:white;width:100%}th,td{text-align:left;padding:.6rem;border-bottom:1px solid #dbe4ea;vertical-align:top}th{cursor:pointer;white-space:nowrap;background:#e8f1f5;position:sticky;top:0}td:nth-child(n+5):not(:last-child){text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}td:last-child{min-width:20rem;max-width:40rem;font-size:.85rem}a{color:#075c8b}.wrap{overflow:auto}#count{font-weight:600}
</style><h1>Current all-submission benchmark — 2026-10-20</h1>
<p>Native ARM64, 1 server CPU, 2 GiB; 3 × 15 seconds, wrk 2 threads / 64 connections. Medians shown. RSS is end-of-load service RSS. Click a column to sort, search or filter below. <a href="report.md">Full methodology, coverage and exclusions</a> · <a href="comparison.csv">CSV</a> · <a href="summary.json">JSON</a></p>
<p>wrk timeout counters count completed responses whose recorded latency falls outside the default two-second histogram range. These completions remain in throughput; their samples are omitted from the displayed latency percentiles. Clean ranking requires zero HTTP and wrk socket-error counters in all three trials. <a href="diagnostics-wrk-timeouts.json">Accounting and binary provenance</a>.</p>
<label>Search <input id="search" placeholder="language, implementation, PR, reason"></label><label>Status <select id="status"><option value="">All statuses</option></select></label><span id="count"></span><div class="wrap"><table><thead><tr>''' + ''.join(f'<th data-key="{key}">{html.escape(label)}</th>' for key, label in columns) + '''</tr></thead><tbody></tbody></table></div><script>
const rows=''' + values + ''',columns=''' + json.dumps(columns) + ''';
let sortKey='rank',direction=1;const search=document.querySelector('#search'),status=document.querySelector('#status'),body=document.querySelector('tbody');
for(const value of [...new Set(rows.map(r=>r.status))].sort()){const option=document.createElement('option');option.value=value;option.textContent=value;status.append(option)}
function matchesSearch(row,query){const term=query.trim().toLowerCase();if(!term)return true;const numbered=/^#?([0-9]+)$/.exec(term);if(numbered)return Number(row.pr)===Number(numbered[1]);const text=term.startsWith('#')?term.slice(1):term;return [row.case_id,row.folder,row.title,row.status,row.reason].some(value=>String(value==null?'':value).toLowerCase().includes(text))}
function draw(){const shown=rows.filter(r=>(!status.value||r.status===status.value)&&matchesSearch(r,search.value));shown.sort((a,b)=>{let x=a[sortKey],y=b[sortKey];if(x==null)return y==null?0:1;if(y==null)return -1;return(typeof x==='number'?x-y:String(x).localeCompare(String(y)))*direction});body.replaceChildren();for(const row of shown){const tr=document.createElement('tr');for(const [key]of columns){const td=document.createElement('td'),value=row[key];if(key==='case_id'){const a=document.createElement('a');a.href=row.url;a.textContent='#'+value;td.append(a)}else if(key==='folder'&&row.source_url){const a=document.createElement('a');a.href=row.source_url;a.textContent=value||'—';td.append(a)}else td.textContent=value==null?'—':typeof value==='number'?value.toLocaleString(undefined,{maximumFractionDigits:['p95_ms','p99_ms'].includes(key)?3:2}):value;tr.append(td)}body.append(tr)}document.querySelector('#count').textContent=shown.length+' of '+rows.length+' implementations'}
search.addEventListener('input',draw);status.addEventListener('change',draw);document.querySelectorAll('th').forEach(th=>th.addEventListener('click',()=>{direction=sortKey===th.dataset.key?-direction:1;sortKey=th.dataset.key;draw()}));draw();
</script></html>'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--strict', action='store_true', help='Fail if any current candidate has unfinished work.')
    parser.add_argument('--recorded-fixtures', action='store_true',
                        help='Reanalyze archived records using their recorded fixture hashes; does not validate current fixture files.')
    args = parser.parse_args()
    candidates = read(ROOT / 'manifest.json', [])
    excluded = read(ROOT / 'excluded.json', [])
    snapshot = read(ROOT / 'prs-snapshot.json', [])
    builds = build_records()
    verification = read(ROOT / 'verification.json', [])
    measurements = read(ROOT / 'measurements.json', [])
    shared = read(ROOT / 'shared-sha256.json', {})
    # Default analysis verifies current bytes. The explicit publication mode only
    # reanalyzes archived records; large seed fixtures are omitted from the bundle.
    if not args.recorded_fixtures:
        shared = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in shared}
    if len({identifier(row) for row in candidates}) != len(candidates):
        raise ValueError('Duplicate candidate case IDs')
    covered = {row['pr'] for row in candidates} | {row['pr'] for row in excluded}
    expected = {row['number'] for row in snapshot}
    if covered != expected:
        raise ValueError(f'PR coverage differs from snapshot: missing={expected-covered}, extra={covered-expected}')
    rows = [summarize(row, builds.get(identifier(row), {}), verification, measurements, shared)
            for row in candidates]
    ranked = sorted((row for row in rows if row['ranked']), key=lambda row: row['successful_rps'], reverse=True)
    for rank, row in enumerate(ranked, 1):
        row['rank'] = rank
    counts = dict(snapshot_prs=len(snapshot), submission_prs=len({row['pr'] for row in candidates}),
                  candidates=len(rows), excluded_prs=len(excluded), ranked=len(ranked),
                  diagnostic=sum(row.get('successful_rps') is not None and not row['ranked'] for row in rows),
                  unmeasured=sum(row.get('successful_rps') is None for row in rows),
                  states=dict(collections.Counter(row['status'] for row in rows)))
    summary = dict(date=DATE, batch='current-2026-10-20', complete=not any(row['status'] in PENDING for row in rows),
                   counts=counts, ranking='Successful HTTP responses/s, clean verified three-trial measurements only; no composite score.',
                   shared_hashes=shared, rows=rows, excluded=excluded)
    save(ROOT / 'build-status.json', builds)
    save(ROOT / 'summary.json', summary)
    fields = ['rank', 'case_id', 'pr', 'folder', 'commit', 'source_url', 'status', 'reason',
              'eligible', 'ranked', 'nginx', 'trials_recorded', 'successful_rps', 'rps_min', 'rps_max',
              'p50_ms', 'p95_ms', 'p99_ms', 'rss_mib', 'cpu_percent', 'app_loc', 'own_loc',
              'http_errors', 'socket_errors', 'database_valid', 'tests_passed', 'tests_failed',
              'semantic_passed_all', 'build_exit_code', 'image_id']
    with (ROOT / 'comparison.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction='ignore')
        writer.writeheader()
        for row in sorted(rows, key=lambda row: (row['rank'] or 10**6, row['pr'], row['case_id'])):
            writer.writerow({key: json.dumps(value, sort_keys=True) if isinstance(value, (dict, list)) else value
                             for key, value in row.items()})
    fields = ['case_id', 'pr', 'trial', 'commit', 'image_id', 'recorded_at', 'rps', 'successful_rps',
              'duration_s', 'p50_ms', 'p95_ms', 'p99_ms', 'rss_mib', 'cpu_percent',
              'http_errors', *SOCKET_KEYS, 'database_valid', 'valid_duration', 'error']
    with (ROOT / 'trials.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction='ignore')
        writer.writeheader()
        for run in measurements:
            writer.writerow(dict(run, **run.get('socket_errors', {})))
    (ROOT / 'report.md').write_text(report(summary))
    (ROOT / 'comparison.html').write_text(interactive(summary))
    print(json.dumps(counts, indent=2))
    if args.strict and not summary['complete']:
        raise SystemExit('Unfinished current candidates remain; see report.md')


if __name__ == '__main__':
    main()
