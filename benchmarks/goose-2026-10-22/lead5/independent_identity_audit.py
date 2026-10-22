"""Independent file-only identity/correctness audit of the selected holdout.

No Docker, HTTP, compilation, training, or benchmark calls. Only audit artifacts
are written; source, protocols, logs, verification and measurements stay intact.
"""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
PINNED = {
    'goose': dict(source_sha256='09e695a0652cc4654e12d5382b423adf75b7ea7c5ef18978313ddff3cc9d13ed',
                  image_id='sha256:d0a2f1e95817cefd26c9563d86849efff6cb2bb5dc0e2ff733ed7656577ef9ea',
                  binary_sha256='309f1138b9c5d6b404670a8c0eaf1d42c2f96d4fc7e30d7a89f5bff326a5af2e'),
    '82': dict(source_sha256='b91b9491e2a7a8856f8f360bc89f376b6493ae9b9a3907c557836b94f5131438',
               image_id='sha256:64227e803306084617be2a4ebc1c3623260d265f158dd8c009f647558a280135',
               binary_sha256='61d48f1be2feb858a14b1617cf3221bebf68df6caaac3541116e0dfbb7562026'),
    'baseline': dict(source_sha256='73148f5d49e07fc62289bf582e261b8df0e1ef51d478d6fb9d44a68fec87b88a',
                     image_id='sha256:a69064953b766ec5c800389b8e17a7d184f73aa8dd46cd4aa2048955ee86eb0f',
                     binary_sha256='f0b086e53343263381c55a9046dbd65f400c4ec5ebbfc872c5d682d20a5679ab'),
}
DRIVER = dict(image='twelve-load-wrk-monotonic:2026-10-22',
              image_id='sha256:a5e8736dcfaf72bf79c0196a89fe3fd49774916ab7ea4ce06a8a2cdfd3a4b504',
              binary_path='/opt/wrk-clock/bin/wrk',
              binary_sha256='20ec627b07490f94b7d1ed73e16ed64e04d993457ceacf4cb92fd66f93f7cb39')


def read(path, default=None):
    return json.loads(path.read_text()) if path.is_file() else default


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def save(path, value):
    temporary = path.with_suffix(path.suffix + '.partial')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def binary(build):
    proof = build.get('proof', {})
    return proof.get('binary_sha256', proof.get('files', {}).get('bin/server', {}).get('sha256'))


def audit(batch, complete=False):
    issues, checks = [], []

    def check(condition, label):
        checks.append(dict(check=label, passed=bool(condition)))
        if not condition:
            issues.append(label)

    rows = read(batch / 'measurements.json', [])
    manifest = {str(row['id']): row for row in read(batch / 'manifest.json', [])}
    builds = read(batch / 'build-status.json', {})
    shared = read(batch / 'shared-sha256.json', {})
    selected = read(batch / 'selection.json', {})
    environment = read(batch / 'environment-bench.json', {})
    verification = read(batch / 'verification.json', [])
    check(set(manifest) == set(builds) == set(PINNED), 'Exactly selected Goose, pinned Rust and retained Goose cases')
    check(sha(batch / 'run.py') == sha(ROOT / 'combined-like-bound/run.py'),
          'Unchanged tested controller enforces immutable image IDs, bench user, dedicated CPU allocations and workload command')
    check(shared == read(ROOT.parent / 'confirmation/shared-sha256.json'), 'Fixture/workload inventory matches pinned previous experiment')
    for name, digest in shared.items():
        check((batch / name).is_file() and sha(batch / name) == digest, 'Current shared bytes: ' + name)
    check(environment.get('shared_hashes') == shared, 'Runtime environment binds unchanged shared fixtures')
    for key, expected in dict(server_cpus='0', server_cpu_quota=1, server_memory='2g',
            server_memory_swap='2g', load_cpus='1,2', load_cpu_quota=2, load_memory='2g', nofile=65535).items():
        check(environment.get(key) == expected, 'Dedicated sequential environment: ' + key)
    config = environment.get('wrk', {})
    check(all(config.get(k) == v for k, v in dict(threads=2, connections=64, warmup_seconds=2,
          measurement_seconds=45).items()) and type(config.get('trials')) is int
          and 10 <= config['trials'] <= 12, 'Controller declares 10 planned rounds plus at most 2 replacements, 45 seconds, 2-second warmup, 2 threads/64 connections')
    check(selected.get('planned_confirmation') == dict(rounds=10, maximum_replacement_rounds=2,
          seconds=45, warmup_seconds=2, controls=['82', 'baseline']), 'Pre-holdout selection binds unchanged confirmation plan')
    bindings = {'manifest_sha256': batch / 'manifest.json', 'build_status_sha256': batch / 'build-status.json',
                'protocol_sha256': ROOT / 'PROTOCOL.md', 'declaration_sha256': ROOT / 'PROTOCOL-monotonic.md',
                'load_generator_sha256': batch / 'load-generator.json', 'verification_sha256': batch / 'verification.json',
                'parser_checks_sha256': batch / 'parser-checks.json', 'edge_checks_sha256': batch / 'edge-checks.json'}
    for field, path in bindings.items():
        check(selected.get(field) == sha(path), 'Selection binding: ' + field)
    diagnostic = ROOT / selected.get('selection_diagnostic', '')
    check(diagnostic.is_file() and selected.get('selection_diagnostic_sha256') == sha(diagnostic), 'Preselection diagnostic retained unchanged')
    check(selected.get('diagnostic_scope') == 'selection only; servers shared one guest CPU', 'Shared-CPU diagnostic explicitly excluded from holdout proof')
    check(selected.get('candidate') == dict(id='goose', **PINNED['goose']), 'Selected candidate exact source/image/binary identity')

    inventories, identities = {}, {}
    for cid in PINNED:
        row, build = manifest[cid], builds[cid]
        inventory = read(batch / row['source_hashes'], {})
        inventories[cid] = inventory
        check(canonical(inventory) == row.get('source_sha256') and len(inventory) == row.get('source_file_count'), cid + ': source inventory identity/count')
        for name, digest in inventory.items():
            path = batch / 'sources' / ('pr' + cid) / name
            check(path.is_file() and sha(path) == digest, cid + ': source bytes ' + name)
        identity = dict(source_sha256=row.get('source_sha256'), image_id=build.get('image_id'), binary_sha256=binary(build))
        identities[cid] = identity
        check(identity == PINNED[cid], cid + ': frozen pinned source/image/binary')
        check(build.get('exit_code') == 0 and build.get('commit') == row.get('commit'), cid + ': successful matching build')
        proof = build.get('proof', {})
        for field in ('source_snapshot_sha256', 'source_sha256'):
            if field in proof:
                check(proof[field] == row.get('source_sha256'), cid + ': image proof ' + field)
        if 'source_hashes' in proof:
            check(proof['source_hashes'] == inventory, cid + ': image/source inventory equality')
    check(manifest['82'].get('commit') == '95aa405a0003599dbc7fb4dfa47a09e8343239df', 'Rust exact unchanged upstream commit')
    live = REPO / 'submissions/goose-native-tbsvttr'
    for name, digest in inventories['goose'].items():
        check((live / name).is_file() and sha(live / name) == digest, 'Live selected source byte: ' + name)
    proof = builds['goose']['proof']
    check(proof.get('source_files_verified') == 19 and proof.get('sqlite_object_sha256') ==
          '2c5663ef60e2bbc9f87a54f05f8eca1057b64614f5ced6fc34591ed3ef3b2178', 'Selected 19-source image uses exact verified legacy SQLite PGO object')
    check(proof.get('sqlite_object_reused') is True and proof.get('normal_default_build') is False,
          'Selected build truthfully distinguishes explicit SQLite reuse from fresh normal reproduction')
    check(proof.get('production_training_symbols_absent') is True and proof.get('production_epoll_interposer_absent') is True,
          'Production contains no profile-dump helper/interposer')
    check(proof.get('application_pgo_profile_file_count') == 4 and proof.get('app_training_requests') == 16953,
          'Fresh four-unit application PGO training proof retained')
    origin_proof = read(ROOT / 'candidates/combined-like-bound/image-proof.json', {})
    check(proof == origin_proof, 'Selected complete image proof copied unchanged from tested candidate')
    reproduction_path = ROOT / 'candidates/selected-reproduction/image-proof.json'
    comparison_path = ROOT / 'candidates/selected-reproduction/comparison.json'
    reproduction, comparison = read(reproduction_path, {}), read(comparison_path, {})
    check(reproduction.get('normal_default_build') is True and reproduction.get('sqlite_object_reused') is False
          and reproduction.get('source_snapshot_sha256') == PINNED['goose']['source_sha256']
          and reproduction.get('source_hashes') == inventories['goose'], 'Separate fresh normal build uses exact selected source and no SQLite object reuse')
    check(comparison.get('selected_image_id') == PINNED['goose']['image_id']
          and comparison.get('selected_binary_sha256') == PINNED['goose']['binary_sha256']
          and comparison.get('reproduction_image_id') == reproduction.get('image_id')
          and comparison.get('reproduction_binary_sha256') == reproduction.get('binary_sha256')
          and comparison.get('binary_identical') == (reproduction.get('binary_sha256') == PINNED['goose']['binary_sha256']),
          'Normal rebuild comparison truthfully preserves different binary identity without replacing selected image')
    check(bool(reproduction.get('build_finished')) and dt.datetime.fromisoformat(reproduction['build_finished'].replace('Z', '+00:00'))
          < dt.datetime.fromisoformat(environment['recorded_at'].replace('Z', '+00:00')),
          'Heavy normal reproduction build finished before holdout environment/start')

    driver = read(batch / 'load-generator.json', {})
    runtime = read(ROOT / 'wrk-monotonic/runtime-proof.json', {})
    check(all(driver.get(k) == v and runtime.get(k) == v for k, v in DRIVER.items()), 'Driver image/executable identities match pinned corrected driver')
    check(environment.get('load_image') == DRIVER['image'] and environment.get('load_image_id') == DRIVER['image_id'], 'Every holdout case uses same corrected driver image')
    for label, expected in [('declaration', ROOT / 'PROTOCOL-monotonic.md'), ('proof', ROOT / 'wrk-monotonic/runtime-proof.json')]:
        reference = (batch / driver.get(label, '')).resolve()
        check(reference == expected.resolve() and driver.get(label + '_sha256') == sha(expected), 'Driver retained ' + label + ' path/hash')
    probes_path = ROOT / 'wrk-monotonic/runtime-probes.json'
    check(runtime.get('runtime_probes_sha256') == sha(probes_path), 'Runtime driver probe unchanged')
    probes = read(probes_path, {}).get('monotonic', {})
    check(probes.get('selected_executable', {}).get('stdout', '').strip() == DRIVER['binary_path']
          and probes.get('selected_sha256') == DRIVER['binary_sha256']
          and probes.get('path') == runtime.get('selected_path'), 'Actual retained PATH probe selected corrected executable')
    check(runtime.get('changed_source_files') == ['src/wrk.c'] and runtime.get('patch_sha256') ==
          sha(ROOT / 'wrk-monotonic/monotonic-clock-only.patch'), 'Declared clock-only source patch retained')
    mock = runtime.get('mock_clock_test', {})
    check(all(mock.get(k) == v for k, v in dict(passed=True, backward_step_stock_timeouts=1,
          backward_step_monotonic_timeouts=0, real_over_two_second_duration_counted_by_both=True,
          timeout_logic_unchanged=True, clock_functions_extracted_from_actual_sources=True).items()),
          'Driver proof retains real-duration timeout counters and deterministic clock-underflow evidence')

    origins = read(batch / 'verification-origin.json', [])
    check({o.get('case_id') for o in origins} == set(PINNED) and len(origins) == len(verification) == 3,
          'Exactly three inherited correctness records and origins')
    for origin in origins:
        cid = origin['case_id']
        previous = ROOT / origin['source_batch']
        check(sha(previous / 'verification.json') == origin['source_verification_sha256'], cid + ': original verification archive unchanged')
        preserved = batch / origin['preserved_record']
        check(sha(preserved) == origin['preserved_record_sha256'], cid + ': preserved original record hash')
        record = next(v for v in verification if v['case_id'] == cid)
        original = next(v for v in read(previous / 'verification.json', []) if v['case_id'] == cid)
        check(record == read(preserved) == original, cid + ': inherited record byte-value identical to original')
        check(record.get('passed_all') and record.get('official_passed_all') and record.get('exit_code') == 0
              and record.get('passed') == 42 and record.get('failed') == 0
              and re.search(r'passed=42 failed=0', record.get('output', '')) is not None,
              cid + ': original raw official 42/42 result')
        semantic = record.get('semantic', {})
        raw_semantic = json.loads(record.get('semantic_output', '{}'))
        check(semantic.get('passed_all') is True and semantic.get('exit_code') == 0
              and bool(semantic.get('checks')) and all(v.get('passed') for v in semantic.get('checks', []))
              and raw_semantic.get('checks') == semantic.get('checks'), cid + ': raw semantic roundtrip proof')
        log = batch / 'logs' / ('verify-' + cid + '-1.log')
        check(sha(log) == origin['raw_log_sha256'] == sha(previous / 'logs' / ('verify-' + cid + '-1.log')),
              cid + ': original raw correctness log preserved')
    supplements = {}
    for name, count in [('edge-checks.json', 25), ('parser-checks.json', 18), ('above-max-checks.json', 9)]:
        record = read(batch / name, {})
        check(sha(batch / name) == sha(ROOT / 'combined-like-bound' / name), 'Supplemental exact tested original: ' + name)
        check(record.get('image_id') == PINNED['goose']['image_id'] and record.get('passed_all') is True
              and record.get('passed') == count and len(record.get('checks', [])) == count
              and all(v.get('passed') for v in record.get('checks', [])) and record.get('uid') == 1001
              and record.get('source_app_verified') is True and record.get('runtime_backend_verified') is True,
              'Supplemental exact image/source/backend and all checks: ' + name)
        supplements[name] = dict(sha256=sha(batch / name), passed=count)

    seccomp = read(batch / 'seccomp-io-uring.json')
    def record_checks(record):
        cid = record['case_id']
        row, build = manifest[cid], builds[cid]
        label = str(record.get('mode')) + ' ' + cid + ' round ' + str(record.get('trial'))
        expected = dict(case_id=cid, pr=row['pr'], commit=row['commit'], image=build['image'],
                        image_id=build['image_id'], source_sha256=row['source_sha256'], shared_hashes=shared)
        check(all(record.get(k) == v for k, v in expected.items()) and record.get('fingerprint') == canonical(expected), label + ': exact case fingerprint')
        service = record.get('service', {})
        check(service.get('ready') is True and service.get('source_sha256') == row['source_sha256']
              and service.get('source_files_verified') == row['source_file_count'] and service.get('initial_post_count') == 500000,
              label + ': fresh pinned source and 500000-post database readiness')
        host = record.get('container_host_config', {})
        check(all(host.get(k) == v for k, v in dict(CpusetCpus='0', NanoCpus=1000000000,
              Memory=2147483648, MemorySwap=2147483648).items()), label + ': actual server CPU/memory limits')
        limits = [v for v in host.get('Ulimits', []) if v.get('Name') == 'nofile']
        check(len(limits) == 1 and limits[0].get('Soft') == limits[0].get('Hard') == 65535, label + ': actual nofile limits')
        profiles = [json.loads(v.split('=', 1)[1]) for v in host.get('SecurityOpt', []) if v.startswith('seccomp=')]
        check(profiles == [seccomp], label + ': actual seccomp profile')
        state = record.get('container_state', {})
        check(not state.get('OOMKilled') and not state.get('Dead') and not state.get('Error'), label + ': no OOM/death/container error')
        databases = [v['database_after'] for v in record.get('final', []) if 'database_after' in v]
        db = databases[0] if len(databases) == 1 else {}
        check(record.get('database_valid') is True and db.get('integrity') == 'ok' and db.get('initial_post_count') == 500000
              and db.get('post_count', 0) > 500000 and db.get('max_post_id', 0) > 500000,
              label + ': post-shutdown SQLite quick_check and committed write growth')
        log = batch / 'logs' / (str(record.get('mode')) + '-' + cid + '-' + str(record.get('trial')) + '.log')
        check(log.is_file() and log.read_text() == record.get('output', '') + record.get('stderr', '') + record.get('error', ''), label + ': complete original raw output retained')
        server_log = batch / 'server-logs' / (str(record.get('mode')) + '-' + cid + '-' + str(record.get('trial')) + '.log')
        text = server_log.read_text() if server_log.is_file() else ''
        marker = 'io_uring' if cid == '82' else 'Goose native transport: epoll'
        check(marker in text, label + ': actual backend retained in server log')
        if record.get('mode') == 'bench':
            check(bool(selected.get('recorded_at')) and selected['recorded_at'] < record.get('recorded_at', ''), label + ': candidate selected before throughput')
            good = [v for v in verification if v.get('fingerprint') == record.get('fingerprint')]
            check(any(v.get('recorded_at', '') < record.get('recorded_at', '')
                      and v.get('after', {}).get('monotonic', float('inf')) <= record.get('before', {}).get('monotonic', -1)
                      for v in good), label + ': matching correctness finished before throughput')
            config = record.get('configuration', {})
            check(all(config.get(k) == v for k, v in dict(threads=2, connections=64, warmup_seconds=2,
                  measurement_seconds=45).items()) and type(config.get('trials')) is int
                  and 10 <= config['trials'] <= 12, label + ': exact planned duration/load configuration and bounded round plan')
            for key, seconds in [('output', 45), ('warmup_output', 2)]:
                raw = record.get(key, '')
                check(re.search(r'Running ' + str(seconds) + r's test @ http://127\.0\.0\.1:24000/feed', raw)
                      is not None and re.search(r'2 threads and 64 connections', raw) is not None,
                      label + ': raw ' + key + ' confirms requested duration/URL/threads/connections')
            if cid == 'goose':
                check('SQLite memory: cache_kib=8192 mmap_mib=0' in text, label + ': selected runtime cache/mmap config')
    for record in verification + rows:
        record_checks(record)

    observed_path = batch / 'independent-identity-observed-prefix.json'
    observed = read(observed_path, {})
    hashes = [canonical(record) for record in rows]
    previous = observed.get('record_hashes', [])
    prefix_unchanged = hashes[:len(previous)] == previous
    check(prefix_unchanged, 'Every measurement record observed earlier remains unchanged as an exact prefix')
    frozen = {field: sha(path) for field, path in bindings.items()}
    frozen.update(selection_sha256=sha(batch / 'selection.json'),
                  controller_sha256=sha(batch / 'run.py'),
                  normal_reproduction_proof_sha256=sha(reproduction_path),
                  normal_reproduction_comparison_sha256=sha(comparison_path),
                  verification_origin_sha256=sha(batch / 'verification-origin.json'),
                  above_max_checks_sha256=sha(batch / 'above-max-checks.json'))
    frozen_unchanged = all(frozen.get(key) == value for key, value in observed.get('frozen_artifact_hashes', {}).items())
    check(frozen_unchanged, 'Selection/protocol/source-build/driver/correctness bindings stay unchanged after first observation')
    if prefix_unchanged and frozen_unchanged and (not previous or len(hashes) >= len(previous)):
        save(observed_path, dict(record_count=len(rows), record_hashes=hashes,
             frozen_artifact_hashes=frozen,
             updated_at=dt.datetime.now(dt.timezone.utc).isoformat()))
    if complete:
        check(30 <= len(rows) <= 36, 'Final attempt count is within ten rounds plus at most two complete replacements')
    return dict(purpose='Independent source/image/driver/fixture/correctness identity audit; file-only',
        recorded_at=dt.datetime.now(dt.timezone.utc).isoformat(), complete=complete,
        evidence_passed_all=not issues, issues=issues, checks=checks, identities=identities,
        measurement_count=len(rows), measurements_sha256=sha(batch / 'measurements.json') if rows else None,
        verification_sha256=sha(batch / 'verification.json'), selection_sha256=sha(batch / 'selection.json'),
        supplemental_proofs=supplements, auditor_sha256=sha(Path(__file__)),
        normal_reproduction=dict(image_id=reproduction.get('image_id'), binary_sha256=reproduction.get('binary_sha256'),
             source_sha256=reproduction.get('source_snapshot_sha256'), comparison_sha256=sha(comparison_path),
             measured=False, binary_identical_to_selected=comparison.get('binary_identical')),
        limitations=['Image/binary and driver execution identities use retained immutable image/runtime proofs; this reviewer runs no new containers.',
          'Inherited correctness records retain original timestamps and bytes; these are not newly executed tests.',
          'A separate full normal source build succeeds but produces different SQLite feedback/object and binary bytes. It is unmeasured and does not replace the selected frozen image.',
          'Statistics, whole-triplet selection and target gates are independently audited in independent-statistics-audit.json.'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('batch', type=Path)
    parser.add_argument('--complete', action='store_true')
    args = parser.parse_args()
    batch = args.batch.resolve()
    result = audit(batch, args.complete)
    save(batch / 'independent-identity-audit.json', result)
    print(json.dumps({key: result[key] for key in ('complete', 'evidence_passed_all', 'measurement_count', 'issues')}, indent=2))
    return 0 if result['evidence_passed_all'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
