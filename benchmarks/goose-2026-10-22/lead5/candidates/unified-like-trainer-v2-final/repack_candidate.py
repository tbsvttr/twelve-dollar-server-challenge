#!/usr/bin/env python3
"""Metadata-only repack. No compilation, training, server or load is run."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
ORIGINAL = ROOT.parent / 'unified-like-trainer-v2'
LEAD = ROOT.parent.parent
IMAGE = 'twelve-goose-unified-like-trainer-v2-final:2026-10-22'


def command(argv, log=None):
    if log:
        with (ROOT / log).open('w') as stream:
            result = subprocess.run(argv, stdout=stream, stderr=subprocess.STDOUT, timeout=120)
    else:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f'Failed: {argv}; log={log}')
    return result


def save(name, value):
    (ROOT / name).write_text(json.dumps(value, indent=2) + '\n')


def main():
    if (ROOT / 'repack.log').exists():
        raise RuntimeError('Preserving existing repack attempt')
    original = json.loads((ORIGINAL / 'image-proof.json').read_text())
    before = json.loads(command(['docker', 'image', 'inspect', original['image']]).stdout)[0]
    assert before['Id'] == original['image_id']
    command(['docker', 'build', '--progress=plain', '-t', IMAGE, str(ROOT)], 'repack.log')
    image = json.loads(command(['docker', 'image', 'inspect', IMAGE]).stdout)[0]
    save('image-inspect.json', image)
    assert image['RootFS']['Layers'][:len(before['RootFS']['Layers'])] == before['RootFS']['Layers']
    result = command(['docker', 'run', '--rm', '--platform', 'linux/arm64', '--network', 'none',
        '--cpuset-cpus', '3,4', '--cpus', '1', '--memory', '512m', '--memory-swap', '512m',
        '--user', 'bench', '-e', 'EXPECT_UNIFIED_PGO=1',
        '-e', 'EXPECT_SQLITE_CACHE_KIB=8192', '-e', 'EXPECT_SQLITE_MMAP_MIB=0',
        '--mount', f'type=bind,src={LEAD / "toolchain/inspect_image.py"},dst=/inspect.py,readonly',
        '--mount', f'type=bind,src={ROOT / "source-sha256.json"},dst=/expected-source.json,readonly',
        image['Id'], 'python3', '/inspect.py'])
    (ROOT / 'image-proof.raw.json').write_text(result.stdout)
    (ROOT / 'inspection.stderr').write_text(result.stderr)
    proof = json.loads(result.stdout)
    compared = ['binary_sha256', 'generated_c_sha256', 'sqlite_object_sha256',
                'lto_objects', 'unified_pgo_profile_files', 'training_metadata_sha256',
                'profile_dump_helper_sha256', 'compiler', 'goose_runtime', 'sqlite_version']
    for key in compared:
        assert proof[key] == original[key], key
    dependencies = '''import hashlib,json,pathlib
root=pathlib.Path('/suite/sources/prgoose')
files=['.deps/sqlite.tar.gz','.deps/sqlite3.c','.deps/sqlite3.h','.build/goose.h','build.sh']
print(json.dumps({name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in files}))
'''
    inventories = {}
    for label, identity in [('original', original['image_id']), ('final', image['Id'])]:
        value = command(['docker', 'run', '--rm', '--network', 'none', '--cpuset-cpus', '3,4',
                         '--cpus', '1', '--memory', '128m', '--memory-swap', '128m',
                         identity, 'python3', '-c', dependencies])
        inventories[label] = json.loads(value.stdout)
    assert inventories['original'] == inventories['final']
    save('dependencies-and-flags-equivalence.json', inventories)
    for filename in ['unified-pgo-training.json', 'unified-lto-ipa.txt']:
        shutil.copyfile(ORIGINAL / filename, ROOT / filename)
    shutil.copytree(ORIGINAL / 'unified-profiles', ROOT / 'unified-profiles')
    training = json.loads((ROOT / 'unified-pgo-training.json').read_text())
    labels = json.loads((ROOT / 'trainer-label-equivalence.json').read_text())
    assert training['trainer_sha256'] == labels['actual_feedback_trainer_sha256']
    assert proof['trainer_sha256'] == labels['final_source_trainer_sha256']
    proof.update(image=IMAGE, image_id=image['Id'], base_image_id=original['image_id'],
        metadata_only_repack=True, new_feedback_generated=False,
        actual_feedback_trainer_sha256=labels['actual_feedback_trainer_sha256'],
        final_source_trainer_sha256=labels['final_source_trainer_sha256'],
        trainer_label_equivalence_file='trainer-label-equivalence.json',
        trainer_label_equivalence_sha256=hashlib.sha256((ROOT / 'trainer-label-equivalence.json').read_bytes()).hexdigest(),
        identical_artifact_fields_verified=compared,
        dependencies_and_build_flags_byte_identical=True,
        actual_synthetic_training_metadata=training,
        retained_unified_profile_files=original['retained_unified_profile_files'],
        original_full_build=dict(image=original['image'], image_id=original['image_id'],
            source_sha256=original['source_snapshot_sha256'],
            trainer_sha256=labels['actual_feedback_trainer_sha256'],
            build_limits=original['build_limits'], object_reuse=False,
            build_started=original['build_started'], build_finished=original['build_finished']),
        image_environment=original['image_environment'],
        build_method='Metadata-only source repack: module documentation and trainer_variant label corrected. Existing generated C, five LTO objects, binary, dependencies, five fresh profiles and original training metadata are byte-identical to the retained full-build image. Profiles were generated by the explicitly recorded pre-repack trainer hash, not the final label-corrected source hash.')
    save('image-proof.json', proof)
    candidate = json.loads((ROOT / 'candidate.json').read_text())
    candidate.update(status='metadata-only final repack and nineteen source hashes verified; API/performance pending',
                     image_id=image['Id'], binary_sha256=proof['binary_sha256'])
    save('candidate.json', candidate)
    print(json.dumps(dict(image=IMAGE, image_id=image['Id'], source_sha256=proof['source_snapshot_sha256'],
                         binary_sha256=proof['binary_sha256'], actual_feedback_trainer_sha256=labels['actual_feedback_trainer_sha256'],
                         final_source_trainer_sha256=proof['trainer_sha256'], new_feedback_generated=False), indent=2))


if __name__ == '__main__':
    main()
