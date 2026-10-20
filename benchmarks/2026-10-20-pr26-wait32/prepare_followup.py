#!/usr/bin/env python3
"""Prepare, but do not build or run, a separate PR26 completion-count screen.

The initial screen remains immutable. This exploratory stage compares new
16/4000 and 8/4000 settings with fresh runs of the pinned 32/4000 reference,
original PR26, and PR82. An independent confirmation must follow final selection.
"""
import argparse
import datetime
import difflib
import hashlib
import json
import math
import re
import shutil
import sys
from pathlib import Path

sys.dont_write_bytecode = True
from prepare_confirmation import (  # noqa: E402
    ROOT, ORIGINAL, LEADER, REBUILT, FIXTURES, copy_evidence_file,
    read_json, relative_file, require, sha256, snapshot,
    validate_initial_screen, write_json,
)


REFERENCE = '26-b32-w4000'
NEW_SETTINGS = (('26-b16-w4000', 16), ('26-b8-w4000', 8))
CANDIDATES = (REFERENCE, *(case for case, _ in NEW_SETTINGS))


def build_script(source, base_image):
    """Retain the existing builder, restricting its work to the two new IDs."""
    expected_base = re.search(r"^BASE_IMAGE = '([^']+)'$", source, re.M)
    require(expected_base is not None and expected_base[1] == base_image,
            'Original builder base image differs from the pinned original PR26 image')
    predicate = "if row.get('local_variant')]"
    require(source.count(predicate) == 1, 'Original builder row filter changed; review required')
    new_ids = tuple(case for case, _ in NEW_SETTINGS)
    source = source.replace(predicate, f"if row['case_id'] in {new_ids!r}]")
    source = source.replace('Build all four PR26 settings', 'Build the two new PR26 follow-up settings')
    source = source.replace('all four variants built; correctness validation pending',
                            'both new variants built; fresh correctness validation pending')
    source = source.replace('All four original PGO builds completed.',
                            'Both new follow-up PGO builds completed; pinned reference images were not rebuilt.')
    return source


def prepare_followup(screen_root, destination):
    screen_root = screen_root.resolve()
    destination = destination.resolve()
    require(destination.parent == screen_root,
            'Follow-up destination must be a direct child of the initial screen directory')
    require(not destination.exists(), f'Refusing to replace existing destination: {destination}')
    screen = validate_initial_screen(screen_root)
    rows = {row['case_id']: row for row in screen['manifest']}
    summaries = {row['case_id']: row for row in screen['summary']['cases']}
    require(summaries[REFERENCE].get('clean_trials') == 3,
            'The 32/4000 follow-up reference must have three clean initial-screen trials')
    baseline = rows[REBUILT]
    original_inventory = read_json(relative_file(screen_root, baseline['source_hashes']))
    source_root = screen_root / 'sources' / REBUILT
    require(source_root.is_dir(), 'Pinned baseline source snapshot is missing')
    paths = dict(screen['input_paths'])
    builder_path = relative_file(screen_root, 'build_variants.py')
    paths['build_variants.py'] = builder_path
    for name, expected in original_inventory.items():
        path = relative_file(screen_root, str((source_root / name).relative_to(screen_root)))
        require(sha256(path) == expected, f'Pinned baseline source changed: {name}')
        paths[str(path.relative_to(screen_root))] = path
    hashes = snapshot(paths)
    require(all(hashes[name] == digest for name, digest in screen['evidence_sha256'].items()),
            'Initial screen changed after validation')
    builder_source = build_script(builder_path.read_text(), screen['builds'][ORIGINAL]['image_id'])
    original_code = (source_root / 'src/server.c').read_text()
    require(original_code.count('#define WAIT_NR 128 ') == 1 and
            original_code.count('#define WAIT_USEC 4000 ') == 1,
            'Pinned baseline wait defaults differ from 128/4000')
    followup_rows = [rows[case] for case in (ORIGINAL, LEADER, REFERENCE)]
    followup_builds = {case: screen['builds'][case] for case in (ORIGINAL, LEADER, REFERENCE)}
    median = {case: summary['median_successful_rps'] for case, summary in summaries.items()}
    count_ratios = {'at_4000us': median[REFERENCE] / median[REBUILT],
                    'at_250us': median['26-b32-w250'] / median['26-b128-w250']}
    wait_ratios = {'at_count128': median['26-b128-w250'] / median[REBUILT],
                   'at_count32': median['26-b32-w250'] / median[REFERENCE]}
    count_effect = math.sqrt(math.prod(count_ratios.values()))
    wait_effect = math.sqrt(math.prod(wait_ratios.values()))
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    destination.mkdir()  # Exclusive creation; existing directories are never modified.
    try:
        for name in (*FIXTURES, 'run.py'):
            copy_evidence_file(screen_root, destination, name, hashes[name])
        for case in (ORIGINAL, LEADER, REFERENCE):
            for name in (rows[case]['source_hashes'], rows[case].get('patch')):
                if name:
                    copy_evidence_file(screen_root, destination, name, hashes[name])
        for case, count in NEW_SETTINGS:
            app = destination / 'sources' / case
            for name in original_inventory:
                source_name = str((source_root / name).relative_to(screen_root))
                source = relative_file(screen_root, source_name)
                require(sha256(source) == hashes[source_name], f'Baseline changed before copy: {name}')
                target = app / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
                require(sha256(target) == original_inventory[name], f'Source copy mismatch: {name}')
            code = original_code.replace('#define WAIT_NR 128 ', f'#define WAIT_NR {count} ')
            (app / 'src/server.c').write_text(code)
            inventory = {name: sha256(app / name) for name in original_inventory}
            changed = [name for name in original_inventory if inventory[name] != original_inventory[name]]
            require(changed == ['src/server.c'], f'Unexpected follow-up source changes: {changed}')
            patch = ''.join(difflib.unified_diff(original_code.splitlines(True), code.splitlines(True),
                                                fromfile='a/src/server.c', tofile='b/src/server.c'))
            patch_name = f'patches/{case}.patch'
            patch_path = destination / patch_name
            patch_path.parent.mkdir(parents=True, exist_ok=True)
            patch_path.write_text(patch)
            inventory_name = f'archives/{case}-sha256.json'
            write_json(destination / inventory_name, inventory)
            source_digest = hashlib.sha256(json.dumps(inventory, sort_keys=True).encode()).hexdigest()
            row = dict(baseline, id=case, case_id=case,
                       source_hashes=inventory_name, source_sha256=source_digest,
                       experiment_role='exploratory completion-count follow-up',
                       local_variant={'WAIT_NR': count, 'WAIT_USEC': 4000},
                       patch=patch_name, patch_sha256=sha256(patch_path),
                       upstream_commit=baseline['commit'],
                       commit_semantics='Upstream base revision; local patch and source inventory define this derivative.')
            followup_rows.append(row)
            followup_builds[case] = dict(status='not_built', exit_code=None,
                                         commit=row['commit'], source_sha256=source_digest,
                                         local_variant=row['local_variant'])
        write_json(destination / 'manifest.json', followup_rows)
        write_json(destination / 'build-status-1-130.json', followup_builds)
        (destination / 'build_variants.py').write_text(builder_source)
        # The unchanged builder opens logs/build-CASE.log before the controller runs.
        (destination / 'logs').mkdir()
        (destination / 'server-logs').mkdir()
        write_json(destination / 'followup-plan.json', {
            'frozen_at': stamp, 'initial_screen_root': str(screen_root),
            'initial_screen_evidence_sha256': hashes,
            'initial_screen_analysis': screen['summary'],
            'reason': 'The first screen points to the completion-count threshold as the main effect. Explore 16 and 8 at a fixed 4000us wait; preserve all first-screen results and the flagged leader row.',
            'descriptive_factor_contrasts': {
                'count_32_over_128': count_ratios, 'wait_250_over_4000': wait_ratios,
                'count_geometric_mean_ratio': count_effect,
                'wait_geometric_mean_ratio': wait_effect,
                'count_has_larger_absolute_log_effect': abs(math.log(count_effect)) > abs(math.log(wait_effect)),
                'interpretation': 'Descriptive screening contrasts; no significance or causality claim.',
            },
            'exploratory': True, 'confirmation_started': False,
            'candidate_cases': list(CANDIDATES), 'new_build_cases': [case for case, _ in NEW_SETTINGS],
            'pinned_reference_cases': [ORIGINAL, LEADER, REFERENCE],
            'selection_rule': 'After all five cases have three valid trials, require original and selected candidate clean 3/3. Select the highest median among clean 32/4000,16/4000,8/4000 cells (case-ID tie break), at least 5% above original. Preserve and annotate leader errors; compare fresh leader throughput without calling a flagged row clean. Then freeze one candidate for independent confirmation.',
            'no_screen_pooling': True,
            'builder_source_sha256': hashes['build_variants.py'],
            'generated_builder_sha256': sha256(destination / 'build_variants.py'),
            'builder_changes': 'Only two-new-case filtering and status text differ; original immutable base image and original PGO build mechanics are unchanged.',
        })
        write_json(destination / 'EXPERIMENT_STATE.json', {
            'objective': 'Bounded exploratory PR26 follow-up of 16/4000 and 8/4000.',
            'phase': 'prepared; only the two new builds are pending',
            'stage': 'followup_screening', 'expected_trials': 3,
            'cases': [row['case_id'] for row in followup_rows],
            'selection_candidates': list(CANDIDATES), 'selection_controls': [ORIGINAL],
            'selection_minimum_ratio': 1.05, 'ranking_control': LEADER,
            'reference_case': REFERENCE, 'new_build_cases': [case for case, _ in NEW_SETTINGS],
            'initial_screen_evidence_sha256': hashes,
            'initial_screen_winner': screen['winner'], 'plan_file': 'followup-plan.json',
            'plan_sha256': sha256(destination / 'followup-plan.json'),
            'load_image': screen['load_image'], 'upstream_commit': screen['state']['upstream_commit'],
            'fixture_hashes': screen['state']['fixture_hashes'],
            'controller_sha256': hashes['run.py'],
            'build_script_sha256': sha256(destination / 'build_variants.py'),
            'build_command': ['python3', 'build_variants.py'],
            'verification_command': ['python3', 'run.py', 'verify', '--load-image', screen['load_image']],
            'benchmark_command': ['python3', 'run.py', 'bench', '--trials', '3', '--seconds', '15',
                                  '--load-image', screen['load_image']],
            'ordering': 'Copied controller uses deterministic shuffled orders for three rounds; no orders.json is supplied.',
            'exploratory': True, 'independent_confirmation_required': True,
            'published_benchmark_unchanged': True, 'remote_publication_authorized': False,
        })
        require(snapshot(paths) == hashes, 'Initial screen inputs changed during follow-up preparation')
        require(not any((destination / name).exists() for name in
                        ('measurements.json', 'verification.json', 'orders.json')) and
                not any((destination / 'logs').iterdir()) and
                not any((destination / 'server-logs').iterdir()),
                'Follow-up unexpectedly contains prior run evidence or orders')
    except BaseException:
        shutil.rmtree(destination)
        raise
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--screen-root', type=Path, default=ROOT)
    parser.add_argument('--output-dir', type=Path, default=Path('followup-screen'),
                        help='New direct child of the initial screen; existing paths are never replaced.')
    args = parser.parse_args()
    destination = args.output_dir if args.output_dir.is_absolute() else args.screen_root / args.output_dir
    try:
        prepared = prepare_followup(args.screen_root, destination)
    except (OSError, ValueError, TypeError, KeyError, ImportError, RuntimeError) as error:
        parser.exit(2, f'Preparation refused: {error}\n')
    print(f'Prepared {prepared}; no builds, containers, verification or timing were started.')
    print('Only the two declared new cases will be built by the generated build_variants.py.')


if __name__ == '__main__':
    main()
