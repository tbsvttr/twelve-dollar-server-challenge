"""Freeze actual authored source, compiler feedback and binary identity in an image."""
import argparse, hashlib, json, pathlib, subprocess
p=argparse.ArgumentParser();p.add_argument('candidate',type=pathlib.Path);p.add_argument('image');a=p.parse_args()
source=a.candidate/'source'
hashes={str(f.relative_to(source)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(source.rglob('*')) if f.is_file()}
code=r'''
import pathlib,hashlib,json,os,subprocess,sys
p=pathlib.Path('/suite/sources/prgoose'); hashes=json.loads(sys.argv[1]); actual={n:hashlib.sha256((p/n).read_bytes()).hexdigest() for n in hashes}; assert hashes==actual
proof={'source_hashes':actual,'source_files_verified':len(actual),'source_snapshot_sha256':hashlib.sha256(json.dumps(actual,sort_keys=True).encode()).hexdigest()}
for name,key in [('bin/server','binary'),('.build/app.c','generated_c'),('.build/sqlite-pgo.o','sqlite_object')]:
 f=p/name;proof[key+'_sha256']=hashlib.sha256(f.read_bytes()).hexdigest();proof[key+'_bytes']=f.stat().st_size
proof['binary_path']=str(p/'bin/server')
proof['compiler']=subprocess.check_output(['gcc','--version'],text=True).splitlines()[0]
proof['goose_runtime']=subprocess.check_output(['/opt/goose/build/goose','version'],text=True).strip()
proof['architecture']=os.uname().machine
proof['image_environment']={k:v for k,v in os.environ.items() if k.startswith('GOOSE_')}
proof['application_pgo_profile_files']=[{'path':str(f.relative_to(p)),'bytes':f.stat().st_size,'sha256':hashlib.sha256(f.read_bytes()).hexdigest()} for f in sorted((p/'.build/app-profile').rglob('*.gcda'))]
training=p/'.build/app-pgo-training.json'
if training.exists(): proof['application_pgo_training']=json.loads(training.read_text())
symbols=subprocess.check_output(['nm',str(p/'bin/server')],text=True)
proof['production_training_symbols_absent']=not any(n in symbols for n in ['__gcov_dump','prepare_training_exit','finish_training','training_complete'])
assert proof['production_training_symbols_absent']
print(json.dumps(proof,indent=2))
'''
output=subprocess.check_output(['docker','run','--rm','--cpuset-cpus','0','--cpus','1','--memory','2g','--memory-swap','2g',a.image,'python3','-c',code,json.dumps(hashes)],text=True)
proof=json.loads(output);meta=json.loads(subprocess.check_output(['docker','image','inspect',a.image],text=True))[0]
proof.update(image=a.image,image_id=meta['Id'],base_image_id='sha256:a69064953b766ec5c800389b8e17a7d184f73aa8dd46cd4aa2048955ee86eb0f',backend='epoll',sqlite_pgo_enabled=True,application_pgo_enabled=True)
(a.candidate/'image-proof.json').write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps({k:proof[k] for k in ['image_id','source_snapshot_sha256','binary_sha256','sqlite_object_sha256','production_training_symbols_absent']},indent=2))
