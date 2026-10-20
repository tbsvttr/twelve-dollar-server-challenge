"""Run selected-source commit fault checks, separately from measured images."""
import argparse
import base64
import hashlib
import json
import os
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def text(value):
    if isinstance(value, bytes):
        return value.decode('utf-8', errors='replace')
    return value or ''


def retain_server_logs(name, output, case, record):
    """Copy the test harness's surviving failure logs before removing its container."""
    script = '''import base64,json,pathlib
logs=[]
for path in sorted(pathlib.Path('/tmp').glob('c-iouring-test-*/server.log')):
    if path.is_file():
        logs.append({'path':str(path),'data':base64.b64encode(path.read_bytes()).decode()})
print(json.dumps(logs))'''
    captured = subprocess.run(['docker', 'exec', '--user', 'bench', name,
                               'python3', '-c', script],
                              capture_output=True, text=True, timeout=20)
    record['server_log_capture'] = dict(exit_code=captured.returncode,
                                        stderr=captured.stderr)
    record['server_logs'] = []
    if captured.returncode:
        return
    for number, item in enumerate(json.loads(captured.stdout), 1):
        log = output / f'{case}-server-{number}.log'
        data = base64.b64decode(item['data'])
        log.write_bytes(data)
        record['server_logs'].append(dict(container_path=item['path'],
                                          log=str(log.relative_to(ROOT)),
                                          log_sha256=hashlib.sha256(data).hexdigest()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('case')
    args = parser.parse_args()
    row = next(row for row in json.loads((ROOT / 'manifest.json').read_text())
               if row['case_id'] == args.case and row.get('local_variant'))
    build = json.loads((ROOT / 'build-status-1-130.json').read_text())[args.case]
    assert build['status'] == 'built' and build['exit_code'] == 0
    output = ROOT / 'durability'
    output.mkdir(exist_ok=True)
    attempt, prefix = 1, args.case
    while (output / (prefix + '.json')).exists():
        attempt += 1
        prefix = args.case + '-attempt' + str(attempt)
    result_path = output / (prefix + '.json')
    image = build['image_id']
    name = f'twelve-tuning26-durability-{os.getpid()}'
    record = dict(case_id=args.case, attempt=attempt, image_id=image, source_sha256=row['source_sha256'],
                  settings=row['local_variant'],
                  recorded_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                  scope='Commit fault checks and production-binary SIGKILL persistence; '
                        'keepalive reduced to 2 connections/0 idle seconds, not a capacity claim.',
                  passed=False)
    commands = [
        ['make', '-j1', 'build/commit', 'build/commit-server', 'build/lifecycle'],
        ['env', 'SEED=/evidence/seed/feed.db', 'SERVER=build/commit-server', './build/commit'],
        ['env', 'SEED=/evidence/seed/feed.db', 'SERVER=../bin/server', 'CONNECTIONS=2',
         'IDLE_SECONDS=0', './build/lifecycle'],
    ]
    record['commands'] = commands
    try:
        subprocess.run(['docker', 'run', '-d', '--name', name, '--platform', 'linux/arm64',
                        '--network', 'none', '--cpuset-cpus', '0', '--cpus', '1', '--memory', '2g',
                        '--memory-swap', '2g', '--ulimit', 'nofile=65535:65535',
                        '--security-opt', 'seccomp=' + str(ROOT / 'seccomp-io-uring.json'),
                        '--mount', f'type=bind,src={ROOT},dst=/evidence,readonly',
                        image, 'sleep', 'infinity'], check=True, capture_output=True, text=True,
                       timeout=60)
        # docker cp retained root ownership for tests omitted from the production
        # build. Grant bench its test workspace only in this disposable container.
        prepared = subprocess.run(['docker', 'exec', name, 'chown', '-R', 'bench:bench',
                                   '/suite/sources/pr26/tests'],
                                  capture_output=True, text=True, timeout=30)
        record['test_workspace_preparation'] = dict(exit_code=prepared.returncode,
                                                   stderr=prepared.stderr)
        if prepared.returncode:
            raise RuntimeError('Cannot prepare the disposable test workspace: ' + prepared.stderr)
        record['steps'] = []
        for number, command in enumerate(commands, 1):
            timed_out = False
            try:
                tested = subprocess.run(['docker', 'exec', '--user', 'bench', '-w',
                                         '/suite/sources/pr26/tests', name] + command,
                                        capture_output=True, text=True, timeout=240)
                stdout, stderr, exit_code = tested.stdout, tested.stderr, tested.returncode
            except subprocess.TimeoutExpired as error:
                stdout, stderr, exit_code = text(error.stdout), text(error.stderr), 124
                timed_out = True
            log = output / f'{prefix}-{number}.log'
            log.write_text(stdout + stderr)
            record['steps'].append(dict(exit_code=exit_code, timed_out=timed_out,
                                        log=str(log.relative_to(ROOT)),
                                        log_sha256=hashlib.sha256(log.read_bytes()).hexdigest()))
            print(stdout[-10000:], flush=True)
            if timed_out:
                raise RuntimeError(f'Durability step {number} timed out after 240 seconds.')
            if exit_code:
                raise RuntimeError(f'Durability step {number} failed: {stderr[-2000:]}')
        record['passed'] = True
    except Exception as error:
        record.update(passed=False, error=str(error))
    finally:
        record['checks_passed'] = record['passed']
        if not record['passed']:
            try:
                retain_server_logs(name, output, prefix, record)
            except Exception as error:
                record['server_log_capture_error'] = str(error)
        try:
            removed = subprocess.run(['docker', 'rm', '-f', name],
                                     capture_output=True, text=True, timeout=60)
            record['cleanup'] = dict(exit_code=removed.returncode, stderr=removed.stderr)
            if removed.returncode:
                raise RuntimeError(f'Container cleanup exited with {removed.returncode}.')
        except Exception as error:
            record['cleanup_error'] = str(error)
            record['passed'] = False
            record.setdefault('error', str(error))
        finally:
            temporary = result_path.with_suffix('.json.partial')
            temporary.write_text(json.dumps(record, indent=2) + '\n')
            temporary.replace(result_path)
    if not record['passed']:
        raise SystemExit(record['error'])


if __name__ == '__main__':
    main()
