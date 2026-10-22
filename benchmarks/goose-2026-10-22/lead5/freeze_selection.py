"""Bind the chosen immutable candidate and protocol before any holdout samples."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('batch', type=Path)
ap.add_argument('--diagnostic', type=Path, required=True)
args = ap.parse_args()
root = Path(__file__).resolve().parent
batch = args.batch.resolve()
if (batch/'selection.json').exists() or (batch/'measurements.json').exists():
    raise SystemExit('Refusing to replace a selection or select after holdout starts')
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
manifest = json.loads((batch/'manifest.json').read_text())
builds = json.loads((batch/'build-status.json').read_text())
row = next(value for value in manifest if value['id'] == 'goose')
build = builds['goose']
for case, value in builds.items():
    actual = json.loads(subprocess.check_output(['docker', 'image', 'inspect', value['image']], text=True))[0]
    if actual['Id'] != value['image_id']:
        raise SystemExit('Image tag changed: ' + case)
diagnostic = json.loads(args.diagnostic.read_text())
if not diagnostic.get('completed') or not diagnostic.get('aa_gate_passed'):
    raise SystemExit('Selection diagnostic is incomplete or failed its A/A gate')
chosen = [attempt for attempt in diagnostic['attempts'] if any(
    instance.get('source_sha256') == row['source_sha256'] and
    instance.get('image_id') == build['image_id'] and
    instance.get('binary_sha256') == build['proof']['binary_sha256']
    for instance in attempt.get('instances', []))]
if len(chosen) < 2 or any(not attempt.get('valid') or '82' not in attempt['requested_pair'] for attempt in chosen):
    raise SystemExit('Chosen source/image/binary needs two clean Rust selection pairs')
record = dict(recorded_at=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    candidate=dict(id='goose', source_sha256=row['source_sha256'],
                   image_id=build['image_id'], binary_sha256=build['proof']['binary_sha256']),
    manifest_sha256=sha(batch/'manifest.json'), build_status_sha256=sha(batch/'build-status.json'),
    protocol_sha256=sha(root/'PROTOCOL.md'), declaration_sha256=sha(root/'PROTOCOL-monotonic.md'),
    load_generator_sha256=sha(batch/'load-generator.json'),
    verification_sha256=sha(batch/'verification.json'),
    parser_checks_sha256=sha(batch/'parser-checks.json'),
    edge_checks_sha256=sha(batch/'edge-checks.json'),
    selection_diagnostic=str(args.diagnostic.resolve().relative_to(root)),
    selection_diagnostic_sha256=sha(args.diagnostic),
    diagnostic_scope='selection only; servers shared one guest CPU',
    selected_diagnostic_ratios=[attempt['requested_first_second_ratio'] for attempt in chosen],
    planned_confirmation=dict(rounds=10, maximum_replacement_rounds=2, seconds=45,
                              warmup_seconds=2, controls=['82', 'baseline']))
(batch/'selection.json').write_text(json.dumps(record, indent=2)+'\n')
print(json.dumps(record, indent=2))
