"""Check immutable successful images for leaked build-only nproc overrides."""
import concurrent.futures,json,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parent
s=json.loads((ROOT/'build-status-41-90.json').read_text())
def check(pair):
 key,r=pair
 if r.get('state')!='built':return None
 current=subprocess.run(['docker','image','inspect',r['image'],'--format','{{.Id}}'],capture_output=True,text=True,check=True).stdout.strip()
 assert current==r['image_id'],(key,'tag differs from recorded immutable ID')
 p=subprocess.run(['docker','run','--rm','--cpus','0.1','--memory','64m',current,'sh','-c','test ! -e /usr/local/bin/nproc'],capture_output=True,text=True,timeout=45)
 return key,dict(image=r['image'],image_id=current,nproc_helper_absent=p.returncode==0,exit_code=p.returncode)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:rows=dict(x for x in pool.map(check,s.items()) if x)
(ROOT/'build-helper-audit-41-90.json').write_text(json.dumps({'checked_at':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'checked_images':len(rows),'all_clean':all(r['nproc_helper_absent'] for r in rows.values()),'images':rows},indent=2)+'\n')
print(json.dumps({'checked_images':len(rows),'all_clean':all(r['nproc_helper_absent'] for r in rows.values())}))
