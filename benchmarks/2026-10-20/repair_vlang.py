"""Repair the pinned V compiler's architecture, then reuse it for the other app."""
import json,subprocess
import build_41_90 as worker
worker.STATUS=worker.ROOT/'repair-v-status.json'
rows={r['pr']:r for r in json.loads((worker.ROOT/'manifest.json').read_text())}
status={}
worker.build(rows[70],status)
if status['70']['state']=='built':
 subprocess.run(['python3',str(worker.ROOT/'capture_vlang.py'),'70','69','repair-v-status.json'],check=True)
 worker.build(rows[69],status)
