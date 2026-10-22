"""Attach an immutable case snapshot to a new discovery batch."""
import argparse
import copy
import json
from pathlib import Path
import shutil

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('batch', type=Path)
ap.add_argument('previous', type=Path)
ap.add_argument('--case', required=True)
ap.add_argument('--id', required=True)
args = ap.parse_args()
rows = json.loads((args.batch/'manifest.json').read_text())
if any(str(row['id']) == args.id for row in rows):
    raise SystemExit('Refusing to replace existing case')
old = next(row for row in json.loads((args.previous/'manifest.json').read_text()) if str(row['id']) == args.case)
row = copy.deepcopy(old)
row.update(id=args.id, case_id=args.id, source_hashes=f'archives/pr{args.id}-sha256.json',
           source_dir=old.get('source_dir', '/suite/sources/pr'+args.case))
shutil.copy2(args.previous/old['source_hashes'], args.batch/row['source_hashes'])
shutil.copy2(args.previous/'source-inventories'/f'pr{args.case}.json', args.batch/'source-inventories'/f'pr{args.id}.json')
shutil.copytree(args.previous/'sources'/f'pr{args.case}', args.batch/'sources'/f'pr{args.id}')
builds = json.loads((args.batch/'build-status.json').read_text())
builds[args.id] = copy.deepcopy(json.loads((args.previous/'build-status.json').read_text())[args.case])
builds[args.id]['id'] = args.id
rows.append(row)
(args.batch/'manifest.json').write_text(json.dumps(rows, indent=2)+'\n')
(args.batch/'build-status.json').write_text(json.dumps(builds, indent=2)+'\n')
