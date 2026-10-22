"""Sequential native ARM64 correctness/throughput controller; preserve every attempt."""
import argparse
import fcntl
import hashlib
import json
import os
import random
import re
import select
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def save(path, value):
    temporary = path.with_suffix(path.suffix + '.partial')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def read(path, default):
    return json.loads(path.read_text()) if path.exists() else default


def command(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, check=True,
                          timeout=kwargs.pop('timeout', 90), **kwargs)


def parse_wrk(output):
    def required(pattern):
        match = re.search(pattern, output)
        if not match:
            raise ValueError('Missing wrk output field: ' + pattern)
        return match
    requests, duration = required(r'(\d+) requests in ([0-9.]+)s,').groups()
    result = dict(requests=int(requests), duration_s=float(duration),
                  rps=float(required(r'Requests/sec:\s+([0-9.]+)')[1]))
    for percentile in (50, 95, 99):
        match = required(r'\s' + str(percentile) + r'(?:\.0+)?%\s+([0-9.]+)(us|ms|s)')
        result[f'p{percentile}_ms'] = float(match[1]) * {'us': .001, 'ms': 1, 's': 1000}[match[2]]
    errors = re.search(r'Non-2xx or 3xx responses:\s*(\d+)', output)
    result['http_errors'] = int(errors[1]) if errors else 0
    socket = re.search(r'Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)', output)
    result['socket_errors'] = dict(zip(('connect', 'read', 'write', 'timeout'),
                                      map(int, socket.groups()) if socket else (0, 0, 0, 0)))
    # wrk's duration display is rounded to hundredths; keep its more precise
    # reported throughput, subtracting only the observed HTTP-error rate.
    result['successful_rps'] = result['rps'] - result['http_errors'] / result['duration_s']
    return result


def receive(process, timeout=90):
    ready, _, _ = select.select([process.stdout], [], [], timeout)
    if not ready:
        raise TimeoutError('Server controller produced no output')
    line = process.stdout.readline()
    if not line:
        try:
            _, error = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            error = 'Server controller exited without a response'
        raise RuntimeError(error[-10000:])
    return json.loads(line)


def image_id(image):
    inspected = json.loads(command(['docker', 'image', 'inspect', image]).stdout)[0]
    if inspected.get('Architecture') not in ('arm64', 'aarch64'):
        raise ValueError(f'Image {image} is {inspected.get("Architecture")}; emulation is excluded')
    return inspected['Id']


def excluded(row):
    return bool(row.get('excluded') or row.get('status') in
                ('excluded', 'closed_duplicate', 'non_submission', 'unsupported_architecture'))


def build_records():
    """Independent builders own disjoint shards; never mask them with a stale merge."""
    shards = sorted(path for path in ROOT.glob('build-status-*-*.json')
                    if re.fullmatch(r'build-status-\d+-\d+\.json', path.name))
    combined = {}
    for path in shards or [ROOT / 'build-status.json']:
        values = read(path, {})
        if isinstance(values, list):
            values = {str(row.get('id', row['pr'])): row for row in values}
        for key, value in values.items():
            if key in combined:
                raise ValueError(f'Duplicate build record for {key} in {path}')
            combined[key] = value
    return combined


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('verify', 'bench'))
    parser.add_argument('--cases', '--prs', dest='cases', help='Comma-separated case IDs')
    parser.add_argument('--trials', type=int, default=3)
    parser.add_argument('--seconds', type=int, default=15)
    parser.add_argument('--load-image', default='twelve-unified:2026-10-07')
    parser.add_argument('--server-user', default='bench')
    parser.add_argument('--repeat', action='store_true', help='Repeat even completed trials')
    args = parser.parse_args()
    # Both modes share append-only evidence files and the server CPU. Serialize
    # resumed controllers as well as individual cases within one invocation.
    run_lock = (ROOT / 'controller.lock').open('a')
    try:
        fcntl.flock(run_lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('Waiting for another correctness/benchmark controller to finish.', flush=True)
        fcntl.flock(run_lock.fileno(), fcntl.LOCK_EX)
    rows = read(ROOT / 'manifest.json', [])
    builds = build_records()
    selected = set(args.cases.split(',')) if args.cases else None
    rows = [row for row in rows if not selected or str(row.get('id', row['pr'])) in selected]
    output = ROOT / ('verification.json' if args.mode == 'verify' else 'measurements.json')
    records = read(output, [])
    verification = read(ROOT / 'verification.json', [])
    for directory in ('logs', 'server-logs'):
        (ROOT / directory).mkdir(exist_ok=True)
    shared_files = ['seed/feed.db', 'seed/tokens.json', 'mixed.lua', 'test/test.sh',
                    'semantic.py', 'serve.py', 'bench/nginx.conf', 'seccomp-io-uring.json']
    shared_files += [str(path.relative_to(ROOT)) for path in sorted((ROOT / 'test/golden').glob('*.json'))]
    shared_hashes = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in shared_files}
    save(ROOT / 'build-status.json', builds)
    save(ROOT / 'shared-sha256.json', shared_hashes)
    load_id = image_id(args.load_image)
    run_environment = {
        'recorded_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'mode': args.mode, 'load_image': args.load_image, 'load_image_id': load_id,
        'shared_hashes': shared_hashes, 'server_cpus': '0', 'server_cpu_quota': 1,
        'server_memory': '2g', 'server_memory_swap': '2g', 'load_cpus': '1,2',
        'load_cpu_quota': 2, 'load_memory': '2g', 'nofile': 65535,
        'server_seccomp': 'Docker default profile plus io_uring_setup/io_uring_enter/io_uring_register',
        'cpu_accounting': 'Sum live service-process self CPU and waited-child CPU (utime+stime+cutime+cstime).',
        'wrk': {'threads': 2, 'connections': 64, 'warmup_seconds': 2,
                'measurement_seconds': args.seconds, 'trials': args.trials},
        'docker_version': command(['docker', 'version', '--format', '{{json .}}']).stdout.strip(),
        'host_uname': command(['uname', '-a']).stdout.strip(),
    }
    if os.uname().sysname == 'Darwin':
        run_environment['host_cpu'] = command(['sysctl', '-n', 'machdep.cpu.brand_string']).stdout.strip()
    save(ROOT / f'environment-{args.mode}.json', run_environment)
    for trial in range(1, (1 if args.mode == 'verify' else args.trials) + 1):
        ordered = rows.copy()
        random.Random(20261020 + trial).shuffle(ordered)
        for row in ordered:
            case_id = str(row.get('id', row['pr']))
            build = builds.get(case_id, {})
            image = build.get('image') or row.get('image')
            if excluded(row) or build.get('exit_code') != 0 or not image:
                print(f'{case_id}: skipped (excluded, not built, or build failed)', flush=True)
                continue
            if build.get('commit') != row.get('commit'):
                raise ValueError(f'Build commit does not match manifest for {case_id}')
            identity = dict(case_id=case_id, pr=row['pr'], commit=row.get('commit'), image=image,
                            source_sha256=row.get('source_sha256'), shared_hashes=shared_hashes)
            identity['image_id'] = image_id(image)
            fingerprint = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
            if not args.repeat and any(record.get('fingerprint') == fingerprint and
                                       record['trial'] == trial and not record.get('error') and
                                       (args.mode != 'bench' or (record.get('completed') and
                                        record.get('configuration') == run_environment['wrk'])) and
                                       (args.mode == 'bench' or record.get('passed_all')) for record in records):
                continue
            if args.mode == 'bench' and not any(record.get('fingerprint') == fingerprint and
                                               record.get('passed_all') and not record.get('error')
                                               for record in verification):
                print(f'{case_id}: skipped throughput (no matching passing correctness run)', flush=True)
                continue
            suffix = re.sub('[^a-zA-Z0-9_.-]', '-', case_id)
            unique = f'{os.getpid()}-{args.mode}-{trial}-{suffix}'
            server_name, load_name = f'twelve-current-s-{unique}', f'twelve-current-l-{unique}'
            port = 24000
            record = dict(identity, fingerprint=fingerprint, trial=trial, mode=args.mode,
                          configuration=run_environment['wrk'],
                          recorded_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
            process = None
            try:
                server_args = ['docker', 'run', '-d', '--name', server_name,
                               '--platform', 'linux/arm64', '--cpuset-cpus', '0', '--cpus', '1',
                               '--memory', '2g', '--memory-swap', '2g',
                               '--security-opt', 'seccomp=' + str(ROOT / 'seccomp-io-uring.json'),
                               '--ulimit', 'nofile=65535:65535', '--mount',
                               f'type=bind,src={ROOT},dst=/evidence,readonly',
                               identity['image_id'], 'sleep', 'infinity']
                command(server_args)
                command(['docker', 'run', '-d', '--name', load_name, '--platform', 'linux/arm64',
                         '--cpuset-cpus', '1,2', '--cpus', '2', '--memory', '2g', '--memory-swap', '2g',
                         '--network', 'container:' + server_name, '--mount',
                         f'type=bind,src={ROOT},dst=/evidence,readonly', load_id, 'sleep', 'infinity'])
                process = subprocess.Popen(['docker', 'exec', '-i', '--user', args.server_user,
                                            server_name, 'python3', '/evidence/serve.py', case_id, str(port)],
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, text=True, bufsize=1)
                record['service'] = receive(process)
                if not record['service'].get('ready'):
                    raise RuntimeError('Server did not report ready')
                load = ['docker', 'exec', '-w', '/evidence', load_name]
                url = f'http://127.0.0.1:{port}'
                if args.mode == 'verify':
                    tested = subprocess.run(load + ['bash', '/evidence/test/test.sh', url],
                                            capture_output=True, text=True, timeout=120)
                    record.update(exit_code=tested.returncode, output=tested.stdout, stderr=tested.stderr)
                    counts = re.search(r'passed=(\d+) failed=(\d+)', tested.stdout)
                    record['passed'] = int(counts[1]) if counts else None
                    record['failed'] = int(counts[2]) if counts else None
                    record['official_passed_all'] = tested.returncode == 0 and record['passed'] == 42 and record['failed'] == 0
                    if record['official_passed_all']:
                        semantic = subprocess.run(load + ['python3', '/evidence/semantic.py', url],
                                                  capture_output=True, text=True, timeout=90)
                        record['semantic_output'] = semantic.stdout
                        record['semantic_stderr'] = semantic.stderr
                        record['semantic'] = json.loads(semantic.stdout)
                        record['semantic']['exit_code'] = semantic.returncode
                else:
                    wrk = load + ['wrk', '-t2', '-c64', '--latency', '-s', '/evidence/mixed.lua']
                    warmup = command(wrk + ['-d2s', url + '/feed'], timeout=20)
                    record['warmup_output'] = warmup.stdout
                    record['warmup_stderr'] = warmup.stderr
                    process.stdin.write('measure\n')
                    process.stdin.flush()
                    record['before'] = receive(process, 15)
                    measured = command(wrk + [f'-d{args.seconds}s', url + '/feed'], timeout=args.seconds + 30)
                    record['output'], record['stderr'] = measured.stdout, measured.stderr
                    record.update(parse_wrk(measured.stdout))
                process.stdin.write('stop\n')
                process.stdin.flush()
                record['after'] = receive(process, 15)
                tail, error = process.communicate(timeout=30)
                record['final'] = [json.loads(line) for line in tail.splitlines() if line.strip()]
                if process.returncode:
                    raise RuntimeError(error[-10000:])
                database = next((item['database_after'] for item in record['final'] if 'database_after' in item), {})
                record['database_valid'] = (database.get('integrity') == 'ok' and
                                            database.get('post_count', 0) > database.get('initial_post_count', 0))
                if args.mode == 'bench':
                    record['valid_duration'] = args.seconds - .5 <= record['duration_s'] <= args.seconds + 2
                    record['rss_mib'] = record['after']['rss_kib'] / 1024
                    elapsed = record['after']['monotonic'] - record['before']['monotonic']
                    record['cpu_percent'] = 100 * (record['after']['cpu_s'] - record['before']['cpu_s']) / elapsed
                    record['completed'] = True
                    print(f'{case_id} trial {trial}: {record["successful_rps"]:,.2f} successful req/s; '
                          f'{record["rss_mib"]:.2f} MiB; errors={record["http_errors"]}/{record["socket_errors"]}', flush=True)
                else:
                    record['passed_all'] = (record['official_passed_all'] and
                                             record.get('semantic', {}).get('passed_all', False) and
                                             (record['database_valid'] or not row.get('eligible', True)))
                    print(f'{case_id}: correctness {record["passed"]}/42; failures={record["failed"]}', flush=True)
            except Exception as error:
                record['error'] = str(error)
                print(f'{case_id} trial {trial}: ERROR {error}', flush=True)
            finally:
                if process is not None and process.poll() is None:
                    try:
                        process.communicate(input='stop\n', timeout=20)
                    except (subprocess.TimeoutExpired, BrokenPipeError):
                        process.kill()
                        process.communicate(timeout=5)
                # Capture the complete service log before the disposable container is removed.
                subprocess.run(['docker', 'cp', f'{server_name}:/tmp/current-pr{case_id}-{port}.log',
                                str(ROOT / 'server-logs' / f'{args.mode}-{suffix}-{trial}.log')],
                               capture_output=True, timeout=20)
                inspected = subprocess.run(['docker', 'inspect', server_name], capture_output=True,
                                           text=True, timeout=20)
                if inspected.returncode == 0:
                    metadata = json.loads(inspected.stdout)[0]
                    record['container_state'] = metadata.get('State')
                    record['container_host_config'] = {key: metadata.get('HostConfig', {}).get(key)
                                                       for key in ('CpusetCpus', 'NanoCpus', 'Memory',
                                                                   'MemorySwap', 'Ulimits', 'SecurityOpt')}
                subprocess.run(['docker', 'rm', '-f', load_name, server_name], capture_output=True, timeout=30)
                records.append(record)
                save(output, records)
                (ROOT / 'logs' / f'{args.mode}-{suffix}-{trial}.log').write_text(
                    record.get('output', '') + record.get('stderr', '') + record.get('error', ''))
    print(output, flush=True)


if __name__ == '__main__':
    main()
