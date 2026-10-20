"""Build all four PR26 settings with identical original PGO build commands."""
import concurrent.futures
import hashlib
import json
import subprocess
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BASE_IMAGE = 'sha256:d4782af7b918b7b0e01f29fce4e50ca879ad2e9e82dc724c0ac0f716d8d3e9f4'
LOCK = threading.Lock()
STATUS_PATH = ROOT / 'build-status-1-130.json'


def command(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True,
                          timeout=kwargs.pop('timeout', 120), **kwargs)


def save_record(case, record):
    with LOCK:
        values = json.loads(STATUS_PATH.read_text())
        values[case] = record
        temporary = STATUS_PATH.with_suffix('.partial')
        temporary.write_text(json.dumps(values, indent=2) + '\n')
        temporary.replace(STATUS_PATH)


def build(row):
    case = row['case_id']
    name = 'twelve-tuning26-build-' + case
    tag = 'twelve-tuning26-' + case + ':2026-10-20'
    record = dict(status='building', commit=row['commit'], source_sha256=row['source_sha256'],
                  upstream_image=BASE_IMAGE, local_variant=row['local_variant'],
                  patch=row['patch'], patch_sha256=row['patch_sha256'],
                  build_cpu_quota=2, build_memory_bytes=3 * 1024**3,
                  build_command=['bash', 'build.sh'], log=f'logs/build-{case}.log')
    save_record(case, record)
    started = time.monotonic()
    try:
        command(['docker', 'run', '-d', '--name', name, '--platform', 'linux/arm64',
                 '--cpus', '2', '--memory', '3g', '--memory-swap', '3g', BASE_IMAGE,
                 'sleep', 'infinity'])
        command(['docker', 'cp', str(ROOT / 'sources' / case) + '/.', name + ':/suite/sources/pr26/'])
        with (ROOT / record['log']).open('w') as log:
            result = subprocess.run(['docker', 'exec', '--user', 'bench', '-w', '/suite/sources/pr26',
                                     name, 'bash', 'build.sh'], stdout=log, stderr=subprocess.STDOUT,
                                    timeout=900)
        record['exit_code'] = result.returncode
        if result.returncode:
            raise RuntimeError(f'Original build.sh failed with exit {result.returncode}')
        expected = json.loads((ROOT / row['source_hashes']).read_text())
        check = '''import hashlib,json,pathlib,sys
p=pathlib.Path('/suite/sources/pr26'); expected=json.loads(sys.argv[1])
bad=[name for name,h in expected.items() if hashlib.sha256((p/name).read_bytes()).hexdigest()!=h]
assert not bad,bad
print(json.dumps({'source_files_verified':len(expected),'binary_sha256':hashlib.sha256((p/'bin/server').read_bytes()).hexdigest(),'nproc_helper_absent':not pathlib.Path('/usr/local/bin/nproc').exists()}))'''
        record['image_source_check'] = json.loads(command(['docker', 'exec', name, 'python3', '-c',
                                                          check, json.dumps(expected)]).stdout)
        assert record['image_source_check']['nproc_helper_absent']
        record['compiler'] = command(['docker', 'exec', name, 'gcc', '--version']).stdout.splitlines()[0]
        image = command(['docker', 'commit', name, tag], timeout=180).stdout.strip()
        inspected = json.loads(command(['docker', 'image', 'inspect', image]).stdout)[0]
        assert inspected['Architecture'] == 'arm64'
        record.update(status='built', image=image, image_id=image, image_tag=tag)
        print(f'{case}: built {image}', flush=True)
    except Exception as error:
        record.update(status='build_failed', error=str(error))
        record.setdefault('exit_code', -1)
        print(f'{case}: FAILED {error}', flush=True)
    finally:
        record['elapsed_s'] = round(time.monotonic() - started, 2)
        save_record(case, record)
        subprocess.run(['docker', 'rm', '-f', name], capture_output=True, timeout=60)
    return record['status'] == 'built'


def main():
    rows = [row for row in json.loads((ROOT / 'manifest.json').read_text()) if row.get('local_variant')]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = list(pool.map(build, rows))
    if not all(outcomes):
        raise SystemExit('At least one variant build failed; inspect preserved logs.')
    state = json.loads((ROOT / 'EXPERIMENT_STATE.json').read_text())
    state['phase'] = 'all four variants built; correctness validation pending'
    (ROOT / 'EXPERIMENT_STATE.json').write_text(json.dumps(state, indent=2) + '\n')
    print('All four original PGO builds completed.', flush=True)


if __name__ == '__main__':
    main()
