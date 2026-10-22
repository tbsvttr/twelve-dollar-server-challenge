"""Combine a targeted fixed-submission rerun with the frozen October 20 results.

Only this batch's manifest is rerun. Historical rows remain explicitly dated,
and an unchanged control never replaces its historical ranking measurement.
"""
import argparse
import collections
import copy
import csv
import hashlib
import html
import importlib.util
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BASELINE = ROOT.parent / 'current-2026-10-20'
if not BASELINE.is_dir():
    BASELINE = ROOT.parent / '2026-10-20'
BASELINE_LINK = '../2026-10-20'
DATE = '2026-10-22'
BATCH = ROOT.name
TARGETS = {'32', '92', '103', '123-arsd-hybridcgi', '123-arsd-threadedcgi',
           '123-vibed', '127', '132'}
SUPERSEDES = {'132': '120'}
BLOCKING = {'not_built', 'building', 'delegated', 'not_verified', 'not_measured',
            'incomplete_measurements', 'stale_build', 'invalid_measurements',
            'invalid_evidence'}


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The old analyzer imports ROOT from "run". Bind it to this batch deliberately:
# importing the baseline run.py would silently inspect the wrong evidence.
controller = load_module('followup_controller', ROOT / 'run.py')
previous_run = sys.modules.get('run')
sys.modules['run'] = controller
try:
    baseline_analyzer = load_module('baseline_analyzer', BASELINE / 'analyze.py')
finally:
    if previous_run is None:
        sys.modules.pop('run', None)
    else:
        sys.modules['run'] = previous_run
assert baseline_analyzer.ROOT == ROOT
read, save = controller.read, controller.save
identifier = baseline_analyzer.identifier
number, cell = baseline_analyzer.number, baseline_analyzer.cell
SOCKET_KEYS = baseline_analyzer.SOCKET_KEYS


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def matching_source(records, candidate):
    """Do not let matching commit/image metadata hide a different source tree."""
    matching = []
    for record in records:
        if record.get('source_sha256') != candidate.get('source_sha256'):
            continue
        service = record.get('service') or {}
        if service and service.get('source_sha256') != candidate.get('source_sha256'):
            continue
        if record.get('passed_all') is True or record.get('completed') is True:
            if (service.get('source_sha256') != candidate.get('source_sha256')
                    or service.get('source_files_verified') != candidate.get('source_file_count')):
                continue
        matching.append(record)
    return matching


def evidence_paths(row, directory):
    case = row['case_id']
    paths = ['manifest.json', 'build-status.json', f'logs/build-pr{case}.log']
    if row.get('tests_passed') is not None or row['status'] == 'runtime_failed':
        paths += ['verification.json', f'logs/verify-{case}-1.log',
                  f'server-logs/verify-{case}-1.log']
    if row.get('trials_recorded'):
        paths += ['measurements.json']
        for trial in (1, 2, 3):
            paths += [f'logs/bench-{case}-{trial}.log', f'server-logs/bench-{case}-{trial}.log']
    paths += [path.name for path in sorted(directory.glob('diagnostics*.json'))
              if re.search(r'(?:^|-)(?:pr)?' + re.escape(case) + r'(?:[-.]|$)', path.name)]
    prefix = '' if directory == ROOT else BASELINE_LINK + '/'
    return [prefix + name for name in dict.fromkeys(paths) if (directory / name).is_file()]


def annotate(row, directory, role='submission'):
    row = copy.deepcopy(row)
    row['batch'] = directory.name
    row['measurement_date'] = DATE if directory == ROOT else '2026-10-20'
    row['role'] = role
    row['evidence'] = evidence_paths(row, directory)
    prefix = '' if directory == ROOT else BASELINE_LINK + '/'
    for field in ('build_log', 'verification_log', 'runtime_setup', 'build_adapter'):
        if row.get(field):
            row[field] = prefix + row[field]
    return row


def followup_rows(candidates, builds, verification, measurements, shared):
    rows = []
    for candidate in candidates:
        case = identifier(candidate)
        build = builds.get(case, {})
        row = annotate(baseline_analyzer.summarize(
            candidate, build, matching_source(verification, candidate),
            matching_source(measurements, candidate), shared), ROOT,
            'control' if candidate.get('role') == 'control' else 'submission')
        diagnostic = read(ROOT / f'diagnostics-pr{case}.json', {})
        if (diagnostic.get('commit') == row.get('commit')
                and diagnostic.get('image_id') == row.get('image_id')
                and diagnostic.get('explanation')):
            row['diagnostic_explanation'] = diagnostic['explanation']
        rows.append(row)
    return rows


def combine(baseline, followup, shared):
    old = {identifier(row): row for row in baseline['rows']}
    targets = [row for row in followup if row['role'] != 'control']
    controls = [row for row in followup if row['role'] == 'control']
    if {identifier(row) for row in targets} != TARGETS:
        raise ValueError('Target manifest differs from the requested eight implementations.')
    removed = TARGETS | set(SUPERSEDES.values())
    retained = [annotate(row, BASELINE) for row in baseline['rows']
                if identifier(row) not in removed]
    rows = retained + targets
    if len(rows) != len(baseline['rows']) or len({identifier(row) for row in rows}) != len(rows):
        raise ValueError('Combined coverage must retain all unaffected cases and replace #120 with #132 exactly once.')
    for control in controls:
        before = old.get(identifier(control))
        if not before or any(control.get(key) != before.get(key)
                             for key in ('commit', 'source_sha256')):
            raise ValueError(f'Control {identifier(control)} must retain the exact baseline source and revision.')
    for row in rows:
        row['rank'] = None
    ranked = sorted((row for row in rows if row['ranked']), key=lambda row: row['successful_rps'], reverse=True)
    for rank, row in enumerate(ranked, 1):
        row['rank'] = rank
    # Controls are summarized under the identical validation rules, but never
    # acquire a combined rank or replace the original case in the table.
    for control in controls:
        control['rank'] = None
        control['ranked'] = False
    before_after = []
    for row in targets:
        old_case = SUPERSEDES.get(identifier(row), identifier(row))
        before_after.append({'case_id': row['case_id'], 'baseline_case_id': old_case,
                             'before': annotate(old[old_case], BASELINE), 'after': row})
    control_comparisons = [{'case_id': row['case_id'],
                            'before': annotate(old[row['case_id']], BASELINE), 'after': row}
                           for row in controls]
    excluded = copy.deepcopy(baseline['excluded'])
    for new_case, old_case in SUPERSEDES.items():
        superseded = old[old_case]
        excluded.append({'pr': superseded['pr'], 'case_id': old_case,
                         'title': superseded['title'], 'url': superseded['url'],
                         'status': 'superseded', 'superseded_by': new_case,
                         'reason': f'Closed submission replaced by PR #{new_case}; original evidence retained in {BASELINE_LINK}/.',
                         'previous_outcome': annotate(superseded, BASELINE)})
    counts = {'candidates': len(rows), 'submission_prs': len({row['pr'] for row in rows}),
              'ranked': len(ranked), 'diagnostic': sum(row.get('successful_rps') is not None and not row['ranked'] for row in rows),
              'unmeasured': sum(row.get('successful_rps') is None for row in rows),
              'excluded_prs': len(excluded), 'targeted_implementations': len(targets),
              'targeted_prs': len({row['pr'] for row in targets}),
              'retained_implementations': len(retained), 'controls': len(controls),
              'states': dict(collections.Counter(row['status'] for row in rows)),
              'followup_states': dict(collections.Counter(row['status'] for row in targets))}
    return {'date': DATE, 'batch': BATCH, 'baseline_batch': BASELINE.name,
            'scope': 'Targeted rerun of fixed submissions; all unaffected results retain their October 20 batch. This is not an all-submission rerun.',
            'complete': not any(row['status'] in BLOCKING for row in followup),
            'counts': counts, 'ranking': baseline['ranking'], 'shared_hashes': shared,
            'baseline_shared_hashes_match': shared == baseline.get('shared_hashes'),
            'controller_sha256': sha256(ROOT / 'run.py'),
            'baseline_summary_sha256': sha256(BASELINE / 'summary.json'),
            'baseline_snapshot_prs': baseline['counts']['snapshot_prs'],
            'rows': rows, 'followup_rows': followup, 'before_after': before_after,
            'control_comparisons': control_comparisons, 'excluded': excluded}


def label(row):
    return f"[#{row['pr']}]({row['url']}) `{cell(row['case_id'])}`"


def errors(row):
    if row.get('http_errors') is None:
        return '—'
    return str(row['http_errors']) + '; ' + '/'.join(str(row.get('socket_errors', {}).get(key, '—')) for key in SOCKET_KEYS)


def tests(row):
    official = 'not run' if row.get('tests_passed') is None else f"{row['tests_passed']}/42"
    semantic = row.get('semantic_passed_all')
    return official + ('; dynamic pass' if semantic is True else '; dynamic fail' if semantic is False else '')


def evidence_links(row):
    return ', '.join(f'[{Path(path).name}]({path})' for path in row.get('evidence', [])) or '—'


def comparison_table(comparisons):
    lines = ['| Case | Batch | Exact pinned commit | Status / checks | Successful req/s | Range | p99 ms | RSS MiB | HTTP; socket C/R/W/T |',
             '|---|---|---|---|---:|---:|---:|---:|---|']
    for comparison in comparisons:
        for phase in ('before', 'after'):
            row = comparison[phase]
            commit = f"[`{row['commit']}`]({row.get('source_url') or row['url']})"
            span = '—' if row.get('rps_min') is None else f"{number(row['rps_min'])}–{number(row['rps_max'])}"
            lines.append(f"| {label(row)} | {row['measurement_date']} {phase} | {commit} | {row['status']}; {tests(row)} | {number(row.get('successful_rps'))} | {span} | {number(row.get('p99_ms'), 3)} | {number(row.get('rss_mib'), 2)} | {errors(row)} |")
    return lines


def report(summary):
    counts = summary['counts']
    ranked = sorted((row for row in summary['rows'] if row['ranked']), key=lambda row: row['rank'])
    diagnostic = sorted((row for row in summary['rows'] if row.get('successful_rps') is not None and not row['ranked']), key=lambda row: row['successful_rps'], reverse=True)
    unmeasured = sorted((row for row in summary['rows'] if row.get('successful_rps') is None), key=lambda row: (row['pr'], row['case_id']))
    lines = [f'**Fixed-submission follow-up — {DATE}.**', '',
             'Targeted follow-up to [issue #7, comment 6298620934](https://github.com/arjaythedev/twelve-dollar-server-challenge/issues/7#issuecomment-6298620934). Current pinned heads of #32, #92, #103, the three #123 implementations, #127 and replacement #132 were retried. #120 is closed and superseded by #132. This is a targeted rerun, not a fresh test of every submission.', '',
             f"**Coverage:** {counts['targeted_implementations']} targeted implementations from {counts['targeted_prs']} PRs; {counts['retained_implementations']} unchanged October 20 results retained. Combined inventory: {counts['candidates']} implementations, {counts['ranked']} clean ranked, {counts['diagnostic']} diagnostic/reference, {counts['unmeasured']} without a valid three-trial result. Follow-up {'complete' if summary['complete'] else 'in progress'}. Target outcome counts: " + ', '.join(f'{key}={value}' for key, value in sorted(counts['followup_states'].items())) + '.', '',
             f'**Comparability.** Every table row names its measurement batch. The combined ordering mixes October 20 and October 22 runs under the same harness and limits; it does not establish simultaneous head-to-head performance. Run-to-run and host variation remain possible. Historical evidence is retained in the [October 20 report]({BASELINE_LINK}/report.md), [summary]({BASELINE_LINK}/summary.json) and [raw trials]({BASELINE_LINK}/trials.csv).', '',
             '**Common conditions.** Native Linux ARM64; server CPU 0, one CPU, 2 GiB RAM with no container swap, 65,535 file descriptors; load generator on CPUs 1–2. All correctness runs and measurements are sequential. `wrk -t2 -c64`, three 15-second trials after a two-second warm-up, fresh process and seeded SQLite database for every trial, deterministic shuffled order per round. The inherited 100 feed : 100 post : 15 like : 2 create workload and its compact-JSON ID recognition are unchanged. Docker-default seccomp permits only the same additional three io_uring system calls. Submitted application and start/build scripts are preserved; native toolchain setup and build substitutions are recorded in [build provenance](build-status.json) and [runtime helpers](runtime-scripts/).', '',
             '**Validation.** Ranking requires 42/42 official checks, dynamic create/read/feed/like round-trip, SQLite integrity and committed-write validation, and three complete, matching source/image/shared-fixture trials with zero HTTP and socket errors. The analyzer reuses the October 20 metric/duration checks and additionally requires matching source hashes. A current failure replaces the old result; it is never hidden by the old score.', '',
             f'**Metrics.** Successful requests/s, p99 and service RSS are medians of three runs; range is min–max successful requests/s. RSS is service-process RSS sampled after load before shutdown, including Nginx where applicable; it is not peak/container memory and shared pages can be counted twice. Error totals cover the three measured trials, excluding warm-up. wrk timeout counters include completed responses outside its two-second latency histogram; those completions remain in throughput but their latency samples are omitted from percentiles ([accounting evidence]({BASELINE_LINK}/diagnostics-wrk-timeouts.json)). Any HTTP/socket error excludes a row from clean ranking.', '',
             '**Targeted before / after.** A dash means no valid measurement, not zero throughput. Diagnostic measurements remain visible with their error counts. Full exact commits link to pinned source; #132 is compared with the superseded #120.', '']
    lines += comparison_table(summary['before_after'])
    lines += ['', '**Follow-up reasons and evidence.**', '', '| Case | Result | Reason / retained evidence |', '|---|---|---|']
    for row in summary['followup_rows']:
        lines.append(f"| {label(row)}{' (control)' if row['role'] == 'control' else ''} | {row['status']} | {cell(row.get('diagnostic_explanation') or row['reason'])} {evidence_links(row)} |")
    if summary['control_comparisons']:
        lines += ['', '**Unchanged control.** The exact October 20 source/revision was rerun to expose batch variation. It is reported separately; the combined ranking retains its original October 20 result. A control is context, not a normalization factor or proof that all submissions drift equally.', '']
        lines += comparison_table(summary['control_comparisons'])
        for comparison in summary['control_comparisons']:
            before, after = comparison['before'], comparison['after']
            if before.get('successful_rps') and after.get('successful_rps') is not None:
                change = (after['successful_rps'] / before['successful_rps'] - 1) * 100
                lines += ['', f"Control {label(after)} median change: **{change:+.1f}%**; no combined score was rescaled."]
    diagnostics = sorted(ROOT.glob('diagnostics*.json'))
    if diagnostics:
        lines += ['', '**Additional diagnostic evidence.** ' + ', '.join(f'[{path.name}]({path.name})' for path in diagnostics) + '. These files document observations; source-based explanations do not by themselves establish the cause of an error.']
    environment = sorted(ROOT.glob('environment*.json'))
    if (ROOT / 'host-context-public.json').is_file():
        environment.append(ROOT / 'host-context-public.json')
    if environment:
        lines += ['', '**Host context.** ' + ', '.join(f'[{path.name}]({path.name})' for path in environment) + '. Unrelated user containers were left running. Their captured premeasurement CPU activity was low; this snapshot does not establish sustained contention or isolation. The server container limits do not isolate the host from unrelated workloads. The control exposes observed batch variation; no historical or new score is normalized.']
    lines += ['', '**Combined clean ranking.** Every retained October 20 score keeps that batch label. LOC remains the physical source-line count at the pinned revision (application / own, including blanks/comments, excluding identified vendored/generated files and lockfiles); counts are heuristic, not a composite score.', '',
              '| Rank | Case / implementation | Batch | Successful req/s | Range | p95 ms | p99 ms | RSS MiB | CPU % | App / Own LOC |',
              '|---:|---|---|---:|---:|---:|---:|---:|---:|---:|']
    for row in ranked:
        implementation = f"[{cell(row['folder'])}]({row['source_url']})"
        lines.append(f"| {row['rank']} | {label(row)} {implementation} | {row['measurement_date']} | {number(row['successful_rps'])} | {number(row['rps_min'])}–{number(row['rps_max'])} | {number(row['p95_ms'], 3)} | {number(row['p99_ms'], 3)} | {number(row['rss_mib'], 2)} | {number(row['cpu_percent'], 1)} | {number(row['app_loc'])} / {number(row['own_loc'])} |")
    lines += ['', '**Combined diagnostic / reference outcomes.**', '',
              '| Case / implementation | Batch | Status | Successful req/s | Range | p99 ms | RSS MiB | HTTP; socket C/R/W/T |',
              '|---|---|---|---:|---:|---:|---:|---|']
    for row in diagnostic:
        lines.append(f"| {label(row)} {cell(row['folder'])} | {row['measurement_date']} | {row['status']} | {number(row['successful_rps'])} | {number(row['rps_min'])}–{number(row['rps_max'])} | {number(row['p99_ms'], 3)} | {number(row['rss_mib'], 2)} | {errors(row)} |")
    lines += ['', '**Combined build, runtime or test failures without a valid three-trial measurement.** A failure on native ARM64 is an outcome on this setup, not proof it cannot run on the official x86-64 host.', '',
              '| Case / implementation | Batch | Status | Checks | Reason / evidence |', '|---|---|---|---|---|']
    for row in unmeasured:
        lines.append(f"| {label(row)} {cell(row['folder'])} | {row['measurement_date']} | {row['status']} | {tests(row)} | {cell(row.get('diagnostic_explanation') or row['reason'])} {evidence_links(row)} |")
    lines += ['', '**Excluded / superseded submissions.** The original excluded inventory is retained; #120 is now superseded.', '',
              '| PR | Title | Reason |', '|---|---|---|']
    for row in summary['excluded']:
        lines.append(f"| [#{row['pr']}]({row['url']}) | {cell(row['title'])} | {cell(baseline_analyzer.reason(row))} |")
    lines += ['', '**Scope.** These local ARM64 throughput measurements do not establish official k6 maximum-user capacity. The [official challenge procedure](../../README.md#scoring) uses a five-minute k6 hold with latency/error thresholds on a different x86-64 server. No new full-inventory snapshot or all-submission rerun is claimed.', '',
              f'**Artifacts and reproduction.** [Combined CSV](comparison.csv), [summary JSON](summary.json), [filterable HTML](comparison.html), [target/control before-after CSV](before-after.csv), and [this batch’s raw trials](trials.csv). [Manifest](manifest.json), [source snapshot](source-snapshot-metadata.json), [verification](verification.json), [measurements](measurements.json), [shared hashes](shared-sha256.json), host/environment records, logs and source inventories retain provenance. `trials.csv` contains this batch only; retained October 20 trials remain in their [original file]({BASELINE_LINK}/trials.csv). The analyzer writes only this follow-up directory.', '',
              f'**Rebuilding prerequisites.** Docker tags in the provenance refer to local cached images; no prebuilt Docker images are distributed. Before invoking the controller, rebuild pinned images using the recorded native toolchains, build/setup helpers and source trees. The unchanged control source and inherited harness are also available in the [baseline batch]({BASELINE_LINK}/). Large seed database/token fixtures and downloaded source archives are omitted from the publication. Regenerate seed fixtures with the original repository scripts, then verify the recorded hashes before using them; a different fixture hash cannot reproduce the stored trials. The analyzer also needs matching local fixtures to validate current shared hashes. The commands below assume those prerequisites and built images are present.', '',
              'From this batch directory:', '', '```text', 'python3 run.py verify', 'python3 run.py bench', 'python3 analyze_followup.py --strict', '```', '']
    return '\n'.join(lines)


def interactive(summary):
    columns = [('rank', 'Rank'), ('case_id', 'Case'), ('folder', 'Implementation'),
               ('measurement_date', 'Batch date'), ('role', 'Role'), ('status', 'Status'),
               ('successful_rps', 'Successful req/s'), ('rps_min', 'Min req/s'), ('rps_max', 'Max req/s'),
               ('p99_ms', 'p99 ms'), ('rss_mib', 'RSS MiB'), ('http_errors', 'HTTP errors'),
               ('socket_errors_display', 'Socket C/R/W/T'), ('tests_passed', 'Checks / 42'),
               ('commit', 'Exact commit'), ('reason', 'Reason')]
    values = []
    for row in summary['rows'] + [row for row in summary['followup_rows'] if row['role'] == 'control']:
        value = dict(row)
        value['reason'] = value.get('diagnostic_explanation') or value['reason']
        value['socket_errors_display'] = '/'.join(str(value.get('socket_errors', {}).get(key, '—')) for key in SOCKET_KEYS) if value.get('socket_errors') is not None else None
        values.append(value)
    data = json.dumps(values, ensure_ascii=False).replace('<', '\\u003c')
    return '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Fixed-submission follow-up — 2026-10-22</title><style>
body{font:15px system-ui,sans-serif;margin:2rem;color:#172b36;background:#f7fafc}h1{font-size:1.5rem}p{max-width:100ch;line-height:1.5}input,select{font:inherit;padding:.5rem;border:1px solid #a9bcc7;border-radius:5px;margin:0 .8rem 1rem 0}table{border-collapse:collapse;background:white;width:100%}th,td{text-align:left;padding:.6rem;border-bottom:1px solid #dbe4ea;vertical-align:top}th{cursor:pointer;white-space:nowrap;background:#e8f1f5;position:sticky;top:0}td{font-variant-numeric:tabular-nums}td:last-child{min-width:20rem;max-width:40rem;font-size:.85rem}a{color:#075c8b}.wrap{overflow:auto}#count{font-weight:600}.control{background:#fff5db}
</style><h1>Fixed-submission follow-up — 2026-10-22</h1>
<p>Targeted rerun of #32, #92, #103, three #123 implementations, #127 and replacement #132. Every unaffected row retains its October 20 measurement. This combined ranking mixes dated batches; it is not an all-submission rerun. Controls are highlighted and excluded from the combined rank. <a href="report.md">Full report, before/after and evidence</a> · <a href="comparison.csv">CSV</a> · <a href="summary.json">JSON</a></p>
<p>Native ARM64, 1 server CPU / 2 GiB; 3 × 15 seconds, wrk 2 threads / 64 connections. Medians shown; RSS is end-of-load service RSS. These are local throughput figures, not official k6 maximum-user capacity. Clean ranking requires all correctness/database checks and zero HTTP/socket errors across all three trials. wrk timeout completions remain in throughput but outside the displayed latency histogram. Click a column to sort.</p>
<label>Search <input id="search" placeholder="language, PR, commit, reason"></label><label>Status <select id="status"><option value="">All statuses</option></select></label><label>Batch <select id="batch"><option value="">Both batches</option></select></label><label>Role <select id="role"><option value="">Submissions and controls</option></select></label><span id="count"></span><div class="wrap"><table><thead><tr>''' + ''.join(f'<th data-key="{key}">{html.escape(label)}</th>' for key, label in columns) + '''</tr></thead><tbody></tbody></table></div><script>
const rows=''' + data + ''',columns=''' + json.dumps(columns) + ''';
let sortKey='rank',direction=1;const search=document.querySelector('#search'),status=document.querySelector('#status'),batch=document.querySelector('#batch'),role=document.querySelector('#role'),body=document.querySelector('tbody');
for(const [select,key]of [[status,'status'],[batch,'measurement_date'],[role,'role']])for(const value of [...new Set(rows.map(r=>r[key]))].sort()){const option=document.createElement('option');option.value=value;option.textContent=value;select.append(option)}
function matchesSearch(row,query){const term=query.trim().toLowerCase();if(!term)return true;const numbered=/^#?([0-9]+)$/.exec(term);if(numbered)return Number(row.pr)===Number(numbered[1]);return [row.case_id,row.folder,row.title,row.status,row.commit,row.reason].some(value=>String(value==null?'':value).toLowerCase().includes(term))}
function draw(){const shown=rows.filter(r=>(!status.value||r.status===status.value)&&(!batch.value||r.measurement_date===batch.value)&&(!role.value||r.role===role.value)&&matchesSearch(r,search.value));shown.sort((a,b)=>{let x=a[sortKey],y=b[sortKey];if(x==null)return y==null?0:1;if(y==null)return -1;return(typeof x==='number'?x-y:String(x).localeCompare(String(y)))*direction});body.replaceChildren();for(const row of shown){const tr=document.createElement('tr');if(row.role==='control')tr.className='control';for(const [key]of columns){const td=document.createElement('td'),value=row[key];if(key==='case_id'||((key==='folder'||key==='commit')&&row.source_url)){const a=document.createElement('a');a.href=key==='case_id'?row.url:row.source_url;a.textContent=(key==='case_id'?'#':'')+(value||'—');td.append(a)}else td.textContent=value==null?'—':typeof value==='number'?value.toLocaleString(undefined,{maximumFractionDigits:key==='p99_ms'?3:2}):value;tr.append(td)}body.append(tr)}document.querySelector('#count').textContent=shown.length+' of '+rows.length+' rows (controls separate)'}
search.addEventListener('input',draw);for(const select of [status,batch,role])select.addEventListener('change',draw);document.querySelectorAll('th').forEach(th=>th.addEventListener('click',()=>{direction=sortKey===th.dataset.key?-direction:1;sortKey=th.dataset.key;draw()}));draw();
</script></html>'''


def write_csv(path, fields, rows):
    with path.open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction='ignore')
        writer.writeheader()
        for row in rows:
            writer.writerow({key: json.dumps(value, sort_keys=True) if isinstance(value, (dict, list)) else value
                             for key, value in row.items()})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--strict', action='store_true', help='Reject unfinished/invalid current evidence before writing final artifacts.')
    args = parser.parse_args()
    baseline = read(BASELINE / 'summary.json', {})
    if baseline.get('complete') is not True:
        raise ValueError('The retained baseline must be complete.')
    candidates = read(ROOT / 'manifest.json', [])
    if len({identifier(row) for row in candidates}) != len(candidates):
        raise ValueError('Duplicate follow-up case IDs.')
    builds = controller.build_records()
    verification = read(ROOT / 'verification.json', [])
    measurements = read(ROOT / 'measurements.json', [])
    expected_shared = read(ROOT / 'shared-sha256.json', {})
    shared = {name: sha256(ROOT / name) for name in expected_shared}
    if args.strict and not shared:
        raise SystemExit('No current shared-fixture evidence exists; run correctness checks first.')
    if shared and shared != baseline.get('shared_hashes'):
        raise ValueError('The shared fixture/harness hashes differ from the retained baseline; the common-condition combined report is not valid.')
    if sha256(ROOT / 'run.py') != sha256(BASELINE / 'run.py'):
        raise ValueError('The sequential controller differs from the retained baseline; review the methodology before combining batches.')
    summary = combine(baseline, followup_rows(candidates, builds, verification, measurements, shared), shared)
    if args.strict and not summary['complete']:
        pending = ', '.join(f"{row['case_id']}={row['status']}" for row in summary['followup_rows'] if row['status'] in BLOCKING)
        raise SystemExit('Unfinished/invalid follow-up evidence; final artifacts not written: ' + pending)
    save(ROOT / 'summary.json', summary)
    fields = ['rank', 'case_id', 'pr', 'folder', 'batch', 'measurement_date', 'role',
              'commit', 'source_url', 'source_sha256', 'status', 'reason', 'diagnostic_explanation', 'eligible',
              'ranked', 'nginx', 'trials_recorded', 'successful_rps', 'rps_min', 'rps_max',
              'p50_ms', 'p95_ms', 'p99_ms', 'rss_mib', 'cpu_percent', 'app_loc', 'own_loc',
              'http_errors', 'socket_errors', 'database_valid', 'tests_passed', 'tests_failed',
              'semantic_passed_all', 'build_exit_code', 'image_id', 'evidence']
    write_csv(ROOT / 'comparison.csv', fields, sorted(summary['rows'], key=lambda row: (row['rank'] or 10**6, row['pr'], row['case_id'])))
    comparisons = []
    for comparison in summary['before_after'] + summary['control_comparisons']:
        for phase in ('before', 'after'):
            row = dict(comparison[phase], phase=phase, target_case_id=comparison['case_id'])
            row['role'] = 'control' if comparison in summary['control_comparisons'] else 'submission'
            comparisons.append(row)
    write_csv(ROOT / 'before-after.csv', ['phase', 'target_case_id'] + fields, comparisons)
    trial_fields = ['batch', 'role', 'case_id', 'pr', 'trial', 'commit', 'source_sha256', 'image_id',
                    'recorded_at', 'rps', 'successful_rps', 'duration_s', 'p50_ms', 'p95_ms', 'p99_ms',
                    'rss_mib', 'cpu_percent', 'http_errors', *SOCKET_KEYS, 'database_valid',
                    'valid_duration', 'completed', 'error']
    roles = {identifier(row): row.get('role', 'submission') for row in candidates}
    write_csv(ROOT / 'trials.csv', trial_fields,
              [dict(run, batch=BATCH, role=roles.get(identifier(run), 'unknown'), **run.get('socket_errors', {})) for run in measurements])
    (ROOT / 'report.md').write_text(report(summary))
    (ROOT / 'comparison.html').write_text(interactive(summary))
    print(json.dumps(summary['counts'], indent=2))


if __name__ == '__main__':
    main()
