#!/usr/bin/env python3
"""Selection-only concurrent comparison: two servers SHARE guest CPU 0.

This is never a dedicated-one-CPU throughput holdout. Existing source snapshots,
images, serve.py, seed and workload are reused without modification.
"""
import argparse
import concurrent.futures
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import statistics
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DEFAULT_IMAGE = 'twelve-load-wrk-monotonic:2026-10-22'
DEFAULT_PAIRS = 'baseline:baseline,goose:82,combined-sqlite:82'
SCOPE = 'selection_only_two_servers_share_one_guest_cpu_not_dedicated_cpu_holdout'
GIB = 1024 ** 3
WRK_WRAPPER = '''import json,subprocess,sys,time
start=time.monotonic()
p=subprocess.run(sys.argv[1:],capture_output=True,text=True)
end=time.monotonic()
print(json.dumps(dict(start_monotonic=start,end_monotonic=end,exit_code=p.returncode,
                     output=p.stdout,stderr=p.stderr,argv=sys.argv[1:])),flush=True)
'''
RUNTIME_PROBE = '''import hashlib,json,pathlib,shutil,sys
binary=pathlib.Path(sys.argv[1]) if sys.argv[1] else pathlib.Path(shutil.which('wrk'))
limits={}
for name in ('cpu.max','cpu.weight','cpuset.cpus.effective','memory.max','memory.swap.max'):
 p=pathlib.Path('/sys/fs/cgroup')/name
 limits[name]=p.read_text().strip() if p.exists() else None
print(json.dumps(dict(binary_path=str(binary),binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                     selected_wrk=shutil.which('wrk'),cgroup=limits)))
'''


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    temporary = path.with_suffix(path.suffix + '.partial')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def parallel(function, values):
    # Wait for both workers even if one fails; never stop/check one database
    # while the other workload is still running.
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(function, value) for value in values]
        results = []
        failures = []
        for future in futures:
            try:
                results.append(future.result())
            except Exception as error:
                failures.append(error)
        if failures:
            raise RuntimeError('; '.join(str(error) for error in failures))
        return results


def load_suite(path):
    spec = importlib.util.spec_from_file_location('paired_existing_controller', path / 'run.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def shared_hashes(path):
    files = ['seed/feed.db', 'seed/tokens.json', 'mixed.lua', 'test/test.sh',
             'semantic.py', 'serve.py', 'bench/nginx.conf', 'seccomp-io-uring.json']
    files += [str(item.relative_to(path)) for item in sorted((path / 'test/golden').glob('*.json'))]
    return {name: sha(path / name) for name in files}


def prepare(args, suite):
    manifest = json.loads((args.suite / 'manifest.json').read_text())
    builds = suite.build_records()
    verification = json.loads((args.suite / 'verification.json').read_text())
    shared = shared_hashes(args.suite)
    rows = {str(row.get('id', row['pr'])): row for row in manifest}
    cases = {}
    for case_id in sorted({case for pair in args.pairs for case in pair}):
        row, build = rows[case_id], builds[case_id]
        if suite.excluded(row) or build.get('exit_code') != 0:
            raise ValueError('Case is not eligible/built: ' + case_id)
        if build.get('commit') != row.get('commit'):
            raise ValueError('Manifest/build commit mismatch: ' + case_id)
        image = build.get('image') or row.get('image')
        image_id = build.get('image_id') or build.get('proof', {}).get('image_id')
        if not image_id or not image:
            raise ValueError('Missing frozen image identity: ' + case_id)
        inventory = json.loads((args.suite / row['source_hashes']).read_text())
        identity = dict(case_id=case_id, pr=row['pr'], commit=row.get('commit'), image=image,
                        source_sha256=row.get('source_sha256'), shared_hashes=shared,
                        image_id=image_id)
        fingerprint = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
        passing = [entry for entry in verification if entry.get('fingerprint') == fingerprint
                   and entry.get('passed_all') and entry.get('official_passed_all')
                   and entry.get('semantic', {}).get('passed_all')
                   and entry.get('database_valid') and not entry.get('error')]
        if not passing:
            raise ValueError('No matching official42/semantic/database pass: ' + case_id)
        proof = build.get('proof', {})
        binary_path, binary_hash = proof.get('binary_path'), proof.get('binary_sha256')
        if not binary_hash and proof.get('files', {}).get('bin/server', {}).get('sha256'):
            binary_path = row.get('source_dir', '/suite/sources/pr' + case_id) + '/bin/server'
            binary_hash = proof['files']['bin/server']['sha256']
        if not binary_path or not binary_hash:
            raise ValueError('Missing pinned service binary proof: ' + case_id)
        cases[case_id] = dict(identity, fingerprint=fingerprint, source_inventory=inventory,
                              source_inventory_file=row['source_hashes'],
                              source_inventory_file_sha256=sha(args.suite / row['source_hashes']),
                              binary_path=binary_path, binary_sha256=binary_hash,
                              passing_verification_fingerprint=passing[-1]['fingerprint'])
    driver_path = ROOT / 'wrk-monotonic/runtime-proof.json'
    driver = json.loads(driver_path.read_text())
    if args.load_image != driver['image']:
        raise ValueError('Only the explicitly declared pinned monotonic driver is accepted')
    config = dict(scope=SCOPE, pairs=args.pairs, repeats=args.repeats, seconds=args.seconds,
                  warmup_seconds=2, threads=2, connections=64,
                  aa_max_symmetric_imbalance=args.aa_max_imbalance,
                  aa_max_cpu_symmetric_imbalance=args.aa_max_cpu_imbalance,
                  max_start_skew_s=args.max_start_skew, server_cpus='0', server_cpu_quota=1,
                  server_memory=2 * GIB, server_memory_swap=2 * GIB,
                  server_cpu_shares=0, load_cpus='1,2', load_cpu_quota=2,
                  load_memory=2 * GIB, load_memory_swap=2 * GIB, load_cpu_shares=0,
                  limits_explanation='Default equal cgroup weights; both servers compete on CPU0; both loads compete on CPUs1,2.',
                  cases=cases, driver=driver, driver_proof_sha256=sha(driver_path),
                  controller_sha256=sha(Path(__file__)),
                  reused_controller_sha256=sha(args.suite / 'run.py'),
                  manifest_sha256=sha(args.suite / 'manifest.json'),
                  build_records_sha256=sha(args.suite / 'build-status.json'),
                  verification_sha256=sha(args.suite / 'verification.json'),
                  shared_hashes=shared)
    return config


def run_pair(args, suite, config, output, pair_index, repeat, pair):
    # Alternate case-to-side placement and launch order. A/A retains distinct
    # instance IDs even though its manifest/source/image identity is identical.
    assigned = list(pair if repeat % 2 else reversed(pair))
    attempt_id = f'pair{pair_index:02d}-repeat{repeat:02d}'
    record = dict(attempt_id=attempt_id, pair_index=pair_index, repeat=repeat,
                  requested_pair=pair, scope=SCOPE, started_at=time.time(), instances=[])
    entries = []
    for side, case_id in zip(('left', 'right'), assigned):
        instance_id = f'{attempt_id}-{side}-{case_id}'
        token = hashlib.sha256(str(output).encode()).hexdigest()[:12] + '-' + instance_id
        entry = dict(config['cases'][case_id], side=side, instance_id=instance_id,
                     server_name='twelve-paired-s-' + token,
                     load_name='twelve-paired-l-' + token, commands=[])
        record['instances'].append(entry)
        entries.append(dict(record=entry, process=None))
    def command(entry, argv, timeout=90):
        entry['commands'].append(argv)
        try:
            return suite.command(argv, timeout=timeout)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            def text(value):
                return value.decode(errors='replace') if isinstance(value, bytes) else value
            entry.setdefault('command_failures', []).append(dict(argv=argv,
                exit_code=getattr(error, 'returncode', None),
                stdout=text(error.stdout), stderr=text(error.stderr), error=str(error)))
            raise

    def inspect(name):
        return json.loads(suite.command(['docker', 'inspect', name]).stdout)[0]

    def setup(item):
        entry = item['record']
        common = ['--platform', 'linux/arm64', '--memory', '2g', '--memory-swap', '2g',
                  '--ulimit', 'nofile=65535:65535', '--mount',
                  f'type=bind,src={args.suite},dst=/evidence,readonly']
        command(entry, ['docker', 'run', '-d', '--name', entry['server_name'],
                       '--cpuset-cpus', '0', '--cpus', '1', '--security-opt',
                       'seccomp=' + str(args.suite / 'seccomp-io-uring.json'),
                       *common, entry['image_id'], 'sleep', 'infinity'])
        command(entry, ['docker', 'run', '-d', '--name', entry['load_name'],
                       '--cpuset-cpus', '1,2', '--cpus', '2', '--network',
                       'container:' + entry['server_name'], *common,
                       config['driver']['image_id'], 'sleep', 'infinity'])
        for role in ('server', 'load'):
            metadata = inspect(entry[role + '_name'])
            host = metadata['HostConfig']
            expected = dict(CpusetCpus='0' if role == 'server' else '1,2',
                            NanoCpus=(1 if role == 'server' else 2) * 10 ** 9,
                            Memory=2 * GIB, MemorySwap=2 * GIB, CpuShares=0)
            if any(host.get(key) != value for key, value in expected.items()):
                raise ValueError('Unequal/unexpected container limits: ' + entry['instance_id'])
            entry[role + '_inspect_before'] = metadata
            binary = entry['binary_path'] if role == 'server' else ''
            probe = command(entry, ['docker', 'exec', '--user', args.server_user,
                                   entry[role + '_name'], 'python3', '-c', RUNTIME_PROBE, binary])
            entry[role + '_runtime'] = json.loads(probe.stdout)
            wanted = entry['binary_sha256'] if role == 'server' else config['driver']['binary_sha256']
            if entry[role + '_runtime']['binary_sha256'] != wanted:
                raise ValueError('Runtime binary mismatch: ' + role + ' ' + entry['instance_id'])
            if role == 'load' and entry[role + '_runtime']['binary_path'] != config['driver']['binary_path']:
                raise ValueError('Load PATH selected an unexpected wrk')
        argv = ['docker', 'exec', '-i', '--user', args.server_user, entry['server_name'],
                'python3', '/evidence/serve.py', entry['case_id'], '24000']
        entry['commands'].append(argv)
        item['process'] = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, text=True, bufsize=1)
        entry['service'] = suite.receive(item['process'])
        if not entry['service'].get('ready') or entry['service'].get('source_sha256') != entry['source_sha256']:
            raise RuntimeError('Service readiness/source verification failed')

    def sample(key, stop=False):
        for item in entries:
            item['process'].stdin.write('stop\n' if stop else 'measure\n')
            item['process'].stdin.flush()
        parallel(lambda item: item['record'].update({key: suite.receive(item['process'], 20)}), entries)

    def load_phase(key, duration):
        barrier = threading.Barrier(2, timeout=20)
        def measured(item):
            entry = item['record']
            argv = ['docker', 'exec', '-w', '/evidence', entry['load_name'], 'python3', '-c', WRK_WRAPPER,
                    'wrk', '-t2', '-c64', '--latency', '-s', '/evidence/mixed.lua',
                    f'-d{duration}s', 'http://127.0.0.1:24000/feed']
            barrier.wait()
            entry[key + '_host_launch_monotonic'] = time.monotonic()
            result = command(entry, argv, duration + 40)
            entry[key + '_host_done_monotonic'] = time.monotonic()
            measured = json.loads(result.stdout)
            entry[key] = measured
            stem = output / (entry['instance_id'] + '-' + key)
            stem.with_suffix('.stdout').write_text(measured['output'])
            stem.with_suffix('.stderr').write_text(measured['stderr'])
            if measured['exit_code'] != 0:
                raise RuntimeError('wrk failed: ' + entry['instance_id'])
            measured.update(suite.parse_wrk(measured['output']))
        parallel(measured, entries if repeat % 2 else list(reversed(entries)))
        starts = [entry['record'][key]['start_monotonic'] for entry in entries]
        record[key + '_start_skew_s'] = max(starts) - min(starts)

    try:
        parallel(setup, entries)
        save(output / (attempt_id + '.json'), record)
        load_phase('warmup', 2)
        sample('before')
        load_phase('measured', args.seconds)
        # Both wrk processes have finished before either service is stopped.
        sample('after')
        sample('stop_metrics', stop=True)
        def shutdown(item):
            entry, process = item['record'], item['process']
            tail, error = process.communicate(timeout=30)
            entry['controller_stderr'] = error
            entry['controller_exit_code'] = process.returncode
            entry['final'] = [json.loads(line) for line in tail.splitlines() if line.strip()]
            database = next((value['database_after'] for value in entry['final'] if 'database_after' in value), {})
            entry['database_valid'] = (database.get('integrity') == 'ok' and
                                       database.get('post_count', 0) > database.get('initial_post_count', 0))
            measured = entry['measured']
            entry['valid_duration'] = args.seconds - .5 <= measured['duration_s'] <= args.seconds + 2
            delta = entry['after']['cpu_s'] - entry['before']['cpu_s']
            elapsed = entry['after']['monotonic'] - entry['before']['monotonic']
            entry['cpu_s_delta'] = delta
            entry['cpu_percent_of_one_shared_guest_cpu'] = 100 * delta / elapsed
            entry['cpu_s_per_completed_request'] = delta / measured['requests']
            entry['rss_mib'] = entry['after']['rss_kib'] / 1024
            entry['clean'] = (not process.returncode and entry['database_valid'] and entry['valid_duration']
                              and measured['http_errors'] == 0 and not any(measured['socket_errors'].values())
                              and entry['warmup']['http_errors'] == 0
                              and not any(entry['warmup']['socket_errors'].values()))
        parallel(shutdown, entries)
        record['valid'] = (all(entry['record'].get('clean') for entry in entries)
                           and record['measured_start_skew_s'] <= args.max_start_skew)
        speeds = [item['record']['measured']['successful_rps'] for item in entries]
        record['left_right_ratio'] = speeds[0] / speeds[1]
        requested_left = next(item for item in entries if item['record']['case_id'] == pair[0])
        record['requested_first_second_ratio'] = (record['left_right_ratio'] if pair[0] == pair[1]
                                                   else requested_left['record']['measured']['successful_rps'] /
                                                   next(item for item in entries if item is not requested_left)['record']['measured']['successful_rps'])
        record['aa_symmetric_imbalance'] = max(record['left_right_ratio'], 1 / record['left_right_ratio']) - 1
        cpu = [item['record']['cpu_s_delta'] for item in entries]
        record['aa_cpu_symmetric_imbalance'] = (max(cpu[0] / cpu[1], cpu[1] / cpu[0]) - 1
                                               if min(cpu) > 0 else None)
        record['completed'] = True
    except BaseException as error:
        record['error'] = type(error).__name__ + ': ' + str(error)
        record['valid'] = False
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
    finally:
        for item in entries:
            entry, process = item['record'], item['process']
            if process is not None and process.poll() is None:
                try:
                    process.communicate(input='stop\n', timeout=25)
                except (subprocess.TimeoutExpired, BrokenPipeError, ValueError):
                    process.kill()
                    process.communicate(timeout=5)
            try:
                copied = subprocess.run(['docker', 'cp', entry['server_name'] +
                                         f':/tmp/current-pr{entry["case_id"]}-24000.log',
                                         str(output / (entry['instance_id'] + '-server.log'))],
                                        capture_output=True, text=True, timeout=20)
                entry['server_log_copy_exit_code'] = copied.returncode
            except Exception as error:
                entry['server_log_copy_error'] = str(error)
            for role in ('server', 'load'):
                try:
                    entry[role + '_inspect_after'] = inspect(entry[role + '_name'])
                except Exception as error:
                    entry[role + '_inspect_error'] = str(error)
            try:
                removed = subprocess.run(['docker', 'rm', '-f', entry['load_name'], entry['server_name']],
                                         capture_output=True, text=True, timeout=30)
                entry['cleanup_exit_code'] = removed.returncode
                entry['cleanup_stderr'] = removed.stderr
            except Exception as error:
                entry['cleanup_error'] = str(error)
        record['finished_at'] = time.time()
        record['evidence_errors'] = []
        for entry in record['instances']:
            if entry.get('server_log_copy_exit_code') != 0:
                record['evidence_errors'].append(entry['instance_id'] + ': missing complete service log')
            for role in ('server', 'load'):
                metadata = entry.get(role + '_inspect_after', {})
                state = metadata.get('State', {})
                if (not state.get('Running') or state.get('OOMKilled') or
                        state.get('Dead') or state.get('ExitCode') != 0):
                    record['evidence_errors'].append(entry['instance_id'] + ': ' + role + ' unhealthy final container state')
            if entry.get('cleanup_exit_code') != 0:
                record['evidence_errors'].append(entry['instance_id'] + ': cleanup failed')
        if record['evidence_errors']:
            record['valid'] = False
        save(output / (attempt_id + '.json'), record)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', type=Path, default=ROOT / 'isolated-screen')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--pairs', default=DEFAULT_PAIRS)
    parser.add_argument('--repeats', type=int, default=2)
    parser.add_argument('--seconds', type=int, default=30)
    parser.add_argument('--aa-max-imbalance', type=float, default=.05)
    parser.add_argument('--aa-max-cpu-imbalance', type=float, default=.05)
    parser.add_argument('--max-start-skew', type=float, default=.25)
    parser.add_argument('--load-image', default=DEFAULT_IMAGE)
    parser.add_argument('--server-user', default='bench')
    parser.add_argument('--plan', action='store_true', help='Static validation/plan only; no Docker calls or loads')
    args = parser.parse_args()
    args.suite = args.suite.resolve()
    args.pairs = [tuple(pair.split(':')) for pair in args.pairs.split(',')]
    if not args.pairs or any(len(pair) != 2 for pair in args.pairs) or args.pairs[0] != ('baseline', 'baseline'):
        parser.error('First pair must be baseline:baseline; every pair needs two case IDs')
    if (args.repeats < 2 or args.seconds < 1 or args.max_start_skew <= 0 or
            not 0 <= args.aa_max_imbalance <= .25 or not 0 <= args.aa_max_cpu_imbalance <= .25):
        parser.error('Require at least two repeats, positive duration and an A/A gate in [0,.25]')
    suite = load_suite(args.suite)
    config = prepare(args, suite)
    if args.plan:
        print(json.dumps(config, indent=2))
        return 0
    output = args.output or ROOT / 'paired-diagnostic-runs' / (time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '-' + uuid.uuid4().hex[:12])
    output = output.resolve()
    if output.exists():
        parser.error('Output already exists; every invocation must preserve a new evidence directory')
    lock = (args.suite / 'controller.lock').open('a')
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error('Existing suite controller is active; no concurrent experiment was started')
    for case in config['cases'].values():
        if suite.image_id(case['image']) != case['image_id']:
            raise ValueError('Server image tag changed: ' + case['case_id'])
    if suite.image_id(args.load_image) != config['driver']['image_id']:
        raise ValueError('Monotonic load image tag changed')
    output.mkdir(parents=True)
    save(output / 'configuration.json', config)
    records = []
    summary = dict(scope=SCOPE, configuration_sha256=sha(output / 'configuration.json'),
                   aa_gate_passed=False, planned_attempts=len(args.pairs) * args.repeats,
                   completed=False, partial_or_invalid=True, attempts=records)
    for pair_index, pair in enumerate(args.pairs, 1):
        for repeat in range(1, args.repeats + 1):
            record = run_pair(args, suite, config, output, pair_index, repeat, pair)
            records.append(record)
            save(output / 'summary.json', summary)
            print(json.dumps({key: record.get(key) for key in ('attempt_id', 'requested_pair', 'valid',
                              'requested_first_second_ratio', 'measured_start_skew_s', 'error')}), flush=True)
        if pair_index == 1:
            aa = records[:args.repeats]
            summary['aa_gate_passed'] = all(record.get('valid') and
                                           record.get('aa_symmetric_imbalance', 1) <= args.aa_max_imbalance
                                           and record.get('aa_cpu_symmetric_imbalance') is not None
                                           and record['aa_cpu_symmetric_imbalance'] <= args.aa_max_cpu_imbalance
                                           for record in aa)
            summary['aa_gate_rule'] = 'Both initial A/A pairs must be clean/valid; each symmetric throughput and CPU-seconds imbalance must satisfy its frozen threshold.'
            save(output / 'summary.json', summary)
            if not summary['aa_gate_passed']:
                print('A/A gate failed; all attempts retained; no variant pairs started.', flush=True)
                return 2
    summary['completed'] = True
    summary['all_attempts_valid'] = all(record.get('valid') for record in records)
    summary['partial_or_invalid'] = not summary['all_attempts_valid']
    summary['pair_counts'] = {}
    summary['pair_ratio_medians'] = {}
    for index in range(1, len(args.pairs) + 1):
        attempted = [record for record in records if record['pair_index'] == index]
        valid = [record for record in attempted if record.get('valid')]
        complete = len(attempted) == len(valid) == args.repeats
        summary['pair_counts'][str(index)] = dict(attempted=len(attempted), valid=len(valid),
                                                  required=args.repeats, complete_and_valid=complete)
        if complete:
            summary['pair_ratio_medians'][str(index)] = statistics.median(
                record['requested_first_second_ratio'] for record in valid)
    save(output / 'summary.json', summary)
    print(output, flush=True)
    return 0 if all(record.get('valid') for record in records) else 2


if __name__ == '__main__':
    sys.exit(main())
