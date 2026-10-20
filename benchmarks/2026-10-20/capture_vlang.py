"""Capture a built V compiler only when both submissions pin identical inputs."""
import hashlib,json,subprocess,sys,time
from pathlib import Path
ROOT=Path(__file__).resolve().parent;source=int(sys.argv[1]);target=int(sys.argv[2]);prefix=f'vlang{source}'
STATUS=ROOT/(sys.argv[3] if len(sys.argv)>3 else 'build-status-41-90.json')
cache=ROOT/'runtime-cache';cache.mkdir(exist_ok=True)
def lines(pr):
 return [x for x in (ROOT/'sources'/f'pr{pr}'/'install.sh').read_text().splitlines() if x.strip() and not x.lstrip().startswith('#') and not x.startswith('apt-get install')]
assert lines(source)==lines(target),'Compiler commits or patches differ'
(cache/f'{prefix}.unavailable').unlink(missing_ok=True)
(cache/f'{prefix}.enabled').write_text('Exact pinned compiler cache watcher active\n')
end=time.monotonic()+1200
while time.monotonic()<end:
 s=json.loads(STATUS.read_text()).get(str(source),{})
 if s.get('state')=='built':break
 if s.get('state') in ('setup_failed','build_failed'):
  (cache/f'{prefix}.unavailable').write_text(s['state']);raise SystemExit(0)
 time.sleep(2)
else:
 (cache/f'{prefix}.unavailable').write_text('wait timed out');raise SystemExit(0)
name='twelve-current-cache-'+prefix
subprocess.run(['docker','create','--name',name,s['image']],check=True,capture_output=True)
try:subprocess.run(['docker','cp',name+':/opt/vlang',str(cache/'vlang')],check=True)
finally:subprocess.run(['docker','rm',name],check=True,capture_output=True)
archive=cache/f'{prefix}.tar.gz.tmp'
subprocess.run(['tar','-czf',str(archive),'-C',str(cache),'vlang'],check=True)
digest=hashlib.sha256(archive.read_bytes()).hexdigest()
meta={'source_pr':source,'target_pr':target,'source_image':s['image'],'source_image_id':s['image_id'],'archive_sha256':digest,'compiler_inputs_sha256':hashlib.sha256('\n'.join(lines(source)).encode()).hexdigest()}
(cache/f'{prefix}-metadata.json').write_text(json.dumps(meta,indent=2)+'\n')
(cache/f'{prefix}.sha256').write_text(digest+f'  {prefix}.tar.gz\n')
archive.rename(cache/f'{prefix}.tar.gz')
subprocess.run(['rm','-rf',str(cache/'vlang')],check=True)
print(json.dumps(meta),flush=True)
