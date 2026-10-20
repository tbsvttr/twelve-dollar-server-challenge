"""Prepare an isolated two-factor tuning experiment without editing published evidence."""
import difflib
import hashlib
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BASE = ROOT.parent / 'current-2026-10-20'
LOAD_IMAGE = 'sha256:901ab577025cfdcf7abc716fb4158774615b881383529bb77163b5f07f963898'


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    if (ROOT / 'manifest.json').exists():
        raise SystemExit('Experiment already prepared; refusing to replace evidence.')
    for name in ('logs', 'server-logs', 'archives', 'sources', 'patches'):
        (ROOT / name).mkdir(exist_ok=True)
    shared = json.loads((BASE / 'shared-sha256.json').read_text())
    for name in shared:
        destination = ROOT / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(BASE / name, destination)
        assert digest(destination.read_bytes()) == shared[name]
    shutil.copy2(BASE / 'run.py', ROOT / 'run.py')
    # Optional prespecified case orders are used only by the confirmation stage.
    controller = (ROOT / 'run.py').read_text()
    old = '        random.Random(20261020 + trial).shuffle(ordered)'
    new = '''        planned = read(ROOT / 'orders.json', {})
        if planned:
            order = planned[str(trial)]
            indexed = {str(row.get('id', row['pr'])): row for row in rows}
            if len(order) != len(indexed) or set(order) != set(indexed):
                raise ValueError('Prespecified order does not match selected cases')
            ordered = [indexed[case] for case in order]
        else:
            random.Random(20261020 + trial).shuffle(ordered)'''
    assert controller.count(old) == 1
    controller = controller.replace(old, new)
    controller = controller.replace("        'mode': args.mode, 'load_image': args.load_image, 'load_image_id': load_id,",
                                    "        'mode': args.mode, 'load_image': args.load_image, 'load_image_id': load_id,\n"
                                    "        'prespecified_orders': read(ROOT / 'orders.json', {}),")
    (ROOT / 'run.py').write_text(controller)
    original_rows = {row['case_id']: row for row in json.loads((BASE / 'manifest.json').read_text())}
    original_builds = json.loads((BASE / 'build-status.json').read_text())
    rows, builds = [], {}
    for case, original in [('26-original', '26'), ('82-leader', '82')]:
        row = dict(original_rows[original], id=case, case_id=case,
                   source_dir=f'/suite/sources/pr{original}', experiment_role='unchanged reference')
        inventory = json.loads((BASE / row['source_hashes']).read_text())
        row['source_hashes'] = f'archives/{case}-sha256.json'
        save(ROOT / row['source_hashes'], inventory)
        build = dict(original_builds[original])
        build['image'] = build['image_id']
        rows.append(row)
        builds[case] = build
    hashes = json.loads((BASE / original_rows['26']['source_hashes']).read_text())
    original_code = (BASE / 'sources/pr26/src/server.c').read_text()
    for count, wait, role in [(128, 4000, 'rebuilt baseline'), (32, 4000, 'count only'),
                              (128, 250, 'timeout only'), (32, 250, 'combined')]:
        case = f'26-b{count}-w{wait}'
        destination = ROOT / 'sources' / case
        shutil.copytree(BASE / 'sources/pr26', destination)
        code = original_code.replace('#define WAIT_NR 128 ', f'#define WAIT_NR {count} ')
        code = code.replace('#define WAIT_USEC 4000 ', f'#define WAIT_USEC {wait} ')
        (destination / 'src/server.c').write_text(code)
        inventory = {name: digest((destination / name).read_bytes()) for name in hashes}
        changed = [name for name in hashes if inventory[name] != hashes[name]]
        assert changed == ([] if (count, wait) == (128, 4000) else ['src/server.c'])
        patch = ''.join(difflib.unified_diff(original_code.splitlines(True), code.splitlines(True),
                                           fromfile='a/src/server.c', tofile='b/src/server.c'))
        patch_path = ROOT / 'patches' / f'{case}.patch'
        patch_path.write_text(patch)
        row = dict(original_rows['26'], id=case, case_id=case,
                   source_dir='/suite/sources/pr26', source_hashes=f'archives/{case}-sha256.json',
                   source_sha256=digest(json.dumps(inventory, sort_keys=True).encode()),
                   experiment_role=role, local_variant={'WAIT_NR': count, 'WAIT_USEC': wait},
                   upstream_commit=original_rows['26']['commit'],
                   commit_semantics='Upstream base revision; local patch and source inventory define the measured derivative.',
                   patch=str(patch_path.relative_to(ROOT)), patch_sha256=digest(patch.encode()))
        save(ROOT / row['source_hashes'], inventory)
        rows.append(row)
        builds[case] = dict(status='not_built', exit_code=None, commit=row['commit'],
                            source_sha256=row['source_sha256'], local_variant=row['local_variant'])
    save(ROOT / 'manifest.json', rows)
    save(ROOT / 'build-status-1-130.json', builds)
    save(ROOT / 'EXPERIMENT_STATE.json', {
        'objective': 'Test PR26 completion-wait tuning against rebuilt/original controls and the current leader.',
        'phase': 'prepared; variant builds pending', 'load_image': LOAD_IMAGE,
        'upstream_commit': original_rows['26']['commit'],
        'published_benchmark_unchanged': True, 'remote_publication_authorized': False,
        'screening': 'Three shuffled rounds, all six cases, fresh 2s warmup +15s per trial.',
        'confirmation': 'If a tuned setting is promising, six balanced rounds of best variant, original26 and82.',
        'selection': 'Highest median successful req/s among clean tuned variants; preserve all settings and errors.',
        'source_delta': 'Only WAIT_NR / WAIT_USEC default constants; original build.sh and PGO training unchanged.',
        'fixture_hashes': shared,
        'controller_sha256': digest(controller.encode()),
        'cases': [row['case_id'] for row in rows],
    })
    print(json.dumps({'cases': len(rows), 'fixture_hashes_identical': True, 'root': str(ROOT)}))


if __name__ == '__main__':
    main()
