"""Build fixed Go and Nim submissions without changing their source scripts."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parent
STATUS = ROOT / 'build-status-103-132.json'
LOCK = threading.Lock()

def save(key, record):
    with LOCK:
        records = json.loads(STATUS.read_text()) if STATUS.exists() else {}
        records[key] = record
        STATUS.write_text(json.dumps(records, indent=2) + '\n')

def build(row):
    key = row['id']
    base = 'twelve-current-pr103:2026-10-20' if key == '103' else 'twelve-unified:2026-10-07'
    container = 'twelve-fixes-build-' + key
    image = 'twelve-fixes-pr' + key + ':2026-10-22'
    log = ROOT / 'logs' / f'build-pr{key}.log'
    record = dict(pr=row['pr'], id=key, commit=row['commit'], architecture='linux/arm64',
                  status='building', base_image=base, container=container, image=image,
                  log=str(log.relative_to(ROOT)), substitutions=[],
                  started_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
    if key == '103':
        record['substitutions'] = ['Reuse official native ARM64 Go 1.27.2 toolchain from previous verified image; submitted install.sh still downloads AMD64. Application source and build/start scripts unchanged.']
    save(key, record)
    started = time.monotonic()
    with log.open('w') as out:
        def run(args, timeout=1200, code=None):
            out.write('$ ' + ' '.join(args) + '\n'); out.flush()
            subprocess.run(args, input=code, text=True, stdout=out,
                           stderr=subprocess.STDOUT, check=True, timeout=timeout)
        try:
            run(['docker','run','-d','--name',container,'--platform','linux/arm64',
                 '--cpus','1.5','--memory','3g','--memory-swap','3g',
                 '--security-opt','seccomp='+str(ROOT/'seccomp-io-uring.json'),
                 '--mount',f'type=bind,src={ROOT},dst=/evidence,readonly',base,'sleep','infinity'],90)
            stage = '''import hashlib,json,shutil,sys
from pathlib import Path
key=sys.argv[1]; root=Path('/suite'); target=root/'sources'/('pr'+key)
shutil.rmtree(root/'sources'); target.mkdir(parents=True)
shutil.copytree(Path('/evidence/sources')/('pr'+key),target,dirs_exist_ok=True)
shutil.copyfile('/evidence/manifest.json',root/'manifest.json')
expected=json.loads((Path('/evidence/archives')/('pr'+key+'-sha256.json')).read_text())
assert all((target/n).is_file() and hashlib.sha256((target/n).read_bytes()).hexdigest()==v for n,v in expected.items())
print('Verified pinned files:',len(expected))
'''
            run(['docker','exec','-i',container,'python3','-',key],120,stage)
            if key == '132':
                run(['docker','exec',container,'bash','/suite/sources/pr132/install.sh'])
            else:
                run(['docker','exec',container,'/usr/local/go/bin/go','version'])
            run(['docker','exec',container,'chown','-R','bench:bench','/suite/sources/pr'+key],120)
            run(['docker','exec',container,'runuser','-u','bench','--','env','NIM_JOBS=2',
                 'PATH=/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin',
                 'bash','/suite/sources/pr'+key+'/build.sh'],1800)
            verify = '''import hashlib,json,sys
from pathlib import Path
key=sys.argv[1]; target=Path('/suite/sources')/('pr'+key)
expected=json.loads((Path('/evidence/archives')/('pr'+key+'-sha256.json')).read_text())
bad=[n for n,v in expected.items() if not (target/n).is_file() or hashlib.sha256((target/n).read_bytes()).hexdigest()!=v]
assert not bad,bad
binary=target/'bin/server'
print('Pinned files verified after build:',len(expected))
print('binary_sha256',hashlib.sha256(binary.read_bytes()).hexdigest())
'''
            run(['docker','exec','-i',container,'python3','-',key],120,verify)
            run(['docker','commit',container,image],240)
            image_meta=json.loads(subprocess.check_output(['docker','image','inspect',image]))[0]
            assert image_meta['Architecture']=='arm64'
            record.update(status='built',exit_code=0,image_id=image_meta['Id'],source_files_verified=row['source_file_count'])
            run(['docker','rm','-f',container],90)
        except subprocess.CalledProcessError as error:
            record.update(status='build_failed',exit_code=error.returncode,reason=str(error))
        except Exception as error:
            record.update(status='builder_failed',exit_code=124 if isinstance(error,subprocess.TimeoutExpired) else 1,reason=str(error))
    record.update(elapsed_s=round(time.monotonic()-started,2),finished_at=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
    save(key,record)
    print(key,record['status'],record['elapsed_s'],flush=True)

if __name__=='__main__':
    rows=[r for r in json.loads((ROOT/'manifest.json').read_text()) if r['id'] in {'103','132'}]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(build,rows))
