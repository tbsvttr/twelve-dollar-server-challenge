"""Read-only independent audit of the fixed-submission benchmark evidence.

Only audit-final.json is written. No containers, network calls or application
workloads are started. --strict requires final reports and all passing cases'
three valid trials; a documented build/runtime/test failure is a final outcome.
"""
import argparse
import collections
import csv
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import time

ROOT = Path(__file__).resolve().parent
BASELINE = ROOT.parent / 'current-2026-10-20'
TARGETS = {'32', '92', '103', '123-arsd-hybridcgi', '123-arsd-threadedcgi',
           '123-vibed', '127', '132'}
SOCKETS = ('connect', 'read', 'write', 'timeout')
METRICS = ('rps', 'successful_rps', 'p50_ms', 'p95_ms', 'p99_ms', 'rss_mib', 'cpu_percent')
CONFIG = dict(threads=2, connections=64, warmup_seconds=2, measurement_seconds=15, trials=3)
CHECKS, FAILURES, PENDING = [], [], []


def read(path, default=None):
    return json.loads(path.read_text()) if path.is_file() else default


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def check(name, condition, detail=None):
    item = dict(check=name, passed=bool(condition))
    if detail is not None:
        item['detail'] = detail
    CHECKS.append(item)
    if not condition:
        FAILURES.append(name)
    return bool(condition)


def pending(name):
    PENDING.append(name)


def case(row):
    return str(row.get('case_id', row.get('id', row['pr'])))


def close(a, b):
    return (isinstance(a, (int, float)) and not isinstance(a, bool)
            and isinstance(b, (int, float)) and not isinstance(b, bool)
            and math.isfinite(a) and math.isfinite(b)
            and math.isclose(a, b, rel_tol=1e-10, abs_tol=1e-9))


def database(record):
    values = [value['database_after'] for value in record.get('final', [])
              if isinstance(value, dict) and 'database_after' in value]
    if len(values) != 1:
        return False
    value = values[0]
    return (value.get('integrity') == 'ok' and value.get('initial_post_count') == 500000
            and type(value.get('post_count')) is int
            and value['post_count'] > value['initial_post_count'])


def parse_wrk(output):
    requests, duration = re.search(r'(\d+) requests in ([0-9.]+)s,', output).groups()
    parsed = dict(requests=int(requests), duration_s=float(duration),
                  rps=float(re.search(r'Requests/sec:\s+([0-9.]+)', output)[1]))
    for percentile in (50, 95, 99):
        value, unit = re.search(r'\s' + str(percentile) + r'(?:\.0+)?%\s+([0-9.]+)(us|ms|s)', output).groups()
        parsed[f'p{percentile}_ms'] = float(value) * {'us': .001, 'ms': 1, 's': 1000}[unit]
    errors = re.search(r'Non-2xx or 3xx responses:\s*(\d+)', output)
    parsed['http_errors'] = int(errors[1]) if errors else 0
    errors = re.search(r'Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)', output)
    parsed['socket_errors'] = dict(zip(SOCKETS, map(int, errors.groups()) if errors else (0, 0, 0, 0)))
    parsed['successful_rps'] = parsed['rps'] - parsed['http_errors'] / parsed['duration_s']
    return parsed


def audit_sources(manifest):
    archives = {}
    for row in manifest:
        key = case(row)
        folder = ROOT / 'sources' / ('pr' + key)
        hashes = read(ROOT / row['source_hashes'], {})
        inventory = read(ROOT / 'source-inventories' / ('pr' + key + '.json'), {}).get('files', {})
        actual = {str(path.relative_to(folder)): sha(path) for path in folder.rglob('*') if path.is_file()}
        check(key + ': exact source tree and checksum inventory', actual == hashes and bool(hashes))
        check(key + ': inventory file coverage', set(inventory) == set(hashes))
        check(key + ': aggregate source identity', row.get('source_sha256') ==
              hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
              and row.get('source_file_count') == len(hashes))
        valid = True
        for name, metadata in inventory.items():
            path = folder / name
            if not path.is_file():
                valid = False
                continue
            content = path.read_bytes()
            valid &= (metadata.get('sha256') == hashes.get(name)
                      and metadata.get('bytes') == len(content)
                      and metadata.get('physical_lines') == len(content.splitlines()))
        check(key + ': inventory physical lines, bytes and hashes', valid)
        app = sum(value['physical_lines'] for value in inventory.values() if value['classification'] == 'application')
        own = sum(value['physical_lines'] for value in inventory.values() if value['classification'] in {'application', 'own_support'})
        check(key + ': reported LOC matches inventory', row.get('app_loc') == app and row.get('own_loc') == own)
        archive = ROOT / row['archive']
        if archive not in archives:
            archives[archive] = sha(archive) if archive.is_file() else None
        check(key + ': pinned archive checksum', archives[archive] == row.get('archive_sha256'))


def audit_environment(shared):
    required = {'seed/feed.db', 'seed/tokens.json', 'mixed.lua', 'test/test.sh', 'semantic.py',
                'serve.py', 'bench/nginx.conf', 'seccomp-io-uring.json'}
    required |= {str(path.relative_to(ROOT)) for path in (ROOT / 'test/golden').glob('*.json')}
    check('shared fixture inventory is complete', set(shared) == required)
    check('shared fixture hashes match actual files', bool(shared) and all(
        (ROOT / name).is_file() and sha(ROOT / name) == value for name, value in shared.items()))
    check('shared fixture identity matches October 20', shared == read(BASELINE / 'shared-sha256.json', {}))
    check('controller is identical to October 20', sha(ROOT / 'run.py') == sha(BASELINE / 'run.py'))
    fixture = read(ROOT / 'fixture-identity.json', {})
    check('before/after fixture identity matches current files', set(fixture) == set(shared) and all(
        value.get('before') == value.get('after') == shared.get(name) for name, value in fixture.items()))
    verify, bench = [read(ROOT / ('environment-' + mode + '.json'), {}) for mode in ('verify', 'bench')]
    expected = dict(server_cpus='0', server_cpu_quota=1, server_memory='2g', server_memory_swap='2g',
                    load_cpus='1,2', load_cpu_quota=2, load_memory='2g', nofile=65535)
    for mode, environment in [('verify', verify), ('bench', bench)]:
        check(mode + ': configured CPU, RAM, swap and fd limits', all(environment.get(k) == v for k, v in expected.items()))
        check(mode + ': shared identity and wrk configuration', environment.get('shared_hashes') == shared and environment.get('wrk') == CONFIG)
        server = json.loads(environment.get('docker_version', '{}')).get('Server', {})
        check(mode + ': native Linux ARM64 engine', server.get('Os') == 'linux' and server.get('Arch') in {'arm64', 'aarch64'})
    baseline_environment = read(BASELINE / 'environment-bench.json', {})
    check('same pinned load image in verify, bench and baseline',
          bool(verify.get('load_image_id')) and all(verify.get(k) == bench.get(k) == baseline_environment.get(k)
                                                   for k in ('load_image', 'load_image_id')))


def audit_record(record, candidate, build, shared, profile):
    name = f"{record.get('mode')} {case(record)} trial {record.get('trial')}"
    identity = dict(case_id=case(candidate), pr=candidate['pr'], commit=candidate.get('commit'),
                    image=build.get('image'), source_sha256=candidate.get('source_sha256'), shared_hashes=shared,
                    image_id=build.get('image_id'))
    check(name + ': exact commit/image/source/shared identity', all(record.get(k) == v for k, v in identity.items()))
    check(name + ': identity fingerprint', record.get('fingerprint') ==
          hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest())
    check(name + ': exact configuration', record.get('configuration') == CONFIG)
    config = record.get('container_host_config', {})
    check(name + ': actual server CPU/RAM/swap limits',
          config.get('CpusetCpus') == '0' and config.get('NanoCpus') == 1000000000
          and config.get('Memory') == config.get('MemorySwap') == 2147483648)
    check(name + ': actual fd limit', any(value.get('Name') == 'nofile' and value.get('Hard') == value.get('Soft') == 65535
                                           for value in config.get('Ulimits', [])))
    options = config.get('SecurityOpt', [])
    actual_profiles = [json.loads(value.split('=', 1)[1]) for value in options if value.startswith('seccomp={')]
    check(name + ': exact seccomp profile', actual_profiles == [profile])
    check(name + ': no OOM kill', record.get('container_state', {}).get('OOMKilled') is False)
    if record.get('service', {}).get('ready'):
        service = record['service']
        check(name + ': runtime source hash check', service.get('source_sha256') == candidate.get('source_sha256')
              and service.get('source_files_verified') == candidate.get('source_file_count')
              and service.get('start_script') == '/suite/sources/pr' + case(candidate) + '/start.sh'
              and service.get('initial_post_count') == 500000 and service.get('nginx') == candidate.get('nginx'))


def audit_trials(manifest, builds, verification, measurements, shared):
    profile = read(ROOT / 'seccomp-io-uring.json', {})
    candidates = {case(row): row for row in manifest}
    check('every evidence record has a known case', all(case(row) in candidates for row in verification + measurements))
    for row in verification + measurements:
        if case(row) in candidates:
            audit_record(row, candidates[case(row)], builds.get(case(row), {}), shared, profile)
    results = {}
    for key, candidate in candidates.items():
        build = builds.get(key, {})
        check(key + ': build revision matches manifest', build.get('commit') == candidate.get('commit'))
        checks = [row for row in verification if case(row) == key]
        runs = [row for row in measurements if case(row) == key]
        result = dict(passed_correctness=False, runs=runs)
        results[key] = result
        if build.get('exit_code') != 0:
            check(key + ': unsuccessful build has no measurements', not runs)
            if build.get('status') in {'building', 'delegated'}:
                pending(key + ': build unfinished')
            continue
        check(key + ': built image identity is pinned ARM64', build.get('architecture') == 'linux/arm64'
              and isinstance(build.get('image_id'), str) and build['image_id'].startswith('sha256:'))
        if not checks:
            pending(key + ': missing correctness run')
            check(key + ': unverified case has no measurements', not runs)
            continue
        latest = checks[-1]
        passed = (not latest.get('error') and latest.get('exit_code') == 0
                  and latest.get('passed') == 42 and latest.get('failed') == 0
                  and latest.get('official_passed_all') is True
                  and latest.get('semantic', {}).get('passed_all') is True
                  and latest.get('semantic', {}).get('exit_code') == 0
                  and latest.get('semantic', {}).get('checks')
                  and all(item.get('passed') is True for item in latest['semantic']['checks'])
                  and latest.get('database_valid') is True and database(latest))
        check(key + ': correctness pass flag reflects official, dynamic and database checks', bool(passed) == bool(latest.get('passed_all')))
        result['passed_correctness'] = bool(passed)
        if not passed:
            check(key + ': failing correctness has no benchmark measurements', not runs)
            continue
        counts = collections.Counter(row.get('trial') for row in runs)
        check(key + ': trial identities unique and in range', all(trial in {1, 2, 3} and count == 1 for trial, count in counts.items()))
        if set(counts) != {1, 2, 3}:
            pending(key + ': needs all three trials (' + ','.join(map(str, sorted(counts))) + ')')
        for run in runs:
            name = key + ' trial ' + str(run.get('trial'))
            valid = (not run.get('error') and run.get('completed') is True and run.get('valid_duration') is True
                     and isinstance(run.get('duration_s'), (int, float)) and 14.5 <= run['duration_s'] <= 17)
            check(name + ': complete valid measured trial', valid)
            if not valid:
                continue
            check(name + ': valid nonnegative metrics', all(isinstance(run.get(metric), (int, float))
                  and not isinstance(run.get(metric), bool) and math.isfinite(run[metric]) and run[metric] >= 0 for metric in METRICS)
                  and run.get('rss_mib', 0) > 0)
            try:
                parsed = parse_wrk(run['output'])
                check(name + ': metrics and success formula independently match raw wrk output', all(
                    run.get(metric) == value if isinstance(value, (dict, int)) else close(run.get(metric), value)
                    for metric, value in parsed.items()))
                cpu = 100 * (run['after']['cpu_s'] - run['before']['cpu_s']) / (run['after']['monotonic'] - run['before']['monotonic'])
                check(name + ': RSS/CPU formulas match process snapshots', close(run['rss_mib'], run['after']['rss_kib'] / 1024)
                      and close(run['cpu_percent'], cpu))
            except (KeyError, TypeError, ValueError, AttributeError, ZeroDivisionError) as error:
                check(name + ': parseable raw measurement evidence', False, str(error))
            check(name + ': committed writes and SQLite integrity', run.get('database_valid') is True and database(run))
    return results


def audit_reports(manifest, results):
    summary = read(ROOT / 'summary.json', {})
    if not summary:
        pending('final summary has not been generated')
        return
    followups = summary.get('followup_rows', [])
    expected = {case(row): row for row in manifest}
    check('summary covers every target and control exactly once', collections.Counter(case(row) for row in followups) == collections.Counter(expected.keys()))
    for row in followups:
        key = case(row)
        result = results.get(key, {})
        runs = result.get('runs', [])
        clean = (result.get('passed_correctness') and len(runs) == 3
                 and all(run.get('completed') is True and not run.get('error') and run.get('database_valid') is True
                         and run.get('http_errors') == 0 and not any(run.get('socket_errors', {}).values()) for run in runs))
        if not clean:
            check(key + ': failed/errored/incomplete result has no clean rank', row.get('ranked') is False and row.get('rank') is None)
        else:
            check(key + ': complete clean result is measured with correct control treatment',
                  row.get('status') == 'measured' and row.get('ranked') is (row.get('role') != 'control'))
        if row.get('successful_rps') is not None:
            check(key + ': only complete trials receive aggregate metrics', result.get('passed_correctness') and len(runs) == 3)
            if len(runs) == 3 and all(all(metric in run for metric in METRICS) for run in runs):
                check(key + ': aggregate medians independently recomputed', all(close(row.get(metric), statistics.median(run[metric] for run in runs)) for metric in METRICS))
                check(key + ': aggregate range and errors independently recomputed', close(row.get('rps_min'), min(run['successful_rps'] for run in runs))
                      and close(row.get('rps_max'), max(run['successful_rps'] for run in runs))
                      and row.get('http_errors') == sum(run['http_errors'] for run in runs)
                      and row.get('socket_errors') == {name: sum(run['socket_errors'][name] for run in runs) for name in SOCKETS})
    rows = summary.get('rows', [])
    check('combined coverage remains 119 unique implementations', len(rows) == 119 and len({case(row) for row in rows}) == 119)
    check('replacement #132 appears once and superseded #120 is absent', sum(case(row) == '132' for row in rows) == 1 and all(case(row) != '120' for row in rows))
    baseline = read(BASELINE / 'summary.json', {})
    old = {case(row): row for row in baseline.get('rows', [])}
    retained = [row for row in rows if case(row) not in TARGETS]
    check('all unaffected baseline outcomes and metrics are retained exactly', all(
        case(row) in old and all(row.get(name) == value for name, value in old[case(row)].items()
                                if name not in {'rank', 'build_log', 'verification_log', 'runtime_setup', 'build_adapter'})
        and row.get('measurement_date') == '2026-10-20' for row in retained))
    check('control remains a separate rerun, retains original combined score',
          [case(row) for row in followups if row.get('role') == 'control'] == ['82']
          and all(row.get('rank') is None for row in followups if row.get('role') == 'control')
          and next((row.get('successful_rps') for row in rows if case(row) == '82'), None) == old.get('82', {}).get('successful_rps'))
    ranked = sorted([row for row in rows if row.get('ranked')], key=lambda row: row.get('rank') or 0)
    check('all combined ranks are clean, contiguous and sorted by successful throughput',
          [row.get('rank') for row in ranked] == list(range(1, len(ranked) + 1))
          and all(row.get('status') == 'measured' and row.get('tests_passed') == 42
                  and row.get('tests_failed') == 0 and row.get('semantic_passed_all') is True
                  and row.get('database_valid') is True and row.get('http_errors') == 0
                  and not any(row.get('socket_errors', {}).values()) for row in ranked)
          and [row.get('successful_rps') for row in ranked] == sorted([row.get('successful_rps') for row in ranked], reverse=True)
          and all(row.get('rank') is None for row in rows if not row.get('ranked')))
    check('summary final flag agrees with audit completeness', summary.get('complete') is True if not PENDING else summary.get('complete') is False)
    for name in ('comparison.csv', 'before-after.csv', 'trials.csv', 'report.md', 'comparison.html'):
        if not (ROOT / name).is_file():
            pending('missing final artifact: ' + name)
    if (ROOT / 'comparison.csv').is_file():
        with (ROOT / 'comparison.csv').open() as stream:
            values = list(csv.DictReader(stream))
        check('combined CSV covers the summary exactly', collections.Counter(row['case_id'] for row in values) == collections.Counter(case(row) for row in rows))
        mapped = {case(row): row for row in rows}
        check('combined CSV ranks, statuses and metrics match summary', all(
            value['status'] == mapped[value['case_id']]['status']
            and value['rank'] == str(mapped[value['case_id']].get('rank') or '')
            and all(value[metric] == ('' if mapped[value['case_id']].get(metric) is None else str(mapped[value['case_id']][metric]))
                    for metric in ('successful_rps', 'p99_ms', 'rss_mib')) for value in values if value['case_id'] in mapped))
    if (ROOT / 'report.md').is_file():
        report = (ROOT / 'report.md').read_text()
        start = report.find('**Combined clean ranking.**')
        end = report.find('**Combined diagnostic / reference outcomes.**', start)
        printed = re.findall(r'^\| (\d+) \| \[#\d+\]\([^)]*\) `([^`]+)`', report[start:end], re.M)
        check('Markdown clean ranking contains exactly audited clean ranks', start >= 0 and end > start
              and [(int(rank), key) for rank, key in printed] == [(row['rank'], case(row)) for row in ranked])
    if (ROOT / 'comparison.html').is_file():
        content = (ROOT / 'comparison.html').read_text()
        prefix = 'const rows='
        position = content.find(prefix)
        try:
            values, _ = json.JSONDecoder().raw_decode(content[position + len(prefix):])
            fields = ('case_id', 'measurement_date', 'role', 'rank', 'ranked', 'status', 'successful_rps')
            signature = lambda row: tuple(row.get(field) for field in fields)
            expected_values = rows + [row for row in followups if row.get('role') == 'control']
            check('interactive HTML ranks, outcomes and scores equal audited summary', position >= 0
                  and collections.Counter(map(signature, values)) == collections.Counter(map(signature, expected_values)))
        except (ValueError, TypeError, AttributeError) as error:
            check('interactive HTML contains parseable benchmark data', False, str(error))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--strict', '--final', action='store_true', help='Fail unless every passing case has all three trials and final reports exist.')
    args = parser.parse_args()
    manifest = read(ROOT / 'manifest.json', [])
    check('targeted scope and single control are exact', {case(row) for row in manifest} == TARGETS | {'82'}
          and len(manifest) == 9 and [case(row) for row in manifest if row.get('role') == 'control'] == ['82'])
    builds = {}
    for path in sorted(ROOT.glob('build-status-*-*.json')):
        if not re.fullmatch(r'build-status-\d+-\d+\.json', path.name):
            continue
        shard = read(path, {})
        check('disjoint build shard ' + path.name, not set(builds) & set(shard))
        builds.update(shard)
    check('merged build provenance equals disjoint authoritative shards', builds == read(ROOT / 'build-status.json', {}))
    check('build provenance covers exactly the manifest cases', set(builds) == {case(row) for row in manifest})
    shared = read(ROOT / 'shared-sha256.json', {})
    audit_sources(manifest)
    audit_environment(shared)
    verification = read(ROOT / 'verification.json', [])
    measurements = read(ROOT / 'measurements.json', [])
    results = audit_trials(manifest, builds, verification, measurements, shared)
    audit_reports(manifest, results)
    evidence_names = ['manifest.json', 'build-status.json', 'verification.json', 'measurements.json',
                      'shared-sha256.json', 'environment-verify.json', 'environment-bench.json', 'summary.json',
                      'comparison.csv', 'before-after.csv', 'trials.csv', 'report.md', 'comparison.html',
                      'run.py', 'serve.py', 'semantic.py', 'analyze_followup.py', 'audit_followup.py']
    output = dict(recorded_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), strict=args.strict,
                  complete=not PENDING, passed=not FAILURES and (not args.strict or not PENDING),
                  passed_all=not FAILURES and not PENDING,
                  checks_passed=sum(item['passed'] for item in CHECKS), checks_total=len(CHECKS),
                  failures=FAILURES, pending=PENDING,
                  coverage=dict(cases=len(manifest), passing_correctness=sum(row['passed_correctness'] for row in results.values()),
                                verification_records=len(verification), measured_records=len(measurements)),
                  evidence_sha256={name: sha(ROOT / name) for name in evidence_names if (ROOT / name).is_file()},
                  limitations=['Load-container settings and pinned load image are checked from the unchanged controller and phase environment records; per-trial load-container inspections were not retained.',
                               'Source LOC classification is heuristic; this audit verifies its physical-line arithmetic and file inventory, not authorship.'],
                  checks=CHECKS)
    target = ROOT / 'audit-final.json'
    temporary = target.with_suffix('.partial')
    temporary.write_text(json.dumps(output, indent=2) + '\n')
    temporary.replace(target)
    print(json.dumps({key: output[key] for key in ('strict', 'complete', 'passed', 'passed_all', 'checks_passed', 'checks_total', 'failures', 'pending', 'coverage')}, indent=2))
    return 0 if output['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
