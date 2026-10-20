#!/usr/bin/env python3
"""Prepare a fresh confirmation stage after a strictly valid initial screen.

Preparation performs offline validation and file copies only. It never runs Docker,
builds a binary, starts a service, or changes the screening evidence.
"""
import argparse
import collections
import datetime
import hashlib
import importlib.util
import itertools
import json
import math
import random
import re
import shutil
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
ORIGINAL = '26-original'
LEADER = '82-leader'
REBUILT = '26-b128-w4000'
TUNED = ('26-b32-w4000', '26-b128-w250', '26-b32-w250')
INITIAL_CASES = frozenset((ORIGINAL, LEADER, REBUILT, *TUNED))
FOLLOWUP_TUNED = ('26-b32-w4000', '26-b16-w4000', '26-b8-w4000')
FOLLOWUP_CASES = frozenset((ORIGINAL, LEADER, *FOLLOWUP_TUNED))
FIXTURES = (
    'seed/feed.db', 'seed/tokens.json', 'mixed.lua', 'test/test.sh',
    'semantic.py', 'serve.py', 'bench/nginx.conf', 'seccomp-io-uring.json',
    'test/golden/feed.json', 'test/golden/post-1.json',
    'test/golden/post-250000.json', 'test/golden/post-500000.json',
)
ORDER_SEED = 20261026


def read_json(path):
    return json.loads(path.read_text())


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def relative_file(root, name):
    require(isinstance(name, str), 'Evidence path must be a string')
    path = root / name
    require(not Path(name).is_absolute() and path.resolve().is_relative_to(root.resolve()),
            f'Evidence path escapes stage directory: {name}')
    require(path.is_file(), f'Missing evidence file: {path}')
    return path


def build_records(root):
    result = {}
    shards = sorted(p for p in root.glob('build-status-*-*.json')
                    if re.fullmatch(r'build-status-\d+-\d+\.json', p.name))
    require(bool(shards), 'No canonical build-status shards found')
    for path in shards:
        values = read_json(path)
        require(isinstance(values, dict), f'Invalid build shard: {path}')
        require(not (result.keys() & values.keys()), f'Duplicate case in build shards: {path}')
        result.update(values)
    return result, shards


def stage_input_paths(root, manifest, shards):
    names = set(FIXTURES) | {
        'manifest.json', 'measurements.json', 'verification.json',
        'environment-bench.json', 'environment-verify.json',
        'EXPERIMENT_STATE.json', 'run.py',
    }
    names.update(str(path.relative_to(root)) for path in shards)
    for row in manifest:
        names.add(row['source_hashes'])
        if row.get('patch'):
            names.add(row['patch'])
    for optional in ('analysis-summary.json', 'shared-sha256.json', 'orders.json', 'followup-plan.json'):
        if (root / optional).exists():
            names.add(optional)
    paths = {name: relative_file(root, name) for name in sorted(names)}
    paths['analyze_experiment.py'] = analyzer_path(root)
    return paths


def snapshot(paths):
    return {name: sha256(path) for name, path in paths.items()}


def analyzer_path(root):
    path = root / 'analyze_experiment.py'
    if not path.is_file():
        path = ROOT / 'analyze_experiment.py'
    require(path.is_file(), f'Missing offline analyzer: {path}')
    return path


def analyze_readonly(root):
    path = analyzer_path(root)
    spec = importlib.util.spec_from_file_location('_tuning26_stage_analyzer', path)
    require(spec is not None and spec.loader is not None, 'Cannot load stage analyzer')
    module = importlib.util.module_from_spec(spec)
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
        require(callable(getattr(module, 'analyze_stage', None)),
                'Analyzer must provide pure analyze_stage(stage_dir)')
        return module.analyze_stage(root)
    finally:
        sys.dont_write_bytecode = previous
        sys.modules.pop(spec.name, None)


def _validate_screen(root, selected, expected_cases, tuned, clean_controls, kind):
    """Return a fresh strict analysis and a stable hash snapshot; never write files."""
    root = root.resolve()
    manifest = read_json(root / 'manifest.json')
    require(isinstance(manifest, list), 'Manifest must be a list')
    ids = [str(row.get('case_id', row.get('id', ''))) for row in manifest]
    require(len(ids) == len(expected_cases) and len(set(ids)) == len(expected_cases)
            and set(ids) == expected_cases, f'{kind} must contain exactly its declared cases')
    for row, case in zip(manifest, ids):
        require(str(row.get('id')) == case, f'Manifest id/case_id mismatch: {case}')
    builds, shards = build_records(root)
    require(set(builds) == expected_cases, 'Build shards must cover exactly the declared cases')
    paths = stage_input_paths(root, manifest, shards)
    before = snapshot(paths)
    state = read_json(root / 'EXPERIMENT_STATE.json')
    if kind == 'followup':
        require(state.get('stage') == 'followup_screening' and state.get('expected_trials') == 3,
                'Explicit follow-up state with three rounds is required')
        require(set(state.get('selection_candidates', [])) == set(tuned) and
                state.get('selection_controls') == [ORIGINAL] and
                state.get('selection_minimum_ratio') == 1.05,
                'Follow-up selection declaration differs from the bounded plan')
        require('followup-plan.json' in before and before['followup-plan.json'] == state.get('plan_sha256'),
                'Frozen follow-up plan is missing or changed')
    environment = read_json(root / 'environment-bench.json')
    expected = state.get('fixture_hashes', {})
    require(set(expected) == set(FIXTURES), 'Expected exactly the twelve frozen fixtures')
    require(all(before[name] == expected[name] for name in FIXTURES), 'Frozen fixture mismatch')
    require(environment.get('shared_hashes') == expected, 'Screen environment fixture mismatch')
    require(before['run.py'] == state.get('controller_sha256'), 'Screen controller hash mismatch')
    require(environment.get('wrk') == {
        'threads': 2, 'connections': 64, 'warmup_seconds': 2,
        'measurement_seconds': 15, 'trials': 3,
    }, 'Screen configuration must be the declared three 15-second rounds')
    load_image = state.get('load_image', '')
    require(re.fullmatch(r'sha256:[0-9a-f]{64}', load_image) is not None,
            'Load image must be an immutable SHA256 image ID')
    require(environment.get('load_image_id') == load_image, 'Load image identity mismatch')
    for row, case in zip(manifest, ids):
        inventory = read_json(relative_file(root, row['source_hashes']))
        digest = hashlib.sha256(json.dumps(inventory, sort_keys=True).encode()).hexdigest()
        require(digest == row['source_sha256'], f'Source inventory digest mismatch: {case}')
        build = builds[case]
        require(build.get('exit_code') == 0 and build.get('commit') == row.get('commit'),
                f'Invalid or mismatched build: {case}')
        require(re.fullmatch(r'sha256:[0-9a-f]{64}', build.get('image', '')) is not None,
                f'Build must use an immutable image ID: {case}')
        require(build['image'] == build.get('image_id'), f'Build image ID mismatch: {case}')
    summary = analyze_readonly(root)
    require(summary.get('stage') == kind and summary.get('expected_trials') == 3,
            'Analyzer did not identify the declared screening stage')
    require(summary.get('complete') is True and not summary.get('global_issues'),
            'Screen is incomplete or has structural issues; inspect analysis-summary.json')
    cases = summary.get('cases', [])
    require(isinstance(cases, list) and len(cases) == len(expected_cases) and
            {case.get('case_id') for case in cases} == expected_cases,
            'Analyzer case coverage mismatch')
    indexed = {case['case_id']: case for case in cases}
    for case, values in indexed.items():
        require(values.get('expected_trials') == 3 and values.get('completed_trials') == 3 and
                values.get('valid_trials') == 3, f'Screen case lacks three valid trials: {case}')
        value = values.get('median_successful_rps')
        require(type(value) in (int, float) and math.isfinite(value) and value > 0,
                f'Invalid screen throughput: {case}')
    for control in clean_controls:
        require(indexed[control].get('clean_trials') == 3,
                f'Baseline control lacks three clean trials: {control}')
    clean_tuned = [case for case in tuned if indexed[case].get('clean_trials') == 3]
    require(bool(clean_tuned), 'No tuned setting has three clean trials')
    winner = min(clean_tuned, key=lambda case: (-indexed[case]['median_successful_rps'], case))
    if selected is not None:
        require(selected in tuned, 'Selected case is not a declared candidate for this stage')
        require(selected == winner, f'Selected case is not the declared median winner: {winner}')
    ratios = {case: indexed[winner]['median_successful_rps'] /
              indexed[case]['median_successful_rps'] for case in clean_controls}
    require(all(value >= 1.05 for value in ratios.values()),
            'Winner must improve at least 5% versus every declared selection control')
    if kind == 'screening':
        candidate = summary.get('selected_candidate')
        require(isinstance(candidate, dict) and candidate.get('case_id') == winner,
                'Analyzer candidate disagrees with independently checked median winner')
        require(candidate.get('promising') is True, 'Analyzer did not accept the promising screen winner')
    require(snapshot(paths) == before, 'Screen evidence changed while validation was running')
    return {
        'root': root, 'manifest': manifest, 'builds': builds, 'state': state,
        'summary': summary, 'input_paths': paths, 'evidence_sha256': before,
        'winner': winner, 'ratios': ratios, 'load_image': load_image, 'screen_kind': kind,
        'analysis_code': {'path': str(analyzer_path(root)), 'sha256': before['analyze_experiment.py']},
    }


def validate_initial_screen(root, selected=None):
    return _validate_screen(root, selected, INITIAL_CASES, TUNED, (ORIGINAL, REBUILT), 'screening')


def validate_followup_screen(root, selected=None):
    validated = _validate_screen(root, selected, FOLLOWUP_CASES, FOLLOWUP_TUNED, (ORIGINAL,), 'followup')
    plan = read_json(root / 'followup-plan.json')
    lineage = plan.get('initial_screen_evidence_sha256')
    require(isinstance(lineage, dict) and bool(lineage), 'Initial-screen lineage is missing')
    require(lineage == validated['state'].get('initial_screen_evidence_sha256'),
            'Follow-up state and plan disagree about initial-screen lineage')
    require(plan.get('candidate_cases') == list(FOLLOWUP_TUNED),
            'Follow-up plan candidate set changed')
    initial_root = Path(plan.get('initial_screen_root', '')).resolve()
    require(initial_root == root.resolve().parent,
            'Follow-up lineage must reference its original parent screen')
    lineage_paths = {name: relative_file(initial_root, name) for name in lineage}
    require(snapshot(lineage_paths) == lineage,
            'Initial-screen evidence changed after the follow-up plan was frozen')
    validated['followup_plan'] = plan
    validated['initial_screen_lineage'] = lineage
    validated['lineage_paths'] = lineage_paths
    return validated


def confirmation_orders(cases):
    require(len(cases) == 3 and len(set(cases)) == 3, 'Confirmation needs three distinct cases')
    permutations = list(itertools.permutations(cases))
    random.Random(ORDER_SEED).shuffle(permutations)
    require(len(set(permutations)) == 6, 'Confirmation permutations are not unique')
    for position in range(3):
        require(collections.Counter(order[position] for order in permutations) ==
                collections.Counter({case: 2 for case in cases}), 'Unbalanced case positions')
    adjacent = collections.Counter(pair for order in permutations for pair in zip(order, order[1:]))
    require(adjacent == collections.Counter({pair: 2 for pair in itertools.permutations(cases, 2)}),
            'Unbalanced within-round ordered pairs')
    return {str(trial): list(order) for trial, order in enumerate(permutations, 1)}


def copy_evidence_file(source_root, destination, name, expected_hash):
    source = relative_file(source_root, name)
    require(sha256(source) == expected_hash, f'Input changed before copy: {name}')
    target = destination / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    require(sha256(target) == expected_hash, f'Copied file hash mismatch: {name}')


def prepare_confirmation(screen_root, selected, destination, stage='initial'):
    screen_root = screen_root.resolve()
    destination = destination.resolve()
    require(destination.parent == screen_root and destination.name not in ('.', '..'),
            'Confirmation destination must be a direct child of the screen directory')
    require(not destination.exists(), f'Refusing to replace existing destination: {destination}')
    require(stage in ('initial', 'followup'), 'Unknown source screen stage')
    validator = validate_initial_screen if stage == 'initial' else validate_followup_screen
    validated = validator(screen_root, selected)
    summary = validated['summary']
    rows = {row['case_id']: row for row in validated['manifest']}
    cases = (selected, ORIGINAL, LEADER)
    orders = confirmation_orders(cases)
    hashes = validated['evidence_sha256']
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    selection = {
        'frozen_at': stamp, 'screen_root': str(screen_root), 'stage': 'confirmation',
        'selected_case': selected, 'screen_stage': validated['screen_kind'],
        'selection_rule': 'Highest median among the three clean declared candidate cells; at least 5% above '
        + ('both original and rebuilt controls.' if stage == 'initial' else 'the fresh original control.'),
        'minimum_ratio': 1.05, 'ratio_vs_original': validated['ratios'][ORIGINAL],
        'ratio_vs_rebuilt': validated['ratios'].get(REBUILT),
        'screen_evidence_sha256': hashes, 'screen_analysis': summary,
        'analysis_code': validated['analysis_code'],
        'followup_plan': validated.get('followup_plan'),
        'initial_screen_lineage': validated.get('initial_screen_lineage'),
        'leader_screen_annotation': next({key: case.get(key) for key in
            ('case_id', 'status', 'valid_trials', 'clean_trials', 'http_errors', 'socket_errors')}
            for case in summary['cases'] if case['case_id'] == LEADER),
        'confirmation_independent': True, 'screen_trials_included_in_confirmation': False,
        'order_seed': ORDER_SEED, 'expected_confirmation_trials_per_case': 6,
    }
    destination.mkdir()  # Exclusive creation: never replace an existing evidence directory.
    try:
        for name in (*FIXTURES, 'run.py'):
            copy_evidence_file(screen_root, destination, name, hashes[name])
        for case in cases:
            for name in (rows[case]['source_hashes'], rows[case].get('patch')):
                if name:
                    copy_evidence_file(screen_root, destination, name, hashes[name])
        write_json(destination / 'manifest.json', [rows[case] for case in cases])
        write_json(destination / 'build-status-1-130.json',
                   {case: validated['builds'][case] for case in cases})
        write_json(destination / 'orders.json', orders)
        write_json(destination / 'selection.json', selection)
        write_json(destination / 'EXPERIMENT_STATE.json', {
            'objective': 'Independent confirmation of the frozen PR26 tuning candidate.',
            'phase': 'prepared; fresh correctness and six-round measurements pending',
            'stage': 'confirmation', 'expected_trials': 6, 'cases': list(cases),
            'source_screen_stage': validated['screen_kind'],
            'selected_case': selected, 'selection_file': 'selection.json',
            'selection_sha256': sha256(destination / 'selection.json'),
            'load_image': validated['load_image'],
            'upstream_commit': validated['state']['upstream_commit'],
            'fixture_hashes': validated['state']['fixture_hashes'],
            'controller_sha256': hashes['run.py'], 'order_seed': ORDER_SEED,
            'orders_sha256': sha256(destination / 'orders.json'),
            'order_validation': {'all_six_permutations_once': True,
                                 'each_case_each_position_twice': True,
                                 'each_within_round_ordered_pair_twice': True},
            'verification_command': ['python3', 'run.py', 'verify', '--load-image', validated['load_image']],
            'benchmark_command': ['python3', 'run.py', 'bench', '--trials', '6',
                                  '--seconds', '15', '--load-image', validated['load_image']],
            'interpretation': 'Use confirmation data alone; report all six paired ratios and errors. No retuning after this holdout starts.',
            'published_benchmark_unchanged': True, 'remote_publication_authorized': False,
        })
        require(snapshot(validated['input_paths']) == hashes,
                'Screen evidence changed during confirmation preparation')
        if validated.get('lineage_paths'):
            require(snapshot(validated['lineage_paths']) == validated['initial_screen_lineage'],
                    'Initial-screen lineage changed during confirmation preparation')
        require(not any((destination / name).exists() for name in
                        ('measurements.json', 'verification.json', 'logs', 'server-logs')),
                'Confirmation unexpectedly contains prior run evidence')
    except BaseException:
        shutil.rmtree(destination)
        raise
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('selected_case', choices=tuple(dict.fromkeys((*TUNED, *FOLLOWUP_TUNED))))
    parser.add_argument('--stage', choices=('initial', 'followup'), default='initial',
                        help='Explicit source stage; followup allows only the declared 32/16/8 settings.')
    parser.add_argument('--screen-root', type=Path, default=ROOT)
    parser.add_argument('--output-dir', type=Path, default=Path('confirmation'),
                        help='New direct child of screen root; existing paths are never replaced.')
    args = parser.parse_args()
    destination = args.output_dir if args.output_dir.is_absolute() else args.screen_root / args.output_dir
    try:
        prepared = prepare_confirmation(args.screen_root, args.selected_case, destination, args.stage)
    except (OSError, ValueError, TypeError, KeyError, ImportError, RuntimeError) as error:
        parser.exit(2, f'Preparation refused: {error}\n')
    print(f'Prepared {prepared}; no builds, containers, verification or timing were started.')
    print('Run the explicit verification_command and benchmark_command in EXPERIMENT_STATE.json from that directory.')


if __name__ == '__main__':
    main()
