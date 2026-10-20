"""Recompute physical LOC roles without changing any pinned source identity.

The first audit baseline is retained on repeat runs. Source bytes, hashes,
archive identities, fixtures, and build/performance evidence are never edited.
"""
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

import prepare

ROOT = Path(__file__).resolve().parent


def main():
    manifest_path = ROOT / 'manifest.json'
    rows = json.loads(manifest_path.read_text())
    identities = [{k: v for k, v in row.items() if k not in {'app_loc', 'own_loc'}} for row in rows]
    report_path = ROOT / 'loc-audit.json'
    previous = json.loads(report_path.read_text()) if report_path.exists() else {}
    baselines = {case['id']: case for case in previous.get('cases', [])}
    cases, checked_files = [], 0
    for row in rows:
        key = row['id']
        path = ROOT / 'source-inventories' / ('pr' + key + '.json')
        inventory = json.loads(path.read_text())
        immutable = deepcopy(inventory)
        directory = ROOT / 'sources' / ('pr' + key)
        context = prepare.classification_context(directory)
        old = {'app_loc': row['app_loc'], 'own_loc': row['own_loc']}
        baseline = baselines.get(key, {})
        old = baseline.get('old', old)
        original_classes = {change['path']: change['old_classification'] for change in baseline.get('changes', [])}
        changes = []
        for name, item in inventory['files'].items():
            content = (directory / name).read_bytes()
            assert hashlib.sha256(content).hexdigest() == item['sha256'], (key, name)
            assert len(content) == item['bytes'] and len(content.splitlines()) == item['physical_lines'], (key, name)
            checked_files += 1
            original = original_classes.get(name, item['classification'])
            category, reason = prepare.classify_detail(name, content,
                runtime_sources=context['runtime_sources'], dependency_roots=context['dependency_roots'])
            item['classification'] = category
            if category != original:
                changes.append({'path': name, 'physical_lines': item['physical_lines'],
                                'old_classification': original, 'new_classification': category,
                                'reason': reason})
        for name, item in inventory['files'].items():
            assert {k: v for k, v in item.items() if k != 'classification'} == {
                k: v for k, v in immutable['files'][name].items() if k != 'classification'}, (key, name)
        assert inventory['skipped_members'] == immutable['skipped_members']
        row['app_loc'] = sum(item['physical_lines'] for item in inventory['files'].values()
                             if item['classification'] == 'application')
        row['own_loc'] = sum(item['physical_lines'] for item in inventory['files'].values()
                             if item['classification'] in {'application', 'own_support'})
        prepare.atomic_json(path, inventory)
        cases.append({'id': key, 'pr': row['pr'], 'folder': row['folder'], 'old': old,
                      'new': {'app_loc': row['app_loc'], 'own_loc': row['own_loc']},
                      'reason': sorted({change['reason'] for change in changes}) or ['No classification changes'],
                      'runtime_application_files': context['runtime_sources'],
                      'dependency_evidence': context['dependency_evidence'], 'changes': changes})
    assert identities == [{k: v for k, v in row.items() if k not in {'app_loc', 'own_loc'}} for row in rows]
    # Explicit regression guards for runtime helpers and legitimate application
    # names that contain check/validation/idle. No substring exclusions added.
    protected = {'4': ['pressure.ts'], '13': ['pressure.py'], '47': ['JwtValidator.cs'],
                 '59': ['src/checkpoint.ts', 'src/validation.ts'], '111': ['checkpoint.go'],
                 '114': ['src/server/idle.rs'],
                 '80': ['src/modules/health/application/useCases/checkHealth.ts']}
    for key, names in protected.items():
        inventory = json.loads((ROOT / 'source-inventories' / ('pr' + key + '.json')).read_text())['files']
        assert all(inventory[name]['classification'] == 'application' for name in names), key
    shell = json.loads((ROOT / 'source-inventories/pr89.json').read_text())['files']['worker.sh']
    assert shell['classification'] == 'application' and shell['physical_lines'] == 269
    prepare.atomic_json(manifest_path, rows)
    prepare.atomic_json(report_path, {
        'audited_at_utc': datetime.now(timezone.utc).isoformat(), 'case_count': len(rows),
        'source_files_verified': checked_files,
        'method': [
            'Physical lines include blank lines and comments; application and own/support roles are heuristic.',
            'Dedicated tests/checks/PGO/development/load-generator directories and exact reviewed root helper names are support source, retained in Own LOC.',
            'Runtime shell scripts directly executed by start.sh are application source; runtime pressure watchers remain application source.',
            'Build/configuration scripts are support. Standard lockfiles and generated benchmark/report/inventory JSON are metadata, excluded from Own LOC.',
            'Recognizable vendored third-party forks and explicit generated-code DO NOT EDIT headers are excluded from both totals.',
        ],
        'limitations': [
            'This is a focused role audit, not a manual authorship or executable-line count for every file.',
            'Entire identifiable third-party forks are excluded, including local patches; authored modifications are not separated.',
            'The original source-extension and remaining helper-name heuristics still apply. Unknown generated/dependency files may remain.',
            'Submodules/dependencies absent from pinned regular-file archives are not counted as submitted application source.',
        ], 'cases': cases})
    changed = [case for case in cases if case['old'] != case['new']]
    print(f'Audited {len(rows)} cases and {checked_files} immutable source files; {len(changed)} LOC totals changed.')
    for case in changed:
        print(case['id'], case['old'], '->', case['new'])


if __name__ == '__main__':
    main()
