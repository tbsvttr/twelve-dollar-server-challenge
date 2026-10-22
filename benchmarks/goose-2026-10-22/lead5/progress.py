"""File-only progress; no acceptance decision from partial measurements."""
import json, pathlib, sys
root=pathlib.Path(sys.argv[1]) if len(sys.argv)>1 else pathlib.Path(__file__).resolve().parent/'holdout-selected'
p=root/'measurements.json';rows=json.loads(p.read_text()) if p.exists() else []
rounds=[]
for trial in sorted({r['trial'] for r in rows}):
 group=[r for r in rows if r['trial']==trial]
 if len(group)==3 and {r['case_id'] for r in group}=={'goose','82','baseline'}:
  cases={r['case_id']:r for r in group};clean=all(r.get('completed') and not r.get('error') and not r.get('http_errors') and not any(r.get('socket_errors',{}).values()) for r in group)
  rounds.append({'round':trial,'clean':clean,'goose_over_rust_pct':round(100*(cases['goose']['rps']/cases['82']['rps']-1),3) if clean else None})
print(json.dumps({'attempts':len(rows),'rounds':rounds,'recent':[{'round':r['trial'],'case':r['case_id'],'rps':r.get('rps'),'p99_ms':r.get('p99_ms'),'socket_errors':r.get('socket_errors'),'error':r.get('error')} for r in rows[-3:]]},indent=2))
