#!/usr/bin/env python3
"""Independent file-only check of one row per current implementation.

No network, Docker, source mutation or benchmark. Historical records are checked
against a frozen 129-row file; visible records must preserve every source field.
"""
import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
CANONICAL_SHA256 = '4799baba4fb9ad2b03e7e1d9b341b84194f7a4c9e455885c7a562fa6e483566a'
RUST_RECHECK = 'control:recheck-3x15-2026-10-22:82'
REMOVED_CURRENT = {'current:19', 'current:121-c-iouring-ssmurfgg04-gif', 'current:82'}
SOCKETS = ('connect', 'read', 'write', 'timeout')
DERIVED_KEYS = {'implementation_key', 'display_role', 'selection_reason', 'superseded_prs'}
CHECKS = []


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path):
    return json.loads(path.read_text())


def check(name, okay, detail=None):
    CHECKS.append({'check': name, 'passed': bool(okay), **({'detail': detail} if detail is not None else {})})


def identity(row):
    parts = urlsplit(row['source_url']).path.strip('/').split('/')
    assert len(parts) >= 2 and row.get('folder'), row['row_id']
    return '/'.join(parts[:2] + [row['folder']]).casefold()


def expected_csv(value):
    if value is None:
        return ''
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True)
    return str(value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--view-dir', type=Path, required=True)
    parser.add_argument('--canonical-rows', type=Path, default=HERE / 'current-view/comparison-rows.json')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    view = args.view_dir
    canonical = load(args.canonical_rows)
    check('frozen canonical file byte hash', sha(args.canonical_rows) == CANONICAL_SHA256)
    check('all 129 original and recheck records retained', len(canonical) == 129)
    original = {row['row_id']: row for row in canonical}
    check('canonical row IDs remain unique', len(original) == 129)
    expected_ids = {row['row_id'] for row in canonical if row['role'] == 'current'} - REMOVED_CURRENT
    expected_ids.add(RUST_RECHECK)
    # Both the old and fresh Goose records are current in the complete history.
    expected_ids.discard('current:143')
    check('independent selected-row policy yields 118 implementations', len(expected_ids) == 118, len(expected_ids))
    visible = load(view / 'visible-rows.json')
    visible_ids = [row['row_id'] for row in visible]
    check('exactly 118 visible unique rows', len(visible) == len(set(visible_ids)) == 118)
    check('visible selection is the specified current implementation set', set(visible_ids) == expected_ids,
          {'missing': sorted(expected_ids - set(visible_ids)), 'extra': sorted(set(visible_ids) - expected_ids)})
    check('129 retained records byte-exact in current view', sha(view / 'comparison-rows.json') == CANONICAL_SHA256)
    identities = [identity(row) for row in visible]
    check('one row per case-insensitive owner/repository/submission folder', len(set(identities)) == len(visible))
    for row in visible:
        source = original.get(row['row_id'], {})
        changed = [key for key, value in source.items() if row.get(key) != value]
        check('preserve every metric, counter, source and classification: ' + row['row_id'], not changed, changed or None)
        added = set(row) - set(source)
        check('only explicit display metadata added: ' + row['row_id'], added <= DERIVED_KEYS, sorted(added - DERIVED_KEYS) or None)
        check('derived current display identifies implementation: ' + row['row_id'], row.get('display_role') == 'current'
              and row.get('implementation_key') == identity(row).rsplit('/', 1)[0] + '/submissions/' + row['folder'].casefold()
              and isinstance(row.get('selection_reason'), str) and bool(row['selection_reason'])
              and isinstance(row.get('superseded_prs'), list))
        check('local requirement scope retained: ' + row['row_id'], row.get('official_conditions_status') == 'UNVERIFIED')
        check('stock protocol only: ' + row['row_id'], row.get('protocol') == 'stock-wrk-3x15s')
        if row.get('requirements_status') == 'PASS':
            check('PASS has zero measured errors: ' + row['row_id'], row.get('http_errors') == 0
                  and all((row.get('socket_errors') or {}).get(key) == 0 for key in SOCKETS))
    byid = {row['row_id']: row for row in visible}
    rust = byid.get(RUST_RECHECK, {})
    check('exactly one Rust scooter entry from current PR82', sum(row.get('folder') == 'rust-epoll-scooter1337' for row in visible) == 1
          and rust.get('pr') == 82 and rust.get('successful_rps') == 102683.76)
    goose = [row for row in visible if row.get('pr') == 143]
    check('one Goose uses complete clean recheck batch', len(goose) == 1 and goose[0].get('measurement_batch') == 'recheck-3x15-2026-10-22'
          and goose[0].get('requirements_status') == 'PASS')
    check('original C io_uring submission retained without inherited duplicate', 'current:112' in byid
          and 'current:121-c-iouring-ssmurfgg04-gif' not in byid)
    check('distinct C libco submission remains visible', 'current:121-c-libco-ssmurfgg04-gif' in byid)
    check('visible order is successful throughput descending', visible == sorted(visible,
          key=lambda row: (row.get('successful_rps') is None, -(row.get('successful_rps') or 0), row['row_id'])))
    with (view / 'comparison.csv').open(newline='') as stream:
        csv_rows = list(csv.DictReader(stream))
    check('CSV exact same ordered 118 row IDs', [row['row_id'] for row in csv_rows] == visible_ids)
    for flat, source in zip(csv_rows, visible):
        differences = []
        for key, value in flat.items():
            if key.startswith('socket_'):
                want = (source.get('socket_errors') or {}).get(key[len('socket_'):])
            else:
                want = source.get(key)
            if value != expected_csv(want):
                differences.append(key)
        check('CSV fields preserve view values: ' + source['row_id'], not differences, differences or None)
    html = (view / 'comparison.html').read_text()
    match = re.search(r'const rows=(.*?);\n', html, re.S)
    # The established browser renderer avoids embedding source_record twice;
    # its complete original copy is retained in each visible JSON row instead.
    browser_rows = [{key: value for key, value in row.items() if key != 'source_record'} for row in visible]
    check('HTML embeds all visible fields except duplicate nested source_record',
          match is not None and json.loads(match[1]) == browser_rows)
    for name in ('issue-comment.md', 'report.md'):
        text = (view / name).read_text()
        ids = [value.strip() for value in re.findall(r'<!--\s*row:([^>]+)\s*-->', text)]
        check(name + ' contains exactly same 118 ordered rows', ids == visible_ids)
        check(name + ' has one primary measurement table', sum(line.startswith('| PR / implementation') for line in text.splitlines()) == 1)
        check(name + ' clearly limits PASS to local conditions', 'Original challenge conditions are not reproduced here' in text)
        check(name + ' keeps history discoverable', 'comparison-rows.json' in text and '129' in text)
    issue = (view / 'issue-comment.md').read_text()
    check('issue payload equals Markdown', load(view / 'issue-comment.json') == {'body': issue})
    check('issue body within GitHub 65536-character limit', len(issue) < 65536)
    failures = [item for item in CHECKS if not item['passed']]
    result = {'passed': not failures, 'checks': len(CHECKS), 'checks_passed': len(CHECKS) - len(failures),
              'canonical_rows': len(canonical), 'visible_rows': len(visible), 'unique_implementations': len(set(identities)),
              'visible_conditions': dict(Counter(row['requirements_status'] for row in visible)),
              'canonical_sha256': sha(args.canonical_rows), 'new_benchmark_commands_run': 0,
              'outputs': {name: sha(view / name) for name in ('comparison-rows.json', 'visible-rows.json', 'comparison.csv',
                          'comparison.html', 'issue-comment.md', 'report.md')}, 'failures': failures, 'results': CHECKS}
    output = args.output or view / 'current-only-audit.json'
    output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps({key: value for key, value in result.items() if key not in ('results', 'outputs')}, ensure_ascii=False))
    raise SystemExit(bool(failures))


if __name__ == '__main__':
    main()
