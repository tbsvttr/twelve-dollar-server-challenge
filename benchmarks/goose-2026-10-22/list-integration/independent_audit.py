"""File-only independent audit of PR143's additive main-list integration."""
import argparse
import collections
import csv
import hashlib
import json
import math
from pathlib import Path
import re
import statistics

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
BATCH = ROOT.parent / 'ranking-3x15-2026-10-22'
OLD = REPO / 'results/fixes-2026-10-22'
BASE = REPO / 'results/current-2026-10-20'
CONFIG = dict(threads=2, connections=64, warmup_seconds=2, measurement_seconds=15, trials=3)
METRICS = ('rps', 'successful_rps', 'p50_ms', 'p95_ms', 'p99_ms', 'rss_mib', 'cpu_percent')
SOCKETS = ('connect', 'read', 'write', 'timeout')
CHECKS = []


def read(path):
    return json.loads(path.read_text())


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1048576), b''):
            h.update(chunk)
    return h.hexdigest()


def key(row):
    return str(row.get('case_id', row.get('id', row['pr'])))


def check(name, ok, detail=None):
    CHECKS.append(dict(check=name, passed=bool(ok), **({'detail': detail} if detail is not None else {})))


def close(a, b):
    return (type(a) in (int, float) and type(b) in (int, float)
            and math.isfinite(a) and math.isfinite(b) and math.isclose(a, b, rel_tol=1e-10, abs_tol=1e-9))


def parse(output):
    count, duration = re.search(r'(\d+) requests in ([0-9.]+)s,', output).groups()
    values = dict(requests=int(count), duration_s=float(duration),
                  rps=float(re.search(r'Requests/sec:\s+([0-9.]+)', output)[1]))
    for percentile in (50, 95, 99):
        number, unit = re.search(r'\s' + str(percentile) + r'(?:\.0+)?%\s+([0-9.]+)(us|ms|s)', output).groups()
        values[f'p{percentile}_ms'] = float(number) * {'us': .001, 'ms': 1, 's': 1000}[unit]
    match = re.search(r'Non-2xx or 3xx responses:\s*(\d+)', output)
    values['http_errors'] = int(match[1]) if match else 0
    match = re.search(r'Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)', output)
    values['socket_errors'] = dict(zip(SOCKETS, map(int, match.groups()) if match else (0, 0, 0, 0)))
    values['successful_rps'] = values['rps'] - values['http_errors'] / values['duration_s']
    return values


def database(row):
    values = [v['database_after'] for v in row.get('final', []) if 'database_after' in v]
    return (len(values) == 1 and values[0].get('integrity') == 'ok'
            and values[0].get('initial_post_count') == 500000
            and type(values[0].get('post_count')) is int and values[0]['post_count'] > 500000)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--final', action='store_true')
    args = parser.parse_args()
    manifest = {key(r): r for r in read(BATCH / 'manifest.json')}
    builds = read(BATCH / 'build-status.json')
    shared = read(BATCH / 'shared-sha256.json')
    verification = read(BATCH / 'verification.json')
    measurements = read(BATCH / 'measurements.json')
    old = read(OLD / 'summary.json')
    summary = read(ROOT / 'summary.json')
    check('original 119-row summary retained at independently observed hash', sha(OLD / 'summary.json')
          == '44746123e12340a6abb2674838b59d9c14cb760a763120d4ba0d6bbe141b4933')
    check('exact two cases and six unique measured attempts, no selection',
          set(manifest) == {'143', '82'} and collections.Counter((key(r), r.get('trial')) for r in measurements)
          == collections.Counter((k, n) for k in ('143', '82') for n in (1, 2, 3)))
    check('original stock-wrk controller, service helper and shared fixture identity',
          all(sha(BATCH / n) == sha(BASE / n) for n in ('run.py', 'serve.py', 'shared-sha256.json')))
    check('actual shared files match frozen inventory', all(sha(BATCH / n) == value for n, value in shared.items()))
    declaration = read(BATCH / 'protocol-declaration.json')
    check('declared stock driver and fixed three-trial protocol',
          declaration.get('no_selection_or_replacements') is True and declaration.get('rounds') == 3
          and declaration.get('measurement_seconds') == 15 and declaration.get('warmup_seconds') == 2
          and declaration.get('expected_load_image_id') == 'sha256:901ab577025cfdcf7abc716fb4158774615b881383529bb77163b5f07f963898')
    for mode in ('verify', 'bench'):
        env = read(BATCH / f'environment-{mode}.json')
        check(mode + ': driver and configured server/load limits',
              env.get('load_image_id') == declaration['expected_load_image_id'] and env.get('wrk') == CONFIG
              and env.get('server_cpus') == '0' and env.get('server_cpu_quota') == 1
              and env.get('server_memory') == env.get('server_memory_swap') == '2g'
              and env.get('load_cpus') == '1,2' and env.get('load_cpu_quota') == 2
              and env.get('shared_hashes') == shared)
    for case, candidate in manifest.items():
        folder = BATCH / candidate.get('source_dir', 'sources/pr' + case)
        inventory = read(BATCH / candidate['source_hashes'])
        actual = {str(p.relative_to(folder)): sha(p) for p in folder.rglob('*') if p.is_file()}
        check(case + ': exact source snapshot and aggregate identity', actual == inventory
              and len(actual) == candidate['source_file_count']
              and hashlib.sha256(json.dumps(inventory, sort_keys=True).encode()).hexdigest() == candidate['source_sha256'])
        build = builds[case]
        check(case + ': build commit/image pinned', build.get('exit_code') == 0
              and build.get('commit') == candidate['commit'] and build.get('image_id', '').startswith('sha256:'))
    for record in verification + measurements:
        case = key(record)
        candidate, build = manifest[case], builds[case]
        name = f"{record['mode']} {case}/{record['trial']}"
        identity = dict(case_id=case, pr=candidate['pr'], commit=candidate['commit'], image=build['image'],
                        source_sha256=candidate['source_sha256'], shared_hashes=shared, image_id=build['image_id'])
        check(name + ': exact recorded identity and fingerprint', all(record.get(k) == v for k, v in identity.items())
              and record.get('fingerprint') == hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest())
        service = record.get('service', {})
        check(name + ': runtime source verified', service.get('ready') is True
              and service.get('source_sha256') == candidate['source_sha256']
              and service.get('source_files_verified') == candidate['source_file_count']
              and service.get('initial_post_count') == 500000 and service.get('nginx') is False)
        host = record.get('container_host_config', {})
        check(name + ': actual resource limits, no OOM, committed writes/integrity',
              host.get('CpusetCpus') == '0' and host.get('NanoCpus') == 1000000000
              and host.get('Memory') == host.get('MemorySwap') == 2147483648
              and record.get('container_state', {}).get('OOMKilled') is False
              and record.get('database_valid') is True and database(record))
        check(name + ': actual fd and seccomp limits',
              any(v.get('Name') == 'nofile' and v.get('Hard') == v.get('Soft') == 65535 for v in host.get('Ulimits', []))
              and [json.loads(v.split('=', 1)[1]) for v in host.get('SecurityOpt', []) if v.startswith('seccomp={')]
              == [read(BATCH / 'seccomp-io-uring.json')])
        check(name + ': fixed configuration', record.get('configuration') == CONFIG)
        if record['mode'] == 'verify':
            semantic = record.get('semantic', {})
            check(name + ': official 42 and dynamic semantic pass', record.get('passed') == 42 and record.get('failed') == 0
                  and record.get('official_passed_all') is True and record.get('passed_all') is True
                  and record.get('exit_code') == 0 and semantic.get('passed_all') is True
                  and semantic.get('exit_code') == 0 and all(c.get('passed') is True for c in semantic.get('checks', [])))
            continue
        raw = parse(record['output'])
        check(name + ': raw measured metrics independently reproduced', all(
            record.get(k) == value if isinstance(value, (dict, int)) else close(record.get(k), value)
            for k, value in raw.items()))
        check(name + ': complete trial without error-counter or throughput exclusion', not record.get('error')
              and record.get('completed') is True and record.get('valid_duration') is True
              and 14.5 <= raw['duration_s'] <= 17)
        cpu = 100 * (record['after']['cpu_s'] - record['before']['cpu_s']) / (record['after']['monotonic'] - record['before']['monotonic'])
        check(name + ': RSS and CPU independently reproduced', close(record['rss_mib'], record['after']['rss_kib'] / 1024)
              and close(record['cpu_percent'], cpu))
        log = BATCH / f'logs/bench-{case}-{record["trial"]}.log'
        check(name + ': retained log contains exact measured output', record['output'] in log.read_text())
    oldrows = {key(r): r for r in old['rows']}
    rows = summary['rows']
    mapped = {key(r): r for r in rows}
    check('all 119 old outcomes retained and PR143 added exactly once', len(rows) == 120
          and set(mapped) == set(oldrows) | {'143'} and len(mapped) == len(rows))
    check('all old row fields and metrics exactly unchanged except rank', all(
        {k: v for k, v in mapped[c].items() if k != 'rank'} == {k: v for k, v in row.items() if k != 'rank'}
        for c, row in oldrows.items()))
    check('historical followups, before/after and control evidence unchanged', all(
        summary.get(k) == old.get(k) for k in ('followup_rows', 'before_after', 'control_comparisons', 'excluded')))
    controls = summary.get('additional_controls', [])
    check('new Rust rerun only a separate unranked control', len(controls) == 1 and key(controls[0]) == '82'
          and controls[0].get('rank') is None and controls[0].get('ranked') is False
          and mapped['82']['successful_rps'] == oldrows['82']['successful_rps'])
    for row in [mapped['143']] + controls:
        case = key(row)
        runs = [r for r in measurements if key(r) == case]
        check(case + ': aggregate medians independently reproduced', len(runs) == 3 and all(
            close(row.get(metric), statistics.median(r[metric] for r in runs)) for metric in METRICS))
        check(case + ': exact PR commit/source identity in summary', row.get('commit') == manifest[case]['commit']
              and row.get('source_sha256') == manifest[case]['source_sha256'])
        errors = {s: sum(r['socket_errors'][s] for r in runs) for s in SOCKETS}
        http_errors = sum(r['http_errors'] for r in runs)
        check(case + ': all error counters retained in aggregate', row.get('socket_errors') == errors
              and row.get('http_errors') == http_errors)
        clean = not http_errors and not any(errors.values())
        check(case + ': clean-ranking eligibility follows every measured error counter',
              row.get('ranked') is (clean and case == '143')
              and (row.get('rank') is None if not clean or case == '82' else type(row.get('rank')) is int)
              and row.get('status') == ('measured' if clean else 'measured_with_errors'))
    ranked = sorted((r for r in rows if r.get('ranked')), key=lambda r: r['rank'])
    check('clean ranks contiguous and sorted by successful throughput', [r['rank'] for r in ranked] == list(range(1, len(ranked) + 1))
          and [r['successful_rps'] for r in ranked] == sorted((r['successful_rps'] for r in ranked), reverse=True)
          and all(r.get('http_errors') == 0 and not any(r.get('socket_errors', {}).values()) for r in ranked))
    check('coverage counts reproduce 120 outcomes with 98 clean, eight diagnostic and 14 unmeasured',
          {k: summary['counts'].get(k) for k in ('candidates', 'ranked', 'diagnostic', 'unmeasured')}
          == dict(candidates=120, ranked=98, diagnostic=8, unmeasured=14))
    with (ROOT / 'comparison.csv').open() as stream:
        csvrows = list(csv.DictReader(stream))
    check('CSV covers all 120 main rows exactly', collections.Counter(r['case_id'] for r in csvrows) == collections.Counter(mapped.keys()))
    check('CSV metric/status/rank values equal summary', all(
        all(r.get(k, '') == ('' if mapped[r['case_id']].get(k) is None else str(mapped[r['case_id']][k]))
            for k in ('status', 'rank', 'successful_rps', 'p99_ms', 'rss_mib')) for r in csvrows))
    html = (ROOT / 'comparison.html').read_text()
    marker = 'const rows='
    position = html.find(marker)
    values, _ = json.JSONDecoder().raw_decode(html[position + len(marker):])
    signature = lambda r: tuple(r.get(k) for k in ('case_id', 'measurement_date', 'role', 'rank', 'ranked', 'status', 'successful_rps'))
    expected = rows + [r for r in summary.get('followup_rows', []) if r.get('role') == 'control'] + controls
    check('HTML main rows and separate controls match summary exactly', position >= 0
          and collections.Counter(map(signature, values)) == collections.Counter(map(signature, expected)))
    report = (ROOT / 'report.md').read_text()
    printed = re.findall(r'^\| (\d+) \| \[#\d+\]\([^)]*\) `([^`]+)`', report, re.M)
    check('Markdown main ranking exactly matches audited ranks', [(int(rank), case) for rank, case in printed]
          == [(r['rank'], key(r)) for r in ranked])
    def section(text, start, end):
        return text.split(start, 1)[1].split(end, 1)[0]
    sections = [
        ('**Combined clean ranking.**', '**Combined diagnostic / reference outcomes.**', lambda r: r.get('ranked')),
        ('**Combined diagnostic / reference outcomes.**', '**Combined build, runtime or test failures',
         lambda r: r.get('successful_rps') is not None and not r.get('ranked')),
        ('**Combined build, runtime or test failures', '**Excluded / superseded submissions.**',
         lambda r: r.get('successful_rps') is None)]
    for start, end, predicate in sections:
        text = section(report, start, end)
        found = re.findall(r'\[#\d+\]\([^)]*\) `([^`]+)`', text)
        check('Markdown section coverage: ' + start, collections.Counter(found)
              == collections.Counter(key(r) for r in rows if predicate(r)))
    original_comment = read(Path('/private/tmp/goose-list-current-20261022.json'))['body']
    comment = (ROOT / 'issue-comment.md').read_text()
    normalize = lambda s: re.sub(r'/blob/[0-9a-f]{40}/benchmarks/2026-10-22/', '/blob/ARTIFACT/benchmarks/2026-10-22/', s)
    preserved = []
    for case, row in oldrows.items():
        label = f"#{row['pr']} [{row['folder']}]({row['source_url']})"
        before = [line for line in original_comment.splitlines() if line.startswith('| ') and '| ' + label + ' |' in line]
        after = [line for line in comment.splitlines() if line.startswith('| ') and '| ' + label + ' |' in line]
        scrub = lambda line: re.sub(r'^\| \d+ \|', '| RANK |', normalize(line)) if row.get('ranked') else normalize(line)
        preserved.append(len(before) == len(after) == 1 and scrub(before[0]) == scrub(after[0]))
    check('public comment retains every old main-table row verbatim except ranks/evidence commit links', all(preserved))
    addendum = '**New Goose submission — separate October 22 local confirmation batch.**'
    old_scope = 'The existing 119-outcome October 20/22 comparison and its historical rows remain unchanged.'
    new_scope = ('The original 119 outcome measurements and historical rows remain preserved. '
                 'The main list above now includes PR #143 as outcome 120 from the matching three-by-15-second stock-driver batch. '
                 'The 45-second figures below remain a separate protocol and are not pooled into that ranking.')
    old_addendum = original_comment[original_comment.index(addendum):]
    check('public comment retains long-holdout addendum exactly except the one explicit scope clarification',
          old_addendum.count(old_scope) == 1 and comment.endswith(old_addendum.replace(old_scope, new_scope, 1)),
          dict(previous_scope=old_scope, current_scope=new_scope))
    evidence = [ROOT / n for n in ('summary.json', 'comparison.csv', 'comparison.html', 'report.md', 'issue-comment.md', 'integrate.py')]
    evidence += [BATCH / n for n in ('measurements.json', 'manifest.json', 'verification.json', 'build-status.json', 'protocol-declaration.json')]
    evidence += [OLD / 'summary.json', Path(__file__)]
    output = dict(complete=len(measurements) == 6, audit_passed=all(c['passed'] for c in CHECKS),
                  checks_passed=sum(c['passed'] for c in CHECKS), checks_total=len(CHECKS),
                  checks=CHECKS, evidence_sha256={str(p.relative_to(REPO)): sha(p) for p in evidence if p.is_file()},
                  measured_attempts=len(measurements), old_rows=len(oldrows), new_main_rows=len(rows),
                  all_measured_http_errors=sum(r['http_errors'] for r in measurements),
                  all_measured_socket_errors={s: sum(r['socket_errors'][s] for r in measurements) for s in SOCKETS},
                  limitations=['Historical rows retain their original measurement dates; adding a new batch does not make the entire ranking a contemporaneous rerun.',
                               'Per-trial load-container inspection is not retained; load limits/image are proven by the unchanged controller and environment record.',
                               'This short stock-wrk ranking batch does not establish the unmet stable-five-percent target from the longer monotonic-clock holdouts.'])
    (ROOT / 'independent-audit.json').write_text(json.dumps(output, indent=2) + '\n')
    print(json.dumps({k: v for k, v in output.items() if k not in {'checks', 'evidence_sha256'}}, indent=2))
    for c in CHECKS:
        if not c['passed']:
            print('FAIL:', c['check'], c.get('detail', ''))
    return 0 if output['audit_passed'] and (output['complete'] or not args.final) else 1


if __name__ == '__main__':
    raise SystemExit(main())
