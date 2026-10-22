"""Freeze authored Goose source and retain the existing pinned Rust control."""
import hashlib
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[1]
BASELINE=ROOT.parent/'current-2026-10-20'
SOURCE=REPO/'submissions/goose-native-tbsvttr'
SKIP={'.deps','.build','bin','generated','__pycache__','.git'}

def save(path,value):
    path.write_text(json.dumps(value,indent=2)+'\n')

def main():
    files={str(p.relative_to(SOURCE)):p for p in SOURCE.rglob('*')
           if p.is_file() and not (set(p.relative_to(SOURCE).parts)&SKIP)}
    hashes={n:hashlib.sha256(p.read_bytes()).hexdigest() for n,p in sorted(files.items())}
    identity=hashlib.sha256(json.dumps(hashes,sort_keys=True).encode()).hexdigest()
    target=ROOT/'sources/prgoose'
    if target.exists():shutil.rmtree(target)
    target.mkdir(parents=True)
    inventory={}
    for name,path in files.items():
        dest=target/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,dest)
        role='own_support' if Path(name).parts[0]=='bench' and path.suffix=='.c' else 'application' if path.suffix in {'.goose','.c','.h'} else 'own_support' if path.suffix in {'.sh','.build'} else 'documentation_lock_or_metadata'
        inventory[name]={'sha256':hashes[name],'bytes':path.stat().st_size,'physical_lines':len(path.read_bytes().splitlines()),'classification':role}
    save(ROOT/'archives/prgoose-sha256.json',hashes)
    save(ROOT/'source-inventories/prgoose.json',{'files':inventory})
    row=dict(pr=0,id='goose',case_id='goose',folder='goose-native-tbsvttr',
             title='Local Goose experiment',status='prepared',eligible=True,nginx=False,
             commit=identity,source_sha256=identity,source_file_count=len(hashes),
             source_hashes='archives/prgoose-sha256.json',
             app_loc=sum(v['physical_lines'] for v in inventory.values() if v['classification']=='application'),
             own_loc=sum(v['physical_lines'] for v in inventory.values() if v['classification'] in {'application','own_support'}),
             goose_compiler_commit='f605b5a07dd2aa3a5cb3f4c9b14002bd3c9d3d1a')
    control=next(r for r in json.loads((BASELINE/'manifest.json').read_text()) if r['id']=='82')
    control['role']='control'
    for name in [control['source_hashes'],'source-inventories/pr82.json']:
        shutil.copyfile(BASELINE/name,ROOT/name)
    shutil.copytree(BASELINE/'sources/pr82',ROOT/'sources/pr82',dirs_exist_ok=True)
    control_build=json.loads((BASELINE/'build-status.json').read_text())['82']
    status_path=ROOT/'build-status.json'
    builds=json.loads(status_path.read_text()) if status_path.exists() else {}
    builds['82']=control_build
    save(status_path,builds)
    save(ROOT/'manifest.json',[row,control])
    print(json.dumps({'source_identity':identity,'source_files':len(hashes),'goose_loc':inventory['app.goose']['physical_lines'],'app_loc_including_native_helpers':row['app_loc']}))

if __name__=='__main__':main()
