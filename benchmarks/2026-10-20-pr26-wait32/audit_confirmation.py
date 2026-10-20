#!/usr/bin/env python3
"""Audit frozen confirmation inputs without reading or changing its measurements.

With --snapshot FILE, create an input-hash baseline if FILE does not exist;
otherwise compare with it. Existing snapshots are never replaced. No Docker,
build, service, benchmark, or reporter is run.
"""
import argparse
import collections
import hashlib
import itertools
import json
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
from prepare_confirmation import FIXTURES, ORIGINAL, LEADER, REBUILT, TUNED, FOLLOWUP_TUNED


ROOT = Path(__file__).resolve().parent


def audit(directory):
    directory = directory.resolve()
    observed = {}

    def require(condition, message):
        if not condition:
            raise ValueError(message)

    def data(path):
        payload = path.read_bytes()
        observed[str(path.resolve())] = hashlib.sha256(payload).hexdigest()
        return payload

    def read(path):
        return json.loads(data(path))

    def local(root, name):
        require(isinstance(name, str) and not Path(name).is_absolute(), 'Invalid relative input path')
        path = root / name
        require(path.resolve().is_relative_to(root.resolve()), f'Input path escapes its stage: {name}')
        return path

    def check_hash(path, expected):
        require(hashlib.sha256(data(path)).hexdigest() == expected, f'Frozen hash mismatch: {path}')

    def check_frozen(root, hashes, analyzer=None):
        require(isinstance(hashes, dict) and bool(hashes), f'No frozen inputs for {root}')
        for name, expected in hashes.items():
            path = local(root, name)
            if name == 'analyze_experiment.py' and not path.is_file() and analyzer is not None:
                path = analyzer
            check_hash(path, expected)

    def builds(root):
        result = {}
        paths = sorted(path for path in root.glob('build-status-*-*.json')
                       if re.fullmatch(r'build-status-\d+-\d+\.json', path.name))
        require(bool(paths), f'No canonical build shards in {root}')
        for path in paths:
            values = read(path)
            require(isinstance(values, dict) and not (result.keys() & values.keys()),
                    f'Invalid or overlapping build shard: {path}')
            result.update(values)
        return result

    selection = read(directory / 'selection.json')
    state = read(directory / 'EXPERIMENT_STATE.json')
    manifest = read(directory / 'manifest.json')
    orders = read(directory / 'orders.json')
    check_hash(directory / 'selection.json', state.get('selection_sha256'))
    check_hash(directory / 'orders.json', state.get('orders_sha256'))
    selected = selection.get('selected_case')
    require(selected == state.get('selected_case'), 'State and selection disagree on the selected case')
    expected_cases = {selected, ORIGINAL, LEADER}
    require(len(expected_cases) == 3 and state.get('stage') == 'confirmation'
            and state.get('expected_trials') == 6 and set(state.get('cases', [])) == expected_cases,
            'Confirmation state must declare the selected case, two controls, and six trials')
    require(isinstance(manifest, list) and len(manifest) == 3,
            'Confirmation manifest must contain exactly three cases')
    indexed = {row['case_id']: row for row in manifest}
    require(set(indexed) == expected_cases and all(row.get('id') == case for case, row in indexed.items()),
            'Confirmation manifest differs from the selected case set')
    screen_root = Path(selection['screen_root']).resolve()
    require(screen_root == directory.parent, 'Selection must reference the direct parent screening stage')
    code = selection.get('analysis_code', {})
    analyzer = Path(code.get('path', str(screen_root / 'analyze_experiment.py'))).resolve()
    require(analyzer in {(screen_root / 'analyze_experiment.py').resolve(),
                         (ROOT / 'analyze_experiment.py').resolve()}, 'Unexpected frozen analyzer path')
    if code:
        check_hash(analyzer, code.get('sha256'))
    frozen = selection.get('screen_evidence_sha256')
    check_frozen(screen_root, frozen, analyzer)
    parent_state = read(screen_root / 'EXPERIMENT_STATE.json')
    source_manifest = {row['case_id']: row for row in read(screen_root / 'manifest.json')}
    source_builds = builds(screen_root)
    actual_builds = builds(directory)
    require(set(actual_builds) == expected_cases, 'Confirmation build cases differ from selection')
    for case, row in indexed.items():
        require(row == source_manifest.get(case), f'Manifest changed from frozen screen: {case}')
        build = actual_builds[case]
        require(build == source_builds.get(case), f'Build changed from frozen screen: {case}')
        require(build.get('exit_code') == 0 and build.get('commit') == row.get('commit')
                and re.fullmatch(r'sha256:[0-9a-f]{64}', build.get('image_id', '')) is not None
                and build.get('image') == build['image_id'], f'Unpinned or mismatched build: {case}')
        inventory_path = local(directory, row['source_hashes'])
        check_hash(inventory_path, frozen[row['source_hashes']])
        inventory = read(inventory_path)
        require(hashlib.sha256(json.dumps(inventory, sort_keys=True).encode()).hexdigest() == row['source_sha256']
                and len(inventory) == row['source_file_count'], f'Invalid source inventory: {case}')
        if row.get('local_variant'):
            check_hash(local(directory, row['patch']), row['patch_sha256'])
    summary = selection.get('screen_analysis', {})
    require(summary.get('complete') is True and summary.get('evidence_valid') is True,
            'Frozen screening analysis was not complete and valid')
    metrics = {row['case_id']: row for row in summary.get('cases', [])}
    stage = selection.get('screen_stage', 'screening')
    require(stage == state.get('source_screen_stage'), 'Screen-stage declaration differs')
    candidates = TUNED if stage == 'screening' else FOLLOWUP_TUNED
    controls = (ORIGINAL, REBUILT) if stage == 'screening' else (ORIGINAL,)
    require(stage in ('screening', 'followup') and summary.get('stage') == stage,
            'Unknown or inconsistent source-screen stage')
    clean = [case for case in candidates if metrics.get(case, {}).get('clean_trials') == 3]
    require(clean and all(row.get('valid_trials') == 3 for row in metrics.values()),
            'Source screen lacks valid trials or a clean selectable candidate')
    winner = min(clean, key=lambda case: (-metrics[case]['median_successful_rps'], case))
    require(selected == winner, 'Confirmation candidate differs from the frozen selection rule')
    for control in controls:
        require(metrics[control].get('clean_trials') == 3
                and metrics[selected]['median_successful_rps'] / metrics[control]['median_successful_rps'] >= 1.05,
                f'Selection threshold/clean-control failure: {control}')
    for case in expected_cases:
        require(metrics[case].get('image_id') == actual_builds[case]['image_id']
                and metrics[case].get('source_sha256') == indexed[case]['source_sha256'],
                f'Confirmation identity differs from frozen screen summary: {case}')
    if stage == 'followup':
        plan = read(screen_root / 'followup-plan.json')
        require(plan == selection.get('followup_plan'), 'Frozen follow-up plan changed')
        lineage = selection.get('initial_screen_lineage')
        require(lineage == plan.get('initial_screen_evidence_sha256')
                and lineage == parent_state.get('initial_screen_evidence_sha256'), 'Initial-screen lineage differs')
        initial_root = Path(plan['initial_screen_root']).resolve()
        require(initial_root == screen_root.parent, 'Unexpected initial-screen lineage directory')
        check_frozen(initial_root, lineage)
    fixtures = state.get('fixture_hashes', {})
    require(set(fixtures) == set(FIXTURES) and fixtures == parent_state.get('fixture_hashes'),
            'Confirmation must retain exactly the twelve original fixtures')
    for name, expected in fixtures.items():
        require(expected == frozen[name], f'Selection fixture digest differs: {name}')
        check_hash(local(directory, name), expected)
    check_hash(directory / 'run.py', state.get('controller_sha256'))
    require(state.get('controller_sha256') == frozen['run.py'], 'Confirmation controller changed')
    require(state.get('load_image') == parent_state.get('load_image')
            and re.fullmatch(r'sha256:[0-9a-f]{64}', state.get('load_image', '')) is not None,
            'Confirmation load image changed')
    if (directory / 'shared-sha256.json').exists():
        # This file is controller output, not part of the pre/post input baseline.
        require(json.loads((directory / 'shared-sha256.json').read_text()) == fixtures,
                'Controller shared hashes differ from the frozen fixtures')
    require(isinstance(orders, dict) and set(orders) == {str(n) for n in range(1, 7)},
            'Orders must declare exactly six rounds')
    values = [orders[str(n)] for n in range(1, 7)]
    require(all(isinstance(order, list) and len(order) == 3 and set(order) == expected_cases for order in values)
            and {tuple(order) for order in values} == set(itertools.permutations(expected_cases)),
            'Orders must contain all six case permutations exactly once')
    for position in range(3):
        require(collections.Counter(order[position] for order in values) ==
                collections.Counter({case: 2 for case in expected_cases}), 'Unbalanced order positions')
    data(Path(__file__))
    data(ROOT / 'prepare_confirmation.py')
    for filename, expected in observed.items():
        require(hashlib.sha256(Path(filename).read_bytes()).hexdigest() == expected,
                f'Input changed while auditing: {filename}')
    return dict(valid=True, confirmation_directory=str(directory), selected_case=selected,
                source_screen_stage=stage, expected_trials=6, cases=sorted(expected_cases),
                identities={case: {'image_id': actual_builds[case]['image_id'],
                                   'source_sha256': indexed[case]['source_sha256'],
                                   'commit': indexed[case]['commit'],
                                   'settings': indexed[case].get('local_variant')}
                            for case in sorted(expected_cases)},
                selection_sha256=observed[str((directory / 'selection.json').resolve())],
                orders_sha256=observed[str((directory / 'orders.json').resolve())],
                fixture_hashes=fixtures, lineage_valid=True,
                input_sha256=observed,
                scope='Frozen inputs and selection lineage only; no confirmation measurements were read.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('confirmation_directory', type=Path)
    parser.add_argument('--snapshot', type=Path, help='Create a baseline if absent, otherwise compare; never overwrite.')
    args = parser.parse_args()
    try:
        result = audit(args.confirmation_directory)
        if args.snapshot:
            if args.snapshot.exists():
                baseline = json.loads(args.snapshot.read_text())
                if baseline.get('input_sha256') != result['input_sha256']:
                    raise ValueError('Confirmation input hashes differ from the saved pre-run baseline')
                result['snapshot_status'] = 'matched'
            else:
                with args.snapshot.open('x') as stream:
                    json.dump({'confirmation_directory': result['confirmation_directory'],
                               'input_sha256': result['input_sha256']}, stream, indent=2)
                    stream.write('\n')
                result['snapshot_status'] = 'created'
            result['snapshot'] = str(args.snapshot)
    except (OSError, ValueError, TypeError, KeyError, OverflowError, ZeroDivisionError) as error:
        result = dict(valid=False, error=str(error))
    print(json.dumps(result, indent=2, allow_nan=False))
    raise SystemExit(0 if result['valid'] else 1)


if __name__ == '__main__':
    main()
