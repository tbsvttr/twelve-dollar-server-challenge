#!/usr/bin/env python3
"""Independent file-only audit of the complete stock recheck and single Goose view.

This script never starts Docker, calls a network API or alters historical files.
It writes only recheck-audit.json after inspecting existing evidence and views.
"""
import argparse
import collections
import csv
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import statistics

HERE = Path(__file__).resolve().parent
BATCH = HERE.parent / 'recheck-3x15-2026-10-22'
OLD = HERE.parent / 'ranking-3x15-2026-10-22'
VIEW = HERE / 'current-view'
SOCKETS = ('connect', 'read', 'write', 'timeout')
METRICS = ('rps', 'successful_rps', 'p50_ms', 'p95_ms', 'p99_ms', 'rss_mib', 'cpu_percent')
CONFIG = dict(threads=2, connections=64, warmup_seconds=2, measurement_seconds=15, trials=3)
LOAD_ID = 'sha256:901ab577025cfdcf7abc716fb4158774615b881383529bb77163b5f07f963898'
OLD_ROWS_SHA = '1e41ba165d524af5f00364c1dbc771923971e680462af288dc7da2ee11da62fa'
OLD_MEASUREMENTS_SHA = '88bd8ca7a4f489192f84b34000c729bca1562d1441d91b90284b6c10ebcfb1d3'
FROZEN_FILES = {
    'run.py': '3d8e8a4418ca845a506ddc64ea8659271706273fb4c962da1bbd11aeab5246f4',
    'serve.py': '52d8bdd75c0dc2477fc5b2391c797a2832eab5ac61a72d3bbe4dac4cb94bf311',
    'manifest.json': 'e5dedc0ace1d5fb3f2a5e0d8b0b18bcaa63071b8f412cb0da9faea552523a2f1',
    'build-status.json': '55d27f66184d7f713e8d335e43f363b74230e372f0947f0c53ef8f80e515ce5a',
    'pr-documentation-image-proof.json': 'adfce44558322d9d3ca9b912bffcf6aa065c5e96caa2ed0719c21de25caa1f33',
}
ARCHIVED = {'current:143', 'confirmation:goose', 'confirmation:baseline'}
CHECKS = []
FILES = set()


def read(path):
    FILES.add(path)
    return json.loads(path.read_text())


def sha(path):
    FILES.add(path)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(name, value, detail=None):
    CHECKS.append(dict(check=name, passed=bool(value), **({'detail': detail} if detail is not None else {})))


def case(row):
    return str(row.get('case_id', row.get('id', row.get('pr'))))


def close(a, b):
    return (type(a) in (int, float) and type(b) in (int, float)
            and math.isfinite(a) and math.isfinite(b)
            and math.isclose(a, b, rel_tol=1e-10, abs_tol=1e-9))


def parse(output):
    count, duration = re.search(r'(\d+) requests in ([0-9.]+)s,', output).groups()
    parsed = dict(requests=int(count), duration_s=float(duration),
                  rps=float(re.search(r'Requests/sec:\s+([0-9.]+)', output)[1]))
    for p in (50, 95, 99):
        value, unit = re.search(r'\s' + str(p) + r'(?:\.0+)?%\s+([0-9.]+)(us|ms|s)', output).groups()
        parsed[f'p{p}_ms'] = float(value) * {'us': .001, 'ms': 1, 's': 1000}[unit]
    match = re.search(r'Non-2xx or 3xx responses:\s*(\d+)', output)
    parsed['http_errors'] = int(match[1]) if match else 0
    match = re.search(r'Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)', output)
    parsed['socket_errors'] = dict(zip(SOCKETS, map(int, match.groups()) if match else (0, 0, 0, 0)))
    parsed['successful_rps'] = parsed['rps'] - parsed['http_errors'] / parsed['duration_s']
    return parsed


def database(record):
    values = [v['database_after'] for v in record.get('final', []) if 'database_after' in v]
    return (record.get('database_valid') is True and len(values) == 1
            and values[0].get('integrity') == 'ok' and values[0].get('initial_post_count') == 500000
            and type(values[0].get('post_count')) is int and values[0]['post_count'] > 500000)


def audit_batch():
    manifest = {case(r): r for r in read(BATCH / 'manifest.json')}
    builds = read(BATCH / 'build-status.json')
    shared = read(BATCH / 'shared-sha256.json')
    verification = read(BATCH / 'verification.json')
    trials = read(BATCH / 'measurements.json')
    check('exactly the two unchanged source/image candidates are used', set(manifest) == set(builds) == {'143', '82'})
    for name, digest in FROZEN_FILES.items():
        check('unchanged stock/source/image evidence: ' + name, sha(BATCH / name) == sha(OLD / name) == digest)
    check('all twelve shared fixture/harness digests equal the previous stock batch',
          len(shared) == 12 and shared == read(OLD / 'shared-sha256.json'))
    for name, digest in shared.items():
        check('actual fixture/harness bytes: ' + name, sha(BATCH / name) == sha(OLD / name) == digest)
    declaration = read(BATCH / 'protocol-declaration.json')
    check('complete new recheck was predeclared with no selection or individual replacement',
          declaration.get('declared_before_measurement') is True
          and declaration.get('no_selection_or_replacements') is True
          and declaration.get('cases') == ['143', '82'] and declaration.get('rounds') == 3
          and declaration.get('measurement_seconds') == 15 and declaration.get('warmup_seconds') == 2
          and declaration.get('expected_load_image_id') == LOAD_ID)
    for mode in ('verify', 'bench'):
        env = read(BATCH / f'environment-{mode}.json')
        check(mode + ': stock driver and exact complete local configuration',
              env.get('mode') == mode and env.get('load_image_id') == LOAD_ID and env.get('wrk') == CONFIG
              and env.get('shared_hashes') == shared and env.get('server_cpus') == '0'
              and env.get('server_cpu_quota') == 1 and env.get('server_memory') == env.get('server_memory_swap') == '2g'
              and env.get('load_cpus') == '1,2' and env.get('load_cpu_quota') == 2)
    check('both correctness attempts retained exactly once', len(verification) == 2
          and collections.Counter((case(r), r.get('trial')) for r in verification)
          == collections.Counter((k, 1) for k in ('143', '82')))
    check('all six measured attempts retained exactly once with no selected replacement', len(trials) == 6
          and collections.Counter((case(r), r.get('trial')) for r in trials)
          == collections.Counter((k, n) for k in ('143', '82') for n in (1, 2, 3)))
    for record in verification + trials:
        key = case(record)
        label = f'{record.get("mode")} {key}/{record.get("trial")}'
        pinned = manifest.get(key, {})
        build = builds.get(key, {})
        identity = dict(case_id=key, pr=pinned.get('pr'), commit=pinned.get('commit'), image=build.get('image'),
                        source_sha256=pinned.get('source_sha256'), shared_hashes=shared, image_id=build.get('image_id'))
        fingerprint = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
        service = record.get('service', {})
        check(label + ': measured source/image identities and fingerprint bind the pinned candidate',
              all(record.get(k) == v for k, v in identity.items()) and record.get('fingerprint') == fingerprint
              and service.get('source_sha256') == pinned.get('source_sha256')
              and service.get('source_files_verified') == pinned.get('source_file_count')
              and service.get('initial_post_count') == 500000 and service.get('ready') is True)
        check(label + ': predeclaration precedes observation',
              bool(declaration.get('declared_at')) and declaration['declared_at'] <= record.get('recorded_at', ''))
        host = record.get('container_host_config', {})
        check(label + ': actual one CPU, 2 GiB and zero swap allowance, without OOM',
              host.get('CpusetCpus') == '0' and host.get('NanoCpus') == 1000000000
              and host.get('Memory') == host.get('MemorySwap') == 2147483648
              and record.get('container_state', {}).get('OOMKilled') is False)
        check(label + ': complete configured run and committed fresh SQLite writes',
              record.get('configuration') == CONFIG and not record.get('error') and database(record))
        path = BATCH / 'logs' / f'{record.get("mode")}-{key}-{record.get("trial")}.log'
        check(label + ': complete raw output log is retained', path.is_file()
              and path.read_text() == record.get('output', '') + record.get('stderr', '') + record.get('error', ''))
        FILES.add(path)
        if record.get('mode') == 'verify':
            semantic = record.get('semantic', {})
            check(label + ': all 42 API and six dynamic checks observed passing',
                  record.get('passed') == 42 and record.get('failed') == 0 and record.get('exit_code') == 0
                  and record.get('official_passed_all') is True and record.get('passed_all') is True
                  and semantic.get('passed_all') is True and semantic.get('exit_code') == 0
                  and len(semantic.get('checks', [])) == 6
                  and all(v.get('passed') is True for v in semantic.get('checks', [])))
        else:
            parsed = parse(record['output'])
            check(label + ': all raw wrk metrics/counters are parsed independently without omission',
                  all(record.get(k) == v if isinstance(v, (dict, int)) else close(record.get(k), v) for k, v in parsed.items()))
            check(label + ': full measured duration and completion',
                  record.get('completed') is True and record.get('valid_duration') is True
                  and 14.5 <= parsed['duration_s'] <= 17)
            before, after = record['before'], record['after']
            expected_cpu = 100 * (after['cpu_s'] - before['cpu_s']) / (after['monotonic'] - before['monotonic'])
            check(label + ': reported resource metrics derive from retained observations',
                  close(record.get('rss_mib'), after['rss_kib'] / 1024)
                  and close(record.get('cpu_percent'), expected_cpu))
            warmup = parse(record['warmup_output'])
            check(label + ': raw warmup is retained with the expected two-second duration', 1.5 <= warmup['duration_s'] <= 4)
        serverlog = BATCH / 'server-logs' / f'{record.get("mode")}-{key}-{record.get("trial")}.log'
        check(label + ': server log is retained for the observed attempt', serverlog.is_file())
        FILES.add(serverlog)
    proof = read(BATCH / 'pr-documentation-image-proof.json')
    check('Goose production binary and image remain the previously measured pinned bytes',
          proof.get('binary_sha256') == 'a5e1c087110e0dde7bda696620327a6c37178ee62e09d3c56d53c49a708c10fb'
          and proof.get('image_id') == 'sha256:b17522f81b6eda12da69f79f6ea38c3e361149beda73ab0f349568c81d0282a0'
          and proof.get('source_snapshot_sha256') == '585649e7bc8dcd98a281a07c682c0bd17869b9eec2bada040d1f80f146ef8796'
          and proof.get('binary_unchanged') is True and proof.get('binary_rebuilt') is False)
    for key, pinned in manifest.items():
        hashes = read(BATCH / pinned['source_hashes'])
        source_dir = pinned.get('source_dir', 'sources/pr' + key)
        check(key + ': actual retained source snapshot matches every pinned file',
              len(hashes) == pinned.get('source_file_count')
              and all(sha(BATCH / source_dir / name) == digest for name, digest in hashes.items()))
    return verification, trials, builds


def audit_rows(verification, trials, builds):
    old = read(HERE / 'rows.json')
    new = read(HERE / 'recheck-rows.json')
    canonical = read(VIEW / 'comparison-rows.json')
    visible = read(VIEW / 'visible-rows.json')
    oldmap, newmap = ({r['row_id']: r for r in collection} for collection in (old, new))
    mapped = {r['row_id']: r for r in canonical}
    visiblemap = {r['row_id']: r for r in visible}
    check('original canonical 127 rows remain byte-identical', len(old) == 127 and sha(HERE / 'rows.json') == OLD_ROWS_SHA)
    check('new normalized rows contain exactly Goose and Rust latest-batch summaries',
          len(new) == len(newmap) == 2 and {case(r) for r in new} == {'143', '82'} and not set(oldmap) & set(newmap))
    check('canonical data preserves all old 127 values plus the new two rows exactly once',
          len(canonical) == len(mapped) == 129 and mapped == oldmap | newmap)
    check('all non-Goose historical and current rows remain value-exact',
          all(mapped.get(key) == row for key, row in oldmap.items() if key not in ARCHIVED))
    expected_visible = {k: v for k, v in mapped.items() if k not in ARCHIVED}
    check('visible view excludes only three old Goose rows and retains all other evidence rows',
          len(visible) == len(visiblemap) == 126 and visiblemap == expected_visible)
    check('the visible table has exactly one current Goose entry',
          len([r for r in visible if case(r) in {'143', 'goose', 'baseline'}]) == 1
          and next((r for r in visible if case(r) == '143'), None) in new)
    spec = importlib.util.spec_from_file_location('independent_recheck_classifier', HERE / 'conditions.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for row in new:
        key = case(row)
        records = [r for r in trials if case(r) == key]
        tests = [r for r in verification if case(r) == key]
        measured_errors = dict(http_errors=sum(r.get('http_errors', 0) for r in records),
                               socket_errors={k: sum(r.get('socket_errors', {}).get(k, 0) for r in records) for k in SOCKETS})
        clean = len(records) == 3 and measured_errors['http_errors'] == 0 and not any(measured_errors['socket_errors'].values())
        check(key + ': all three trials reproduce every reported median and throughput range',
              len(records) == 3 and all(close(row.get(k), statistics.median(r[k] for r in records)) for k in METRICS)
              and close(row.get('rps_min'), min(r['successful_rps'] for r in records))
              and close(row.get('rps_max'), max(r['successful_rps'] for r in records)))
        check(key + ': every measured HTTP/socket error remains included in aggregate',
              all(row.get(k) == v for k, v in measured_errors.items()))
        warmups = [parse(r['warmup_output']) for r in records]
        check(key + ': every raw warmup HTTP/socket counter remains included in aggregate',
              row.get('warmup_http_errors') == sum(r['http_errors'] for r in warmups)
              and row.get('warmup_socket_errors') == sum(sum(r['socket_errors'].values()) for r in warmups))
        check(key + ': local PASS follows the complete observed zero-error evidence only',
              row.get('requirements_status') == ('PASS' if clean else 'FAIL')
              and row.get('benchmark_requirements_met') is clean
              and row.get('status') == ('measured' if clean else 'measured_with_errors')
              and row.get('trials_recorded') == 3 and len(tests) == 1
              and row.get('tests_passed') == 42 and row.get('tests_failed') == 0
              and row.get('official_passed_all') is True and row.get('semantic_passed_all') is True
              and row.get('database_valid') is True)
        check(key + ': exact classifier output and explicit local-only official-condition scope',
              all(row.get(k) == v for k, v in module.classify(row).items())
              and row.get('official_conditions_status') == 'UNVERIFIED'
              and 'local' in row.get('requirements_scope', '').lower())
        check(key + ': normalized source/image/binary match the unchanged retained build',
              row.get('commit') == records[0].get('commit')
              and row.get('source_sha256') == records[0].get('source_sha256')
              and row.get('image_id') == records[0].get('image_id')
              and row.get('binary_sha256') == builds[key]['proof']['binary_sha256'])
        check(key + ': latest row names the new full stock batch and exact protocol',
              row.get('measurement_batch') == BATCH.name and row.get('batch') == BATCH.name
              and row.get('protocol') == 'stock-wrk-3x15s' and row.get('measurement_seconds') == 15
              and row.get('warmup_seconds') == 2)
        reference = row.get('raw_trials_ref', {})
        check(key + ': exact raw evidence reference pins the complete new batch',
              reference.get('sha256') == sha(BATCH / 'measurements.json')
              and reference.get('case_id') == key and reference.get('trials') == [1, 2, 3]
              and BATCH.name in reference.get('path', '') and BATCH.name in row.get('evidence_url', ''))
    for name in ('comparison.csv',):
        path = VIEW / name
        with path.open() as stream:
            csvrows = list(csv.DictReader(stream))
        FILES.add(path)
        check(name + ': all visible evidence IDs appear exactly once',
              [r['row_id'] for r in csvrows] == [r['row_id'] for r in visible])
        correct = True
        for value in csvrows:
            row = mapped[value['row_id']]
            for k, v in value.items():
                expected = row.get(k)
                if k.startswith('socket_') and k[7:] in SOCKETS:
                    expected = (row.get('socket_errors') or {}).get(k[7:])
                correct &= v == ('' if expected is None else str(expected))
        check(name + ': every scalar field matches canonical evidence exactly', correct)
    for name in ('report.md', 'issue-comment.md'):
        path = VIEW / name
        text = path.read_text()
        FILES.add(path)
        check(name + ': exactly one table contains all visible rows in order',
              re.findall(r'<!-- row:([^ ]+) -->', text) == [r['row_id'] for r in visible]
              and len(re.findall(r'^\|[ :|-]+\|$', text, re.M)) == 1)
        check(name + ': historical Goose evidence remains linked without duplicate rows',
              all(key not in re.findall(r'<!-- row:([^ ]+) -->', text) for key in ARCHIVED)
              and '38' in text and 'history' in text.lower())
        check(name + ': local conditions and official-scope distinction remain explicit',
              'Local conditions' in text and 'official' in text.lower() and 'x86' in text.lower() and 'k6' in text.lower())
        numeric_ok = labels_ok = True
        number = lambda value, digits=0: '—' if value is None else f'{value:,.{digits}f}'
        for line in text.splitlines():
            markers = re.findall(r'<!-- row:([^ ]+) -->', line)
            if not markers:
                continue
            row = visiblemap[markers[0]]
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
                8: number(row.get('app_loc')) + ' / ' + number(row.get('own_loc')),
            }
            numeric_ok &= len(cells) == 10 and all(cells[k] == v for k, v in expected_cells.items())
            status = row.get('requirements_status')
            labels_ok &= ('OTHER PROTOCOL' if status == 'DIFFERENT_PROTOCOL' else status) in cells[1]
        check(name + ': all displayed metrics, ranges, counters and LOC equal canonical data', numeric_ok)
        check(name + ': every visible condition label equals independently checked row metadata', labels_ok)
    htmlpath = VIEW / 'comparison.html'
    html = htmlpath.read_text()
    FILES.add(htmlpath)
    marker = 'const rows='
    embedded, _ = json.JSONDecoder().raw_decode(html[html.index(marker) + len(marker):])
    check('HTML embeds the full visible evidence with exactly one table',
          embedded == [{k: v for k, v in r.items() if k != 'source_record'} for r in visible]
          and html.count('<table') == html.count('<tbody') == 1)
    return new, canonical, visible


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allow-pending', action='store_true', help='Report absent generated views without writing a failed audit.')
    args = parser.parse_args()
    needed = [HERE / 'recheck-rows.json', VIEW / 'comparison-rows.json', VIEW / 'visible-rows.json',
              VIEW / 'comparison.csv', VIEW / 'comparison.html', VIEW / 'report.md', VIEW / 'issue-comment.md']
    missing = [str(p) for p in needed if not p.is_file()]
    raw = read(BATCH / 'measurements.json')
    if args.allow_pending and (missing or len(raw) != 6):
        print(json.dumps(dict(pending=True, missing=missing, measured_attempts=len(raw)), indent=2))
        return
    check('old raw stock attempts remain byte-identical', sha(OLD / 'measurements.json') == OLD_MEASUREMENTS_SHA)
    verification, trials, builds = audit_batch()
    new, canonical, visible = audit_rows(verification, trials, builds)
    check('old raw stock attempts still byte-identical after all file-only checks', sha(OLD / 'measurements.json') == OLD_MEASUREMENTS_SHA)
    FILES.add(Path(__file__).resolve())
    output = dict(passed_all=all(v['passed'] for v in CHECKS), complete=True,
                  checks_passed=sum(v['passed'] for v in CHECKS), checks_total=len(CHECKS), checks=CHECKS,
                  counts=dict(correctness_attempts=len(verification), measured_attempts=len(trials),
                              canonical_rows=len(canonical), visible_rows=len(visible), archived_goose_rows=3),
                  output_sha256={str(p.relative_to(HERE.parent)): sha(p) for p in sorted(FILES) if p.is_file()},
                  latest_results={case(r): {k: r[k] for k in ('successful_rps', 'requirements_status', 'http_errors', 'socket_errors')} for r in new},
                  limitations=['File-only audit of retained observations; no server or Docker invocation.',
                               'PASS covers documented local runtime checks only, not official x86-64 droplet/k6 conditions.',
                               'This new stock batch does not overturn the prior UNMET stable-five-percent conclusion.',
                               'Historical raw counters are preserved; their cause is not inferred.'])
    (HERE / 'recheck-audit.json').write_text(json.dumps(output, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: v for k, v in output.items() if k not in {'checks', 'output_sha256'}}, indent=2))
    for value in CHECKS:
        if not value['passed']:
            print('FAIL:', value['check'], value.get('detail', ''))
    raise SystemExit(0 if output['passed_all'] else 1)


if __name__ == '__main__':
    main()
