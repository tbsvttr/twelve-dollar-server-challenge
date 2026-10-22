"""Audit this frozen local experiment and summarize every retained attempt.

Only complete, clean trials for the current source/image/fixtures, preceded by
matching passing correctness evidence, may support an observed throughput result.
This script reads local evidence only; it does not run Docker or publish results.
"""
import argparse
import csv
import datetime as dt
import hashlib
import json
import math
import re
import sqlite3
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOCKETS = ('connect', 'read', 'write', 'timeout')
METRICS = ('rps', 'successful_rps', 'p50_ms', 'p95_ms', 'p99_ms', 'rss_mib', 'cpu_percent')
MEASURED_ERRORS = 'Measured HTTP/socket errors exclude this trial from clean comparison'


def read(name, default=None):
    path = ROOT / name
    return json.loads(path.read_text()) if path.exists() else default


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def identifier(row):
    return str(row.get('case_id', row.get('id', row.get('pr'))))


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def parse_wrk(output):
    """Independently parse the original printed wrk results, including custom p95."""
    def field(pattern):
        match = re.search(pattern, output)
        if not match:
            raise ValueError('Missing raw wrk field: ' + pattern)
        return match
    requests, seconds = field(r'(\d+) requests in ([0-9.]+)s,').groups()
    result = dict(requests=int(requests), duration_s=float(seconds),
                  rps=float(field(r'Requests/sec:\s*([0-9.]+)')[1]))
    if not result['requests'] or not result['duration_s'] or not result['rps']:
        raise ValueError('Raw wrk counts, duration and throughput must be positive')
    inferred = result['requests'] / result['rps']
    if abs(inferred - result['duration_s']) > .0051 + .006 * inferred / result['rps']:
        raise ValueError('Raw wrk count/rate and rounded duration are inconsistent')
    for percentile in (50, 95, 99):
        value = field(r'\s' + str(percentile) + r'(?:\.0+)?%\s+([0-9.]+)(us|ms|s)')
        result[f'p{percentile}_ms'] = float(value[1]) * {'us': .001, 'ms': 1, 's': 1000}[value[2]]
    if not result['p50_ms'] <= result['p95_ms'] <= result['p99_ms']:
        raise ValueError('Raw latency percentiles are not ordered')
    http = re.search(r'Non-2xx or 3xx responses:\s*(\d+)', output)
    result['http_errors'] = int(http[1]) if http else 0
    socket = re.search(r'Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)', output)
    result['socket_errors'] = dict(zip(SOCKETS, map(int, socket.groups()) if socket else (0, 0, 0, 0)))
    result['successful_rps'] = result['rps'] - result['http_errors'] / result['duration_s']
    return result


def same_number(first, second):
    return (type(first) in (int, float) and type(second) in (int, float)
            and math.isfinite(first) and math.isfinite(second)
            and math.isclose(first, second, rel_tol=1e-8, abs_tol=1e-6))


def audit_source(candidate):
    hashes = read(candidate['source_hashes'], {})
    issues = []
    if not hashes or canonical_hash(hashes) != candidate.get('source_sha256'):
        issues.append('Source inventory identity differs from manifest')
    if len(hashes) != candidate.get('source_file_count'):
        issues.append('Source file count differs from manifest')
    directory = ROOT / 'sources' / ('pr' + identifier(candidate))
    for name, expected in hashes.items():
        path = directory / name
        if not path.is_file() or digest(path) != expected:
            issues.append('Frozen source mismatch: ' + name)
    inventory = read('source-inventories/pr' + identifier(candidate) + '.json', {}).get('files', {})
    loc = {}
    for name, value in inventory.items():
        if name in hashes and value.get('sha256') != hashes[name]:
            issues.append('LOC inventory hash differs: ' + name)
        if name in hashes and (directory / name).is_file():
            lines = len((directory / name).read_bytes().splitlines())
            if lines != value.get('physical_lines'):
                issues.append('LOC inventory count differs: ' + name)
            if name.endswith('train_sqlite.c') or value.get('classification') == 'application':
                suffix = '.build-time-c' if name.endswith('train_sqlite.c') else Path(name).suffix
                loc[suffix] = loc.get(suffix, 0) + lines
    return issues, loc


def identity_issues(record, candidate, build, shared):
    expected = dict(case_id=identifier(candidate), pr=candidate['pr'],
                    commit=candidate.get('commit'), image=build.get('image'),
                    source_sha256=candidate.get('source_sha256'), shared_hashes=shared,
                    image_id=build.get('image_id'))
    issues = [key + ' differs from current manifest/build/fixtures'
              for key, value in expected.items() if record.get(key) != value]
    if record.get('fingerprint') != canonical_hash(expected):
        issues.append('Identity fingerprint differs')
    return issues


def service_issues(record, candidate, initial_posts, seccomp):
    issues = []
    if record.get('error'):
        issues.append('Controller error: ' + str(record['error']))
    service = record.get('service', {})
    for key, expected in [('ready', True), ('source_sha256', candidate.get('source_sha256')),
                          ('source_files_verified', candidate.get('source_file_count')),
                          ('initial_post_count', initial_posts), ('nginx', candidate.get('nginx', False))]:
        if service.get(key) != expected:
            issues.append('Service startup ' + key + ' differs')
    limits = record.get('container_host_config', {})
    for key, expected in [('CpusetCpus', '0'), ('NanoCpus', 1000000000),
                          ('Memory', 2147483648), ('MemorySwap', 2147483648)]:
        if limits.get(key) != expected:
            issues.append('Actual server limit differs: ' + key)
    nofile = [value for value in limits.get('Ulimits', []) if value.get('Name') == 'nofile']
    if len(nofile) != 1 or nofile[0].get('Hard') != 65535 or nofile[0].get('Soft') != 65535:
        issues.append('Actual nofile limit differs from 65535:65535')
    options = limits.get('SecurityOpt', [])
    try:
        profiles = [json.loads(value.split('=', 1)[1]) for value in options if value.startswith('seccomp=')]
        if profiles != [seccomp]:
            issues.append('Actual seccomp profile differs from shared profile')
    except (ValueError, TypeError):
        issues.append('Actual seccomp profile cannot be parsed')
    state = record.get('container_state', {})
    if state.get('OOMKilled') or state.get('Dead') or state.get('Error'):
        issues.append('Container reports OOM, death or error')
    databases = [value['database_after'] for value in record.get('final', []) if 'database_after' in value]
    database = databases[0] if len(databases) == 1 else {}
    growth = (type(database.get('post_count')) is int and
              type(database.get('max_post_id')) is int and
              database.get('initial_post_count') == initial_posts and
              database['post_count'] > initial_posts and database['max_post_id'] > initial_posts)
    if database.get('integrity') != 'ok' or not growth or record.get('database_valid') is not True:
        issues.append('Post-shutdown SQLite integrity/committed-write validation failed')
    return issues, database


def verification_issues(record):
    issues = []
    counts = re.search(r'passed=(\d+) failed=(\d+)', record.get('output', ''))
    if (not counts or counts.groups() != ('42', '0') or record.get('passed') != 42
            or record.get('failed') != 0 or record.get('exit_code') != 0
            or record.get('official_passed_all') is not True or record.get('passed_all') is not True):
        issues.append('Official verification is not 42/42 passing')
    semantic = record.get('semantic', {})
    checks = semantic.get('checks', [])
    if (semantic.get('passed_all') is not True or semantic.get('exit_code') != 0
            or not checks or not all(value.get('passed') is True for value in checks)):
        issues.append('Dynamic API round-trip verification failed')
    try:
        raw = json.loads(record.get('semantic_output', ''))
        if raw.get('checks') != checks or raw.get('passed_all') is not True:
            issues.append('Stored dynamic verification differs from raw output')
    except ValueError:
        issues.append('Raw dynamic verification output cannot be parsed')
    return issues


def sample_metrics(sample):
    processes = sample.get('processes', {})
    if not processes:
        raise ValueError('Missing sampled service processes')
    cpu = sum(value['cpu_s'] for value in processes.values())
    rss = sum(value['rss_kib'] for value in processes.values())
    if not same_number(cpu, sample.get('cpu_s')) or not same_number(rss, sample.get('rss_kib')):
        raise ValueError('Sampled aggregate CPU/RSS differs from process totals')
    for value in processes.values():
        if not same_number(value['cpu_s'], value['cpu_self_s'] + value['cpu_waited_children_s']):
            raise ValueError('Process CPU does not equal self plus waited-child CPU')
    return cpu, rss


def measurement_issues(record, passing_verifications):
    issues, computed = [], {}
    configuration = record.get('configuration', {})
    expected = dict(threads=2, connections=64, warmup_seconds=2, measurement_seconds=15)
    if any(configuration.get(key) != value for key, value in expected.items()):
        issues.append('Measured configuration differs from 2 threads / 64 connections / 2s warm-up / 15s load')
    if record.get('completed') is not True or record.get('valid_duration') is not True:
        issues.append('Measurement is unfinished or duration is invalid')
    try:
        computed.update(parse_wrk(record.get('output', '')))
        if not 14.5 <= computed['duration_s'] <= 17:
            issues.append('Raw measured duration is outside tolerance')
        for key, value in computed.items():
            equal = record.get(key) == value if isinstance(value, dict) else same_number(record.get(key), value)
            if not equal:
                issues.append('Stored metric differs from raw wrk output: ' + key)
        before, after = record['before'], record['after']
        before_cpu, _ = sample_metrics(before)
        after_cpu, rss = sample_metrics(after)
        elapsed = after['monotonic'] - before['monotonic']
        if elapsed <= 0 or after_cpu < before_cpu or rss <= 0:
            raise ValueError('Invalid sampled measurement interval, CPU or RSS')
        computed['cpu_percent'] = 100 * (after_cpu - before_cpu) / elapsed
        computed['rss_mib'] = rss / 1024
        for key in ('rss_mib', 'cpu_percent'):
            if not same_number(record.get(key), computed[key]):
                issues.append('Stored metric differs from service-process samples: ' + key)
        if not any(value.get('recorded_at', '') <= record.get('recorded_at', '')
                   and value.get('after', {}).get('monotonic', math.inf) <= before['monotonic']
                   for value in passing_verifications):
            issues.append('No matching passing verification completed before this benchmark')
        if computed['http_errors'] or any(computed['socket_errors'].values()):
            issues.append(MEASURED_ERRORS)
    except (ValueError, KeyError, TypeError, ZeroDivisionError) as error:
        issues.append(str(error))
    return issues, computed


def paired_exclusion_audit(excluded, trial_count, manifest, measurements):
    """Require the retained original pairs and a decision preceding one extra pair."""
    if not excluded:
        return [], None
    issues = []
    decision_path = 'paired-retry-decision.json'
    decision = read(decision_path, {})
    original = read('archives/original-six-rounds/measurements.json', [])
    cases = {identifier(row) for row in manifest}
    if not decision or not original:
        return ['Paired exclusion requires the predeclared decision and archived original measurements'], None
    declared = decision.get('excluded_rounds', [6] if 'round-6' in decision.get('selection', '') else [])
    if sorted(excluded) != sorted(declared) or decision.get('no_further_retries') is not True:
        issues.append('Requested paired exclusions differ from the bounded predeclared decision')
    original_last = max((run.get('trial', 0) for run in original), default=0)
    if (trial_count != original_last + 1 or len(original) != original_last * len(cases)
            or len(measurements) != trial_count * len(cases)
            or measurements[:len(original)] != original):
        issues.append('Exactly one extra complete pair and unchanged original attempts are required')
    for trial in range(1, trial_count + 1):
        ids = [identifier(run) for run in measurements if run.get('trial') == trial]
        if len(ids) != len(cases) or set(ids) != cases:
            issues.append(f'Round {trial} does not contain exactly one attempt for every case')
    try:
        declared_at = dt.datetime.fromisoformat(decision['recorded_at'].replace('Z', '+00:00'))
        replacement = [run for run in measurements if run.get('trial') == original_last + 1]
        if not replacement or any(dt.datetime.fromisoformat(run['recorded_at'].replace('Z', '+00:00')) <= declared_at
                                  for run in replacement):
            issues.append('Paired retry decision does not predate every replacement attempt')
    except (KeyError, TypeError, ValueError):
        issues.append('Paired retry decision timestamps cannot be audited')
    proof = dict(path=decision_path, sha256=digest(ROOT / decision_path), decision=decision,
                 original_measurements='archives/original-six-rounds/measurements.json',
                 original_measurements_sha256=digest(ROOT / 'archives/original-six-rounds/measurements.json'),
                 original_attempt_count=len(original), replacement_round=original_last + 1,
                 issues=list(issues))
    return issues, proof


def report(summary):
    rows = summary['rows']
    control = next((row for row in rows if row.get('role') == 'control'), None)
    lines = ['**Local Goose versus Rust experiment — 2026-10-22.**', '']
    if summary['complete'] and control:
        for row in rows:
            if row is control:
                continue
            ratio = row['relative_to_control']
            lines.append(f"**{row['label']}: {row['successful_rps']:,.0f} successful req/s**, versus "
                         f"{control['successful_rps']:,.0f} for {control['label']} "
                         f"({ratio:.3f}×; {abs(ratio - 1) * 100:.1f}% "
                         f"{'higher' if ratio >= 1 else 'lower'} observed median).")
    else:
        lines.append('**Comparison incomplete.** No winning result is supported until every required case passes the audit.')
    lines += ['', f"Medians of {summary['selected_round_count']} selected clean, fresh-process trials per case "
              f"from {summary['attempted_round_count']} attempted matched pairs; "
              'ranges are observed min–max. One server CPU, 2 GiB RAM, no container swap, 65,535 descriptors; '
              'native Linux ARM64 on the recorded Apple M2 Pro host. Separate two-CPU load generator. '
              '`wrk -t2 -c64`, 2-second warm-up, 15-second measurement, fresh seeded SQLite database. '
              'Mixed request ratio: 100 feed reads : 100 post reads : 15 likes : 2 creates.']
    if summary['excluded_rounds']:
        lines += ['', '**Paired exclusion declared before the replacement run.** '
                  'Both cases from round ' + ', '.join(map(str, summary['excluded_rounds'])) +
                  ' are excluded from the clean medians. Selected rounds: ' +
                  ', '.join(map(str, summary['selected_rounds'])) +
                  '. Rust round 6 recorded **58 socket timeouts**; Goose round 6 was clean and is excluded with its pair. '
                  'Exactly one additional matched pair, round 7, was run; both cases were clean. '
                  'The [recorded decision](paired-retry-decision.json) predates round 7. '
                  'The [original six-round evidence](archives/original-six-rounds/) and all 14 current raw attempts remain retained.']
    errors = summary['total_socket_errors']
    lines += ['', f"**All-attempt errors:** {summary['total_http_errors']} HTTP errors; "
              f"{sum(errors.values())} socket errors "
              f"(connect/read/write/timeout: {'/'.join(str(errors[key]) for key in SOCKETS)}). "
              'Excluded errors remain diagnostic evidence; only selected clean pairs enter the medians.', '',
              '| Case | Status | Successful req/s | Range | Ratio to Rust | p95 / p99 ms | RSS MiB | CPU % |',
              '|---|---|---:|---:|---:|---:|---:|---:|']
    for row in rows:
        if row.get('successful_rps') is None:
            lines.append(f"| {row['label']} | {row['status']} | — | — | — | — | — | — |")
            continue
        ratio = f"{row['relative_to_control']:.3f}×" if row.get('relative_to_control') else '—'
        lines.append(f"| {row['label']} | {row['status']} | {row['successful_rps']:,.0f} | "
                     f"{row['rps_min']:,.0f}–{row['rps_max']:,.0f} | {ratio} | "
                     f"{row['p95_ms']:.3f} / {row['p99_ms']:.3f} | {row['rss_mib']:.2f} | {row['cpu_percent']:.1f} |")
    lines += ['', '| Round | Case | Selection | Successful req/s | p95 / p99 ms | RSS MiB | CPU % | HTTP / socket errors |',
              '|---:|---|---|---:|---:|---:|---:|---:|']
    for trial in range(1, summary['required_trials'] + 1):
        for row in rows:
            run = next((value for value in row['trials'] if value['trial'] == trial), None)
            if run and all(key in run['computed'] for key in METRICS):
                value = run['computed']
                choice = 'included' if run['included_in_median'] else 'excluded pair'
                lines.append(f"| {trial} | {row['label']} | {choice} | {value['successful_rps']:,.2f} | "
                             f"{value['p95_ms']:.3f} / {value['p99_ms']:.3f} | {value['rss_mib']:.2f} | "
                             f"{value['cpu_percent']:.1f} | {value['http_errors']} / "
                             f"{sum(value['socket_errors'].values())} |")
    lines += ['', '**Audit and provenance.**']
    for row in rows:
        source_kind = 'source snapshot' if re.fullmatch(r'[a-f0-9]{64}', str(row['commit'])) else 'source commit'
        lines += ['', f"- {row['label']}: {source_kind} `{row['commit']}`; source SHA-256 `{row['source_sha256']}`; "
                  f"image `{row['image_id']}`; binary SHA-256 `{row.get('binary_sha256') or 'not recorded'}`."]
        if row.get('compiler'):
            lines.append('  Compiler: ' + str(row['compiler']) + '.')
        if row.get('goose_compiler_commit'):
            lines.append(f"  Goose compiler `{row['goose_compiler_commit']}`; runtime `df5f78ce88d4`; "
                         'generated C built with GCC 13.3.0, `-O3 -march=native -DNDEBUG`.')
        if row.get('loc', {}).get('.goose'):
            loc = row['loc']
            lines.append(f"  Authored source: {loc['.goose']} Goose lines plus "
                         f"{loc.get('.c', 0) + loc.get('.h', 0) + loc.get('.inc', 0)} C/header support lines, including blanks/comments; "
                         'vendored SQLite, generated C and compiler runtime excluded.')
            if loc.get('.build-time-c'):
                lines.append(f"  Separate build-time SQLite PGO trainer: {loc['.build-time-c']} C lines; never linked into the server.")
        if row['status'] == 'measured':
            lines.append(f"  Official API 42/42, dynamic API round-trip and all {summary['required_trials']} post-shutdown "
                         f"SQLite integrity/committed-growth checks passed; the {summary['selected_round_count']} selected trials "
                         'have zero HTTP/socket errors. '
                         'Source/image/fixture identities, raw wrk output, CPU/RSS samples and actual container limits agree.')
        else:
            lines.extend('  Audit issue: ' + issue + '.' for issue in row['issues'])
        if row.get('supplemental'):
            extra = row['supplemental']
            lines.append(f"  Matching supplemental API edge diagnostics: {extra['passed']}/{extra['count']} passed ({extra['path']}).")
    if summary['issues']:
        lines += ['', '**Global audit issues:** ' + '; '.join(summary['issues']) + '.']
    lines += ['', f"All {summary['attempt_count']} measurement attempts and {summary['verification_attempt_count']} "
              'verification attempts remain in the original JSON evidence; `summary.json` records selection/rejection '
              'reasons, including stale or superseded attempts. The latest matching attempt for each round is authoritative. '
              'p95/p99 are medians of per-run histogram percentiles. RSS is sampled process RSS after load, not peak/container '
              'memory; CPU includes waited-child CPU. Successful req/s uses wrk’s printed rate minus the HTTP-error rate. '
              'Wrk socket-timeout counters can include completed responses outside its latency histogram.', '',
              '**Scope.** This compares a Goose application with C epoll/SQLite/OpenSSL support against Rust raw io_uring. '
              'Both final implementations use SQLite 3.53.4 with source-trained PGO and the same synthetic-data trainer. '
              'It does not isolate a language effect. Local results only: no GitHub publication and '
              'no official k6 capacity score is claimed.', '']
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--trials', type=int, default=3)
    parser.add_argument('--exclude-rounds', default='', help='Comma-separated whole paired rounds excluded under a predeclared bounded retry decision')
    parser.add_argument('--strict', action='store_true', help='Exit unsuccessfully unless the entire comparison is clean and complete')
    args = parser.parse_args()
    if args.trials < 1:
        parser.error('--trials must be positive')
    try:
        excluded = {int(value) for value in args.exclude_rounds.split(',') if value}
    except ValueError:
        parser.error('--exclude-rounds must contain comma-separated round numbers')
    if not excluded <= set(range(1, args.trials + 1)) or len(excluded) == args.trials:
        parser.error('Excluded rounds must leave at least one selected round within --trials')
    selected_rounds = [trial for trial in range(1, args.trials + 1) if trial not in excluded]
    manifest, builds = read('manifest.json', []), read('build-status.json', {})
    verification, measurements = read('verification.json', []), read('measurements.json', [])
    shared = read('shared-sha256.json', {})
    global_issues = []
    paired_issues, paired_proof = paired_exclusion_audit(excluded, args.trials, manifest, measurements)
    global_issues += paired_issues
    if not manifest or not shared:
        global_issues.append('Manifest or shared fixture inventory is missing')
    for name, expected in shared.items():
        path = ROOT / name
        if not path.is_file() or digest(path) != expected:
            global_issues.append('Current shared fixture mismatch: ' + name)
    environment = read('environment-bench.json', {})
    if environment.get('shared_hashes') != shared:
        global_issues.append('Benchmark environment does not match current fixtures')
    expected_environment = dict(server_cpus='0', server_cpu_quota=1, server_memory='2g', server_memory_swap='2g',
                                load_cpus='1,2', load_cpu_quota=2, load_memory='2g', nofile=65535)
    for key, expected in expected_environment.items():
        if environment.get(key) != expected:
            global_issues.append('Benchmark environment differs: ' + key)
    with sqlite3.connect('file:' + str(ROOT / 'seed/feed.db') + '?mode=ro&immutable=1', uri=True) as connection:
        initial_posts = connection.execute('SELECT count(*) FROM posts').fetchone()[0]
    seccomp = read('seccomp-io-uring.json', {})
    rows, attempts = [], []
    for candidate in manifest:
        case_id = identifier(candidate)
        build = builds.get(case_id, {})
        issues, loc = audit_source(candidate)
        if build.get('commit') != candidate.get('commit') or build.get('exit_code') != 0 or not build.get('image_id'):
            issues.append('Current build identity or successful build evidence is missing')
        proof = build.get('proof', {})
        row = dict(case_id=case_id, label=candidate.get('label', candidate.get('title', case_id)),
                   role=candidate.get('role'), commit=candidate.get('commit'),
                   source_sha256=candidate.get('source_sha256'), image_id=build.get('image_id'),
                   binary_sha256=proof.get('binary_sha256', build.get('binary_sha256')),
                   compiler=proof.get('compiler', proof.get('rustc_version', build.get('compiler'))),
                   goose_compiler_commit=candidate.get('goose_compiler_commit', build.get('compiler_commit')),
                   loc=loc, issues=issues, trials=[], verification_attempts=[], status='incomplete')
        if not re.fullmatch(r'[a-f0-9]{64}', str(row['binary_sha256'] or '')):
            issues.append('Exact server binary SHA-256 is missing')
        supplemental = read('edge-checks.json', {})
        source_hashes = read(candidate['source_hashes'], {})
        if (supplemental and supplemental.get('image_id') == build.get('image_id')
                and supplemental.get('source_app_sha256') == source_hashes.get('app.goose')
                and supplemental.get('seed_sha256') == shared.get('seed/feed.db')):
            checks = supplemental.get('checks', [])
            passed = sum(value.get('passed') is True for value in checks)
            row['supplemental'] = dict(path='edge-checks.json', count=len(checks), passed=passed)
            if not checks or passed != len(checks) or supplemental.get('passed_all') is not True:
                issues.append('Matching supplemental API edge diagnostics failed')
        matching_verifications, passing = [], []
        for index, run in enumerate(verification):
            if identifier(run) != case_id:
                continue
            identity = identity_issues(run, candidate, build, shared)
            run_issues = list(identity)
            if not identity:
                extra, _ = service_issues(run, candidate, initial_posts, seccomp)
                run_issues += extra + verification_issues(run)
                matching_verifications.append((run, run_issues))
                if not run_issues:
                    passing.append(run)
            row['verification_attempts'].append(dict(index=index, recorded_at=run.get('recorded_at'), issues=run_issues))
        if not matching_verifications:
            issues.append('No matching verification attempt')
        elif matching_verifications[-1][1]:
            issues.append('Latest matching verification fails: ' + '; '.join(matching_verifications[-1][1]))
        matching = {}
        for index, run in enumerate(measurements):
            if identifier(run) != case_id:
                continue
            identity = identity_issues(run, candidate, build, shared)
            attempt = dict(index=index, case_id=case_id, trial=run.get('trial'), recorded_at=run.get('recorded_at'),
                           fingerprint=run.get('fingerprint'), image_id=run.get('image_id'), selected=False, issues=identity)
            attempts.append(attempt)
            if not identity:
                trial = run.get('trial')
                if type(trial) is not int or trial < 1:
                    attempt['issues'].append('Invalid trial number')
                elif trial > args.trials:
                    issues.append(f'Trial {trial} exists beyond requested count; include all rounds with --trials {trial}')
                    attempt['issues'].append('Beyond requested trial count')
                else:
                    if trial in matching:
                        matching[trial][1]['issues'].append('Superseded by a later matching attempt for this round')
                    matching[trial] = (run, attempt)
        for trial in range(1, args.trials + 1):
            if trial not in matching:
                issues.append(f'Missing matching trial {trial}/{args.trials}')
                continue
            run, attempt = matching[trial]
            included = trial not in excluded
            attempt['selected'] = included
            attempt['authoritative'] = True
            attempt['selection_reason'] = ('Selected clean paired round' if included else
                                           'Both cases in this original round excluded by the predeclared paired retry decision')
            service, database = service_issues(run, candidate, initial_posts, seccomp)
            measured, computed = measurement_issues(run, passing)
            attempt['issues'] += service + measured
            row['trials'].append(dict(trial=trial, recorded_at=run.get('recorded_at'), computed=computed,
                                      database_after=database, issues=list(attempt['issues']), attempt_index=attempt['index'],
                                      included_in_median=included, selection_reason=attempt['selection_reason']))
            fatal = [issue for issue in attempt['issues'] if included or issue != MEASURED_ERRORS]
            if fatal:
                issues.append(f'Trial {trial}: ' + '; '.join(fatal))
        row['attempted_round_count'] = len(row['trials'])
        row['selected_rounds'] = selected_rounds
        row['selected_round_count'] = sum(run['included_in_median'] for run in row['trials'])
        row['attempted_http_errors'] = sum(run['computed'].get('http_errors', 0) for run in row['trials'])
        row['attempted_socket_errors'] = {key: sum(run['computed'].get('socket_errors', {}).get(key, 0)
                                                  for run in row['trials']) for key in SOCKETS}
        if not issues and len(row['trials']) == args.trials:
            row['status'] = 'measured'
            selected = [run for run in row['trials'] if run['included_in_median']]
            for key in METRICS:
                row[key] = statistics.median(run['computed'][key] for run in selected)
            rates = [run['computed']['successful_rps'] for run in selected]
            row.update(rps_min=min(rates), rps_max=max(rates), http_errors=0,
                       socket_errors={key: 0 for key in SOCKETS}, database_valid=True)
        rows.append(row)
    control = next((row for row in rows if row.get('role') == 'control'), None)
    if not control:
        global_issues.append('Manifest has no control case')
    if control and control['status'] == 'measured':
        for row in rows:
            if row['status'] != 'measured':
                continue
            row['relative_to_control'] = row['successful_rps'] / control['successful_rps']
            paired_control = {run['trial']: run for run in control['trials']}
            row['paired_round_numbers'] = selected_rounds
            row['paired_round_ratios'] = [run['computed']['successful_rps'] / paired_control[run['trial']]['computed']['successful_rps']
                                          for run in row['trials'] if run['included_in_median']]
    raw_errors, unknown_error_attempts = [], []
    for index, run in enumerate(measurements):
        try:
            raw_errors.append(parse_wrk(run.get('output', '')))
        except (TypeError, ValueError) as error:
            unknown_error_attempts.append(dict(index=index, case_id=identifier(run), trial=run.get('trial'), error=str(error)))
    summary = dict(date='2026-10-22', generated_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                   required_trials=args.trials, complete=bool(rows) and not global_issues and all(row['status'] == 'measured' for row in rows),
                   attempted_rounds=list(range(1, args.trials + 1)), attempted_round_count=args.trials,
                   selected_rounds=selected_rounds, selected_round_count=len(selected_rounds), excluded_rounds=sorted(excluded),
                   paired_exclusion_rule=('Exclude both cases from each predeclared excluded round; require all attempted pairs; '
                                          'use only complete clean selected pairs, with exactly one extra replacement pair and no further retries.'),
                   paired_retry_proof=paired_proof,
                   total_http_errors=sum(run['http_errors'] for run in raw_errors),
                   total_socket_errors={key: sum(run['socket_errors'][key] for run in raw_errors) for key in SOCKETS},
                   unknown_error_attempts=unknown_error_attempts,
                   issues=global_issues, rows=rows, attempts=attempts,
                   attempt_count=len(measurements), verification_attempt_count=len(verification),
                   manifest_sha256=digest(ROOT / 'manifest.json'), shared_hashes=shared, environment=environment,
                   scope='Local implementation comparison; not an isolated language effect or official k6 capacity score.')
    (ROOT / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    fields = ['case_id', 'label', 'status', 'commit', 'source_sha256', 'image_id', 'binary_sha256',
              'successful_rps', 'rps_min', 'rps_max', 'relative_to_control', 'p50_ms', 'p95_ms', 'p99_ms',
              'rss_mib', 'cpu_percent', 'http_errors', 'socket_errors', 'database_valid', 'issues']
    fields += ['attempted_round_count', 'selected_round_count', 'selected_rounds', 'attempted_http_errors', 'attempted_socket_errors']
    with (ROOT / 'comparison.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction='ignore')
        writer.writeheader()
        for row in rows:
            writer.writerow({key: json.dumps(value, sort_keys=True) if isinstance(value, (dict, list)) else value
                             for key, value in row.items()})
    (ROOT / 'RESULT.md').write_text(report(summary))
    print(json.dumps(dict(complete=summary['complete'], required_trials=args.trials,
                         selected_rounds=selected_rounds, excluded_rounds=sorted(excluded),
                         cases={row['case_id']: row['status'] for row in rows}, issues=global_issues), indent=2))
    if args.strict and not summary['complete']:
        raise SystemExit('Comparison is incomplete or failed audit; see RESULT.md and summary.json')


if __name__ == '__main__':
    main()
