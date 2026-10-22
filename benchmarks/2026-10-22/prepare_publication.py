"""Prepare reviewable public text artifacts; performs no remote writes."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PREFIX = 'benchmarks/2026-10-22/'
SKIP_DIRS = {'seed', '__pycache__', 'publication', 'pull-files'}
SKIP_FILES = {'controller.lock', 'TASK_STATE.json', 'host-context-before.json'}

def main():
    summary = json.loads((ROOT / 'summary.json').read_text())
    audit = json.loads((ROOT / 'audit-final.json').read_text())
    assert summary['complete'], 'Incomplete summary'
    assert audit.get('passed_all') is True, 'Independent audit must pass'
    elements, inventory = [], []
    for path in sorted(ROOT.rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT)
        if (set(relative.parts) & SKIP_DIRS or path.name in SKIP_FILES
                or path.suffix in {'.pyc', '.partial'}
                or relative.as_posix().startswith('sources/pr82/')
                or relative.parts[0] == 'archives' and path.suffix != '.json'):
            continue
        data = path.read_bytes()
        content = data.decode('utf-8')
        elements.append({'path': PREFIX + relative.as_posix(),
                         'mode': '100755' if path.stat().st_mode & 0o111 else '100644',
                         'type': 'blob', 'content': content})
        inventory.append({'path': relative.as_posix(), 'bytes': len(data),
                          'sha256': hashlib.sha256(data).hexdigest()})
    target = ROOT / 'publication'
    target.mkdir(exist_ok=True)
    (target / 'tree-elements.json').write_text(json.dumps(elements, ensure_ascii=False))
    (target / 'artifact-inventory.json').write_text(json.dumps(inventory, indent=2)+'\n')
    print(json.dumps({'files':len(elements),'bytes':sum(r['bytes'] for r in inventory),
                      'tree_payload_bytes':(target/'tree-elements.json').stat().st_size,
                      'sha256':hashlib.sha256((target/'tree-elements.json').read_bytes()).hexdigest()}))

if __name__ == '__main__':
    main()
