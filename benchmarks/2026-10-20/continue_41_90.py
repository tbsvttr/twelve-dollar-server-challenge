"""Finish the initial running batch, remove build helpers, then build remaining PRs."""
import hashlib,json,subprocess,time
from pathlib import Path
from build_41_90 import ROOT,STATUS,save
FIRST={41,42,44,47,48,52,56,64,65,68,72,74,75,76,77,80,82,86,89,90}
while True:
 try:s=json.loads(STATUS.read_text())
 except (FileNotFoundError,json.JSONDecodeError):s={}
 if all(s.get(str(pr),{}).get('state') in ('built','build_failed','setup_failed','unsupported_architecture','missing_build_script') for pr in FIRST):break
 time.sleep(3)
for key,r in s.items():
 if r.get('state')!='built':continue
 name='twelve-current-clean-pr'+key
 image=r['image']
 log=ROOT/'logs'/f'build-pr{key}.log'
 with log.open('a') as out:
  subprocess.run(['docker','run','-d','--name',name,image,'sleep','infinity'],stdout=out,stderr=out,check=True)
  try:
   subprocess.run(['docker','exec',name,'rm','-f','/usr/local/bin/nproc'],stdout=out,stderr=out,check=True)
   if key in {'44','48','52','65','72','76'}:
    p=subprocess.run(['docker','exec',name,'/usr/local/go/bin/go','version','-m',f'/suite/sources/pr{key}/bin/server'],capture_output=True,text=True)
    out.write('\nCompiler provenance:\n'+p.stdout+p.stderr)
    r['compiler_evidence']=p.stdout.strip()
   p=subprocess.run(['docker','commit',name,image],capture_output=True,text=True,check=True)
   r['image_id']=p.stdout.strip();r['build_helper_removed']=True
  finally:subprocess.run(['docker','rm','-f',name],stdout=out,stderr=out)
 save(s)
 print(f'PR {key}: build helper removed',flush=True)
rows=json.loads((ROOT/'manifest.json').read_text())
remaining=[str(r['pr']) for r in rows if 41<=r['pr']<=90 and (r['pr'] not in FIRST or r['pr']==56)]
subprocess.run(['python3',str(ROOT/'build_41_90.py'),*remaining],check=True)
