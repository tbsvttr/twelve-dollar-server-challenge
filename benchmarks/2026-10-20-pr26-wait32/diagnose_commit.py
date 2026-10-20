"""Retain repeated original and instrumented commit-test evidence; no production edits."""
import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SCREEN = ROOT / 'followup-screen'


def run(command, timeout=240):
    return subprocess.run(command, capture_output=True, text=True, timeout=timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('case', choices=['26-original', '26-b32-w4000', '26-b8-w4000'])
    args = parser.parse_args()
    output = SCREEN / 'commit-diagnostics' / args.case
    output.mkdir(parents=True, exist_ok=False)
    rows = {r['case_id']: r for r in json.loads((SCREEN / 'manifest.json').read_text())}
    builds = json.loads((SCREEN / 'build-status-1-130.json').read_text())
    source = (SCREEN / 'sources/26-b8-w4000/tests/commit.c').read_text()
    old = '        cread(&a, &r);'
    new = '        int read_write = cread(&a, &r); fprintf(stderr, "DIAG round=%d write_read=%d write_status=%d\\n", i, read_write, r.status);'
    assert source.count(old) == 1
    source = source.replace(old, new)
    old = '    ok = !leaked && req("GET", "/feed", NULL, NULL, &r) == 200 && !strstr(r.body, "phantom") && req("GET", path, NULL, NULL, &r) == 404;'
    new = '''    int fs = req("GET", "/feed", NULL, NULL, &r);
    int fp = r.body && strstr(r.body, "phantom");
    fprintf(stderr, "DIAG final_feed_status=%d contains_phantom=%d body=%s\\n", fs, fp, r.body ? r.body : "(null)");
    int ps = req("GET", path, NULL, NULL, &r);
    fprintf(stderr, "DIAG final_post_status=%d body=%s\\n", ps, r.body ? r.body : "(null)");
    ok = !leaked && fs == 200 && !fp && ps == 404;'''
    assert source.count(old) == 1
    source = source.replace(old, new)
    diagnostic = output / 'commit-diagnostic.c'
    diagnostic.write_text(source)
    image = builds[args.case]['image_id']
    name = f'twelve-tuning26-commit-diagnostic-{os.getpid()}'
    record = dict(case_id=args.case, image_id=image, source_sha256=rows[args.case]['source_sha256'],
                  diagnostic_source_sha256=hashlib.sha256(diagnostic.read_bytes()).hexdigest(), steps=[])
    try:
        started = run(['docker', 'run', '-d', '--name', name, '--platform', 'linux/arm64',
                       '--network', 'none', '--cpuset-cpus', '0', '--cpus', '1', '--memory', '2g',
                       '--memory-swap', '2g', '--ulimit', 'nofile=65535:65535', '--security-opt',
                       'seccomp=' + str(SCREEN / 'seccomp-io-uring.json'), '--mount',
                       f'type=bind,src={SCREEN},dst=/evidence,readonly', image, 'sleep', 'infinity'], 60)
        started.check_returncode()
        run(['docker', 'cp', str(diagnostic), name + ':/suite/sources/pr26/tests/commit-diagnostic.c']).check_returncode()
        run(['docker', 'exec', name, 'chown', '-R', 'bench:bench', '/suite/sources/pr26/tests']).check_returncode()
        prefix = ['docker', 'exec', '--user', 'bench', '-w', '/suite/sources/pr26/tests', name]
        commands = [(['make', '-j1', 'build/commit', 'build/commit-server'], 'build-original'),
                    (['gcc', '-O2', '-g', '-std=gnu11', '-Wall', '-Wextra', '-Wno-unused-function',
                      'commit-diagnostic.c', '-o', 'build/commit-diagnostic'], 'build-diagnostic')]
        for program in ('commit', 'commit-diagnostic'):
            for repetition in range(1, 4):
                commands.append((['env', 'SEED=/evidence/seed/feed.db', 'SERVER=build/commit-server',
                                  './build/' + program], program + '-' + str(repetition)))
        for command, label in commands:
            result = run(prefix + command)
            log = output / (label + '.log')
            log.write_text(result.stdout + result.stderr)
            record['steps'].append(dict(label=label, exit_code=result.returncode,
                                        log_sha256=hashlib.sha256(log.read_bytes()).hexdigest()))
            print(label, result.returncode, result.stdout[-1000:], flush=True)
            if label.startswith('build'):
                result.check_returncode()
    except Exception as error:
        record['error'] = str(error)
        raise
    finally:
        run(['docker', 'rm', '-f', name], 60)
        (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')


if __name__ == '__main__':
    main()
