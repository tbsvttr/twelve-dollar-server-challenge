"""Select JDK25 required by submitted compact-header JVM flag; app scripts untouched."""
import json,subprocess,time
from pathlib import Path
import build_41_90 as w
ROOT=w.ROOT
state=json.loads((ROOT/'build-status-41-90.json').read_text())
r=dict(state['85']);jdk=state['88'];start=time.monotonic()
src='twelve-current-jdk25-for85';target='twelve-current-repair85'
log=ROOT/'logs'/'runtime-repair-pr85.log'
cache=ROOT/'runtime-cache'/'jdk25-for85'
with log.open('w') as out:
 def run(args,timeout=180):
  out.write('\n$ docker '+' '.join(args)+'\n');out.flush()
  p=subprocess.run(['docker',*args],stdout=out,stderr=subprocess.STDOUT,timeout=timeout)
  if p.returncode:raise RuntimeError(f'Docker step failed: {args[0]} ({p.returncode})')
 run(['create','--name',src,jdk['image_id']])
 try:run(['cp',src+':/opt/jdk',str(cache)])
 finally:run(['rm',src])
 run(['run','-d','--name',target,'--cpus','2','--memory','3g','--memory-swap','3g','--mount',f'type=bind,src={ROOT},dst=/evidence,readonly',r['image_id'],'sleep','infinity'])
 try:
  run(['cp',str(cache),target+':/opt/jdk-25'])
  run(['exec',target,'bash','-c','for name in java javac jar; do ln -sf /opt/jdk-25/bin/$name /usr/local/bin/$name; done; java -version; java -XX:+UseCompactObjectHeaders -version'])
  run(['exec',target,'runuser','-u','bench','--',*w.ENV,'JAVA_HOME=/opt/jdk-25','bash','/suite/sources/pr85/build.sh'])
  p=subprocess.run(['docker','commit',target,r['image']],capture_output=True,text=True,check=True,timeout=180)
  r['image_id']=p.stdout.strip();r['runtime_adapter']='JDK21 minimum installer satisfied with Temurin25.0.4.1+1, required by original -XX:+UseCompactObjectHeaders flag; application/build/start scripts unchanged.'
  r['runtime_reuse']={'source_pr':88,'source_image_id':jdk['image_id'],'sdk_path':'/opt/jdk','version':'25.0.4.1+1','arm64_archive_sha256':'69df11a02cfa3ef7d7ca645e03edce6778ec090e100f6ae2b42097865730ac52'}
  r['runtime_repair_elapsed_s']=round(time.monotonic()-start,2);r['runtime_repair_log']='logs/runtime-repair-pr85.log'
 finally:run(['rm','-f',target])
(ROOT/'repair85-status.json').write_text(json.dumps({'85':r},indent=2)+'\n')
subprocess.run(['rm','-rf',str(cache)],check=True)
print('PR85 runtime repaired, image '+r['image_id'],flush=True)
