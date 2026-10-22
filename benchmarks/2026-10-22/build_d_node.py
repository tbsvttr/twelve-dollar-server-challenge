"""Build the frozen PR123/127 fixes on native ARM64 without application edits.

The D images cache only the native LDC 1.42.0 toolchain and dependency downloads;
all /suite/sources are removed before staging the new exact-SHA source snapshot.
The submitted build.sh is always run unchanged as the non-root bench user.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parent
STATUS = ROOT / 'build-status-123-127.json'
BASE = 'twelve-unified:2026-10-07'
D_BASES = {
    '123-arsd-hybridcgi': 'twelve-current-pr123-arsd-threadedcgi:2026-10-20',
    '123-arsd-threadedcgi': 'twelve-current-pr123-arsd-threadedcgi:2026-10-20',
    '123-vibed': 'twelve-current-pr123-vibed:2026-10-20',
}
ENV = ['PATH=/opt/twelve-rust/cargo/bin:/usr/local/go/bin:/opt/twelve-go-1.27.1/bin:/opt/ruby/bin:/usr/local/bin:/usr/bin:/bin',
       'RUSTUP_HOME=/opt/twelve-rust/rustup', 'CARGO_BUILD_JOBS=2',
       'DOTNET_CLI_HOME=/home/bench', 'DOTNET_CLI_TELEMETRY_OPTOUT=1',
       'DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1', 'NIM_JOBS=2', 'MAKEFLAGS=-j2']
STAGE = r'''
import hashlib,json,shutil,sys
from pathlib import Path
key=sys.argv[1];base=Path('/suite');target=base/'sources'/('pr'+key)
shutil.rmtree(base/'sources');target.mkdir(parents=True)
shutil.copytree(Path('/evidence/sources')/('pr'+key),target,dirs_exist_ok=True)
for name in ('manifest.json','schema.sql'):
 shutil.copyfile(Path('/evidence')/name,base/name)
expected=json.loads((Path('/evidence/archives')/('pr'+key+'-sha256.json')).read_text())
actual={str(p.relative_to(target)):hashlib.sha256(p.read_bytes()).hexdigest() for p in target.rglob('*') if p.is_file()}
assert actual==expected,(actual.keys()-expected.keys(),expected.keys()-actual.keys())
print('Verified exact clean source snapshot:',len(expected),'files')
'''
VERIFY = r'''
import hashlib,json,sys
from pathlib import Path
key=sys.argv[1];target=Path('/suite/sources')/('pr'+key)
expected=json.loads((Path('/evidence/archives')/('pr'+key+'-sha256.json')).read_text())
assert all((target/n).is_file() and hashlib.sha256((target/n).read_bytes()).hexdigest()==v for n,v in expected.items())
print('Verified all',len(expected),'submitted source files unchanged after build')
'''


def save(key, record):
    status = json.loads(STATUS.read_text()) if STATUS.exists() else {}
    status[key] = record
    temporary = STATUS.with_suffix('.partial')
    temporary.write_text(json.dumps(status, indent=2) + '\n')
    temporary.replace(STATUS)


def docker(args, log, timeout=900, input=None):
    with log.open('a') as out:
        out.write('\n$ docker ' + ' '.join(args) + '\n')
        out.flush()
        try:
            return subprocess.run(['docker', *args], input=input, text=True,
                                  stdout=out, stderr=subprocess.STDOUT,
                                  timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            out.write(f'\nTIMEOUT after {timeout}s\n')
            return 124


def build(row, retry=False, fresh=False):
    key = row['id']
    prior = json.loads(STATUS.read_text()).get(key) if STATUS.exists() else None
    if prior and not retry:
        return
    log = ROOT / 'logs' / ('build-pr' + key + '.log')
    previous = []
    if prior:
        previous = prior.get('previous_attempts', [])
        previous_record = {k:v for k,v in prior.items() if k != 'previous_attempts'}
        if log.exists():
            archive = log.with_name(log.stem + '-attempt' + str(len(previous) + 1) + '.log')
            shutil.copyfile(log, archive)
            previous_record['log'] = str(archive.relative_to(ROOT))
        previous.append(previous_record)
    log.write_text('Pinned source: ' + row['commit'] + '\n')
    base = BASE if fresh else D_BASES.get(key, BASE)
    container = 'twelve-fixes-build-' + key
    image = 'twelve-fixes-pr' + key + ':2026-10-22'
    record = dict(pr=row['pr'], id=key, commit=row['commit'], base_image=base,
                  architecture='linux/arm64', log=str(log.relative_to(ROOT)),
                  substitutions=[], started_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                  container=container, image=image, status='building')
    if previous:
        record['previous_attempts'] = previous
    if key in D_BASES:
        record['runtime_setup'] = 'runtime-scripts/pr' + key + '.sh'
        record['substitutions'] = json.loads((ROOT / 'runtime-scripts' / ('pr' + key + '.json')).read_text())
        if not fresh:
            record['cached_toolchain'] = 'Reuse native LDC 1.42.0 and dependency downloads; delete all old application sources and outputs before staging.'
    else:
        record['runtime_setup'] = 'runtime-scripts/pr127.sh'
        record['substitutions'] = json.loads((ROOT / 'runtime-scripts/pr127.json').read_text())
        record['build_environment'] = ['CI=true (noninteractive pnpm dependency installation)']
    save(key, record)
    start = time.monotonic()
    subprocess.run(['docker', 'rm', '-f', container], capture_output=True)
    try:
        rc = docker(['run', '-d', '--name', container, '--cpus', '1.5', '--memory', '3g', '--memory-swap', '3g',
                     '--security-opt', 'seccomp=' + str(ROOT / 'seccomp-io-uring.json'),
                     '--mount', f'type=bind,src={ROOT},dst=/evidence,readonly', base, 'sleep', 'infinity'], log, 90)
        if rc:
            raise RuntimeError('Container creation failed: ' + str(rc))
        rc = docker(['exec', '-i', container, 'python3', '-', key], log, 120, input=STAGE)
        if rc:
            raise RuntimeError('Pinned source staging failed: ' + str(rc))
        work = '/suite/sources/pr' + key
        if key in D_BASES and not fresh:
            rc = docker(['exec', '-w', work, container, 'bash', '-c',
                         'set -e; uname -m; ldc2 --version; dub --version; dpkg-query -W libsqlite3-dev'], log, 60)
        else:
            installer = '/evidence/' + record['runtime_setup']
            rc = docker(['exec', '-w', work, container, 'bash', installer], log, 1800)
            if rc == 0 and key not in D_BASES:
                rc = docker(['exec', '-w', work, container, 'bash', work + '/install.sh'], log, 1800)
        if rc:
            record.update(status='setup_failed', exit_code=rc)
        else:
            rc = docker(['exec', container, 'chown', '-R', 'bench:bench', work], log, 120)
            if rc:
                raise RuntimeError('Source ownership setup failed: ' + str(rc))
            build_env = ENV + (['CI=true'] if key == '127' else [])
            rc = docker(['exec', '-w', work, container, 'runuser', '-u', 'bench', '--', 'env', *build_env,
                         'bash', work + '/build.sh'], log, 1800)
            record.update(status='built' if rc == 0 else 'build_failed', exit_code=rc)
            check = docker(['exec', '-i', container, 'python3', '-', key], log, 60, input=VERIFY)
            if check:
                raise RuntimeError('Submitted source hash changed during build')
            if rc == 0:
                docker(['exec', container, 'bash', '-c',
                        'rm -rf /tmp/* /root/.cache /home/bench/.npm/_cacache /var/lib/apt/lists/* /var/cache/apt/archives/*.deb'], log, 120)
                rc = docker(['commit', container, image], log, 300)
                if rc:
                    record.update(status='image_failed', exit_code=rc)
                else:
                    record['image_id'] = subprocess.check_output(['docker', 'image', 'inspect', image, '--format', '{{.Id}}'], text=True).strip()
        if record['status'] != 'built':
            record['reason'] = '\n'.join(log.read_text(errors='replace').splitlines()[-25:])[-5000:]
        if key == '127' and 'Ignored build scripts: better-sqlite3' in log.read_text(errors='replace'):
            record['build_warnings'] = ['pnpm ignored better-sqlite3 dependency build scripts under the submitted configuration. No dependency lifecycle approval/configuration was added.']
    except Exception as error:
        record.update(status='builder_failed', reason=str(error))
    finally:
        if record['status'] == 'built':
            subprocess.run(['docker', 'rm', '-f', container], capture_output=True)
        record.update(elapsed_s=round(time.monotonic() - start, 2), finished_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
        save(key, record)
        print('PR ' + key + ': ' + record['status'] + ' (' + str(record['elapsed_s']) + 's)', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--prs')
    parser.add_argument('--retry', action='store_true')
    parser.add_argument('--fresh', action='store_true', help='Install toolchains from the unified image instead of reusing D caches.')
    args = parser.parse_args()
    wanted = set(args.prs.split(',')) if args.prs else None
    rows = [r for r in json.loads((ROOT / 'manifest.json').read_text()) if r['pr'] in (123, 127) and (not wanted or r['id'] in wanted)]
    for row in rows:
        build(row, args.retry, args.fresh)
