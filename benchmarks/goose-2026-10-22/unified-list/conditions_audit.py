"""Independent file-only review of local-condition labels and their evidence."""
import collections
import copy
import csv
import hashlib
import importlib.util
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
SOCKETS = ('connect', 'read', 'write', 'timeout')
CONFIG = dict(threads=2, connections=64, warmup_seconds=2, measurement_seconds=15, trials=3)
LOAD_ID = 'sha256:901ab577025cfdcf7abc716fb4158774615b881383529bb77163b5f07f963898'
CANONICAL_ROWS_SHA256 = '69f33b4f3d3f2e1a65feb3549793a52d5a86ed88e1a24aea00b34afac322146b'
CHECKS = []
EVIDENCE_FILES = []


def read(path):
    return json.loads(path.read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(name, condition, detail=None):
    CHECKS.append(dict(check=name, passed=bool(condition), **({'detail': detail} if detail is not None else {})))


def case(row):
    return str(row['case_id'] if 'case_id' in row else row['pr'])


def load_classifier():
    spec = importlib.util.spec_from_file_location('reviewed_conditions', ROOT / 'conditions.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def database(record):
    values = [v['database_after'] for v in record.get('final', []) if 'database_after' in v]
    return (len(values) == 1 and values[0].get('integrity') == 'ok'
            and values[0].get('initial_post_count') == 500000
            and type(values[0].get('post_count')) is int and values[0]['post_count'] > 500000)


def audit_pass_evidence(rows):
    """Check stored observations, not just the derived summary flags."""
    batches = {
        'current-2026-10-20': REPO / 'results/current-2026-10-20',
        'fixes-2026-10-22': REPO / 'results/fixes-2026-10-22',
        'ranking-3x15-2026-10-22': ROOT.parent / 'ranking-3x15-2026-10-22',
    }
    loaded = {}
    for name, folder in batches.items():
        EVIDENCE_FILES.extend(folder / filename for filename in
                              ('environment-bench.json', 'verification.json', 'measurements.json',
                               'shared-sha256.json', 'run.py', 'serve.py'))
        environment = read(folder / 'environment-bench.json')
        check(name + ': exact stock driver and configured load/server budget',
              environment.get('load_image_id') == LOAD_ID and environment.get('wrk') == CONFIG
              and environment.get('server_cpus') == '0' and environment.get('server_cpu_quota') == 1
              and environment.get('server_memory') == environment.get('server_memory_swap') == '2g'
              and environment.get('load_cpus') == '1,2' and environment.get('load_cpu_quota') == 2)
        loaded[name] = (read(folder / 'verification.json'), read(folder / 'measurements.json'),
                        read(folder / 'shared-sha256.json'))
    base = batches['current-2026-10-20']
    check('all short batches preserve the exact stock controller, service helper and fixture inventory',
          all(sha(folder / name) == sha(base / name) for folder in batches.values()
              for name in ('run.py', 'serve.py', 'shared-sha256.json')))
    for row in rows:
        name = row['row_id']
        batch = row['measurement_batch']
        if batch not in loaded:
            check(name + ': known passing stock batch', False, batch)
            continue
        verification, measurements, shared = loaded[batch]
        source = row['source_record']
        def same(r):
            return (case(r) == case(source) and r.get('commit') == source.get('commit')
                    and r.get('source_sha256') == source.get('source_sha256')
                    and r.get('image_id') == source.get('image_id') and r.get('shared_hashes') == shared)
        tests = [r for r in verification if same(r)]
        trials = [r for r in measurements if same(r)]
        check(name + ': source/image/shared identities bind complete observed tests and trials',
              bool(tests) and len(trials) == 3 and sorted(r['trial'] for r in trials) == [1, 2, 3])
        test = tests[-1] if tests else {}
        semantic = test.get('semantic', {})
        check(name + ': observed 42 official checks, dynamic roundtrip and durable database',
              test.get('passed') == 42 and test.get('failed') == 0 and test.get('official_passed_all') is True
              and semantic.get('passed_all') is True and semantic.get('exit_code') == 0
              and bool(semantic.get('checks')) and all(c.get('passed') is True for c in semantic.get('checks', []))
              and test.get('database_valid') is True and database(test))
        evidence_ok = bool(trials)
        for trial in trials:
            host = trial.get('container_host_config', {})
            evidence_ok &= (trial.get('configuration') == CONFIG and trial.get('completed') is True
                            and not trial.get('error') and trial.get('valid_duration') is True
                            and trial.get('database_valid') is True and database(trial)
                            and trial.get('http_errors') == 0 and trial.get('socket_errors') == dict.fromkeys(SOCKETS, 0)
                            and host.get('CpusetCpus') == '0' and host.get('NanoCpus') == 1000000000
                            and host.get('Memory') == host.get('MemorySwap') == 2147483648
                            and trial.get('container_state', {}).get('OOMKilled') is False
                            and trial.get('service', {}).get('source_sha256') == source.get('source_sha256'))
        check(name + ': all three actual runtime limits, clean completion and committed writes', evidence_ok)


def main():
    module = load_classifier()
    rows = read(ROOT / 'rows.json')
    results = {}
    for row in rows:
        before = copy.deepcopy(row)
        results[row['row_id']] = module.classify(row)
        check(row['row_id'] + ': classifier does not mutate source data', row == before)
    derived_keys = set(next(iter(results.values())))
    canonical = [{k: v for k, v in row.items() if k not in derived_keys} for row in rows]
    canonical_bytes = (json.dumps(canonical, ensure_ascii=False, indent=2) + '\n').encode()
    check('all 127 original rows, source_records, metrics and source identities remain byte-reconstructible',
          len(rows) == 127 and hashlib.sha256(canonical_bytes).hexdigest() == CANONICAL_ROWS_SHA256)
    statuses = collections.Counter(result['requirements_status'] for result in results.values())
    check('local counts match independent evidence categories', statuses == collections.Counter(
        PASS=100, FAIL=13, UNVERIFIED=11, DIFFERENT_PROTOCOL=3), dict(statuses))
    fail_states = {'measured_with_errors', 'ineligible_reference', 'database_check_failed', 'runtime_failed', 'source_missing_start'}
    for row in rows:
        actual = results[row['row_id']]
        expected = ('DIFFERENT_PROTOCOL' if row['role'] == 'confirmation' else
                    'FAIL' if row.get('status') in fail_states else
                    'UNVERIFIED' if row.get('status') == 'unsupported_architecture' else
                    'PASS' if row.get('status') == 'measured' else 'UNVERIFIED')
        check(row['row_id'] + ': local status follows recorded observation', actual.get('requirements_status') == expected)
        check(row['row_id'] + ': official conditions remain explicitly unverified',
              actual.get('official_conditions_status') == 'UNVERIFIED'
              and 'x86' in actual.get('official_conditions_reason', '')
              and 'k6' in actual.get('official_conditions_reason', '')
              and 'local' in actual.get('requirements_scope', '').lower())
        check(row['row_id'] + ': tri-state qualification matches its local scope',
              actual.get('benchmark_requirements_met') is (True if expected == 'PASS' else False if expected in ('FAIL', 'DIFFERENT_PROTOCOL') else None))
    passed_rows = [r for r in rows if results[r['row_id']]['requirements_status'] == 'PASS']
    audit_pass_evidence(passed_rows)
    sample = copy.deepcopy(next(r for r in canonical if r['row_id'] == 'current:1'))
    cases = [
        ('normal complete local evidence', {}, 'PASS'),
        ('known non-SQLite implementation', {'eligible': False}, 'FAIL'),
        ('observed non-durable database', {'database_valid': False}, 'FAIL'),
        ('executed API assertion failure', {'tests_passed': 41, 'tests_failed': 1}, 'FAIL'),
        ('explicit negative API verdict', {'official_passed_all': False}, 'FAIL'),
        ('missing API verdict', {'official_passed_all': None}, 'UNVERIFIED'),
        ('observed dynamic live-data failure', {'semantic_passed_all': False}, 'FAIL'),
        ('missing live-data evidence', {'semantic_passed_all': None}, 'UNVERIFIED'),
        ('three-trial requirement incomplete', {'trials_recorded': 2}, 'UNVERIFIED'),
        ('missing HTTP counters', {'http_errors': None}, 'UNVERIFIED'),
        ('missing socket counters', {'socket_errors': {}}, 'UNVERIFIED'),
        ('observed HTTP errors', {'http_errors': 1}, 'FAIL'),
        ('observed timeout errors', {'socket_errors': dict(connect=0, read=0, write=0, timeout=1)}, 'FAIL'),
        ('different warmup duration', {'warmup_seconds': 0}, 'DIFFERENT_PROTOCOL'),
        ('missing warmup duration', {'warmup_seconds': None}, 'UNVERIFIED'),
        ('missing measured duration', {'measurement_seconds': None}, 'UNVERIFIED'),
        ('missing driver protocol', {'protocol': None}, 'UNVERIFIED'),
        ('different measured duration', {'measurement_seconds': 30}, 'DIFFERENT_PROTOCOL'),
        ('different clock driver', {'protocol': 'unknown-driver'}, 'DIFFERENT_PROTOCOL'),
        ('known startup failure', {'status': 'runtime_failed'}, 'FAIL'),
        ('missing required startup scripts', {'status': 'source_missing_start'}, 'FAIL'),
        ('unexecuted architecture-specific submission', {'status': 'unsupported_architecture'}, 'UNVERIFIED'),
        ('unknown batch without limits proof', {'measurement_batch': 'unknown-batch'}, 'UNVERIFIED'),
        ('explicit two-CPU override', {'server_cpu_quota': 2}, 'FAIL'),
        ('explicit excess memory override', {'server_memory_bytes': 4294967296}, 'FAIL'),
        ('explicit swap-enabled override', {'server_memory_swap_bytes': 4294967296}, 'FAIL'),
    ]
    for name, changes, expected in cases:
        row = copy.deepcopy(sample)
        row.update(changes)
        result = module.classify(row)
        check('classifier edge: ' + name, result.get('requirements_status') == expected,
              dict(expected=expected, observed=result.get('requirements_status')))
    emitted = all(all(row.get(k) == v for k, v in results[row['row_id']].items()) for row in rows)
    check('shared emitted rows contain exact independently recomputed condition fields', emitted)
    ids = [r['row_id'] for r in rows]
    mapped = {r['row_id']: r for r in rows}
    with (ROOT / 'comparison.csv').open() as stream:
        csvrows = list(csv.DictReader(stream))
    check('CSV preserves all 127 shared row IDs in order', [r['row_id'] for r in csvrows] == ids)
    csv_ok = True
    for value in csvrows:
        row = mapped[value['row_id']]
        for k, v in value.items():
            expected_value = row.get(k)
            if k.startswith('socket_') and k[7:] in SOCKETS:
                expected_value = (row.get('socket_errors') or {}).get(k[7:])
            csv_ok &= v == ('' if expected_value is None else str(expected_value))
    check('all CSV metrics and condition scalar fields match shared rows', csv_ok)
    surfaces = []
    for name in ('comparison.html', 'report.md', 'issue-comment.md'):
        text = (ROOT / name).read_text()
        surfaces.append(name)
        check(name + ': local conditions have an explicit label',
              'Local conditions' in text or 'Local Conditions' in text)
        check(name + ': clean-rank presentation removed', 'Clean rank' not in text)
        check(name + ': official measurement scope is explicitly distinguished',
              'official' in text.lower() and 'x86' in text.lower() and 'k6' in text.lower())
        if name.endswith('.html'):
            marker = 'const rows='
            embedded, _ = json.JSONDecoder().raw_decode(text[text.index(marker) + len(marker):])
            check(name + ': embedded metrics and conditions equal all 127 shared rows',
                  embedded == [{k: v for k, v in r.items() if k != 'source_record'} for r in rows]
                  and text.count('<table') == text.count('<tbody') == 1)
            continue
        check(name + ': one table preserves all 127 row IDs in order',
              re.findall(r'<!-- row:([^ ]+) -->', text) == ids
              and len(re.findall(r'^\|[ :|-]+\|$', text, re.M)) == 1)
        numeric_ok = labels_ok = True
        number = lambda v, digits=0: '—' if v is None else f'{v:,.{digits}f}'
        for line in text.splitlines():
            markers = re.findall(r'<!-- row:([^ ]+) -->', line)
            if not markers:
                continue
            row = mapped[markers[0]]
            cells = [c.strip() for c in re.split(r'(?<!\\)\|', line)[1:-1]]
            rps = number(row.get('successful_rps'))
            if row.get('successful_rps') is not None:
                rps += '<br>' + number(row.get('rps_min')) + '–' + number(row.get('rps_max'))
            sockets = row.get('socket_errors')
            errors = number(row.get('http_errors')) + '; ' + ('/'.join(str(sockets[k]) for k in SOCKETS) if sockets else '—')
            expected_cells = {
                4: rps,
                5: number(row.get('p95_ms'), 3) + ' / ' + number(row.get('p99_ms'), 3),
                6: number(row.get('rss_mib'), 2) + ' / ' + number(row.get('cpu_percent'), 1),
                7: errors,
                8: number(row.get('app_loc')) + ' / ' + number(row.get('own_loc'))}
            numeric_ok &= len(cells) == 10 and all(cells[k] == v for k, v in expected_cells.items())
            status = row['requirements_status']
            display_status = 'OTHER PROTOCOL' if status == 'DIFFERENT_PROTOCOL' else status
            labels_ok &= display_status in cells[1]
        check(name + ': every visible local-condition label equals its derived classification', labels_ok)
        check(name + ': all original displayed metrics/ranges/errors/LOC remain unchanged', numeric_ok)
    files = ['conditions.py', 'conditions_audit.py', 'rows.json', 'comparison.csv', 'comparison.html',
             'report.md', 'issue-comment.md', 'render.py', 'render_markdown.py']
    output = dict(complete=emitted, audit_passed=all(c['passed'] for c in CHECKS),
                  checks_passed=sum(c['passed'] for c in CHECKS), checks_total=len(CHECKS),
                  local_status_counts=dict(statuses), official_status_counts=dict(UNVERIFIED=len(rows)),
                  pass_rows_with_runtime_and_harness_evidence=len(passed_rows),
                  canonical_rows_sha256=CANONICAL_ROWS_SHA256,
                  classification={k: v for k, v in results.items()}, checks=CHECKS,
                  evidence_sha256={str(p.relative_to(REPO)): sha(p) for p in [REPO / 'README.md', REPO / 'SPEC.md']}
                  | {str(p.relative_to(REPO)): sha(p) for p in EVIDENCE_FILES}
                  | {n: sha(ROOT / n) for n in files if (ROOT / n).is_file()},
                  limitations=['PASS describes the retained local ARM64 Docker stock-wrk comparison checks only, not full challenge compliance or an official user-capacity score.',
                               'All 127 rows remain unverified under the original x86-64 DigitalOcean/k6/no-affinity measurement conditions.',
                               'The audit does not perform an exhaustive source review for schema, caching, hardcoding, dependency/build-budget or 15000-connection compliance.',
                               'Actual server limits are checked from retained per-trial inspections; load limits are checked from the unchanged controller and environment records.'])
    (ROOT / 'conditions-audit.json').write_text(json.dumps(output, indent=2) + '\n')
    print(json.dumps({k: v for k, v in output.items() if k not in {'classification', 'checks', 'evidence_sha256'}}, indent=2))
    for c in CHECKS:
        if not c['passed']:
            print('FAIL:', c['check'], c.get('detail', ''))
    return 0 if output['complete'] and output['audit_passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
