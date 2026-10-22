"""Read-only image/source/profile proof; this never starts the server."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


root = Path('/suite/sources/prgoose')
unified = os.environ.get('EXPECT_UNIFIED_PGO') == '1'
expected = json.loads(Path('/expected-source.json').read_text())
hashes = {name: digest(root / name) for name in expected}
assert hashes == expected, 'frozen source differs from image'
source_files = {str(p.relative_to(root)) for p in root.rglob('*') if p.is_file()
                and not any(part in ('.build', '.deps', 'bin') for part in p.relative_to(root).parts)}
assert source_files == set(expected), 'unexpected authored files in image'
binary = root / 'bin/server'
symbols = subprocess.check_output(['nm', str(binary)], text=True)
assert not any(name in symbols for name in ('finish_training', 'prepare_training_exit', '__gcov_dump'))
assert not re.search(r'\b[Tt]\s+epoll_wait$', symbols, re.MULTILINE), 'production epoll_wait interposer present'
result = dict(source_files_verified=len(hashes),
    source_snapshot_sha256=hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest(),
    source_hashes=hashes, binary_path=str(binary), binary_sha256=digest(binary),
    binary_bytes=binary.stat().st_size, binary_owner_uid=binary.stat().st_uid,
    generated_c_sha256=digest(root / '.build/app.c'), sqlite_object_sha256=digest(root / '.build/sqlite-pgo.o'),
    compiler=subprocess.check_output(['gcc', '--version'], text=True).splitlines()[0],
    goose_runtime=subprocess.check_output(['/opt/goose/build/goose', 'version'], text=True).strip(),
    architecture=platform.machine(), inspection_uid=os.getuid(),
    sqlite_version=re.search(r'#define SQLITE_VERSION\s+"([^"]+)"', (root / '.deps/sqlite3.h').read_text()).group(1),
    sqlite_pgo_enabled=True, application_pgo_enabled=os.environ.get('EXPECT_APP_PGO') == '1' or unified,
    production_training_symbols_absent=True, production_epoll_interposer_absent=True,
    backend=os.environ.get('GOOSE_IO_BACKEND'))


def profiles(folder):
    return [dict(path=str(p.relative_to(root)), bytes=p.stat().st_size, sha256=digest(p))
            for p in sorted((root / folder).rglob('*.gcda'))]


result['sqlite_pgo_profile_files'] = profiles('.build/sqlite-profile')
result['sqlite_pgo_profile_file_count'] = len(result['sqlite_pgo_profile_files'])
result['sqlite_trainer_sha256'] = digest(root / 'bench/train_sqlite.c')
result['trainer_sha256'] = result['sqlite_trainer_sha256']
if result['application_pgo_enabled'] and not unified:
    profile = profiles('.build/app-profile')
    assert {Path(p['path']).stem for p in profile} == {'app', 'net', 'db', 'json_fast'}
    training = json.loads((root / '.build/app-pgo-training.json').read_text())
    assert all(p['database_integrity'] == 'ok' and p['server_exit_code'] == 0 for p in training['phases'])
    removed = not any(p.is_dir() for p in (root / '.build').glob('app-pgo-training-*'))
    assert removed
    instrumented = subprocess.check_output(['nm', str(root / '.build/server-profiled')], text=True)
    assert re.search(r'\bT\s+epoll_wait$', instrumented, re.MULTILINE)
    assert '__gcov_dump' in instrumented
    result.update(application_pgo_profile_files=profile, application_pgo_profile_file_count=len(profile),
        app_trainer_sha256=digest(root / 'bench/train_app.py'),
        profile_dump_helper_sha256=digest(root / 'bench/app_pgo_exit.c'),
        training_metadata_sha256=digest(root / '.build/app-pgo-training.json'), training_requests=training['requests'],
        app_training_metadata_sha256=digest(root / '.build/app-pgo-training.json'),
        app_training_requests=training['requests'],
        training_databases_removed=removed, instrumented_epoll_interposer_verified=True,
        profile_dump_lifecycle='SIGUSR1 flag only in handler; atomically unblocked in epoll_pwait; main-thread dump before/after wait',
        training_phases=[dict(phase=p['phase'], requests=p['requests'], database_integrity=p['database_integrity'],
                             server_exit_code=p['server_exit_code']) for p in training['phases']])
    result['app_training_phases'] = result['training_phases']
if os.environ.get('EXPECT_SQLITE_APP_PGO') == '1':
    assert len(result['sqlite_pgo_profile_files']) == 1
    assert Path(result['sqlite_pgo_profile_files'][0]['path']).stem == 'sqlite-pgo'
    training_path = root / '.build/sqlite-app-pgo-training.json'
    training = json.loads(training_path.read_text())
    assert all(p['database_integrity'] == 'ok' and p['server_exit_code'] == 0 for p in training['phases'])
    assert not any(p.is_dir() for p in (root / '.build').glob('app-pgo-training-*'))
    instrumented = subprocess.check_output(['nm', str(root / '.build/server-sqlite-profiled')], text=True)
    assert re.search(r'\bT\s+epoll_wait$', instrumented, re.MULTILINE)
    assert '__gcov_dump' in instrumented
    result.update(sqlite_app_pgo_enabled=True, trainer_sha256=digest(root / 'bench/train_app.py'),
        sqlite_trainer_sha256=digest(root / 'bench/train_app.py'), sqlite_trainer_source='bench/train_app.py',
        legacy_sqlite_trainer_unused=True,
        legacy_sqlite_trainer_sha256=digest(root / 'bench/train_sqlite.c'),
        profile_dump_helper_sha256=digest(root / 'bench/app_pgo_exit.c'),
        training_metadata_sha256=digest(training_path), training_requests=training['requests'],
        sqlite_training_metadata_sha256=digest(training_path), sqlite_training_requests=training['requests'],
        training_databases_removed=True, instrumented_epoll_interposer_verified=True,
        profile_dump_lifecycle='SIGUSR1 flag only in handler; atomically unblocked in epoll_pwait; main-thread dump before/after wait',
        training_phases=[dict(phase=p['phase'], requests=p['requests'], database_integrity=p['database_integrity'],
                             server_exit_code=p['server_exit_code']) for p in training['phases']])
    result['sqlite_training_phases'] = result['training_phases']
if result['application_pgo_enabled'] and result.get('sqlite_app_pgo_enabled'):
    result['training_requests'] = result['app_training_requests'] + result['sqlite_training_requests']
    result['training_phases'] = [dict(stage=stage, **phase)
        for stage in ('sqlite', 'app') for phase in result[stage + '_training_phases']]
    del result['training_metadata_sha256']
if unified:
    profile = profiles('.build/unified-profile')
    assert len(profile) == 5
    assert {Path(p['path']).stem for p in profile} == {'app', 'net', 'db', 'json_fast', 'sqlite-pgo'}
    training_path = root / '.build/unified-pgo-training.json'
    training = json.loads(training_path.read_text())
    assert all(p['database_integrity'] == 'ok' and p['server_exit_code'] == 0 for p in training['phases'])
    assert not any(p.is_dir() for p in (root / '.build').glob('app-pgo-training-*'))
    instrumented = subprocess.check_output(['nm', str(root / '.build/server-unified-profiled')], text=True)
    assert re.search(r'\bT\s+epoll_wait$', instrumented, re.MULTILINE)
    assert '__gcov_dump' in instrumented
    lto_objects = []
    for unit in ('app', 'net', 'db', 'json_fast', 'sqlite-pgo'):
        path = root / ('.build/sqlite-pgo.o' if unit == 'sqlite-pgo' else '.build/unified-native/' + unit + '.o')
        sections = subprocess.check_output(['readelf', '-SW', str(path)], text=True)
        assert '.gnu.lto_' in sections
        lto_objects.append(dict(path=str(path.relative_to(root)), sha256=digest(path), gcc_lto_sections_verified=True))
    report = root / '.build/unified-lto-ipa.txt'
    report_text = report.read_text() if report.is_file() else ''
    result.update(unified_pgo_enabled=True, sqlite_app_pgo_enabled=True, unified_lto_enabled=True,
        unified_pgo_profile_files=profile, unified_pgo_profile_file_count=5,
        sqlite_pgo_profile_files=[p for p in profile if Path(p['path']).stem == 'sqlite-pgo'],
        sqlite_pgo_profile_file_count=1,
        application_pgo_profile_files=[p for p in profile if Path(p['path']).stem != 'sqlite-pgo'],
        application_pgo_profile_file_count=4,
        lto_objects=lto_objects, trainer_sha256=digest(root / 'bench/train_app.py'),
        sqlite_trainer_sha256=digest(root / 'bench/train_app.py'), sqlite_trainer_source='bench/train_app.py',
        legacy_sqlite_trainer_unused=True, legacy_sqlite_trainer_sha256=digest(root / 'bench/train_sqlite.c'),
        app_trainer_sha256=digest(root / 'bench/train_app.py'),
        profile_dump_helper_sha256=digest(root / 'bench/app_pgo_exit.c'),
        training_metadata_sha256=digest(training_path), training_requests=training['requests'],
        training_databases_removed=True, instrumented_epoll_interposer_verified=True,
        profile_dump_lifecycle='SIGUSR1 flag only in handler; atomically unblocked in epoll_pwait; main-thread dump before/after wait',
        training_phases=[dict(stage='unified', phase=p['phase'], requests=p['requests'], database_integrity=p['database_integrity'],
                             server_exit_code=p['server_exit_code']) for p in training['phases']],
        ipa_optimization_report_sha256=digest(report) if report.is_file() else None,
        ipa_optimization_report_bytes=report.stat().st_size if report.is_file() else 0,
        sqlite_api_inlining_report_lines=[line for line in report_text.splitlines()
            if 'inlin' in line.lower() and re.search(r'sqlite3_(?:column|bind|step)', line)][:40])
if os.environ.get('EXPECT_SQLITE_CACHE_KIB') is not None:
    configurations = []
    expected = (int(os.environ['EXPECT_SQLITE_CACHE_KIB']), int(os.environ['EXPECT_SQLITE_MMAP_MIB']))
    stages = [('unified', 'unified-pgo-training.json')] if unified else [('sqlite', 'sqlite-app-pgo-training.json'), ('app', 'app-pgo-training.json')]
    for stage, name in stages:
        metadata = json.loads((root / '.build' / name).read_text())
        for phase in metadata['phases']:
            values = re.findall(r'SQLite memory: cache_kib=(\d+) mmap_mib=(\d+)', phase['server_log'])
            assert len(values) == 1 and tuple(map(int, values[0])) == expected
            configurations.append(dict(stage=stage, phase=phase['phase'], cache_kib=expected[0], mmap_mib=expected[1]))
    result['training_database_configurations'] = configurations
print(json.dumps(result, indent=2))
