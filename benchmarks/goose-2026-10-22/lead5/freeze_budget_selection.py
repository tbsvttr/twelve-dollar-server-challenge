"""Freeze a resource-validated candidate after sequential selection only."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import statistics
import subprocess

ROOT = Path(__file__).resolve().parent
ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('batch', type=Path)
ap.add_argument('--diagnostic', type=Path, required=True)
args = ap.parse_args()
batch, diagnostic = args.batch.resolve(), args.diagnostic.resolve()
if (batch/'selection.json').exists() or (batch/'measurements.json').exists():
    raise SystemExit('Refusing to replace selection or select after holdout begins')
read = lambda p: json.loads(p.read_text())
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
spec = importlib.util.spec_from_file_location('budget_selection_checks', ROOT/'analyze_holdout.py')
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)
suite = diagnostic.parent
rows = read(diagnostic)
manifest = {str(row['id']): row for row in read(suite/'manifest.json')}
builds = read(suite/'build-status.json')
shared = read(suite/'shared-sha256.json')
if len(rows) != 6:
    raise SystemExit('Require exactly six retained sequential selection attempts')
ratios, previous_ratios = [], []
for trial in (1, 2):
    group = [row for row in rows if row.get('trial') == trial]
    if sorted(row['case_id'] for row in group) != ['82', 'goose', 'previous']:
        raise SystemExit('Selection triplet incomplete or duplicated')
    rates = {}
    for row in group:
        case = row['case_id']
        issues = (checks.problems(row, 15)
                  + checks.record_identity(row, manifest[case], builds[case], shared)
                  + checks.evidence.backend_issues(suite, row, manifest[case], builds[case]))
        if issues:
            raise SystemExit(str((trial, case, issues)))
        rates[case] = checks.parse_output(row['output'])['successful_rps']
    ratios.append(rates['goose']/rates['82'])
    previous_ratios.append(rates['goose']/rates['previous'])
geomean = lambda xs: math.exp(statistics.mean(map(math.log, xs)))
if geomean(ratios) < 1.05 or geomean(previous_ratios) <= 1:
    raise SystemExit('Predeclared selection margin failed: ' + json.dumps(dict(
        rust_ratio=geomean(ratios), previous_ratio=geomean(previous_ratios))))
target_manifest = {str(row['id']): row for row in read(batch/'manifest.json')}
target_builds = read(batch/'build-status.json')
for case, build in target_builds.items():
    actual = json.loads(subprocess.check_output(
        ['docker', 'image', 'inspect', build['image']], text=True))[0]
    if actual['Id'] != build['image_id']:
        raise SystemExit('Image tag changed: ' + case)
candidate, build = target_manifest['goose'], target_builds['goose']
if (candidate['source_sha256'] != manifest['goose']['source_sha256']
        or build['image_id'] != builds['goose']['image_id']
        or build['proof']['binary_sha256'] != builds['goose']['proof']['binary_sha256']):
    raise SystemExit('Candidate differs from measured selection identity')
budget_path = ROOT/'candidates/hmac-budget/resource-budget-build.json'
budget = read(budget_path)
assert budget['exit_code'] == 0 and budget['build_uid'] == 1001
assert budget['normal_build'] and not budget['sqlite_object_reuse']
assert budget['limits']['cpu.max'] == '100000 100000'
assert budget['limits']['memory.max'] == str(2*1024**3)
assert budget['limits']['memory.swap.max'] == '0'
assert budget['memory_peak_bytes'] < 2*1024**3
assert budget['bin/server']['sha256'] == build['proof']['binary_sha256']
record = dict(recorded_at=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    candidate=dict(id='goose', source_sha256=candidate['source_sha256'],
        image_id=build['image_id'], binary_sha256=build['proof']['binary_sha256']),
    manifest_sha256=sha(batch/'manifest.json'), build_status_sha256=sha(batch/'build-status.json'),
    protocol_sha256=sha(ROOT/'PROTOCOL.md'), declaration_sha256=sha(ROOT/'PROTOCOL-monotonic.md'),
    additional_protocol='PROTOCOL-resource-budget.md',
    candidate_protocol_sha256=sha(ROOT/'PROTOCOL-resource-budget.md'),
    additional_protocol_sha256=sha(ROOT/'PROTOCOL-resource-budget.md'),
    hmac_protocol_sha256=sha(ROOT/'PROTOCOL-hmac-only.md'),
    resource_budget_build_proof=str(budget_path.relative_to(ROOT)),
    resource_budget_build_proof_sha256=sha(budget_path),
    load_generator_sha256=sha(batch/'load-generator.json'),
    verification_sha256=sha(batch/'verification.json'),
    parser_checks_sha256=sha(batch/'parser-checks.json'), edge_checks_sha256=sha(batch/'edge-checks.json'),
    selection_diagnostic=str(diagnostic.relative_to(ROOT)), selection_diagnostic_sha256=sha(diagnostic),
    diagnostic_scope='selection only; sequential one-server budget',
    selected_diagnostic_ratios=ratios, selected_previous_ratios=previous_ratios,
    previous_completed_holdout='holdout-selected/finalholdout-summary.json',
    previous_completed_holdout_sha256=sha(ROOT/'holdout-selected/finalholdout-summary.json'),
    planned_confirmation=dict(rounds=10, maximum_replacement_rounds=2, seconds=45,
                              warmup_seconds=2, controls=['82', 'baseline']))
(batch/'selection.json').write_text(json.dumps(record, indent=2)+'\n')
print(json.dumps(record, indent=2))
