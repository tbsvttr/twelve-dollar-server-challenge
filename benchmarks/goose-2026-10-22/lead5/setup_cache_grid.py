"""Freeze a runtime-only SQLite memory grid; never alter earlier evidence."""
import copy, hashlib, json, pathlib, shutil, subprocess
ROOT = pathlib.Path(__file__).resolve().parent
BATCH = ROOT/'cache-grid'
def save(path, value): path.write_text(json.dumps(value, indent=2)+'\n')
rows=json.loads((BATCH/'manifest.json').read_text()); template=rows[0]; rust=rows[1]
builds=json.loads((BATCH/'build-status.json').read_text())
proof=json.loads((ROOT/'candidates/cache/binary-proof.json').read_text())
common='twelve-goose-cache-common:2026-10-22'
common_meta=json.loads(subprocess.check_output(['docker','image','inspect',common], text=True))[0]
proof.update(image=common,image_id=common_meta['Id'],source_sha256=template['source_sha256'],sqlite_object_reused_from='sha256:a69064953b766ec5c800389b8e17a7d184f73aa8dd46cd4aa2048955ee86eb0f')
save(ROOT/'candidates/cache/binary-proof.json',proof)
base=ROOT.parent/'optimization/final'
base_row=next(r for r in json.loads((base/'manifest.json').read_text()) if r['id']=='goose')
base_build=json.loads((base/'build-status.json').read_text())['goose']
base_row.update(id='baseline',case_id='baseline',title='Retained Goose baseline',source_hashes='archives/prbaseline-sha256.json',source_dir='/suite/sources/prgoose',role='previous_implementation')
for src,dst in [('archives/prgoose-sha256.json','archives/prbaseline-sha256.json'),('source-inventories/prgoose.json','source-inventories/prbaseline.json')]:shutil.copy2(base/src,BATCH/dst)
shutil.copytree(base/'sources/prgoose',BATCH/'sources/prbaseline',dirs_exist_ok=True)
new_rows=[base_row,rust];new_builds={'baseline':base_build,'82':builds['82']}
for kib,mib in [(2000,1024),(8192,0),(32768,0),(131072,0),(32768,1024),(131072,1024)]:
    case=f'c{kib}-m{mib}'; image=f'twelve-goose-{case}:2026-10-22'
    directory=ROOT/'candidates'/case;directory.mkdir(exist_ok=True)
    dockerfile=f'FROM {common}\nENV GOOSE_SQLITE_CACHE_KIB={kib} GOOSE_SQLITE_MMAP_MIB={mib}\n'
    (directory/'Dockerfile').write_text(dockerfile)
    built=subprocess.run(['docker','build','-t',image,str(directory)],capture_output=True,text=True)
    (directory/'build.log').write_text(built.stdout+built.stderr);built.check_returncode()
    meta=json.loads(subprocess.check_output(['docker','image','inspect',image],text=True))[0]
    row=copy.deepcopy(template);row.update(id=case,case_id=case,title=f'Goose cache {kib} KiB mmap {mib} MiB',source_dir='/suite/sources/prgoose',source_hashes=f'archives/pr{case}-sha256.json',sqlite_memory={'cache_kib':kib,'mmap_mib':mib},backend='epoll')
    shutil.copy2(BATCH/'archives/prgoose-sha256.json',BATCH/row['source_hashes'])
    shutil.copy2(BATCH/'source-inventories/prgoose.json',BATCH/f'source-inventories/pr{case}.json')
    shutil.copytree(BATCH/'sources/prgoose',BATCH/f'sources/pr{case}',dirs_exist_ok=True)
    build=dict(pr=0,id=case,commit=row['commit'],status='built',exit_code=0,image=image,image_id=meta['Id'],proof=copy.deepcopy(proof))
    build['proof'].update(image=image,image_id=meta['Id'],image_environment={s.split('=',1)[0]:s.split('=',1)[1] for s in meta['Config']['Env'] if s.startswith('GOOSE_')})
    new_rows.append(row);new_builds[case]=build
save(BATCH/'manifest.json',new_rows);save(BATCH/'build-status.json',new_builds)
print(json.dumps({r['id']:new_builds[r['id']]['image_id'] for r in new_rows},indent=2))
