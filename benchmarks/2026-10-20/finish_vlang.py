"""One bounded GC config correction; preserve exact V compiler and app sources."""
import json,subprocess,time
import build_41_90 as w
w.STATUS=w.ROOT/'repair-v-status.json'
s=json.loads(w.STATUS.read_text());r=s['70'];name=r['retained_container'];log='build-pr70.log'
r['fallback_disabled']=True
start=time.monotonic()
rc=w.docker(['exec',name,'bash','/evidence/runtime-scripts/vlang-gc-config-arm64.sh'],log,timeout=120,check=False)
if rc==0:
 rc=w.docker(['exec',name,'runuser','-u','bench','--',*w.ENV,'V_MACOS_V3_NO_FALLBACK=1','bash','/suite/sources/pr70/build.sh'],log,timeout=180,check=False)
r['exit_code']=rc;r['state']='built' if rc==0 else 'build_failed'
r['native_gc_config']='USE_MMAP=1 plus existing USE_MUNMAP=1; vendored GC source unchanged'
r['native_gc_commit']='c1a45b9ad86f7449509a86360a6c0746615d8c97';r['build_memory_limit_gib']=6
r['exact_pin_retry_elapsed_s']=round(time.monotonic()-start,2)
r['failure_tail']=(w.ROOT/'logs'/log).read_text()[-6000:] if rc else None
w.docker(['exec',name,'bash','-c','rm -f /usr/local/bin/nproc; rm -rf /home/bench/.cache/v/v1-fallback /tmp/*'],log)
checkpoint='twelve-current-v-toolchain:2026-10-20'
checkpoint_id=w.docker(['commit',name,checkpoint],timeout=180)
r['toolchain_image']=checkpoint;r['toolchain_image_id']=checkpoint_id
if rc==0:
 w.docker(['tag',checkpoint,r['image']]);r['image_id']=checkpoint_id
 r.pop('retained_container',None);w.docker(['rm','-f',name],check=False)
else:r['reason']='Original application build fails with exact pinned compiler and automatic version fallback disabled; see log.'
w.save(s);print('PR 70 exact compiler:',r['state'],flush=True)
w.BASE=checkpoint
w.ENV.append('V_MACOS_V3_NO_FALLBACK=1')
row=next(x for x in json.loads((w.ROOT/'manifest.json').read_text()) if x['pr']==69)
w.build(row,s)
s['69']['toolchain_reuse']={'source_pr':70,'image':checkpoint,'image_id':checkpoint_id,'same_V_VC_TCC_and_patches':True,'native_gc_commit':r['native_gc_commit'],'native_gc_config':r['native_gc_config']}
s['69']['fallback_disabled']=True;s['69']['build_memory_limit_gib']=6
w.save(s)
