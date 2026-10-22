#!/usr/bin/env python3
"""Build the already frozen candidate; no HTTP benchmark is run."""
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parent
LEAD = ROOT.parent.parent
BASE_ID = 'sha256:a69064953b766ec5c800389b8e17a7d184f73aa8dd46cd4aa2048955ee86eb0f'
IMAGE = 'twelve-goose-unified-like-trainer-v2:2026-10-22'
STAGING = 'twelve-goose-unified-like-trainer-v2-build:2026-10-22'
CONTAINER = 'twelve-build-unified-like-trainer-v2'


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def command(argv, log=None, timeout=120):
    print(stamp(), argv[:5], flush=True)
    if log:
        with (ROOT / log).open('w') as output:
            result = subprocess.run(argv, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    else:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}); retained log={log}: {argv}')
    return result


def save(name, value):
    (ROOT / name).write_text(json.dumps(value, indent=2) + '\n')


def main():
    if (ROOT / 'build.log').exists():
        raise RuntimeError('This attempt already exists; preserve it rather than overwrite')
    started = stamp()
    before = time.monotonic()
    base = json.loads(command(['docker', 'image', 'inspect', 'twelve-goose-final:2026-10-22']).stdout)[0]
    assert base['Id'] == BASE_ID and base['Architecture'] == 'arm64'
    frozen = json.loads((ROOT / 'source-sha256.json').read_text())
    assert {str(path.relative_to(ROOT / 'source')): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in (ROOT / 'source').rglob('*') if path.is_file()} == frozen
    command(['docker', 'build', '--progress=plain', '-t', STAGING, str(ROOT)], 'staging.log')
    argv = ['docker', 'run', '--name', CONTAINER, '--platform', 'linux/arm64',
            '--network', 'none', '--cpuset-cpus', '3,4', '--cpus', '2',
            '--memory', '3g', '--memory-swap', '3g', '--user', 'bench', STAGING,
            'bash', '-c', 'set -e\nrm -rf .build bin\nexec bash -x build.sh']
    save('build-command.json', dict(argv=argv, started_at=started, source_files=19,
                                   object_reuse=False, fresh_build_directories=True))
    command(argv, 'build.log', timeout=1800)
    inspected = json.loads(command(['docker', 'inspect', CONTAINER]).stdout)[0]
    save('container-inspect.json', inspected)
    assert inspected['State']['ExitCode'] == 0 and not inspected['State']['OOMKilled']
    host = inspected['HostConfig']
    assert host['CpusetCpus'] == '3,4' and host['NanoCpus'] == 2_000_000_000
    assert host['Memory'] == host['MemorySwap'] == 3 * 1024 ** 3 and host['NetworkMode'] == 'none'
    for remote, local in [('.build/unified-pgo-training.json', 'unified-pgo-training.json'),
                          ('.build/unified-lto-ipa.txt', 'unified-lto-ipa.txt'),
                          ('.build/unified-profile', 'unified-profiles')]:
        command(['docker', 'cp', f'{CONTAINER}:/suite/sources/prgoose/{remote}', str(ROOT / local)])
    command(['docker', 'commit', CONTAINER, IMAGE])
    image = json.loads(command(['docker', 'image', 'inspect', IMAGE]).stdout)[0]
    save('image-inspect.json', image)
    helper = LEAD / 'toolchain/inspect_image.py'
    proof = command(['docker', 'run', '--rm', '--platform', 'linux/arm64', '--network', 'none',
                     '--cpuset-cpus', '3,4', '--cpus', '1', '--memory', '512m', '--memory-swap', '512m',
                     '--user', 'bench', '-e', 'EXPECT_UNIFIED_PGO=1',
                     '-e', 'EXPECT_SQLITE_CACHE_KIB=8192', '-e', 'EXPECT_SQLITE_MMAP_MIB=0',
                     '--mount', f'type=bind,src={helper},dst=/inspect.py,readonly',
                     '--mount', f'type=bind,src={ROOT / "source-sha256.json"},dst=/expected-source.json,readonly',
                     image['Id'], 'python3', '/inspect.py'])
    (ROOT / 'image-proof.raw.json').write_text(proof.stdout)
    (ROOT / 'inspection.stderr').write_text(proof.stderr)
    result = json.loads(proof.stdout)
    training = json.loads((ROOT / 'unified-pgo-training.json').read_text())
    dense = next(phase for phase in training['phases'] if phase['phase'] == 'dense')
    assert dense['fixture']['seed_posts'] == 131072 and dense['fixture']['database_bytes'] > 8 * 1024 ** 2
    assert dense['main_profile_coverage']['target_counts']['like:recent:created'] > 0
    assert dense['main_profile_coverage']['created_liked_feed_observations'] > 0
    assert dense['main_profile_coverage']['successful_standard_auth_subject_count'] > 1
    assert all(phase['fresh_probe_like_count_verified'] for phase in training['phases'] if phase['phase'] != 'empty')
    profiles = sorted((ROOT / 'unified-profiles').rglob('*.gcda'))
    assert len(profiles) == 5
    result.update(image=IMAGE, image_id=image['Id'], base_image_id=BASE_ID,
                  build_uid=1001, build_started=started, build_finished=stamp(),
                  build_elapsed_s=round(time.monotonic() - before, 3),
                  build_limits=dict(cpus=2, cpuset='3,4', memory='3g', memory_swap='3g', network='none'),
                  object_reuse=False, fresh_build_directories=True,
                  image_environment={value.split('=', 1)[0]: value.split('=', 1)[1]
                                     for value in image['Config']['Env'] if value.startswith('GOOSE_')},
                  actual_synthetic_training_metadata=training,
                  retained_unified_profile_files=[dict(path=str(path.relative_to(ROOT)), bytes=path.stat().st_size,
                        sha256=hashlib.sha256(path.read_bytes()).hexdigest()) for path in profiles],
                  build_method='Fresh profile-generate and profile-use for all five units with shared GCC LTO; real HTTP synthetic v2 training; no object reuse; hard missing-profile, coverage and LTO-type mismatch checks; production excludes training helper.')
    save('image-proof.json', result)
    candidate = json.loads((ROOT / 'candidate.json').read_text())
    candidate.update(status='fresh unified-v2 build/profiles/LTO/source verified; API/performance gates pending',
                     image_id=image['Id'], binary_sha256=result['binary_sha256'])
    save('candidate.json', candidate)
    print(json.dumps(dict(image=IMAGE, image_id=image['Id'], source_sha256=result['source_snapshot_sha256'],
                          binary_sha256=result['binary_sha256'], profile_files=len(profiles),
                          dense_fixture_bytes=dense['fixture']['database_bytes'],
                          main_like_recent_created=dense['main_profile_coverage']['target_counts']['like:recent:created'],
                          main_successful_auth_subjects=dense['main_profile_coverage']['successful_standard_auth_subject_count']), indent=2), flush=True)
    command(['docker', 'rm', CONTAINER])


if __name__ == '__main__':
    main()
