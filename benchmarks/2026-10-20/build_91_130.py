"""Build frozen PRs 91–130 without changing submitted sources or build scripts.

Two jobs, each limited to 1.5 CPUs and 3 GiB RAM. Runtime setup scripts are
separate, auditable adaptations of toolchain installation for native ARM64.
"""
import argparse
import concurrent.futures
import json
from pathlib import Path
import shutil
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parent
STATUS = ROOT / 'build-status-91-130.json'
BASE = 'twelve-unified:2026-10-07'
CPU = '1.5'
MEMORY = '3g'
LOCK = threading.Lock()
ENV = ['PATH=/opt/twelve-rust/cargo/bin:/usr/local/go/bin:/opt/twelve-go-1.27.1/bin:/opt/ruby/bin:/usr/local/bin:/usr/bin:/bin',
       'RUSTUP_HOME=/opt/twelve-rust/rustup', 'CARGO_BUILD_JOBS=2',
       'DOTNET_CLI_HOME=/home/bench', 'DOTNET_CLI_TELEMETRY_OPTOUT=1',
       'DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1', 'NIM_JOBS=2', 'MAKEFLAGS=-j2']
UNSUPPORTED = {
    '91': 'build.py requires Linux/amd64, GOARCH=amd64 and x86-64 PGO profiles; native platform is ARM64.',
    '95': 'Submitted build.sh explicitly publishes --runtime linux-x64; native platform is ARM64. Build script left unchanged.',
    '115': 'Submitted compiler/ailang-opt11.x is an ELF x86-64 executable; build.sh requires this bundled compiler. Native platform is ARM64.',
    '117': 'Submission is x86-64 assembly; native platform is ARM64.',
    '120': 'src/jsonbuf.nim unconditionally emits #include <emmintrin.h>, __m128i and SSE2 _mm_* intrinsics without an ARM64 implementation. Application changes would be required for the native ARM64 platform.',
    '130': 'Submission is x86-64 assembly and explicitly links x86_64-linux-gnu libraries; native platform is ARM64.',
}

def save(key, record):
    with LOCK:
        status = json.loads(STATUS.read_text()) if STATUS.exists() else {}
        status[key] = record
        temporary = STATUS.with_suffix('.partial')
        temporary.write_text(json.dumps(status, indent=2) + '\n')
        temporary.replace(STATUS)

def docker(args, log, timeout=900, input=None):
    with log.open('a') as out:
        out.write('\n$ docker ' + ' '.join(args) + '\n'); out.flush()
        try:
            return subprocess.run(['docker', *args], input=input, text=True,
                                  stdout=out, stderr=subprocess.STDOUT,
                                  timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            out.write(f'\nTIMEOUT after {timeout}s\n')
            return 124

def build(row, retry=False):
    key = row['id']
    with LOCK:
        prior = json.loads(STATUS.read_text()).get(key) if STATUS.exists() else None
    if prior and not retry:
        return
    log = ROOT / 'logs' / ('build-pr' + key + '.log')
    previous=[]
    if prior:
        previous=prior.get('previous_attempts', [])
        previous_record={k:v for k,v in prior.items() if k!='previous_attempts'}
        if log.exists():
            archived=log.with_name(log.stem+'-attempt'+str(len(previous)+1)+'.log')
            shutil.copyfile(log,archived)
            previous_record['log']=str(archived.relative_to(ROOT))
        previous.append(previous_record)
    log.write_text('Pinned source: ' + row['commit'] + '\n')
    record = dict(pr=row['pr'], id=key, commit=row['commit'], base_image=BASE,
                  architecture='linux/arm64', log=str(log.relative_to(ROOT)), substitutions=[],
                  started_at=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
    if previous:record['previous_attempts']=previous
    if row['status'] != 'prepared':
        record.update(status=row['status'], reason='Pinned submission does not supply start.sh.', exit_code=None)
        save(key,record); return
    if key in UNSUPPORTED:
        record.update(status='unsupported_architecture', reason=UNSUPPORTED[key],exit_code=None)
        log.write_text(record['reason']+'\n')
        save(key,record); return
    container = 'twelve-current-build-' + key
    image = 'twelve-current-pr' + key + ':2026-10-20'
    record.update(container=container,image=image,status='building')
    save(key,record)
    start=time.monotonic()
    subprocess.run(['docker','rm','-f',container],capture_output=True)
    stage = r'''
import hashlib,json,shutil,sys
from pathlib import Path
key=sys.argv[1];base=Path('/suite');target=base/'sources'/('pr'+key)
shutil.rmtree(base/'sources');target.mkdir(parents=True)
shutil.copytree(Path('/evidence/sources')/('pr'+key),target,dirs_exist_ok=True)
shutil.copyfile('/evidence/manifest.json',base/'manifest.json')
expected=json.loads((Path('/evidence/archives')/('pr'+key+'-sha256.json')).read_text())
assert all((target/n).is_file() and hashlib.sha256((target/n).read_bytes()).hexdigest()==v for n,v in expected.items())
print('Verified',len(expected),'pinned source files')
'''
    try:
        rc=docker(['run','-d','--name',container,'--cpus',CPU,'--memory',MEMORY,'--memory-swap',MEMORY,
                   '--security-opt','seccomp='+str(ROOT/'seccomp-io-uring.json'),
                   '--mount',f'type=bind,src={ROOT},dst=/evidence,readonly',BASE,'sleep','infinity'],log,90)
        if rc: raise RuntimeError('Container creation failed')
        rc=docker(['exec','-i',container,'python3','-',key],log,120,input=stage)
        if rc: raise RuntimeError('Pinned source staging failed')
        setup=ROOT/'runtime-scripts'/('pr'+key+'.sh')
        if setup.exists():
            record['runtime_setup']=str(setup.relative_to(ROOT))
            note=setup.with_suffix('.json')
            if note.exists():record['substitutions']=json.loads(note.read_text())
            rc=docker(['exec',container,'bash','/evidence/'+str(setup.relative_to(ROOT))],log,1800)
        else:
            rc=docker(['exec',container,'bash','/suite/sources/pr'+key+'/install.sh'],log,1800)
        if rc:
            record.update(status='setup_failed',exit_code=rc)
        else:
            rc=docker(['exec',container,'chown','-R','bench:bench','/suite/sources/pr'+key],log,120)
            if rc: raise RuntimeError('Source ownership setup failed')
            rc=docker(['exec',container,'runuser','-u','bench','--','env',*ENV,'bash',
                       '/suite/sources/pr'+key+'/build.sh'],log,1800)
            record.update(status='built' if rc==0 else 'build_failed',exit_code=rc)
            if rc==0:
                # Coursier/JVM and other caches may hold runtime classpath
                # artifacts. Preserve the user cache rather than assuming it
                # contains only disposable build products.
                cleanup='rm -rf /tmp/* /root/.cache /home/bench/.npm/_cacache /var/lib/apt/lists/* /var/cache/apt/archives/*.deb'
                docker(['exec',container,'bash','-c',cleanup],log,120)
                rc=docker(['commit',container,image],log,300)
                if rc:record.update(status='image_failed',exit_code=rc)
                else:
                    record['image_id']=subprocess.check_output(['docker','image','inspect',image,'--format','{{.Id}}'],text=True).strip()
        if record['status']!='built':
            record['reason']='\n'.join(log.read_text(errors='replace').splitlines()[-18:])[-3500:]
    except Exception as error:
        record.update(status='builder_failed',reason=str(error))
    finally:
        if record['status']=='built':subprocess.run(['docker','rm','-f',container],capture_output=True)
        record.update(elapsed_s=round(time.monotonic()-start,2),finished_at=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
        save(key,record)
        print('PR '+key+': '+record['status']+' ('+str(record['elapsed_s'])+'s)',flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--prs');parser.add_argument('--retry',action='store_true');args=parser.parse_args()
    wanted=set(args.prs.split(',')) if args.prs else None
    rows=[r for r in json.loads((ROOT/'manifest.json').read_text()) if 91<=r['pr']<=130 and (not wanted or r['id'] in wanted)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(lambda r:build(r,args.retry),rows))
