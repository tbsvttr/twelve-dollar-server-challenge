"""Evaluate the predeclared holdout, retaining all attempts and invalid rounds."""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import statistics

ROOT = Path(__file__).resolve().parent
HELPERS_PATH = ROOT.parent / 'optimization/audit.py'
spec = importlib.util.spec_from_file_location('holdout_evidence_helpers', HELPERS_PATH)
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)
PINNED = {
    '82': dict(commit='95aa405a0003599dbc7fb4dfa47a09e8343239df',
               image_id='sha256:64227e803306084617be2a4ebc1c3623260d265f158dd8c009f647558a280135',
               binary_sha256='61d48f1be2feb858a14b1617cf3221bebf68df6caaac3541116e0dfbb7562026'),
    'baseline': dict(source_sha256='73148f5d49e07fc62289bf582e261b8df0e1ef51d478d6fb9d44a68fec87b88a',
                     image_id='sha256:a69064953b766ec5c800389b8e17a7d184f73aa8dd46cd4aa2048955ee86eb0f',
                     binary_sha256='f0b086e53343263381c55a9046dbd65f400c4ec5ebbfc872c5d682d20a5679ab'),
}
ORIGINAL_LOAD = dict(
    image_id='sha256:901ab577025cfdcf7abc716fb4158774615b881383529bb77163b5f07f963898',
    binary_path='/usr/bin/wrk',
    binary_sha256='55157ab26d15f39e68d80ed3e16240dcdcb1722abf0fa7d74bfd3e20dd50254c')
MONOTONIC_LOAD = dict(
    image_id='sha256:a5e8736dcfaf72bf79c0196a89fe3fd49774916ab7ea4ce06a8a2cdfd3a4b504',
    binary_path='/opt/wrk-clock/bin/wrk',
    binary_sha256='20ec627b07490f94b7d1ed73e16ed64e04d993457ceacf4cb92fd66f93f7cb39')


def parse_output(output):
    # Recompute from raw text independently of the controller's stored metrics.
    return evidence.raw_wrk(output)


def read(path, default=None):
    return json.loads(path.read_text()) if path.is_file() else default


def identity(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def binary_hash(build):
    proof = build.get('proof', {})
    return proof.get('binary_sha256', proof.get('files', {}).get('bin/server', {}).get('sha256'))


def load_generator_issues(root, environment, selection):
    """Allow the original driver or this one explicitly declared correction."""
    issues = []
    load_id = environment.get('load_image_id')
    path = root / 'load-generator.json'
    record = read(path)
    if load_id == ORIGINAL_LOAD['image_id'] and record is None:
        return issues, dict(mode='original', **ORIGINAL_LOAD)
    if load_id not in (ORIGINAL_LOAD['image_id'], MONOTONIC_LOAD['image_id']):
        return ['unrecognized load-generator image'], dict(mode='unrecognized', image_id=load_id)
    expected = MONOTONIC_LOAD if load_id == MONOTONIC_LOAD['image_id'] else ORIGINAL_LOAD
    details = dict(mode='declared_monotonic' if expected is MONOTONIC_LOAD else 'original', **expected)
    if not isinstance(record, dict):
        return ['load-generator.json missing or invalid'], details
    for key, value in expected.items():
        if record.get(key) != value:
            issues.append('load-generator record differs: ' + key)
    if record.get('image') != environment.get('load_image'):
        issues.append('load-generator image tag differs from run environment')
    record_sha = hashlib.sha256(path.read_bytes()).hexdigest()
    details['record_sha256'] = record_sha
    if selection.get('load_generator_sha256') != record_sha:
        issues.append('pre-holdout selection does not bind load-generator record')
    if expected is ORIGINAL_LOAD:
        if any(key in record for key in ('declaration', 'proof')):
            issues.append('original load-generator record unexpectedly declares a correction')
        return issues, details

    for name, required in [('declaration', ROOT / 'PROTOCOL-monotonic.md'),
                           ('proof', ROOT / 'wrk-monotonic/runtime-proof.json')]:
        try:
            referenced = (root / record.get(name, '')).resolve()
            if referenced != required.resolve() or not referenced.is_file():
                raise ValueError('missing or unexpected path')
            digest = hashlib.sha256(referenced.read_bytes()).hexdigest()
            if record.get(name + '_sha256') != digest:
                raise ValueError('file hash differs from record')
            details[name + '_sha256'] = digest
        except (OSError, TypeError, ValueError) as error:
            issues.append('load-generator ' + name + ': ' + str(error))
    if selection.get('declaration_sha256') != details.get('declaration_sha256') or 'declaration_sha256' not in details:
        issues.append('pre-holdout selection does not bind monotonic declaration')
    proof = read(ROOT / 'wrk-monotonic/runtime-proof.json', {})
    for key, value in dict(image=record.get('image'), **MONOTONIC_LOAD).items():
        if proof.get(key) != value:
            issues.append('load-generator runtime proof differs: ' + key)
    # selected_path in the retained proof is the PATH environment string;
    # the separately hashed runtime probe records command -v and binary SHA.
    probes_path = ROOT / 'wrk-monotonic/runtime-probes.json'
    if (proof.get('runtime_probes_file') != probes_path.name or not probes_path.is_file()
            or proof.get('runtime_probes_sha256') != hashlib.sha256(probes_path.read_bytes()).hexdigest()):
        issues.append('runtime executable-selection probe missing or changed')
    probes = read(probes_path, {}).get('monotonic', {})
    selected = probes.get('selected_executable', {})
    if (selected.get('exit_code') != 0 or selected.get('stdout', '').strip() != MONOTONIC_LOAD['binary_path']
            or probes.get('selected_sha256') != MONOTONIC_LOAD['binary_sha256']
            or proof.get('selected_path') != probes.get('path')):
        issues.append('runtime PATH did not select declared wrk executable')
    if proof.get('changed_source_files') != ['src/wrk.c']:
        issues.append('runtime proof does not establish the bounded clock patch')
    patch = ROOT / 'wrk-monotonic/monotonic-clock-only.patch'
    if not patch.is_file() or proof.get('patch_sha256') != hashlib.sha256(patch.read_bytes()).hexdigest():
        issues.append('runtime proof clock patch hash differs')
    mock = proof.get('mock_clock_test', {})
    for key, value in dict(passed=True, backward_step_stock_timeouts=1,
            backward_step_monotonic_timeouts=0, real_over_two_second_duration_counted_by_both=True,
            timeout_logic_unchanged=True, clock_functions_extracted_from_actual_sources=True).items():
        if mock.get(key) != value:
            issues.append('load-generator deterministic proof differs: ' + key)
    return issues, details


def record_identity(record, row, build, shared):
    expected = dict(case_id=str(row['id']), pr=row['pr'], commit=row['commit'],
                    image=build.get('image'), image_id=build.get('image_id'),
                    source_sha256=row['source_sha256'], shared_hashes=shared)
    issues = ['identity mismatch: ' + key for key, value in expected.items() if record.get(key) != value]
    if record.get('fingerprint') != identity(expected):
        issues.append('fingerprint mismatch')
    return issues


def log_problems(root, row):
    suffix = re.sub('[^a-zA-Z0-9_.-]', '-', str(row['case_id']))
    path = root / 'logs' / f"{row.get('mode')}-{suffix}-{row.get('trial')}.log"
    raw = row.get('output', '') + row.get('stderr', '') + row.get('error', '')
    return [] if path.is_file() and path.read_text() == raw else ['raw log missing or differs']


def problems(row, seconds):
    issues = []
    if row.get('error'): issues.append(row['error'])
    for key in ('completed', 'database_valid', 'valid_duration'):
        if not row.get(key): issues.append(key + ' failed')
    if row.get('http_errors', 0): issues.append('HTTP errors')
    if any(row.get('socket_errors', {}).values()): issues.append('socket errors')
    config = row.get('configuration', {})
    if any(config.get(key) != value for key, value in
           {'threads': 2, 'connections': 64, 'warmup_seconds': 2,
            'measurement_seconds': seconds}.items()):
        issues.append('measurement configuration mismatch')
    if not seconds - .5 <= row.get('duration_s', 0) <= seconds + 2:
        issues.append('raw duration outside tolerance')
    if not 0 < row.get('rss_mib', 0) < 2048: issues.append('memory bound')
    host = row.get('container_host_config', {})
    if (host.get('CpusetCpus') != '0' or host.get('NanoCpus') != 1000000000
            or host.get('Memory') != 2147483648 or host.get('MemorySwap') != 2147483648):
        issues.append('server resource limits')
    try:
        decoded = parse_output(row['output'])
        for key in ('requests', 'duration_s', 'rps', 'successful_rps', 'p50_ms', 'p95_ms', 'p99_ms', 'http_errors', 'socket_errors'):
            if decoded[key] != row.get(key): issues.append('raw output differs: ' + key)
        before, after = row['before'], row['after']
        first, _ = evidence.process_sample(before)
        last, rss = evidence.process_sample(after)
        elapsed = after['monotonic'] - before['monotonic']
        if elapsed <= 0 or last < first or rss <= 0:
            raise ValueError('invalid sampled interval/CPU/RSS')
        if not evidence.equal(row.get('rss_mib'), rss / 1024):
            issues.append('sampled RSS differs')
        if not evidence.equal(row.get('cpu_percent'), 100 * (last - first) / elapsed):
            issues.append('sampled CPU differs')
        warmup = parse_output(row['warmup_output'])
        if warmup['http_errors'] or any(warmup['socket_errors'].values()):
            issues.append('warmup HTTP/socket errors')
    except Exception as error:
        issues.append('raw output parsing: ' + str(error))
    return issues


def evaluate(root, candidate):
    rows = read(root / 'measurements.json', [])
    manifest = {str(row['id']): row for row in read(root / 'manifest.json', [])}
    builds = read(root / 'build-status.json', {})
    cases = [candidate, '82', 'baseline']
    protocol_issues = []
    if len(set(cases)) != 3 or set(manifest) != set(cases):
        protocol_issues.append('holdout must contain exactly one candidate, Rust and retained Goose')
    if not all(case in manifest and case in builds for case in cases):
        raise ValueError('missing required manifest/build record')
    shared = read(root / 'shared-sha256.json', {})
    pinned_shared = read(ROOT.parent / 'confirmation/shared-sha256.json', {})
    if not shared or shared != pinned_shared:
        protocol_issues.append('shared workload/fixtures differ from pinned experiment')
    for name, expected in shared.items():
        path = root / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            protocol_issues.append('current shared file differs: ' + name)
    environment = read(root / 'environment-bench.json', {})
    if environment.get('shared_hashes') != shared:
        protocol_issues.append('environment shared hashes differ')
    for key, expected in dict(server_cpus='0', server_cpu_quota=1, server_memory='2g',
            server_memory_swap='2g', load_cpus='1,2', load_cpu_quota=2, load_memory='2g', nofile=65535).items():
        if environment.get(key) != expected:
            protocol_issues.append('environment resource differs: ' + key)
    seccomp = read(root / 'seccomp-io-uring.json', {})
    verification = read(root / 'verification.json', [])
    valid_verification = {}
    identities = {}
    supplemental = {}
    for case in cases:
        row, build = manifest[case], builds[case]
        source = root / 'sources' / ('pr' + case)
        hashes = read(root / row['source_hashes'], {})
        try:
            actual = {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in hashes}
        except OSError:
            actual = {}
        if not hashes or actual != hashes or identity(actual) != row['source_sha256'] or len(hashes) != row.get('source_file_count'):
            protocol_issues.append(case + ': source mismatch')
        if build.get('exit_code') != 0 or build.get('commit') != row.get('commit'):
            protocol_issues.append(case + ': successful matching build missing')
        binary = binary_hash(build)
        if not re.fullmatch('[0-9a-f]{64}', str(binary or '')):
            protocol_issues.append(case + ': binary hash missing')
        proof = build.get('proof', {})
        for key in ('source_snapshot_sha256', 'source_sha256'):
            if key in proof and proof[key] != row['source_sha256']:
                protocol_issues.append(case + ': image/source proof differs')
        if 'source_hashes' in proof and proof['source_hashes'] != hashes:
            protocol_issues.append(case + ': image source hashes differ')
        identities[case] = dict(source_sha256=row['source_sha256'], image_id=build.get('image_id'), binary_sha256=binary)
        for key, expected in PINNED.get(case, {}).items():
            actual_value = row.get(key) if key in ('commit', 'source_sha256') else build.get(key) if key == 'image_id' else binary
            if actual_value != expected:
                protocol_issues.append(case + ': pinned control differs: ' + key)
        valid_verification[case] = []
        for check in verification:
            if check.get('case_id') != case or record_identity(check, row, build, shared):
                continue
            issues = (evidence.audit_record(check, row, build, shared, seccomp)
                      + evidence.official_issues(check) + evidence.backend_issues(root, check, row, build)
                      + log_problems(root, check))
            if not issues and check.get('mode') == 'verify':
                valid_verification[case].append(check)
        if not valid_verification[case]:
            protocol_issues.append(case + ': no raw-verified identity-matched correctness/semantic/database proof')
        if case == candidate:
            issues, proofs = evidence.supplemental(root, row, build, hashes, shared)
            protocol_issues.extend(case + ': ' + issue for issue in issues)
            supplemental = proofs

    # This record is created once after candidate selection and before holdout.
    selection = read(root / 'selection.json', {})
    load_issues, load_generator = load_generator_issues(root, environment, selection)
    protocol_issues.extend(load_issues)
    expected_candidate = dict(id=candidate, **identities[candidate])
    if selection.get('candidate') != expected_candidate:
        protocol_issues.append('pre-holdout candidate selection missing or differs')
    for field, path in [('manifest_sha256', root / 'manifest.json'),
                        ('build_status_sha256', root / 'build-status.json'),
                        ('protocol_sha256', ROOT / 'PROTOCOL.md')]:
        if selection.get(field) != hashlib.sha256(path.read_bytes()).hexdigest():
            protocol_issues.append('pre-holdout selection differs: ' + field)
    if not selection.get('recorded_at') or any(not row.get('recorded_at') or selection['recorded_at'] > row['recorded_at'] for row in rows):
        protocol_issues.append('candidate selection not recorded before all throughput attempts')

    trials = sorted({row.get('trial') for row in rows if type(row.get('trial')) is int and row['trial'] > 0})
    if any(type(row.get('trial')) is not int or row['trial'] < 1 for row in rows):
        protocol_issues.append('invalid round identifier')
    if trials != list(range(1, max(trials, default=0) + 1)):
        protocol_issues.append('attempted rounds are not contiguous from one')
    matched, excluded, attempts = [], [], []
    candidate_invalid = []
    totals = {case: dict(http_errors=0, socket_errors=0, warmup_http_errors=0, warmup_socket_errors=0) for case in cases}
    for trial in trials:
        group = [row for row in rows if row.get('trial') == trial]
        issues = {}
        if sorted(str(row.get('case_id')) for row in group) != sorted(cases):
            issues['round'] = ['incomplete or duplicate matched round']
            protocol_issues.append(f'round {trial}: incomplete or duplicate matched triplet')
        for run in group:
            case = run.get('case_id')
            if case not in cases:
                protocol_issues.append(f'round {trial}: unexpected case {case}')
                continue
            row, build = manifest[case], builds[case]
            identity_issues = record_identity(run, row, build, shared) + log_problems(root, run)
            if identity_issues:
                protocol_issues.extend(f'{case} round {trial}: ' + issue for issue in identity_issues)
            current = (identity_issues + problems(run, 45)
                       + evidence.audit_record(run, row, build, shared, seccomp)
                       + evidence.backend_issues(root, run, row, build))
            if run.get('mode') != 'bench':
                current.append('record mode is not bench')
            if not any(check.get('recorded_at', '') <= run.get('recorded_at', '') and
                       check.get('after', {}).get('monotonic', math.inf) <= run.get('before', {}).get('monotonic', -math.inf)
                       for check in valid_verification[case]):
                current.append('matching correctness did not precede throughput')
            decoded, warmup = {}, {}
            try:
                decoded = parse_output(run.get('output', ''))
                warmup = parse_output(run.get('warmup_output', ''))
            except (ValueError, KeyError, TypeError):
                pass
            totals[case]['http_errors'] += decoded.get('http_errors', run.get('http_errors', 0))
            totals[case]['socket_errors'] += sum(decoded.get('socket_errors', run.get('socket_errors', {})).values())
            totals[case]['warmup_http_errors'] += warmup.get('http_errors', 0)
            totals[case]['warmup_socket_errors'] += sum(warmup.get('socket_errors', {}).values())
            current = sorted(set(current))
            if current:
                issues[case] = current
                if case == candidate:
                    candidate_invalid.append(trial)
            attempts.append(dict(trial=trial, case_id=case, issues=current,
                raw=decoded, warmup=warmup, rss_mib=run.get('rss_mib'), cpu_percent=run.get('cpu_percent')))
        if issues:
            excluded.append(dict(trial=trial, issues=issues))
        else:
            matched.append(group)
    clean = matched[:10]
    selected_trials = [group[0]['trial'] for group in clean]
    for attempt in attempts:
        attempt['included_in_comparison'] = attempt['trial'] in selected_trials
    paired = [dict(trial=group[0]['trial'],
        rps={run['case_id']: parse_output(run['output'])['successful_rps'] for run in group},
        p99_ms={run['case_id']: parse_output(run['output'])['p99_ms'] for run in group}) for group in clean]
    ratios = [pair['rps'][candidate] / pair['rps']['82'] for pair in paired]
    for pair, ratio in zip(paired, ratios):
        pair['candidate_rust_ratio'] = ratio
    logs = list(map(math.log, ratios))
    mean = statistics.mean(logs) if logs else None
    # Exactly the first ten clean rounds: one-sided 95% Student-t, df=9.
    lower = math.exp(mean - 1.833112932653633 * statistics.stdev(logs) / math.sqrt(10)) if len(logs) == 10 else None
    median_p99 = {case: statistics.median(pair['p99_ms'][case] for pair in paired) for case in cases} if paired else {}
    error_trials = [attempt['trial'] for attempt in attempts if attempt['case_id'] == candidate and
                    any(attempt[phase].get('http_errors', 0) or any(attempt[phase].get('socket_errors', {}).values())
                        for phase in ('raw', 'warmup'))]
    gates = dict(evidence_checks=not protocol_issues, ten_clean_rounds=len(clean) == 10,
        replacement_limit=len(excluded) <= 2 and len(trials) <= 12 and max(trials, default=0) <= 12,
        zero_candidate_errors_in_all_attempts=not error_trials,
        candidate_valid_in_all_attempts=not candidate_invalid,
        geometric_mean_at_least_5_percent=mean is not None and math.exp(mean) >= 1.05,
        one_sided_95_percent_lower_bound_at_least_5_percent=lower is not None and lower >= 1.05,
        nine_of_ten_pairs_at_least_5_percent=sum(r > 1.05 for r in ratios) >= 9,
        median_p99_within_5_percent_of_rust=bool(median_p99) and median_p99[candidate] <= median_p99['82'] * 1.05)
    return dict(passed_all=all(gates.values()), gates=gates,
        geometric_mean_ratio=math.exp(mean) if mean is not None else None,
        one_sided_95_percent_lower_ratio=lower, t_degrees_of_freedom=9, one_sided_confidence=.95,
        protocol_issues=protocol_issues, candidate_error_trials=error_trials,
        candidate_invalid_attempt_trials=candidate_invalid, all_attempts=len(rows),
        attempted_rounds=trials, selected_rounds=selected_trials, clean_rounds_available=len(matched),
        excluded_rounds=excluded, paired_rounds=paired, median_p99_ms=median_p99,
        all_attempt_error_totals=totals, attempts=attempts, identities=identities,
        supplemental_proofs=supplemental, shared_hashes=shared,
        load_generator=load_generator,
        analyzer_helper_sha256=hashlib.sha256(HELPERS_PATH.read_bytes()).hexdigest())


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('batch', type=Path)
    ap.add_argument('--candidate', default='goose')
    ap.add_argument('--strict', action='store_true', help='Exit nonzero unless every predeclared gate passes')
    args = ap.parse_args()
    root = args.batch.resolve()
    summary = evaluate(root, args.candidate)
    (root/'holdout-summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    print(json.dumps(summary, indent=2))
    return 0 if not args.strict or summary['passed_all'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
