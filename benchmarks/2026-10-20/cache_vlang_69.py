"""Reuse only identical pinned V compiler inputs, never application artifacts."""
import hashlib,json,re,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parent
cache=ROOT/'runtime-cache';cache.mkdir(exist_ok=True)
def compiler_lines(pr):
 s=(ROOT/'sources'/f'pr{pr}'/'install.sh').read_text().splitlines()
 return [x for x in s if x.strip() and not x.lstrip().startswith('#') and not x.startswith('apt-get install')]
assert compiler_lines(69)==compiler_lines(70),'Compiler inputs or patches differ'
(cache/'vlang69.enabled').write_text('Exact pinned compiler reuse watcher active\n')
end=time.monotonic()+1200
while time.monotonic()<end:
 s=json.loads((ROOT/'build-status-41-90.json').read_text()).get('69',{})
 if s.get('state')=='built':break
 if s.get('state') in ('setup_failed','build_failed'):
  (cache/'vlang69.unavailable').write_text(s['state']);raise SystemExit(0)
 time.sleep(2)
else:
 (cache/'vlang69.unavailable').write_text('wait timed out');raise SystemExit(0)
name='twelve-current-cache-vlang69'
subprocess.run(['docker','create','--name',name,s['image']],check=True,capture_output=True)
try:
 subprocess.run(['docker','cp',name+':/opt/vlang',str(cache/'vlang')],check=True)
finally:subprocess.run(['docker','rm',name],check=True,capture_output=True)
archive=cache/'vlang69.tar.gz.tmp'
subprocess.run(['tar','-czf',str(archive),'-C',str(cache),'vlang'],check=True)
digest=hashlib.sha256(archive.read_bytes()).hexdigest()
meta={'source_pr':69,'source_image':s['image'],'source_image_id':s['image_id'],'archive_sha256':digest,
      'compiler_inputs_sha256':hashlib.sha256('\n'.join(compiler_lines(69)).encode()).hexdigest(),
      'V_COMMIT':'c36172591e766668cf8aa7cc307f05764b6a0d49','VC_COMMIT':'bcfdc7f33e7b7908ee40f76d059c0e2894fb4a3b','TCC_COMMIT':'d6e7ac1b1bcc98aed734a6ecbfa8509f24606c74'}
(cache/'vlang69-metadata.json').write_text(json.dumps(meta,indent=2)+'\n')
(cache/'vlang69.sha256').write_text(digest+'  vlang69.tar.gz\n')
archive.rename(cache/'vlang69.tar.gz')
subprocess.run(['rm','-rf',str(cache/'vlang')],check=True)
print(json.dumps(meta),flush=True)
