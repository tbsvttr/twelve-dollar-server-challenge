"""Create an independent candidate experiment; never modifies previous batches."""
import argparse, importlib.util, json, pathlib, shutil
ROOT=pathlib.Path(__file__).resolve().parent
PREVIOUS=ROOT.parent/'confirmation'
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def main():
    ap=argparse.ArgumentParser();ap.add_argument('name');ap.add_argument('--source',type=pathlib.Path,required=True);ap.add_argument('--old-baseline',action='store_true');args=ap.parse_args()
    batch=ROOT/args.name
    if (batch/'manifest.json').exists():raise SystemExit('Refusing to replace an existing experiment')
    batch.mkdir(parents=True,exist_ok=True)
    for d in ('archives','source-inventories','logs','server-logs'): (batch/d).mkdir(exist_ok=True)
    for name in ('serve.py','semantic.py','mixed.lua','schema.sql','seccomp-io-uring.json','analyze.py','edge_checks.py'):
        shutil.copy2(PREVIOUS/name,batch/name)
    analyzer=batch/'analyze.py'
    analyzer.write_text(analyzer.read_text().replace("loc.get('.c', 0) + loc.get('.h', 0)","loc.get('.c', 0) + loc.get('.h', 0) + loc.get('.inc', 0)"))
    shutil.copy2(ROOT.parent/'run.py',batch/'run.py')
    for name in ('seed','bench','test'):
        shutil.copytree(PREVIOUS/name,batch/name,dirs_exist_ok=True)
    spec=importlib.util.spec_from_file_location('freeze_previous',ROOT.parent/'prepare_experiment.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    m.ROOT=batch;m.SOURCE=args.source.resolve();m.main()
    builds=json.loads((batch/'build-status.json').read_text())
    builds['82']=json.loads((PREVIOUS/'build-status.json').read_text())['82']
    save(batch/'build-status.json',builds)
    rows=json.loads((batch/'manifest.json').read_text());rows[0]['title']='Goose '+args.name;rows[0]['variant']=args.name
    inventory_path=batch/'source-inventories/prgoose.json'
    inventory=json.loads(inventory_path.read_text())
    for name,item in inventory['files'].items():
        if pathlib.Path(name).suffix=='.inc':item['classification']='application'
    save(inventory_path,inventory)
    rows[0]['app_loc']=sum(v['physical_lines'] for v in inventory['files'].values() if v['classification']=='application')
    rows[0]['own_loc']=sum(v['physical_lines'] for v in inventory['files'].values() if v['classification'] in ('application','own_support'))
    if args.old_baseline:
        row=json.loads((PREVIOUS/'manifest.json').read_text())[0].copy()
        row.update(id='goose-old',case_id='goose-old',title='Previous Goose PGO/read-once',source_hashes='archives/prgoose-old-sha256.json',source_dir='/suite/sources/prgoose',role='previous_implementation')
        rows.insert(1,row)
        shutil.copy2(PREVIOUS/'archives/prgoose-sha256.json',batch/row['source_hashes'])
        shutil.copy2(PREVIOUS/'source-inventories/prgoose.json',batch/'source-inventories/prgoose-old.json')
        shutil.copytree(PREVIOUS/'sources/prgoose',batch/'sources/prgoose-old')
        builds=json.loads((batch/'build-status.json').read_text());builds['goose-old']=json.loads((PREVIOUS/'build-status.json').read_text())['goose'];save(batch/'build-status.json',builds)
    save(batch/'manifest.json',rows)
    print(batch)
if __name__=='__main__':main()
