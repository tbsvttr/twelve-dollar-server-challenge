"""Resource-limited exact-runtime repair, isolated from the main worker status."""
import json
import build_41_90 as worker
worker.STATUS=worker.ROOT/'retry71-status.json'
original_docker=worker.docker
def docker(args,*pos,**kw):
 args=list(args)
 if args and args[0]=='run':
  args[args.index('--cpus')+1]='0.5'
  args[args.index('--memory')+1]='2g'
  args[args.index('--memory-swap')+1]='2g'
 if kw.get('timeout')==900:kw['timeout']=2400
 return original_docker(args,*pos,**kw)
worker.docker=docker
row=next(r for r in json.loads((worker.ROOT/'manifest.json').read_text()) if r['pr']==71)
worker.build(row,{})
