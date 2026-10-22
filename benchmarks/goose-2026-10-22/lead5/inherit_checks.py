"""Carry exact existing checks into a fresh batch only when identities match."""
import argparse, hashlib, json, pathlib, shutil
p=argparse.ArgumentParser();p.add_argument('batch',type=pathlib.Path);p.add_argument('--candidate-batch',type=pathlib.Path,required=True);a=p.parse_args();r=pathlib.Path(__file__).resolve().parent;b=a.batch.resolve()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
rows={v['id']:v for v in json.loads((b/'manifest.json').read_text())};builds=json.loads((b/'build-status.json').read_text())
if (b/'verification.json').exists():raise SystemExit('Refusing to replace existing verification evidence')
origins=[];records=[];target=b/'inherited-verification';target.mkdir(exist_ok=True)
for case,previous in [('goose',a.candidate_batch.resolve()),('82',a.candidate_batch.resolve()),('baseline',r/'isolated-screen')]:
 values=json.loads((previous/'verification.json').read_text());record=next(v for v in values if v['case_id']==case and v.get('passed_all'))
 assert record['source_sha256']==rows[case]['source_sha256'] and record['image_id']==builds[case]['image_id']
 expected=json.loads((previous/'shared-sha256.json').read_text());assert record['shared_hashes']==expected
 for name,digest in expected.items():assert sha(b/name)==digest,(case,name)
 raw=f'verify-{case}-1.log';shutil.copy2(previous/'logs'/raw,b/'logs'/raw)
 server=previous/'server-logs'/raw
 if server.exists():shutil.copy2(server,b/'server-logs'/raw)
 save(target/f'{case}.json',record);records.append(record)
 origins.append({'case_id':case,'source_batch':str(previous.relative_to(r)),'source_verification_sha256':sha(previous/'verification.json'),'preserved_record':str((target/f'{case}.json').relative_to(b)),'preserved_record_sha256':sha(target/f'{case}.json'),'raw_log_sha256':sha(b/'logs'/raw)})
for name in ['parser-checks.json','edge-checks.json']:
 shutil.copy2(a.candidate_batch.resolve()/name,b/name)
save(b/'verification.json',records);save(b/'verification-origin.json',origins);save(b/'shared-sha256.json',records[0]['shared_hashes'])
print(json.dumps({'inherited_exact_identity_matched_checks':[v['case_id'] for v in records]},indent=2))
