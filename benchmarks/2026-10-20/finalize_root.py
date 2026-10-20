"""Finalize the root build shard after its original worker has stopped writing."""
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

import audit_root_images
import build_root

ROOT = Path(__file__).resolve().parent
STATUS = ROOT / 'build-status-1-40.json'


def read(path):
    return json.loads(path.read_text())


def save(path, value):
    temporary = path.with_suffix('.partial')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def docker(args, check=True, timeout=120):
    return subprocess.run(['docker', *args], capture_output=True, text=True,
                          check=check, timeout=timeout)


def clean_failed_container(row):
    name = row.get('container')
    if not name:
        return
    found = docker(['inspect', name], check=False)
    if found.returncode == 0:
        row['container_state_before_cleanup'] = json.loads(found.stdout)[0].get('State')
        removed = docker(['rm', '-f', name], check=False)
        row['failed_container_cleanup'] = dict(exit_code=removed.returncode,
                                              output=removed.stdout.strip(), stderr=removed.stderr.strip())


def mark_timeout(row, key):
    if row.get('exit_code') == 124:
        row['status'] = 'build_timeout'
        row['reason'] = ('Local build subprocess exceeded its deadline before API tests could run '
                         '(application-build limit: 900 seconds; runtime-setup limit: 1200 seconds). '
                         'The disposable build container was removed to stop remaining compiler processes.')
        row['timeout_scope'] = 'local_build_environment'
        row['timeout_log'] = f'logs/build-pr{key}.log'
        clean_failed_container(row)


BUILD_PROCESSES = r'''
import json,os,pathlib
processes=[]
for path in pathlib.Path('/proc').iterdir():
 if not path.name.isdigit():continue
 try:
  fields=(path/'stat').read_text().rsplit(')',1)[1].split()
  if fields[0]=='Z':continue
  command=(path/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
  comm=(path/'comm').read_text().strip()
  if comm in ('cargo','rustc','cc','cc1','gcc','g++','clang','clang++','ld','collect2','baml-cli','baml-pack-host') or (comm=='bash' and '/suite/sources/pr35/build.sh' in command):
   processes.append(dict(pid=int(path.name),comm=comm,command=command[:600],cpu_s=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK')))
 except (OSError,ValueError):pass
events=pathlib.Path('/sys/fs/cgroup/memory.events')
memory_events=dict(line.split() for line in events.read_text().splitlines()) if events.exists() else {}
print(json.dumps(dict(processes=processes,memory_events=memory_events)))
'''


def extend_baml_build(status):
    """Keep useful compilation after the initial host docker-exec deadline."""
    record = status['35']
    if record.get('exit_code') != 124:
        return
    name = record['container']
    log = ROOT / 'logs/build-pr35.log'
    existing = record.get('build_deadline_extension')
    continuation = existing or dict(initial_exit_code=124, extension_seconds=900,
                                   started_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), observations=[])
    used = max(0, time.time() - datetime.fromisoformat(continuation['started_at'].replace('Z', '+00:00')).timestamp())
    grace_started = time.monotonic() - used
    deadline = grace_started + 900
    record['build_deadline_extension'] = continuation
    save(STATUS, status)
    print('PR 35 initial deadline reached; preserving healthy compilation for up to 900 more seconds.', flush=True)
    previous = None
    last_progress = time.monotonic()
    while True:
        state = docker(['inspect', name], check=False)
        if state.returncode or not json.loads(state.stdout)[0]['State'].get('Running'):
            record.update(status='build_timeout', reason='BAML continuation container was unavailable after the initial build deadline.')
            break
        snapshot = json.loads(docker(['exec', name, 'python3', '-c', BUILD_PROCESSES]).stdout)
        snapshot['elapsed_grace_s'] = round(time.monotonic() - grace_started, 2)
        snapshot['log_bytes'] = log.stat().st_size
        continuation['observations'].append(snapshot)
        # Parent Cargo output can stop when its docker-exec reader times out.
        # Compiler CPU time and process transitions still demonstrate real work.
        progress = (snapshot['log_bytes'], [(p['pid'], p['cpu_s']) for p in snapshot['processes']])
        if progress != previous:
            last_progress = time.monotonic()
            previous = progress
        if int(snapshot['memory_events'].get('oom_kill', 0)):
            record.update(status='build_oom', reason='The local BAML build exceeded its container memory budget before API tests.')
            break
        if time.monotonic() >= deadline or time.monotonic() - last_progress > 180:
            record.update(status='build_timeout', reason='BAML build exhausted its additional 900-second grace period or showed no compiler/log progress for 180 seconds.')
            break
        if not snapshot['processes']:
            print('BAML original compilation ended; rerunning submitted build.sh with retained artifacts to obtain a checked exit code.', flush=True)
            args = ['docker', 'exec', name, 'runuser', '-u', 'bench', '--', 'env',
                    *build_root.ENV, 'bash', '/suite/sources/pr35/build.sh']
            with log.open('a') as stream:
                stream.write('\nRe-running the submitted build after the initial host deadline; prior compilation artifacts retained.\n')
                stream.flush()
                try:
                    result = subprocess.run(args, stdout=stream, stderr=subprocess.STDOUT,
                                            timeout=max(1, deadline - time.monotonic()))
                    continuation['verified_retry_exit_code'] = result.returncode
                    if result.returncode:
                        record.update(exit_code=result.returncode, status='build_failed',
                                      reason='The submitted BAML build failed when rerun with retained compilation artifacts; see full build log.')
                    else:
                        image = 'twelve-current-pr35:2026-10-20'
                        committed = docker(['commit', name, image], timeout=180)
                        record.update(exit_code=0, status='built', image=image,
                                      image_id=committed.stdout.strip(), runtime_setup='runtime-scripts/pr35.sh')
                    break
                except subprocess.TimeoutExpired:
                    continuation['verified_retry_exit_code'] = 124
                    record.update(status='build_timeout', reason='The submitted BAML build and checked cached retry exhausted the additional 900-second grace period.')
                    break
        save(STATUS, status)
        time.sleep(10)
    continuation['elapsed_s'] = round(time.monotonic() - grace_started, 2)
    record['initial_attempt_elapsed_s'] = record.get('initial_attempt_elapsed_s', record['elapsed_s'])
    record['elapsed_s'] = record['initial_attempt_elapsed_s'] + continuation['elapsed_s']
    record['timeout_scope'] = 'local_build_environment'
    if record['status'] == 'built':
        docker(['rm', '-f', name], check=False)
    else:
        clean_failed_container(record)
    save(STATUS, status)
    print('PR 35 continuation outcome: ' + record['status'], flush=True)


def main():
    while True:
        status = read(STATUS)
        if all(status.get(key, {}).get('exit_code') is not None for key in ('35', '40')):
            break
        print('Waiting for the original root worker: PR 35 / PR 40 must both be terminal.', flush=True)
        time.sleep(30)
    print('Original root worker finished; taking exclusive ownership of the root shard.', flush=True)
    if not (ROOT / 'build-status-root-before-finalization.json').exists():
        save(ROOT / 'build-status-root-before-finalization.json', status)
    repair = read(ROOT / 'repair-root31.json')
    assert repair['commit'] == status['31']['commit']
    old_image = status['31'].get('image_id')
    status['31'].update(repair)
    status['31'].setdefault('image_id_before_runtime_repair', old_image)
    extend_baml_build(status)
    manifest = read(ROOT / 'manifest.json')
    rows = {row['id']: row for row in manifest if row['pr'] <= 40}

    reason32 = ('Pinned C++ source unconditionally uses x86 SSE2 <emmintrin.h> '
                '(src/json.cpp:3, src/http.cpp:3, src/writer.hpp:4). Native ARM64 compilation '
                'fails with "fatal error: emmintrin.h: No such file or directory".')
    reason34 = ('Pinned generated Go codecs require x86 AVX2: domain/domain_ggen.go imports '
                'simd/archsimd and calls ggen.SkipSpaceAVX2, ggen.StringAVX2, '
                'archsimd.LoadUint8x32 and BroadcastUint8x32. Native ARM64 Go compilation '
                'reports these symbols undefined; README.md:39 documents AVX2 codec generation.')
    evidence = {
        '32': [('src/json.cpp', 3), ('src/http.cpp', 3), ('src/writer.hpp', 4)],
        '34': [('domain/domain_ggen.go', 8), ('domain/domain_ggen.go', 29), ('README.md', 39)],
    }
    for key, explanation in [('32', reason32), ('34', reason34)]:
        record = status[key]
        record['original_build_status'] = record.get('status')
        record['status'] = 'unsupported_architecture'
        record['reason'] = explanation
        record['architecture'] = 'linux/arm64'
        record['required_architecture'] = 'x86_64'
        record['source_evidence'] = [dict(file=file, line=line,
            url=rows[key]['source_url'].replace('/tree/', '/blob/') + f'/{file}#L{line}')
            for file, line in evidence[key]]
        clean_failed_container(record)
    for key, record in status.items():
        if record.get('exit_code') == 0 and (ROOT / 'runtime-scripts' / f'pr{key}.sh').exists():
            record['runtime_setup'] = f'runtime-scripts/pr{key}.sh'
        if key != '35' or not record.get('build_deadline_extension'):
            mark_timeout(record, key)
    save(STATUS, status)

    # Retain the initial container-collision attempt before the helper rewrites its log.
    initial25 = ROOT / 'logs/build-pr25.log'
    if initial25.exists():
        (ROOT / 'logs/build-pr25-before-retry.log').write_bytes(initial25.read_bytes())
    print('Retrying PR 25 with submitted install.sh, native Zig 0.17 and the narrow io_uring profile.', flush=True)
    build_root.build(rows['25'], retry=True)
    status = read(STATUS)
    mark_timeout(status['25'], '25')
    status['25']['previous_attempt_evidence'] = ['build-status-root-before-finalization.json',
                                                'logs/build-pr25-before-retry.log']
    save(STATUS, status)
    audit_root_images.main()
    observations = read(audit_root_images.OUTPUT)
    for key, observation in observations.items():
        if not observation.get('nproc_local_exists'):
            continue
        record = status[key]
        name = 'twelve-current-remove-nproc-' + key
        docker(['run', '-d', '--name', name, '--cpus', '1', '--memory', '512m',
                record['image_id'], 'sleep', 'infinity'])
        try:
            docker(['exec', name, 'rm', '-f', '/usr/local/bin/nproc'])
            old = record['image_id']
            committed = docker(['commit', name, record['image']], timeout=180)
            record['image_id'] = committed.stdout.strip()
            record['image_cleanup'] = dict(previous_image_id=old,
                                           removed_paths=['/usr/local/bin/nproc'],
                                           reason='Temporary build parallelism shim must not affect submitted runtime settings.')
            save(STATUS, status)
        finally:
            docker(['rm', '-f', name], check=False)
    audit_root_images.main()
    status = read(STATUS)
    missing = [key for key, row in rows.items() if row.get('status') == 'prepared'
               and (key not in status or status[key].get('exit_code') is None)]
    if missing:
        raise RuntimeError('Root shard lacks terminal records: ' + ', '.join(missing))
    for key, record in status.items():
        if record.get('exit_code') == 0:
            assert record['commit'] == rows[key]['commit']
    print('Every current root submission has a terminal build outcome; starting resumed correctness only.', flush=True)
    with (ROOT / 'verification-progress.log').open('a') as log:
        checked = subprocess.run([sys.executable, str(ROOT / 'run.py'), 'verify', '--cases',
                                  ','.join(rows)], stdout=log, stderr=subprocess.STDOUT)
    if checked.returncode:
        raise RuntimeError(f'Root correctness controller exited {checked.returncode}; see verification-progress.log')
    save(ROOT / 'root-finalization.json', dict(
        finished_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        root_cases=len(rows), states={key: value.get('status') for key, value in status.items()},
        verification_controller_exit_code=checked.returncode, performance_started=False))
    print('Root shard finalized and correctness sweep finished. No performance started.', flush=True)


if __name__ == '__main__':
    main()
