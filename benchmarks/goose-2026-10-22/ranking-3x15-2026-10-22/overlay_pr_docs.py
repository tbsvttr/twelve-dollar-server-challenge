"""Run in one restricted disposable container; update only PR documentation."""
import hashlib
import json
import shutil
from pathlib import Path

EVIDENCE = Path('/evidence')
SOURCE = Path('/suite/sources/prgoose')
old = json.loads((EVIDENCE / 'original-goose-source-sha256.json').read_text())
new = json.loads((EVIDENCE / 'archives/pr143-sha256.json').read_text())
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
for name, expected in old.items():
    assert sha(SOURCE / name) == expected, name
binary_before = sha(SOURCE / 'bin/server')
for name in ['README.md', 'benchmark-results.json', 'validation-results.json']:
    shutil.copy2(EVIDENCE / 'sources/prgoose' / name, SOURCE / name)
for name, expected in new.items():
    assert sha(SOURCE / name) == expected, name
assert sha(SOURCE / 'bin/server') == binary_before
print(json.dumps(dict(source_files_verified=len(new), source_hashes=new,
    source_snapshot_sha256=hashlib.sha256(json.dumps(new, sort_keys=True).encode()).hexdigest(),
    binary_sha256=binary_before, documentation_only_overlay=True,
    runtime_and_build_files_unchanged=18, binary_unchanged=True,
    binary_rebuilt=False, original_build_receipt='../lead5/candidates/hmac-budget/resource-budget-build.json',
    architecture='aarch64', image_environment={'GOOSE_IO_BACKEND':'epoll'})))
