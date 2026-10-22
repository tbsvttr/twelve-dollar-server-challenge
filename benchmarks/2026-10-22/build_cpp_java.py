"""Build the pinned PR32/92 fixes without modifying submitted source or scripts."""
import argparse
import concurrent.futures
import json
from pathlib import Path
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parent
STATUS = ROOT / 'build-status-32-92.json'
BASE = 'twelve-unified:2026-10-07'
LOCK = threading.Lock()
ENV = ['PATH=/opt/twelve-rust/cargo/bin:/usr/local/go/bin:/opt/twelve-go-1.27.1/bin:/opt/ruby/bin:/usr/local/bin:/usr/bin:/bin',
       'CMAKE_BUILD_PARALLEL_LEVEL=2', 'MAKEFLAGS=-j2']
STAGE = r'''
import hashlib,json,shutil,sys
from pathlib import Path
key=sys.argv[1];base=Path('/suite');target=base/'sources'/('pr'+key)
shutil.rmtree(base/'sources',ignore_errors=True);target.mkdir(parents=True)
shutil.copytree(Path('/evidence/sources')/('pr'+key),target,dirs_exist_ok=True)
shutil.copyfile('/evidence/manifest.json',base/'manifest.json')
shutil.copyfile('/evidence/schema.sql',base/'schema.sql')
expected=json.loads((Path('/evidence/archives')/('pr'+key+'-sha256.json')).read_text())
for n,v in expected.items():
 assert (target/n).is_file() and hashlib.sha256((target/n).read_bytes()).hexdigest()==v,n
print('Verified',len(expected),'pinned source files before build')
'''
VERIFY = r'''
import hashlib,json,sys
from pathlib import Path
target=Path('/suite/sources')/('pr'+sys.argv[1]);expected=json.loads(sys.argv[2])
for n,v in expected.items():
 assert (target/n).is_file() and hashlib.sha256((target/n).read_bytes()).hexdigest()==v,n
print('Verified',len(expected),'pinned source files in image')
'''

def save(key, row):
    with LOCK:
        status=json.loads(STATUS.read_text()) if STATUS.exists() else {}
        status[key]=row
        tmp=STATUS.with_suffix('.partial')
        tmp.write_text(json.dumps(status,indent=2)+'\n');tmp.replace(STATUS)

def docker(args,log,timeout=1800,input=None):
    with log.open('a') as stream:
        stream.write('\n$ docker '+' '.join(args)+'\n');stream.flush()
        try:
            return subprocess.run(['docker',*args],input=input,text=True,stdout=stream,
                                  stderr=subprocess.STDOUT,timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            stream.write(f'\nTIMEOUT after {timeout}s\n');return 124

def build(row,retry=False):
    key=str(row['id'])
    if not retry and STATUS.exists() and key in json.loads(STATUS.read_text()):return
    container='twelve-fixes-build-'+key
    image='twelve-fixes-pr'+key+':2026-10-22'
    log=ROOT/'logs'/('build-pr'+key+'.log')
    log.write_text('Pinned source: '+row['commit']+'\n')
    record=dict(pr=row['pr'],id=key,commit=row['commit'],base_image=BASE,
                architecture='linux/arm64',image=image,image_id=None,status='building',
                exit_code=None,substitutions=[],log=str(log.relative_to(ROOT)),
                container=container,started_at=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
    save(key,record);started=time.monotonic()
    try:
        subprocess.run(['docker','rm','-f',container],capture_output=True)
        rc=docker(['run','-d','--name',container,'--platform','linux/arm64',
                   '--cpus','1.5','--memory','3g','--memory-swap','3g',
                   '--security-opt','seccomp='+str(ROOT/'seccomp-io-uring.json'),
                   '--mount',f'type=bind,src={ROOT},dst=/evidence,readonly',
                   BASE,'sleep','infinity'],log,90)
        if rc:record.update(status='container_failed',exit_code=rc);return
        rc=docker(['exec','-i',container,'python3','-',key],log,120,input=STAGE)
        if rc:record.update(status='source_staging_failed',exit_code=rc);return
        record['staged_source_hashes_verified']=True
        rc=docker(['exec',container,'bash','/suite/sources/pr'+key+'/install.sh'],log)
        if rc:record.update(status='setup_failed',exit_code=rc);return
        rc=docker(['exec',container,'chown','-R','bench:bench','/suite/sources/pr'+key],log,120)
        if rc:record.update(status='ownership_failed',exit_code=rc);return
        rc=docker(['exec',container,'runuser','-u','bench','--','env',*ENV,'bash',
                   '/suite/sources/pr'+key+'/build.sh'],log)
        record.update(status='built' if rc==0 else 'build_failed',exit_code=rc)
        if rc:return
        rc=docker(['commit',container,image],log,300)
        if rc:record.update(status='image_failed',exit_code=rc);return
        inspection=json.loads(subprocess.check_output(['docker','image','inspect',image],text=True))[0]
        record['image_id']=inspection['Id']
        record['image_architecture']=inspection['Architecture']
        expected=(ROOT/'archives'/('pr'+key+'-sha256.json')).read_text()
        rc=docker(['run','--rm','-i','--platform','linux/arm64',image,'python3','-',key,expected],
                  log,120,input=VERIFY)
        record['source_hashes_verified']=rc==0
        if rc:record.update(status='source_verification_failed',exit_code=rc)
    except Exception as error:
        record.update(status='builder_failed',reason=str(error))
    finally:
        if record['status']=='built':subprocess.run(['docker','rm','-f',container],capture_output=True)
        elif 'reason' not in record:
            record['reason']='\n'.join(log.read_text(errors='replace').splitlines()[-20:])[-4000:]
        record.update(elapsed_s=round(time.monotonic()-started,2),
                      finished_at=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
        save(key,record)
        print('PR '+key+': '+record['status']+' ('+str(record['elapsed_s'])+'s)',flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--retry',action='store_true')
    parser.add_argument('--prs',default='32,92');args=parser.parse_args()
    wanted=set(args.prs.split(','))
    rows=[r for r in json.loads((ROOT/'manifest.json').read_text()) if str(r['id']) in wanted]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(lambda row:build(row,args.retry),rows))
