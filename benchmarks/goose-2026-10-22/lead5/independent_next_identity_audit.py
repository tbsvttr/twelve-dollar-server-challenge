"""Independent file-only identity/correctness audit of the distinct feed/HMAC holdout.

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
    'goose': dict(source_sha256='3a5271f6162b7f53487a5e756da4d43c92ed7027db08f9b21f6a21b1b65317ba',
                  image_id='sha256:65583483e06c442bb34bed51560d93b4c9690ca85c46b56caea92a3dbf3d1421',
                  binary_sha256='0ec54da7ff328bcf5de309a5f95f58e984c91a453cf5b2034f7b5d0fe094ac54'),
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

APP_PIN = '7b739ebc5ce7bf14a3a7cdfa9090813680874af9cdf01a0bdf31cc30862ed417'
DB_PIN = '425bfd09e1729a5578393a61884997104e76eee467434fffb83946c1273429f7'
HISTORY = {
    "analyze_holdout.py": "a759420725083ecc24e4a132eeb5633a2849faa8eb21152ca48641e30fa895d1",
    "audit_holdout_statistics.py": "9508741fae4d336a913b43891f0b1307ab6c792daa050aab08febd1cc53451f8",
    "holdout-selected/RESULT.md": "77587b0f2a620d05e269276d5c0180ac659ef15ff4c351f169a5e56cd47721d3",
    "holdout-selected/finalholdout-summary.json": "fcc6590cd3fd4f8d7bb518521d4d8fd434a540a1e1503723d1586996d279a8ae",
    "holdout-selected/holdout-complete.json": "aefedd73b977e776734389377dcd7ebef16a0ecb39db7201c7c19c2424d5aa89",
    "holdout-selected/holdout-summary.json": "fcc6590cd3fd4f8d7bb518521d4d8fd434a540a1e1503723d1586996d279a8ae",
    "holdout-selected/independent-audit.json": "b9008c2c69581ec350a21b2b77b2f8c9ec455160fbb7dd003de9fe8d55d3afba",
    "holdout-selected/independent-identity-audit.json": "88c75c7de68d97039c44935ffe05fd2d27412e811e5577ab1bc3ad2e9922f762",
    "holdout-selected/independent-statistics-audit.json": "9b52d52eec5dd0a02c76b9dd215217e24528e762cc83a119104e9fcdd5b9ea20",
    "holdout-selected/measurements.json": "99ff301c0c7231105f57441479f20789cc5cad1ecccdcc432a700107639eb4b1",
    "holdout-selected/report-consistency-audit.json": "32d20b6d727e23753384a43d909d72d7a40e2a0c4a7c69d29ed4218ed093c6d3",
    "holdout-selected/selection.json": "1421ddc8f3de969a01e9a71fc23f141d2fe5c5a4016b25d84662f7b5e7c92939",
    "independent_identity_audit.py": "3ca10ef3b6f28a2642d91bf7cb271a2cec62a091d3b5181fe037417160aaed38",
    "merge_holdout_audits.py": "01c021e3beae97222877bed9e50aa475c85e14647819e026950efc766ded861b"
}


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
    check(sha(batch / 'run.py') == sha(ROOT / 'feed-hmac-checks/run.py'),
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
                'protocol_sha256': ROOT / 'PROTOCOL.md', 'candidate_protocol_sha256': ROOT / 'PROTOCOL-feed-hmac.md',
                'declaration_sha256': ROOT / 'PROTOCOL-monotonic.md',
                'load_generator_sha256': batch / 'load-generator.json', 'verification_sha256': batch / 'verification.json',
                'parser_checks_sha256': batch / 'parser-checks.json', 'edge_checks_sha256': batch / 'edge-checks.json'}
    for field, path in bindings.items():
        check(selected.get(field) == sha(path), 'Selection binding: ' + field)
    check((batch / selected.get('additional_protocol', '')).resolve() == (ROOT / 'PROTOCOL-feed-hmac.md').resolve()
          and selected.get('additional_protocol_sha256') == sha(ROOT / 'PROTOCOL-feed-hmac.md')
          == selected.get('candidate_protocol_sha256'), 'Additional-protocol reference and explicit candidate-protocol alias bind the new declaration')
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
    check(proof.get('production_training_symbols_absent') is True,
          'Actual new production image contains no training helper/gcov dump symbols')
    profile_files = proof.get('application_pgo_profile_files', [])
    training = proof.get('application_pgo_training', {})
    check(len(profile_files) == 4 and {Path(v['path']).stem for v in profile_files} == {'app', 'net', 'db', 'json_fast'}
          and all(v.get('bytes', 0) > 0 and re.fullmatch('[0-9a-f]{64}', v.get('sha256', '')) for v in profile_files),
          'Actual new image retains fresh four-unit application PGO profile identities')
    check(training.get('requests') == 16953 and training.get('synthetic_fixture_only') is True
          and training.get('challenge_seed_read') is False and training.get('training_databases_removed') is True
          and len(training.get('phases', [])) == 3
          and all(v.get('database_integrity') == 'ok' and v.get('server_exit_code') == 0 for v in training.get('phases', [])),
          'Actual new image synthetic application training and all three DB integrity/exits pass')
    origin_proof = read(ROOT / 'candidates/feed-hmac/image-proof.json', {})
    check(proof == origin_proof, 'Selected complete new-image proof copied unchanged from tested candidate')
    check(inventories['goose'].get('app.goose') == APP_PIN and inventories['goose'].get('db.c') == DB_PIN,
          'Exact fused-feed Goose and keyed-HMAC native source bytes are frozen')
    crypto_dir = ROOT / 'candidates/feed-hmac/hmac-tests'
    crypto = read(crypto_dir / 'results.json', {})
    crypto_proof = read(crypto_dir / 'proof.json', {})
    peer = read(ROOT / 'candidates/feed-hmac/hmac-peer-review.json', {})
    check(crypto.get('passed_all') is True and crypto.get('passed') == 139 and len(crypto.get('checks', [])) == 139
          and crypto.get('candidate_db_sha256') == crypto_proof.get('candidate_db_sha256') == DB_PIN,
          '139 differential/fault crypto checks bind exact candidate db.c')
    check(crypto_proof.get('equivalence_results') == 'results.json' and crypto_proof.get('sanitizer_log') == 'sanitizer.log'
          and crypto_proof.get('sanitizer_exit_code') == 0
          and crypto_proof.get('sanitizer_calls') == dict(valid=10000, invalid_signature=10000)
          and 'PASS:' in (crypto_dir / crypto_proof.get('sanitizer_log', '')).read_text(),
          'Retained HMAC lifecycle ASAN/UBSAN/leak proof exits zero for 20000 valid/invalid calls')
    check(peer.get('passed_all') is True and peer.get('db_c_sha256') == DB_PIN
          and peer.get('tests_sha256') == sha(crypto_dir / 'results.json') and not peer.get('blocking_findings'),
          'Independent keyed-HMAC ownership/failure/ABI peer review binds exact crypto proof')
    for name, digest in HISTORY.items():
        check((ROOT / name).is_file() and sha(ROOT / name) == digest, 'First completed UNMET holdout preserved: ' + name)

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
        check(sha(batch / name) == sha(ROOT / 'feed-hmac-checks' / name), 'Supplemental exact tested original: ' + name)
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
                  crypto_results_sha256=sha(crypto_dir / 'results.json'),
                  crypto_proof_sha256=sha(crypto_dir / 'proof.json'),
                  crypto_sanitizer_sha256=sha(crypto_dir / 'sanitizer.log'),
                  crypto_peer_review_sha256=sha(ROOT / 'candidates/feed-hmac/hmac-peer-review.json'),
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
        first_holdout_preserved_artifacts=HISTORY,
        crypto_proofs=dict(results_sha256=sha(crypto_dir / 'results.json'), proof_sha256=sha(crypto_dir / 'proof.json'),
             sanitizer_sha256=sha(crypto_dir / 'sanitizer.log'), peer_review_sha256=sha(ROOT / 'candidates/feed-hmac/hmac-peer-review.json')),
        limitations=['Image/binary and driver execution identities use retained immutable image/runtime proofs; this reviewer runs no new containers.',
          'Inherited correctness records retain original timestamps and bytes; these are not newly executed tests.',
          'The earlier candidate normal reproduction is historical, unmeasured evidence for a different source; this audit does not require it to match the new candidate.',
          'Statistics, whole-triplet selection and target gates are independently audited in independent-statistics-audit.json.'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--batch', type=Path, default=ROOT / 'holdout-feed-hmac')
    parser.add_argument('--complete', action='store_true')
    args = parser.parse_args()
    batch = args.batch.resolve()
    result = audit(batch, args.complete)
    save(batch / 'independent-identity-audit.json', result)
    print(json.dumps({key: result[key] for key in ('complete', 'evidence_passed_all', 'measurement_count', 'issues')}, indent=2))
    return 0 if result['evidence_passed_all'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
