"""Build PRs 1–40 from the frozen source inventory; retain full diagnostics."""
import argparse, concurrent.futures, hashlib, json, os, subprocess, threading, time
from pathlib import Path

P = Path(__file__).resolve().parent
BASE = 'twelve-unified:2026-10-07'
STATUS = P / 'build-status-1-40.json'
LOCK = threading.Lock()
ENV = ['PATH=/opt/twelve-rust/cargo/bin:/opt/twelve-go-1.27.1/bin:/opt/ruby/bin:/usr/local/bin:/usr/bin:/bin',
       'RUSTUP_HOME=/opt/twelve-rust/rustup', 'CARGO_BUILD_JOBS=2',
       'DOTNET_CLI_HOME=/home/bench', 'DOTNET_CLI_TELEMETRY_OPTOUT=1']

def save(key, data):
    with LOCK:
        status = json.loads(STATUS.read_text()) if STATUS.exists() else {}
        status[key] = data
        STATUS.write_text(json.dumps(status, indent=2) + '\n')

def run(args, log, timeout=900):
    with log.open('a') as stream:
        try:
            return subprocess.run(args, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            stream.write('\nBUILD TIMEOUT\n')
            return 124

def build(row, retry=False):
    key = str(row.get('id', row['pr']))
    status = json.loads(STATUS.read_text()) if STATUS.exists() else {}
    if key in status and not retry:
        return
    if row.get('status') not in (None, 'ready', 'prepared'):
        save(key, dict(exit_code=None, status=row.get('status'), reason=row.get('exclusion_reason', row.get('reason', 'Not prepared'))))
        return
    name = 'twelve-current-build-' + key
    log = P / 'logs' / ('build-pr' + key + '.log')
    log.write_text('Pinned source: ' + row['commit'] + '\n')
    started = time.monotonic()
    subprocess.run(['docker','rm','-f',name],capture_output=True)
    rc = run(['docker', 'run', '-d', '--name', name, '--cpus', '2', '--memory', '3g', '--memory-swap', '3g',
              '--security-opt', 'seccomp='+str(P/'seccomp-io-uring.json'),
              '--mount', f'type=bind,src={P},dst=/evidence,readonly', BASE, 'sleep', 'infinity'], log, 90)
    if rc:
        save(key, dict(exit_code=rc, status='container_failed', log=str(log)))
        return
    # The existing image holds downloaded dependencies. Remove old tracked source
    # files before overlaying the new snapshot, retaining build caches only.
    stage = r'''
import hashlib,json,shutil,sys
from pathlib import Path
key=sys.argv[1]; base=Path('/suite'); target=base/'sources'/('pr'+key)
source=Path('/evidence/sources')/('pr'+key)
old=Path('/evidence/../never')
target.mkdir(parents=True,exist_ok=True)
keep={'.deps','target','bin','vendor','.bundle','node_modules'}
for child in target.iterdir():
 if child.name not in keep:
  if child.is_dir():shutil.rmtree(child)
  else:child.unlink()
shutil.copytree(source,target,dirs_exist_ok=True)
shutil.copyfile('/evidence/manifest.json',base/'manifest.json')
shutil.copyfile('/evidence/schema.sql',base/'schema.sql')
expected=json.loads((Path('/evidence/archives')/('pr'+key+'-sha256.json')).read_text())
assert all((target/n).is_file() and hashlib.sha256((target/n).read_bytes()).hexdigest()==v for n,v in expected.items())
'''
    with log.open('a') as stream:
        rc = subprocess.run(['docker', 'exec', '-i', name, 'python3', '-', key], input=stage, text=True, stdout=stream, stderr=stream).returncode
    if not rc:
        rc = run(['docker', 'exec', name, 'chown', '-R', 'bench:bench', '/suite/sources/pr'+key], log, 120)
    if not rc and (P/'runtime-scripts'/('pr'+key+'.sh')).exists():
        rc = run(['docker','exec',name,'bash','/evidence/runtime-scripts/pr'+key+'.sh'],log,1200)
    if not rc:
        rc = run(['docker','exec',name,'runuser','-u','bench','--','env',*ENV,'bash','/suite/sources/pr'+key+'/build.sh'],log)
    result = dict(exit_code=rc, status='built' if rc==0 else 'build_failed', elapsed_s=round(time.monotonic()-started,2),
                  commit=row['commit'], container=name, log=str(log), base_image=BASE, substitutions=[])
    if (P/'runtime-scripts'/('pr'+key+'.sh')).exists():
        result['runtime_setup']='runtime-scripts/pr'+key+'.sh'
    if rc == 0:
        image = 'twelve-current-pr'+key+':2026-10-20'
        proc = subprocess.run(['docker','commit',name,image],capture_output=True,text=True,timeout=180)
        result.update(exit_code=proc.returncode,image=image,image_id=proc.stdout.strip())
        if proc.returncode:result.update(status='image_failed',reason=proc.stderr[-2000:])
        subprocess.run(['docker','rm','-f',name],capture_output=True)
    # Failed containers remain available for toolchain-only repairs.
    save(key,result)
    print(f'PR {key}: {result["status"]} ({result["elapsed_s"]}s)',flush=True)

if __name__ == '__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--prs');ap.add_argument('--retry',action='store_true');ap.add_argument('--jobs',type=int,default=2);args=ap.parse_args()
    rows=json.loads((P/'manifest.json').read_text())
    rows=[r for r in rows if r['pr']<=40 and (not args.prs or str(r['pr']) in args.prs.split(','))]
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        list(pool.map(lambda r:build(r,args.retry),rows))
