"""Offline, stage-local analysis of the PR26 tuning experiment.

No Docker or benchmark command is run. Latest attempts are chosen before any
identity/validity filtering, so a newer failure cannot expose an older success.
Screening and confirmation must use separate evidence directories.
"""
import argparse
import collections
import csv
import hashlib
import importlib.util
import json
import math
import re
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REFERENCE = next((parent / 'current-2026-10-20' for parent in ROOT.parents
                  if (parent / 'current-2026-10-20' / 'analyze.py').is_file()), ROOT.parent / 'current-2026-10-20')
CONTROLS = ('26-original', '82-leader')
REBUILT = '26-b128-w4000'
TUNED = {'26-b32-w4000', '26-b128-w250', '26-b32-w250'}
SOCKET_KEYS = ('connect', 'read', 'write', 'timeout')
METRICS = ('rps', 'successful_rps', 'p50_ms', 'p95_ms', 'p99_ms', 'cpu_percent',
           'rss_mib', 'cpu_us_per_request')
LOAD_ID = 'sha256:901ab577025cfdcf7abc716fb4158774615b881383529bb77163b5f07f963898'


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def finite(value):
    try:
        return type(value) in (int, float) and math.isfinite(value)
    except OverflowError:
        return False


def load_helpers():
    """Reuse the established metric schema and wrk parser without running them."""
    modules = []
    for name in ('run', 'analyze'):
        path = REFERENCE / (name + '.py')
        spec = importlib.util.spec_from_file_location('_tuning_reference_' + name, path)
        module = importlib.util.module_from_spec(spec)
        previous = sys.modules.get('run')
        if name == 'analyze':
            sys.modules['run'] = modules[0]
        try:
            spec.loader.exec_module(module)
        finally:
            if name == 'analyze':
                if previous is None:
                    sys.modules.pop('run', None)
                else:
                    sys.modules['run'] = previous
        modules.append(module)
    return modules[0].parse_wrk, modules[1].invalid_trial


def case_id(row):
    return str(row.get('case_id', row.get('id', row.get('pr', ''))))


def database_issues(record):
    issues = []
    final = record.get('final', [])
    databases = [item['database_after'] for item in final
                 if isinstance(item, dict) and isinstance(item.get('database_after'), dict)] if isinstance(final, list) else []
    if len(databases) != 1:
        return ['Missing unique post-stop database result.']
    db = databases[0]
    initial = db.get('initial_post_count')
    count, maximum = db.get('post_count'), db.get('max_post_id')
    service = record.get('service') if isinstance(record.get('service'), dict) else {}
    if (record.get('database_valid') is not True or db.get('integrity') != 'ok'
            or type(initial) is not int or initial <= 0 or type(count) is not int
            or count <= initial or type(maximum) is not int or maximum < count
            or service.get('initial_post_count') != initial):
        issues.append('Committed post growth, seed count, or SQLite quick_check failed.')
    return issues


def identity_issues(record, identity, fingerprint, candidate, inventory):
    issues = [f'Identity mismatch: {key}.' for key, value in identity.items()
              if record.get(key) != value]
    if record.get('fingerprint') != fingerprint:
        issues.append('Fingerprint does not match the current source/image/fixture identity.')
    service = record.get('service', {})
    expected_start = candidate.get('source_dir', '/suite/sources/pr' + candidate['id']) + '/start.sh'
    if (not isinstance(service, dict) or service.get('ready') is not True
            or service.get('source_sha256') != candidate.get('source_sha256')
            or service.get('source_files_verified') != len(inventory)
            or service.get('start_script') != expected_start
            or service.get('nginx') != bool(candidate.get('nginx'))):
        issues.append('In-image pinned-source/start-script acknowledgment is missing or mismatched.')
    return issues


def resource_issues(record, profile):
    host = record.get('container_host_config', {})
    expected = {'CpusetCpus': '0', 'NanoCpus': 1000000000,
                'Memory': 2147483648, 'MemorySwap': 2147483648}
    if (not isinstance(host, dict) or any(host.get(key) != value for key, value in expected.items())
            or {'Name': 'nofile', 'Soft': 65535, 'Hard': 65535} not in (host.get('Ulimits') or [])):
        return ['Server CPU/memory/no-swap/file-descriptor limits differ.']
    security = host.get('SecurityOpt', [])
    try:
        same = (len(security) == 1 and security[0].startswith('seccomp=')
                and json.loads(security[0].split('=', 1)[1]) == profile)
    except (TypeError, ValueError, AttributeError):
        same = False
    issues = [] if same else ['Server seccomp policy differs.']
    state = record.get('container_state', {})
    if (not isinstance(state, dict) or state.get('Running') is not True
            or state.get('OOMKilled') is not False or state.get('Dead') is not False
            or state.get('Restarting') is not False or state.get('Error')):
        issues.append('Service was not alive without OOM/restart at the final inspection.')
    return issues


def measurement_issues(record, configuration, parse_wrk, invalid_trial):
    issues = []
    if record.get('mode') != 'bench' or record.get('configuration') != configuration:
        issues.append('Benchmark mode/configuration differs from this stage environment.')
    if record.get('completed') is not True:
        issues.append('Latest measured attempt is unfinished.')
    if record.get('error'):
        issues.append('Controller error: ' + str(record['error']))
    problem = invalid_trial(record)
    if problem:
        issues.append(problem)
        return issues, None
    requests = record.get('requests')
    if type(requests) is not int or requests <= 0 or record['http_errors'] > requests:
        issues.append('Completed request count is missing or invalid.')
    if not 0 <= record['p50_ms'] <= record['p95_ms'] <= record['p99_ms']:
        issues.append('Latency percentiles are out of order.')
    try:
        parsed = parse_wrk(record.get('output', ''))
        if any(parsed[key] != record.get(key) for key in parsed):
            issues.append('Retained metrics do not match raw wrk output.')
    except (TypeError, ValueError, KeyError, AttributeError) as error:
        issues.append('Cannot parse retained wrk output: ' + str(error))
    try:
        before, after = record['before'], record['after']
        elapsed = after['monotonic'] - before['monotonic']
        cpu_seconds = after['cpu_s'] - before['cpu_s']
        if not finite(elapsed) or elapsed <= 0 or not finite(cpu_seconds) or cpu_seconds < 0:
            raise ValueError('invalid CPU sample interval/delta')
        if not math.isclose(record['cpu_percent'], 100 * cpu_seconds / elapsed, rel_tol=1e-9, abs_tol=1e-9):
            raise ValueError('CPU percentage does not match samples')
        if record['rss_mib'] != after['rss_kib'] / 1024:
            raise ValueError('RSS does not match final sample')
        for sample in (before, after):
            processes = sample['processes'].values()
            if not math.isclose(sample['cpu_s'], sum(p['cpu_s'] for p in processes), abs_tol=1e-8):
                raise ValueError('CPU process sum differs')
            if not math.isclose(sample['cpu_s'], sample['cpu_self_s'] + sample['cpu_waited_children_s'], abs_tol=1e-8):
                raise ValueError('self/waited-child CPU components differ')
            if sample['rss_kib'] != sum(p['rss_kib'] for p in sample['processes'].values()):
                raise ValueError('RSS process sum differs')
        cpu_us = cpu_seconds * 1_000_000 / requests if type(requests) is int and requests > 0 else None
    except (KeyError, TypeError, ValueError, ZeroDivisionError) as error:
        issues.append('Invalid CPU/RSS accounting: ' + str(error))
        cpu_us = None
    return issues, cpu_us


def analyze_stage(stage_dir=ROOT, kind=None):
    stage_dir = Path(stage_dir).resolve()
    global_issues, input_hashes = [], {}

    def read(name, default):
        path = stage_dir / name
        try:
            data = path.read_bytes()
            input_hashes[name] = hashlib.sha256(data).hexdigest()
            return json.loads(data)
        except (OSError, ValueError, TypeError) as error:
            global_issues.append(f'{name}: {error}')
            return default

    candidates = read('manifest.json', [])
    if not isinstance(candidates, list) or any(not isinstance(row, dict) for row in candidates):
        global_issues.append('Manifest must be a list of case records.')
        candidates = []
    indexed = {case_id(row): row for row in candidates}
    if len(indexed) != len(candidates) or any(not row.get('id') or row['id'] != case_id(row) for row in candidates):
        global_issues.append('Manifest IDs are missing, duplicated, or differ from case_id.')
    environment = read('environment-bench.json', {})
    if not isinstance(environment, dict):
        environment = {}
    configuration = environment.get('wrk', {})
    expected_trials = configuration.get('trials') if isinstance(configuration, dict) else None
    if type(expected_trials) is not int or expected_trials < 1:
        global_issues.append('Benchmark environment has no positive integer trial count.')
        expected_trials = 0
    required = dict(threads=2, connections=64, warmup_seconds=2, measurement_seconds=15)
    if (environment.get('mode') != 'bench' or not isinstance(configuration, dict)
            or any(configuration.get(key) != value for key, value in required.items())):
        global_issues.append('Stage must retain the 2-thread/64-connection, 2s warmup/15s protocol.')
    resources = dict(server_cpus='0', server_cpu_quota=1, server_memory='2g',
                     server_memory_swap='2g', load_cpus='1,2', load_cpu_quota=2,
                     load_memory='2g', nofile=65535, load_image_id=LOAD_ID)
    if any(environment.get(key) != value for key, value in resources.items()):
        global_issues.append('Recorded stage resources or immutable load image differ.')
    if kind is None:
        kind = ('confirmation' if expected_trials == 6 else
                'screening' if TUNED <= set(indexed) and expected_trials == 3 else 'followup')
    if kind not in ('screening', 'confirmation', 'followup'):
        raise ValueError('Unknown stage kind: ' + str(kind))
    shared = read('shared-sha256.json', {})
    if not isinstance(shared, dict) or not shared:
        global_issues.append('Recorded shared fixture digests are missing.')
        shared = {}
    if shared != environment.get('shared_hashes'):
        global_issues.append('Stage environment/shared fixture digests differ.')
    for name, sha in shared.items():
        try:
            if hashlib.sha256((stage_dir / name).read_bytes()).hexdigest() != sha:
                global_issues.append('Current fixture bytes differ: ' + name)
        except OSError as error:
            global_issues.append(f'Cannot verify fixture {name}: {error}')
    profile = read('seccomp-io-uring.json', {})
    builds = {}
    shards = sorted(path.name for path in stage_dir.glob('build-status-*-*.json')
                    if re.fullmatch(r'build-status-\d+-\d+\.json', path.name))
    for filename in shards or ['build-status.json']:
        values = read(filename, {})
        if not isinstance(values, dict):
            global_issues.append(filename + ' must contain a case-keyed map.')
            continue
        for key, value in values.items():
            if key in builds:
                global_issues.append('Duplicate build case: ' + key)
            builds[key] = value
    verification = read('verification.json', [])
    measurements = read('measurements.json', [])
    if not isinstance(verification, list):
        global_issues.append('Verification records must be a list.')
        verification = []
    if not isinstance(measurements, list):
        global_issues.append('Measurement records must be a list.')
        measurements = []
    latest_verification, latest, attempts = {}, {}, collections.Counter()
    superseded_failures = []
    for position, record in enumerate(verification):
        if not isinstance(record, dict) or case_id(record) not in indexed:
            global_issues.append(f'Unknown/malformed verification record at index {position}.')
            continue
        latest_verification[case_id(record)] = record
    for position, record in enumerate(measurements):
        if not isinstance(record, dict):
            global_issues.append(f'Malformed measurement record at index {position}.')
            continue
        case, trial = case_id(record), record.get('trial')
        if case not in indexed or type(trial) is not int or not 1 <= trial <= expected_trials:
            global_issues.append(f'Unknown case/out-of-stage trial at measurement index {position}.')
            continue
        key = case, trial
        if key in latest:
            previous = latest[key][1]
            sockets = previous.get('socket_errors')
            if (previous.get('error') or previous.get('completed') is not True
                    or previous.get('http_errors') or not isinstance(sockets, dict) or any(sockets.values())):
                superseded_failures.append(dict(case_id=case, trial=trial,
                                               record_index=latest[key][0], record=previous))
        latest[key] = position, record
        attempts[key] += 1
    planned = environment.get('prespecified_orders', {})
    if (stage_dir / 'orders.json').exists():
        if read('orders.json', {}) != planned:
            global_issues.append('Current orders.json differs from the recorded environment.')
    if planned:
        if not isinstance(planned, dict) or set(planned) != {str(i) for i in range(1, expected_trials + 1)}:
            global_issues.append('Prespecified orders do not cover exactly the expected rounds.')
        else:
            for trial in range(1, expected_trials + 1):
                order = planned[str(trial)]
                if not isinstance(order, list) or len(order) != len(indexed) or set(order) != set(indexed):
                    global_issues.append(f'Invalid case permutation for round {trial}.')
                    continue
                recorded = sorted((position, case) for (case, n), (position, record) in latest.items() if n == trial)
                if len(recorded) == len(indexed) and [case for _, case in recorded] != order:
                    global_issues.append(f'Latest-attempt order differs from declared round {trial}; retries may have changed balance.')
    if kind == 'confirmation':
        if expected_trials != 6 or len(indexed) != 3 or not set(CONTROLS) <= set(indexed):
            global_issues.append('Confirmation requires six rounds and the selected candidate plus both controls.')
        if (not planned or len({tuple(order) for order in planned.values() if isinstance(order, list)}) != 6):
            global_issues.append('Confirmation must retain all six distinct balanced case orders.')
    parse_wrk, invalid_trial = load_helpers()
    cases, trial_rows = [], []
    for case, candidate in indexed.items():
        issues = []
        build = builds.get(case, {})
        if not isinstance(build, dict):
            build = {}
        if (not isinstance(build, dict) or build.get('exit_code') != 0
                or build.get('commit') != candidate.get('commit')
                or not re.fullmatch(r'sha256:[a-f0-9]{64}', str(build.get('image_id', '')))
                or build.get('image') != build.get('image_id')
                or build.get('source_sha256', candidate.get('source_sha256')) != candidate.get('source_sha256')):
            issues.append('Build is missing, failed, stale, or not pinned to an immutable matching image.')
        inventory = read(candidate.get('source_hashes', ''), {})
        if (not isinstance(inventory, dict) or not inventory
                or digest(inventory) != candidate.get('source_sha256')
                or len(inventory) != candidate.get('source_file_count')):
            issues.append('Source hash inventory does not match the manifest.')
            inventory = {}
        if candidate.get('local_variant'):
            patch = candidate.get('patch', '')
            try:
                if hashlib.sha256((stage_dir / patch).read_bytes()).hexdigest() != candidate.get('patch_sha256'):
                    issues.append('Local variant patch digest differs.')
            except OSError:
                issues.append('Local variant patch is missing.')
        identity = dict(case_id=case, pr=candidate.get('pr'), commit=candidate.get('commit'),
                        image=build.get('image'), image_id=build.get('image_id'),
                        source_sha256=candidate.get('source_sha256'), shared_hashes=shared)
        fingerprint = digest(identity)
        verified = latest_verification.get(case)
        if verified is None:
            issues.append('No correctness attempt is recorded.')
        else:
            issues += identity_issues(verified, identity, fingerprint, candidate, inventory)
            semantic = verified.get('semantic', {})
            checks = semantic.get('checks') if isinstance(semantic, dict) else None
            if (verified.get('mode') != 'verify' or verified.get('error') or verified.get('exit_code') != 0
                    or verified.get('passed') != 42 or verified.get('failed') != 0
                    or verified.get('official_passed_all') is not True or verified.get('passed_all') is not True
                    or not isinstance(semantic, dict) or semantic.get('passed_all') is not True
                    or semantic.get('exit_code') != 0 or not isinstance(checks, list) or len(checks) != 6
                    or any(not isinstance(item, dict) or item.get('passed') is not True for item in checks)):
                issues.append('Latest correctness attempt failed official, semantic, or persistence validation.')
            verify_config = verified.get('configuration', {})
            if not isinstance(verify_config, dict) or any(verify_config.get(key) != value for key, value in required.items()):
                issues.append('Correctness attempt used a different workload configuration.')
            issues += database_issues(verified) + resource_issues(verified, profile)
        own = []
        for trial in range(1, expected_trials + 1):
            entry = dict(case_id=case, trial=trial, status='missing', issues=['No recorded attempt.'],
                         attempts=attempts[(case, trial)], completed=False, valid=False, clean=False)
            if (case, trial) in latest:
                position, record = latest[(case, trial)]
                problems = list(issues) + list(global_issues)
                problems += identity_issues(record, identity, fingerprint, candidate, inventory)
                problems += database_issues(record) + resource_issues(record, profile)
                metric_problems, cpu_us = measurement_issues(record, configuration, parse_wrk, invalid_trial)
                problems += metric_problems
                entry.update(record_index=position, completed=record.get('completed') is True,
                             issues=problems, raw_error=record.get('error'), valid=not problems,
                             commit=record.get('commit'), image_id=record.get('image_id'),
                             source_sha256=record.get('source_sha256'))
                if not problems:
                    entry.update({key: record[key] for key in METRICS if key != 'cpu_us_per_request'})
                    entry.update(cpu_us_per_request=cpu_us, requests=record['requests'],
                                 duration_s=record['duration_s'], http_errors=record['http_errors'],
                                 socket_errors=record['socket_errors'])
                    entry['clean'] = not entry['http_errors'] and not any(entry['socket_errors'].values())
                    entry['status'] = 'clean' if entry['clean'] else 'measured_with_errors'
                else:
                    entry['status'] = 'invalid'
                    entry['observed_http_errors'] = record.get('http_errors')
                    entry['observed_socket_errors'] = record.get('socket_errors')
            own.append(entry)
        complete = expected_trials > 0 and all(entry['completed'] for entry in own)
        valid = expected_trials > 0 and all(entry['valid'] for entry in own)
        clean = valid and all(entry['clean'] for entry in own)
        result = dict(case_id=case, role=candidate.get('experiment_role', ''),
                      local_variant=candidate.get('local_variant'), image_id=build.get('image_id'),
                      source_sha256=candidate.get('source_sha256'), expected_trials=expected_trials,
                      completed_trials=sum(entry['completed'] for entry in own),
                      valid_trials=sum(entry['valid'] for entry in own), clean_trials=sum(entry['clean'] for entry in own),
                      complete=complete, valid=valid, clean=clean, issues=issues,
                      status='clean' if clean else 'measured_with_errors' if valid else 'invalid' if complete else 'incomplete')
        if valid:
            for key in METRICS:
                result['median_' + key] = statistics.median(entry[key] for entry in own)
            result.update(rps_min=min(entry['successful_rps'] for entry in own),
                          rps_max=max(entry['successful_rps'] for entry in own),
                          http_errors=sum(entry['http_errors'] for entry in own),
                          socket_errors={key: sum(entry['socket_errors'][key] for entry in own) for key in SOCKET_KEYS})
        cases.append(result)
        trial_rows.extend(own)
    strict_valid = bool(cases) and not global_issues and all(row['valid'] for row in cases)
    all_clean = strict_valid and all(row['clean'] for row in cases)
    by_case = {row['case_id']: row for row in cases}
    selected = None
    selection = dict(promising=False, reason='Selection is performed only on the original six-case screening stage.')
    if kind == 'screening':
        expected_cases = TUNED | set(CONTROLS) | {REBUILT}
        if expected_trials != 3 or set(indexed) != expected_cases:
            selection['reason'] = 'Selection requires exactly the three original tuned cells and three controls, with three trials.'
        elif not strict_valid:
            selection['reason'] = 'No selection: not every screening case has three valid latest attempts.'
        elif not by_case[CONTROLS[0]]['clean'] or not by_case[REBUILT]['clean']:
            selection['reason'] = 'No selection: original/rebuilt PR26 controls must both be clean.'
        elif not any(by_case[case]['clean'] for case in TUNED):
            selection['reason'] = 'No selection: no tuned cell is clean in all three trials.'
        else:
            best = sorted((by_case[case] for case in TUNED if by_case[case]['clean']), key=lambda row: (-row['median_successful_rps'], row['case_id']))[0]
            original = by_case[CONTROLS[0]]['median_successful_rps']
            rebuilt = by_case[REBUILT]['median_successful_rps']
            selected = dict(case_id=best['case_id'], median_successful_rps=best['median_successful_rps'],
                            ratio_vs_original=best['median_successful_rps'] / original,
                            ratio_vs_rebuilt=best['median_successful_rps'] / rebuilt)
            selected['promising'] = selected['ratio_vs_original'] >= 1.05 and selected['ratio_vs_rebuilt'] >= 1.05
            selection = dict(promising=selected['promising'], reason=(
                'Highest clean tuned-cell median; >=5% above both original and rebuilt controls.' if selected['promising'] else
                'Highest clean tuned-cell median does not meet the >=5% trigger against both controls.'))
    pairs = []
    trial_index = {(row['case_id'], row['trial']): row for row in trial_rows}
    for case in indexed:
        for control in CONTROLS:
            if case == control or control not in indexed:
                continue
            rounds = []
            for trial in range(1, expected_trials + 1):
                a, b = trial_index[(case, trial)], trial_index[(control, trial)]
                clean = a['clean'] and b['clean']
                rounds.append(dict(trial=trial, valid=a['valid'] and b['valid'], clean=clean,
                                   ratio=a['successful_rps'] / b['successful_rps'] if a['valid'] and b['valid'] and b['successful_rps'] > 0 else None))
            full = bool(rounds) and all(row['clean'] for row in rounds)
            full_valid = bool(rounds) and all(row['valid'] for row in rounds)
            pairs.append(dict(candidate=case, control=control, complete_clean=full, complete_valid=full_valid,
                              valid_pairs=sum(row['valid'] for row in rounds),
                              clean_pairs=sum(row['clean'] for row in rounds),
                              wins=sum(row['valid'] and row['ratio'] is not None and row['ratio'] > 1 for row in rounds),
                              ties=sum(row['valid'] and row['ratio'] == 1 for row in rounds),
                              median_ratio=statistics.median(row['ratio'] for row in rounds) if full_valid and all(row['ratio'] is not None for row in rounds) else None,
                              rounds=rounds))
    return dict(schema_version=1, stage=kind, stage_directory=str(stage_dir), expected_trials=expected_trials,
                complete=bool(cases) and all(row['complete'] for row in cases), strict_valid=strict_valid,
                evidence_valid=strict_valid, all_clean=all_clean,
                global_issues=global_issues, cases=cases, trials=trial_rows, paired_comparisons=pairs,
                selected_candidate=selected, selection=selection,
                superseded_failed_attempts=superseded_failures,
                raw_measurement_records=len(measurements), latest_attempts=len(latest),
                environment=environment, input_sha256=input_hashes,
                interpretation='Descriptive tuning experiment, not statistical significance or an automatic #1 claim. Screening and confirmation are never pooled.',
                cpu_definition='CPU microseconds per completed request = 1e6 * sampled self+waited-child CPU delta / wrk completed requests; medians of per-trial values.',
                timeout_definition='wrk timeout counters count completed samples outside its two-second histogram range. They remain in throughput and are omitted from latency percentiles; HTTP/timeout counters can overlap.')


def markdown(summary):
    def number(value, places=0):
        return '—' if value is None else f'{value:,.{places}f}'

    lines = [f"# PR26 tuning — {summary['stage']}", '',
             f"{summary['expected_trials']} expected rounds per case; complete={summary['complete']}; evidence valid={summary['strict_valid']}; all counters clean={summary['all_clean']}.", '',
             'Same native ARM64, one server CPU/2 GiB, separate two-CPU load, wrk 2 threads/64 connections, fresh process/database, 2s warmup then 15s per trial.', '',
             summary['interpretation'], '',
             '| Case | Status | Clean / expected | Successful req/s median [range] | p95 ms | p99 ms | RSS MiB | CPU % | CPU µs/request | HTTP | Socket C/R/W/T |',
             '|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|']
    for row in summary['cases']:
        rate = number(row.get('median_successful_rps'))
        if row.get('rps_min') is not None:
            rate += f" [{number(row['rps_min'])}–{number(row['rps_max'])}]"
        socket = '/'.join(str(row['socket_errors'][key]) for key in SOCKET_KEYS) if 'socket_errors' in row else '—'
        lines.append(f"| {row['case_id']} | {row['status']} | {row['clean_trials']}/{row['expected_trials']} | {rate} | {number(row.get('median_p95_ms'), 3)} | {number(row.get('median_p99_ms'), 3)} | {number(row.get('median_rss_mib'), 2)} | {number(row.get('median_cpu_percent'), 1)} | {number(row.get('median_cpu_us_per_request'), 3)} | {row.get('http_errors', '—')} | {socket} |")
    lines += ['', summary['cpu_definition'], '', summary['timeout_definition'], '',
              '**Screen selection:** ' + summary['selection']['reason']]
    if summary['selected_candidate']:
        candidate = summary['selected_candidate']
        lines += ['', f"Selected `{candidate['case_id']}`: {candidate['ratio_vs_original']:.3f}× original; {candidate['ratio_vs_rebuilt']:.3f}× rebuilt. Promising={candidate['promising']}. The 5% trigger is a practical decision rule, not a significance test."]
    lines += ['', '| Candidate / control | Clean pairs | Wins | Median paired ratio | Per-round ratios |',
              '|---|---:|---:|---:|---|']
    for pair in summary['paired_comparisons']:
        ratios = ', '.join(f"{row['trial']}:{number(row['ratio'], 3)}{'*' if not row['clean'] else ''}" for row in pair['rounds'])
        lines.append(f"| {pair['candidate']} / {pair['control']} | {pair['clean_pairs']}/{summary['expected_trials']} | {pair['wins']} | {number(pair['median_ratio'], 3)} | {ratios} |")
    lines += ['', 'An asterisk marks an invalid/unclean pair. Ratios and wins use valid retained throughput even when counters are present; those comparisons are diagnostic. A paired median requires every expected pair to be valid. Counter-flagged leader runs are never called clean.', '', '**Failures and incomplete evidence**']
    failures = list(summary['global_issues'])
    for row in summary['cases']:
        failures += [row['case_id'] + ': ' + issue for issue in row['issues']]
    for row in summary['trials']:
        failures += [f"{row['case_id']} round {row['trial']}: {issue}" for issue in row['issues']]
        if row['status'] == 'measured_with_errors':
            failures.append(f"{row['case_id']} round {row['trial']}: HTTP={row['http_errors']}, sockets={row['socket_errors']}.")
    lines += [''] + (['- ' + issue.replace('\n', ' ').replace('|', '\\|') for issue in dict.fromkeys(failures)] or ['None.'])
    lines += ['', f"Latest attempts: {summary['latest_attempts']}; raw measurement attempts: {summary['raw_measurement_records']}; superseded failed/error attempts retained in JSON: {len(summary['superseded_failed_attempts'])}.",
              '', 'Original evidence files are never edited. `analysis-summary.json`, `analysis-cases.csv`, and `analysis-trials.csv` retain identities, validation details and trial data.', '']
    return '\n'.join(lines)


def write_outputs(summary, output_dir):
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    def safe(value):
        if isinstance(value, float) and not math.isfinite(value):
            return {'invalid_numeric_value': str(value)}
        if isinstance(value, dict):
            return {key: safe(item) for key, item in value.items()}
        if isinstance(value, list):
            return [safe(item) for item in value]
        return value

    text = json.dumps(safe(summary), indent=2, allow_nan=False) + '\n'
    (output_dir / 'analysis-summary.json').write_text(text)
    for name, records, fields in (
        ('analysis-cases.csv', summary['cases'], ['case_id', 'status', 'expected_trials', 'completed_trials', 'valid_trials', 'clean_trials',
                                                *['median_' + key for key in METRICS], 'rps_min', 'rps_max', 'http_errors', 'socket_errors',
                                                'image_id', 'source_sha256', 'issues']),
        ('analysis-trials.csv', summary['trials'], ['case_id', 'trial', 'record_index', 'attempts', 'status', 'completed', 'valid', 'clean',
                                                  *METRICS, 'requests', 'duration_s', 'http_errors', 'socket_errors',
                                                  'observed_http_errors', 'observed_socket_errors', 'commit', 'image_id', 'source_sha256',
                                                  'raw_error', 'issues'])):
        with (output_dir / name).open('w', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=fields, extrasaction='ignore')
            writer.writeheader()
            for row in records:
                writer.writerow({key: json.dumps(value, sort_keys=True) if isinstance(value, (dict, list)) else value
                                 for key, value in row.items()})
    (output_dir / 'analysis-report.md').write_text(markdown(summary))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', type=Path, default=ROOT, help='One stage evidence directory; never pool stages.')
    parser.add_argument('--output-dir', type=Path, help='Defaults to the selected stage directory.')
    parser.add_argument('--kind', choices=('screening', 'confirmation', 'followup'), help='Default: infer from configuration and case set.')
    parser.add_argument('--strict', action='store_true', help='Exit nonzero unless every expected latest attempt is valid; counters remain separately flagged.')
    args = parser.parse_args()
    summary = analyze_stage(args.stage, args.kind)
    write_outputs(summary, args.output_dir or args.stage)
    print(json.dumps(dict(stage=summary['stage'], complete=summary['complete'], strict_valid=summary['strict_valid'],
                          selected_candidate=summary['selected_candidate'], global_issues=summary['global_issues']), indent=2))
    if args.strict and not summary['strict_valid']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
