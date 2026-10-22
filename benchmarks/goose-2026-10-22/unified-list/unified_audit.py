"""Independent, file-only audit of the single unified measurements table."""
import collections
import csv
import hashlib
import json
import math
from pathlib import Path
import re
import statistics

ROOT = Path(__file__).resolve().parent
GOOSE = ROOT.parent
REPO = ROOT.parents[2]
CHECKS = []
SOCKETS = ('connect', 'read', 'write', 'timeout')
METRICS = ('rps', 'successful_rps', 'p50_ms', 'p95_ms', 'p99_ms', 'rss_mib', 'cpu_percent')
FROZEN = {
    'results/fixes-2026-10-22/summary.json': '44746123e12340a6abb2674838b59d9c14cb760a763120d4ba0d6bbe141b4933',
    'results/goose-2026-10-22/list-integration/summary.json': '5f486bd45a79aaed781b9b928f1ecb07c82670f47b867b190bedc344a6fff613',
    'results/goose-2026-10-22/ranking-3x15-2026-10-22/measurements.json': '88bd8ca7a4f489192f84b34000c729bca1562d1441d91b90284b6c10ebcfb1d3',
    'results/goose-2026-10-22/lead5/holdout-hmac/measurements.json': '52e56cecd0b75279b4fa7301d4b561ccef4b06a3452eb6ccbb1c8c2167cc27ab',
    'results/goose-2026-10-22/lead5/holdout-hmac/finalholdout-summary.json': 'c4f873838637c4ea99ce8ce3ed187465f1ff1dc23a921db1f60875e71fc51070',
}


def read(path):
    return json.loads(path.read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(name, condition, detail=None):
    CHECKS.append(dict(check=name, passed=bool(condition), **({'detail': detail} if detail is not None else {})))


def close(a, b):
    return (type(a) in (int, float) and type(b) in (int, float)
            and math.isfinite(a) and math.isfinite(b) and math.isclose(a, b, rel_tol=1e-10, abs_tol=1e-9))


def case(row):
    return str(row['case_id'] if 'case_id' in row else row['id'] if 'id' in row else row['pr'])


def parse(output):
    count, duration = re.search(r'(\d+) requests in ([0-9.]+)s,', output).groups()
    values = dict(requests=int(count), duration_s=float(duration),
                  rps=float(re.search(r'Requests/sec:\s+([0-9.]+)', output)[1]))
    for percentile in (50, 95, 99):
        number, unit = re.search(r'\s' + str(percentile) + r'(?:\.0+)?%\s+([0-9.]+)(us|ms|s)', output).groups()
        values[f'p{percentile}_ms'] = float(number) * {'us': .001, 'ms': 1, 's': 1000}[unit]
    match = re.search(r'Non-2xx or 3xx responses:\s*(\d+)', output)
    values['http_errors'] = int(match[1]) if match else 0
    match = re.search(r'Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)', output)
    values['socket_errors'] = dict(zip(SOCKETS, map(int, match.groups()) if match else (0, 0, 0, 0)))
    values['successful_rps'] = values['rps'] - values['http_errors'] / values['duration_s']
    return values


def expected_sources():
    integrated = read(GOOSE / 'list-integration/summary.json')
    return dict(current=integrated['rows'],
                historical=[r['before'] for r in integrated['before_after'] if r['before'].get('successful_rps') is not None],
                controls=[r for r in integrated['followup_rows'] if r.get('role') == 'control'] + integrated['additional_controls'],
                long_trials=read(GOOSE / 'lead5/holdout-hmac/measurements.json'))


def audit_frozen():
    for name, digest in FROZEN.items():
        check('prior evidence unchanged: ' + name, sha(REPO / name) == digest)


def audit_long_raw(trials):
    check('long confirmation retains all 30 original attempts', len(trials) == 30 and collections.Counter(
        (case(r), r['trial']) for r in trials) == collections.Counter((k, n) for k in ('goose', '82', 'baseline') for n in range(1, 11)))
    for row in trials:
        parsed = parse(row['output'])
        check(f'long {case(row)}/{row["trial"]}: exact raw metrics and zero measured errors',
              all(row.get(k) == v if isinstance(v, (dict, int)) else close(row.get(k), v) for k, v in parsed.items())
              and parsed['http_errors'] == 0 and not any(parsed['socket_errors'].values()))


def main():
    audit_frozen()
    sources = expected_sources()
    audit_long_raw(sources['long_trials'])
    rows = read(ROOT / 'rows.json')
    mapped = {r['row_id']: r for r in rows}
    expected = {}
    for r in sources['current']:
        expected['current:' + case(r)] = ('current', r)
    for r in sources['historical']:
        expected[f'historical:{case(r)}:{r["commit"]}'] = ('historical', r)
    for r in sources['controls']:
        expected[f'control:{r["batch"]}:{case(r)}'] = ('control', r)
    additions = read(GOOSE / 'publication-additive-draft/goose-addition.json')
    for r in additions['submission_additions'] + additions['reference_controls']:
        expected['confirmation:' + case(r)] = ('confirmation', r)
    check('127 unique rows contain exactly 120 current, two historical, two controls and three confirmations',
          len(rows) == len(mapped) == len(expected) == 127 and set(mapped) == set(expected)
          and collections.Counter(r['role'] for r in rows)
          == collections.Counter(current=120, historical=2, control=2, confirmation=3))
    for row_id, (role, original) in expected.items():
        row = mapped[row_id]
        check(row_id + ': complete original source record preserved exactly', row.get('source_record') == original)
        allowed = {'role', 'rank', 'ranked'} | ({'source_url', 'pr_url'} if role == 'confirmation' else set())
        check(row_id + ': original display metrics, source identities and status preserved',
              all(row.get(k) == v for k, v in original.items() if k not in allowed)
              and row.get('source_role') == original.get('role')
              and row.get('source_rank') == original.get('rank') and row.get('role') == role)
        check(row_id + ': explicit duration and clock protocol', row.get('measurement_seconds') == (45 if role == 'confirmation' else 15)
              and row.get('warmup_seconds') == 2
              and row.get('protocol') == ('monotonic-wrk-10x45s' if role == 'confirmation' else 'stock-wrk-3x15s')
              and bool(row.get('protocol_label')))
        if role != 'confirmation':
            check(row_id + ': ranks apply only to the original clean current rows',
                  row.get('rank') == (original.get('rank') if role == 'current' else None)
                  and row.get('ranked') is (original.get('ranked') if role == 'current' else False))
            continue
        trials = [r for r in sources['long_trials'] if case(r) == case(original)]
        check(row_id + ': all ten raw trials independently reproduce confirmation medians', len(trials) == 10
              and all(close(row.get(k), statistics.median(r[k] for r in trials)) for k in METRICS if k != 'rps')
              and close(row.get('rps_min'), min(r['successful_rps'] for r in trials))
              and close(row.get('rps_max'), max(r['successful_rps'] for r in trials)))
        check(row_id + ': long zero errors and UNMET outcome remain unranked', row.get('rank') is None
              and row.get('ranked') is False and row.get('target_outcome') == 'UNMET'
              and row.get('http_errors') == 0 and row.get('socket_errors') == dict.fromkeys(SOCKETS, 0)
              and row.get('warmup_http_errors') == row.get('warmup_socket_errors') == 0)
        check(row_id + ': exact raw/summary evidence references',
              row.get('raw_trials_ref', {}).get('sha256') == FROZEN['results/goose-2026-10-22/lead5/holdout-hmac/measurements.json']
              and row.get('raw_trials_ref', {}).get('case_id') == case(original)
              and row.get('raw_trials_ref', {}).get('trials') == list(range(1, 11))
              and row.get('summary_ref', {}).get('sha256') == FROZEN['results/goose-2026-10-22/lead5/holdout-hmac/finalholdout-summary.json'])
    rankrows = sorted((r for r in rows if r.get('rank') is not None), key=lambda r: r['rank'])
    check('exactly 98 clean current ranks are preserved without ranking references',
          len(rankrows) == 98 and [r['rank'] for r in rankrows] == list(range(1, 99))
          and all(r['role'] == 'current' and r.get('ranked') is True
                  and r.get('http_errors') == 0 and not any(r.get('socket_errors', {}).values()) for r in rankrows))
    throughputs = [r.get('successful_rps') for r in rows]
    nonnull = [v for v in throughputs if v is not None]
    check('all measured rows sorted by descending throughput, 14 unmeasured rows last',
          nonnull == sorted(nonnull, reverse=True)
          and throughputs == nonnull + [None] * 14)
    check('short Goose38 and Rust34 timeouts remain explicit with no rank',
          mapped['current:143']['socket_errors'] == dict(connect=0, read=0, write=0, timeout=38)
          and mapped['control:ranking-3x15-2026-10-22:82']['socket_errors'] == dict(connect=0, read=0, write=0, timeout=34)
          and mapped['current:143']['rank'] is None
          and mapped['control:ranking-3x15-2026-10-22:82']['rank'] is None)
    ids = [r['row_id'] for r in rows]
    with (ROOT / 'comparison.csv').open() as stream:
        reader = csv.DictReader(stream)
        csvrows = list(reader)
    check('CSV has all 127 row IDs once in the shared sorted order', [r['row_id'] for r in csvrows] == ids)
    csv_ok = True
    for value in csvrows:
        row = mapped[value['row_id']]
        for k, v in value.items():
            expected_value = row.get(k)
            if k.startswith('socket_') and k[7:] in SOCKETS:
                expected_value = (row.get('socket_errors') or {}).get(k[7:])
            expected_text = '' if expected_value is None else str(expected_value)
            csv_ok &= v == expected_text
    check('every CSV field equals its shared-row value', csv_ok)
    html = (ROOT / 'comparison.html').read_text()
    marker = 'const rows='
    htmlrows, _ = json.JSONDecoder().raw_decode(html[html.index(marker) + len(marker):])
    check('HTML has exactly one table/body and the same 127 rows in order',
          html.count('<table') == html.count('<tbody') == 1
          and htmlrows == [{k: v for k, v in r.items() if k != 'source_record'} for r in rows])
    missing = []
    for name in ('report.md', 'issue-comment.md'):
        path = ROOT / name
        if not path.is_file():
            missing.append(name)
            continue
        text = path.read_text()
        rendered_ids = re.findall(r'<!-- row:([^ ]+) -->', text)
        check(name + ': exactly one measurements table with all 127 shared IDs in order',
              rendered_ids == ids and len(re.findall(r'^\|[ :|-]+\|$', text, re.M)) == 1)
        check(name + ': every data row carries its explicit clock/duration protocol', all(
              ('10×45s' in line and ('monotonic' in line or 'mono ' in line) if mapped[row_id]['role'] == 'confirmation'
               else '3×15s' in line and 'stock' in line)
              for line in text.splitlines() for row_id in re.findall(r'<!-- row:([^ ]+) -->', line)))
        markdown_values_ok = True
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
                3: rps,
                4: number(row.get('p95_ms'), 3) + ' / ' + number(row.get('p99_ms'), 3),
                5: number(row.get('rss_mib'), 2) + ' / ' + number(row.get('cpu_percent'), 1),
                6: errors,
                7: number(row.get('app_loc')) + ' / ' + number(row.get('own_loc'))}
            markdown_values_ok &= len(cells) == 9 and all(cells[k] == v for k, v in expected_cells.items())
        check(name + ': every displayed metric, range, error counter and LOC equals rounded source data', markdown_values_ok)
    check('both final Markdown surfaces exist', not missing, missing or None)
    audit_frozen()
    files = ['rows.json', 'comparison.csv', 'comparison.html', 'report.md', 'issue-comment.md', 'render.py', 'render_markdown.py', 'unified_audit.py']
    output = dict(complete=not missing, audit_passed=all(c['passed'] for c in CHECKS),
                  checks_passed=sum(c['passed'] for c in CHECKS), checks_total=len(CHECKS), checks=CHECKS,
                  counts=dict(display_rows=len(rows), current=120, historical=2, controls=2, confirmations=3, ranked=98),
                  frozen_evidence_sha256=FROZEN,
                  output_sha256={n: sha(ROOT / n) for n in files if (ROOT / n).is_file()},
                  limitations=['One presentation table includes different explicitly labeled measurement protocols and dates; sorting does not establish a simultaneous head-to-head ranking.',
                               'The original 98 clean current ranks remain separate from display order; references and errored outcomes are unranked.',
                               'This file-only audit does not rerun servers or infer the cause of recorded timeout counters.'])
    (ROOT / 'unified-audit.json').write_text(json.dumps(output, indent=2) + '\n')
    print(json.dumps({k: v for k, v in output.items() if k not in {'checks', 'frozen_evidence_sha256', 'output_sha256'}}, indent=2))
    for c in CHECKS:
        if not c['passed']:
            print('FAIL:', c['check'], c.get('detail', ''))
    return 0 if output['audit_passed'] and output['complete'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
