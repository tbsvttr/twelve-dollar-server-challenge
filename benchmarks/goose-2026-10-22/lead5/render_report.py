"""Render only the completed selected holdout and this experiment's index.

Run after the controller, bounded replacements, final JSON summary and audits:
    python3 results/goose-2026-10-22/lead5/render_report.py
This reads files only. It never runs a server, compiler, container or workload.
Earlier experiment reports and all raw evidence are left untouched.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import re
import statistics

ROOT = Path(__file__).resolve().parent
BATCH = ROOT / 'holdout-selected'
CASES = ('82', 'goose', 'baseline')
NAMES = {'82': 'Rust PR 82', 'goose': 'Selected Goose', 'baseline': 'Retained Goose'}
SHARED_BATCHES = ('paired-diagnostic-first', 'paired-diagnostic-second', 'paired-diagnostic-final-selection')
SHARED_NAMES = {
    'baseline': 'Retained Goose A/A', '82': 'Rust PR 82',
    'goose': 'Combined cache/header/application PGO',
    'combined-sqlite': 'Combined + application-query SQLite PGO',
    'combined-like-bound': 'Selected combined + bounded likes',
    'unified-pgo-lto': 'Unified five-unit PGO/LTO',
    'unified-like-final': 'Unified PGO/LTO + bounded likes',
    'unified-like-trainer-v2-final': 'Unified + bounded likes + trainer v2',
}
REQUIRED_GATES = (
    'evidence_checks', 'ten_clean_rounds', 'replacement_limit',
    'zero_candidate_errors_in_all_attempts', 'candidate_valid_in_all_attempts',
    'geometric_mean_at_least_5_percent',
    'one_sided_95_percent_lower_bound_at_least_5_percent',
    'nine_of_ten_pairs_at_least_5_percent', 'median_p99_within_5_percent_of_rust',
)


def read(path):
    return json.loads(path.read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def number(value, digits=2):
    return f'{value:,.{digits}f}' if finite(value) else 'n/a'


def ratio(value):
    return f'{value:.5f}× ({(value - 1) * 100:+.2f}%)' if finite(value) else 'n/a'


def status(value):
    return 'PASS' if value is True else 'FAIL'


def cell(value):
    return str(value).replace('|', '\\|').replace('\n', ' ')


def table(headers, rows):
    lines = ['| ' + ' | '.join(map(cell, headers)) + ' |',
             '| ' + ' | '.join('---' for _ in headers) + ' |']
    lines.extend('| ' + ' | '.join(map(cell, row)) + ' |' for row in rows)
    return '\n'.join(lines)


def link(label, path, destination):
    relative = Path(os.path.relpath(path, destination.parent)).as_posix()
    return f'[{label}](<{relative}>)'


def socket_errors(row):
    value = row.get('socket_errors', {})
    return sum(value.values()) if isinstance(value, dict) else value or 0


def median(values):
    values = [value for value in values if finite(value)]
    return statistics.median(values) if values else None


def binary_hash(build):
    proof = build.get('proof', {})
    return proof.get('binary_sha256', proof.get('files', {}).get('bin/server', {}).get('sha256'))


def load_completed():
    summary_path = BATCH / 'finalholdout-summary.json'
    marker = read(BATCH / 'holdout-complete.json')
    summary = read(summary_path)
    audit = read(BATCH / 'independent-audit.json')
    rows = read(BATCH / 'measurements.json')
    if marker.get('complete') is not True and marker.get('status') not in ('complete', 'completed'):
        raise ValueError('Holdout completion marker is not final; refusing a partial report')
    count = marker.get('attempt_count', marker.get('attempts_count', marker.get('all_attempts')))
    if count != len(rows) or summary.get('all_attempts') != len(rows):
        raise ValueError('Completion marker, final summary and raw attempt counts differ')
    if marker.get('selected_rounds') != summary.get('selected_rounds'):
        raise ValueError('Completion marker and final selected rounds differ')
    if audit.get('complete') is not True or audit.get('measurement_count') != len(rows):
        raise ValueError('Independent evidence audit is unfinished or describes different attempts')
    raw_sha = sha(BATCH / 'measurements.json')
    if audit.get('measurements_sha256') != raw_sha:
        raise ValueError('Independent audit does not bind the current raw measurements')
    summary_sha = sha(summary_path)
    if audit.get('primary_summary', {}).get('sha256') != summary_sha:
        raise ValueError('Independent audit does not bind the displayed final primary summary')
    for key, actual in [('summary_sha256', summary_sha), ('measurements_sha256', raw_sha)]:
        if key in marker and marker[key] != actual:
            raise ValueError('Completion marker hash differs: ' + key)
    gates = summary.get('gates', {})
    target = (summary.get('passed_all') is True and all(gates.get(name) is True for name in REQUIRED_GATES)
              and all(value is True for value in gates.values())
              and audit.get('audit_passed') is True and audit.get('target_passed') is True)
    manifest = {str(row['id']): row for row in read(BATCH / 'manifest.json')}
    builds = read(BATCH / 'build-status.json')
    return dict(summary=summary, audit=audit, rows=rows, marker=marker, target=target,
                manifest=manifest, builds=builds, selection=read(BATCH / 'selection.json'),
                environment=read(BATCH / 'environment-bench.json'))


def discovery(destination):
    paragraphs = []
    seq_rows, seq_count = [], 0
    for name in ('cache-grid', 'isolated-screen'):
        path = ROOT / name / 'measurements.json'
        rows = read(path)
        seq_count += len(rows)
        ranges = []
        for case in ('82', 'baseline'):
            values = [row.get('successful_rps') for row in rows if row.get('case_id') == case
                      and finite(row.get('successful_rps'))]
            ranges.append(f'{number(min(values))}–{number(max(values))}' if values else 'n/a')
        seq_rows.append([link(name, path, destination), len(rows),
                         sum(row.get('http_errors', 0) for row in rows),
                         sum(socket_errors(row) for row in rows), *ranges])
    shared_rows, shared_count = [], 0
    for name in SHARED_BATCHES:
        summary_path = ROOT / name / 'summary.json'
        data = read(summary_path)
        shared_count += len(data['attempts'])
        groups = {}
        for attempt in data['attempts']:
            groups.setdefault(attempt['pair_index'], []).append(attempt)
        for index, attempts in sorted(groups.items()):
            pair = attempts[0]['requested_pair']
            label = ' / '.join(SHARED_NAMES.get(case, case) for case in pair)
            ratios = ', '.join(number(attempt.get('requested_first_second_ratio'), 5) + '×' for attempt in attempts)
            value = data.get('pair_ratio_medians', {}).get(str(index))
            raw = ', '.join(link(attempt['attempt_id'], ROOT / name / (attempt['attempt_id'] + '.json'), destination)
                            for attempt in attempts)
            shared_rows.append([name.removeprefix('paired-diagnostic-'), label, ratios,
                ratio(value), f"{sum(attempt.get('valid') is True for attempt in attempts)}/{len(attempts)}",
                status(data.get('aa_gate_passed')), raw])
    if seq_count != 32 or shared_count != 18:
        raise ValueError('Discovery inventory differs from the frozen 32 sequential / 18 shared-pair attempts')
    paragraphs += [f'All **{seq_count} sequential discovery attempts** and **{shared_count} shared-CPU pair attempts** '
        '(36 measured server instances) remain preserved as selection evidence. They are excluded from the holdout statistics. '
        'The shared diagnostics put two servers on one guest CPU and swapped sides; their ratios describe that diagnostic setup.',
        table(['Sequential batch', 'Attempts', 'HTTP errors', 'Socket errors', 'Rust RPS range', 'Retained Goose RPS range'], seq_rows),
        'Sequential controls varied substantially on the occupied Mac. The unchanged host state and scheduling noise limit '
        'interpretation of those discovery rates. A/A checks and the complete comparison matrix are retained below; '
        'their exploratory results cannot establish the predeclared 5% target.',
        table(['Shared batch', 'Requested first / second', 'Both ratios', 'Median ratio', 'Valid / attempted', 'A/A gate', 'Raw pairs'], shared_rows),
        'Only the combined candidate with legacy SQLite PGO, four-unit application PGO, transport/header changes, '
        '8 MiB cache/mmap disabled and the bounded likes query was selected. Five-unit SQLite-inclusive LTO, '
        'application-query SQLite training and trainer-v2 variants were not selected and are not shipped. '
        'Their sources, builds and measurements remain in ' + link('candidates/', ROOT / 'candidates', destination) + '.']
    return '\n\n'.join(paragraphs)


def render(context, destination, index=False):
    s, audit, rows = context['summary'], context['audit'], context['rows']
    selected = set(s.get('selected_rounds', []))
    outcome = 'MET' if context['target'] else 'UNMET'
    lead = f'**Predeclared stable ≥5% target: {outcome}.**'
    failed = [name for name, passed in s.get('gates', {}).items() if passed is not True]
    if audit.get('audit_passed') is not True:
        failed.append('independent evidence audit')
    if audit.get('target_passed') is not True:
        failed.append('independent target audit')
    if failed:
        lead += ' Failed gates: ' + ', '.join(name.replace('_', ' ') for name in failed) + '.'
    paired = s.get('paired_rounds', [])
    ratios = [pair.get('candidate_rust_ratio', pair.get('rps', {}).get('goose', 0) / pair['rps']['82'])
              for pair in paired if pair.get('rps', {}).get('82', 0) > 0]
    wins = sum(value > 1.05 for value in ratios)
    p99 = s.get('median_p99_ms', {})
    tail_ratio = p99.get('goose', 0) / p99['82'] if p99.get('82', 0) > 0 else None
    chunks = [f'# Goose versus Rust: 5% holdout — {outcome}', lead,
        f"Goose/Rust geometric mean of paired throughput ratios: **{ratio(s.get('geometric_mean_ratio'))}**. "
        f"One-sided 95% Student-t lower bound: **{ratio(s.get('one_sided_95_percent_lower_ratio'))}**. "
        f"{wins}/{len(paired)} selected pairs exceeded 5%. "
        f"Independent evidence audit: **{status(audit.get('audit_passed'))}**; independent target audit: "
        f"**{status(audit.get('target_passed'))}**.",
        'The outcome uses the ' + link('predeclared protocol', ROOT / 'PROTOCOL.md', destination) + ', '
        + link('final primary summary', BATCH / 'finalholdout-summary.json', destination) + ' and '
        + link('independent audit', BATCH / 'independent-audit.json', destination) + '. '
        'A positive point estimate alone does not satisfy the target.']
    if index:
        chunks.append('The complete selected holdout report is ' + link('holdout-selected/RESULT.md', BATCH / 'RESULT.md', destination) + '. '
                      'Earlier reports remain unchanged in ' + link('the experiment archive', ROOT.parent, destination) + '.')
    gates = s.get('gates', {})
    total_errors = s.get('all_attempt_error_totals', {}).get('goose', {})
    candidate_errors = sum(total_errors.get(key, 0) for key in ('http_errors', 'socket_errors', 'warmup_http_errors', 'warmup_socket_errors'))
    criteria = [
        ('Identity, fixtures, raw correctness, database and resource evidence', 'All verified', status(gates.get('evidence_checks'))),
        ('Complete clean matched rounds', f'{len(selected)}/10', status(gates.get('ten_clean_rounds'))),
        ('Replacement bound', f"{len(s.get('excluded_rounds', []))} excluded; at most two replacements", status(gates.get('replacement_limit'))),
        ('Candidate errors in every attempted run, including warmup', candidate_errors, status(gates.get('zero_candidate_errors_in_all_attempts'))),
        ('Every candidate attempt valid', str(s.get('candidate_invalid_attempt_trials', [])), status(gates.get('candidate_valid_in_all_attempts'))),
        ('Paired geometric mean ≥1.05', ratio(s.get('geometric_mean_ratio')), status(gates.get('geometric_mean_at_least_5_percent'))),
        ('One-sided 95% lower bound ≥1.05', ratio(s.get('one_sided_95_percent_lower_ratio')), status(gates.get('one_sided_95_percent_lower_bound_at_least_5_percent'))),
        ('At least 9/10 pairs above 5%', f'{wins}/{len(paired)}', status(gates.get('nine_of_ten_pairs_at_least_5_percent'))),
        ('Candidate median p99 ≤1.05× Rust', f"{number(p99.get('goose'))} / {number(p99.get('82'))} ms; {ratio(tail_ratio)}", status(gates.get('median_p99_within_5_percent_of_rust'))),
    ]
    chunks += ['## Confirmation', table(['Requirement', 'Observed', 'Gate'], criteria),
        f"{len(s.get('attempted_rounds', []))} rounds and {len(rows)} server attempts are retained. Selected rounds: "
        + ', '.join(map(str, sorted(selected))) + '. '
        'Any invalid round is excluded for all three implementations. Low throughput alone is not an exclusion reason. '
        'The confidence bound uses log ratios and Student-t with nine degrees of freedom when ten clean rounds exist.']
    if s.get('excluded_rounds'):
        chunks.append('Excluded whole rounds: ' + '; '.join(f"{item['trial']}: " + json.dumps(item.get('issues', {}), sort_keys=True)
                      for item in s['excluded_rounds']) + '.')
    if s.get('protocol_issues'):
        chunks.append('Protocol/evidence issues: ' + '; '.join(map(str, s['protocol_issues'])) + '.')
    groups = {}
    for row in rows:
        groups.setdefault(row.get('trial'), {}).setdefault(row.get('case_id'), []).append(row)
    round_rows = []
    for trial, cases in sorted(groups.items()):
        rates = {case: cases[case][0].get('successful_rps') if len(cases.get(case, [])) == 1 else None for case in CASES}
        comparison = rates['goose'] / rates['82'] if finite(rates['goose']) and finite(rates['82']) and rates['82'] > 0 else None
        round_rows.append([trial, 'yes' if trial in selected else 'no', *(number(rates[case]) for case in CASES), ratio(comparison)])
    chunks.append(table(['Round', 'Selected', 'Rust req/s', 'New Goose req/s', 'Retained Goose req/s', 'New / Rust'], round_rows))
    medians = []
    for case in CASES:
        current = [row for row in rows if row.get('case_id') == case and row.get('trial') in selected]
        medians.append([NAMES[case], number(median([row.get('successful_rps') for row in current])),
            number(median([row.get('p95_ms') for row in current])), number(median([row.get('p99_ms') for row in current])),
            number(median([row.get('rss_mib') for row in current])), number(median([row.get('cpu_percent') for row in current]))])
    chunks += ['Selected-round medians are descriptive; the success test uses paired ratios.',
        table(['Implementation', 'Req/s', 'p95 ms', 'p99 ms', 'RSS MiB', 'CPU %'], medians),
        '## All attempts',
        'Every raw latency and error count remains in ' + link('measurements.json', BATCH / 'measurements.json', destination)
        + '; links below retain the raw output. Candidate errors also prevent success when their whole round is excluded.']
    attempts = []
    summary_attempts = {(row['trial'], row['case_id']): row for row in s.get('attempts', [])}
    for index_number, row in enumerate(rows, 1):
        trial, case = row.get('trial'), row.get('case_id')
        info = summary_attempts.get((trial, case), {})
        warmup = info.get('warmup', {})
        suffix = re.sub('[^a-zA-Z0-9_.-]', '-', str(case))
        raw = BATCH / 'logs' / f'bench-{suffix}-{trial}.log'
        latencies = '/'.join(number(row.get(key), 3) for key in ('p50_ms', 'p95_ms', 'p99_ms'))
        attempts.append([index_number, trial, NAMES.get(case, case), 'yes' if trial in selected else 'no',
            number(row.get('successful_rps')), number(row.get('duration_s')), latencies,
            number(row.get('rss_mib')), number(row.get('cpu_percent')),
            f"{row.get('http_errors', 'n/a')}/{socket_errors(row)}",
            f"{warmup.get('http_errors', 'n/a')}/{socket_errors(warmup)}", link('raw', raw, destination)])
    chunks.append(table(['#', 'Round', 'Case', 'Used', 'Req/s', 'Seconds', 'p50/p95/p99 ms', 'RSS MiB', 'CPU %', 'HTTP/socket', 'Warmup HTTP/socket', 'Output'], attempts))
    error_rows = [[NAMES.get(case, case), values.get('http_errors', 0), values.get('socket_errors', 0),
                   values.get('warmup_http_errors', 0), values.get('warmup_socket_errors', 0)]
                  for case, values in s.get('all_attempt_error_totals', {}).items()]
    chunks.append(table(['All attempted runs', 'HTTP', 'Socket', 'Warmup HTTP', 'Warmup socket'], error_rows))
    identities = []
    for case in CASES:
        manifest, build = context['manifest'][case], context['builds'][case]
        source = manifest['source_sha256']
        source_label = source + (f"; commit {manifest['commit']}" if case == '82' else '')
        identities.append([NAMES[case], source_label, build['image_id'], binary_hash(build)])
    selected_build = context['builds']['goose']['proof']
    chunks += ['## Frozen implementation', table(['Implementation', 'Source snapshot / Git commit', 'Image SHA-256', 'Binary SHA-256'], identities),
        'The selected Goose snapshot contains 19 files. ' + link('Selection record', BATCH / 'selection.json', destination)
        + ' binds the source, image, binary, protocol and common driver before confirmation. Compiler: '
        + str(selected_build.get('compiler', 'recorded in build proof')) + '; Goose runtime '
        + str(selected_build.get('goose_runtime', 'recorded in build proof'))
        + ', compiler commit `f605b5a07dd2aa3a5cb3f4c9b14002bd3c9d3d1a`.',
        'The shipping build uses separately trained **legacy SQLite PGO** and **four-unit application PGO/LTO** '
        '(generated Goose, transport, database adapters and JSON quoting). Runtime changes are fixed response-header '
        'fragments/decimal lengths, monotonic activity time refreshed per poll/flush including after commit, '
        'an 8 MiB SQLite page cache with mmap disabled, and an indexed lower-bound likes query whose upper bound '
        'is checked in Goose before bounded array access. Writes commit before responses. '
        'This selected build does not include SQLite in application LTO and does not use trainer v2.']
    verification = read(BATCH / 'verification.json')
    api_rows = [[NAMES[case], next((str(row.get('passed')) + '/42' for row in verification if row.get('case_id') == case), 'missing'),
                status(any(row.get('case_id') == case and row.get('passed_all') is True for row in verification))] for case in CASES]
    parser, edge, above = (read(BATCH / name) for name in ('parser-checks.json', 'edge-checks.json', 'above-max-checks.json'))
    api_rows += [['Selected parser', f"{parser.get('passed')}/18", status(parser.get('passed_all'))],
                 ['Selected edge cases', f"{edge.get('passed')}/25", status(edge.get('passed_all'))],
                 ['Likes above maximum / omitted IDs', f"{above.get('passed')}/9", status(above.get('passed_all'))]]
    transport = read(ROOT / 'transport/results.json')
    chunks += ['## Correctness and transport', table(['Evidence', 'Checks', 'Result'], api_rows),
        'Official checks are followed by dynamic create/read/like/feed semantic checks and committed SQLite '
        'growth/integrity checks. See ' + link('verification', BATCH / 'verification.json', destination) + ', '
        + link('parser checks', BATCH / 'parser-checks.json', destination) + ', '
        + link('edge checks', BATCH / 'edge-checks.json', destination) + ' and '
        + link('nine additional likes checks', BATCH / 'above-max-checks.json', destination) + '.',
        f"Transport regression result: **{transport.get('status', 'unknown')}**. "
        'The retained suite covers 2,320 exact header comparisons, clock freshness after waits/commits, '
        'fragmentation, pipelining, chunked bodies, large/blocked writes, half-close and failed-commit responses. '
        'Address/undefined-behavior sanitizers and leak checks returned exit code '
        + str(transport.get('sanitizer_run', {}).get('exit_code', 'unknown')) + '. '
        'The initial clock-fixture failure and correction are retained with the '
        + link('transport evidence', ROOT / 'transport/results.json', destination) + '.',
        '## Discovery and rejected variants', discovery(destination)]
    clock = read(ROOT / 'wrk-monotonic/runtime-proof.json')
    chunks += ['## Measurement scope and build reproduction',
        'The host is ' + str(context['environment'].get('host_cpu', 'the recorded Apple ARM64 host'))
        + '. Servers run native Linux ARM64 containers on guest CPU 0 with one CPU quota and 2 GiB memory; '
        'the unchanged mixed load runs on CPUs 1–2 with two threads and 64 connections. '
        'Confirmation uses two-second warmups and 45-second measurements. The Mac stayed as-is, including '
        'unrelated host activity. These are comparisons of complete Goose+C/SQLite/OpenSSL and Rust/SQLite '
        'implementations, not an isolated language-speed result or an official x86-64 k6 capacity claim.',
        'All confirmation implementations use the same declared corrected Ubuntu wrk 4.1.0 driver: image `'
        + clock['image_id'] + '`, executable `' + clock['binary_path'] + '`, SHA-256 `' + clock['binary_sha256'] + '`. '
        'The minimal patch moves wrk elapsed timestamps to CLOCK_MONOTONIC; the deterministic proof preserves '
        'real over-two-second timeout accounting. Event-loop scheduling remains on wall time. The correction '
        'does not prove that every historical timeout came from a clock step, and it cannot remove host scheduling noise. '
        'See the ' + link('declaration', ROOT / 'PROTOCOL-monotonic.md', destination) + ' and '
        + link('runtime and clock proof', ROOT / 'wrk-monotonic/runtime-proof.json', destination) + '.']
    reproduction = read(ROOT / 'candidates/selected-reproduction/comparison.json')
    chunks.append('A full normal build of the exact selected 19-file source succeeded with fresh legacy SQLite and '
        'application feedback. Source bytes and generated C match. The rebuild is not bit-identical: selected binary `'
        + reproduction['selected_binary_sha256'] + '`, reproduced binary `' + reproduction['reproduction_binary_sha256']
        + '`; size difference ' + str(reproduction['binary_size_difference_bytes']) + ' bytes. Fresh execution counters '
        'differ beyond the compilation stamp. The reproduction is retained **unmeasured** and never replaces the frozen '
        'holdout binary. See ' + link('source reproduction comparison', ROOT / 'candidates/selected-reproduction/comparison.json', destination) + '.')
    chunks.append('Raw records, every exclusion and error, all exploratory sources/builds and prior reports remain preserved. '
                  'Only this selected holdout determines the target outcome.')
    return '\n\n'.join(chunks) + '\n'


def main():
    context = load_completed()
    outputs = {BATCH / 'RESULT.md': render(context, BATCH / 'RESULT.md'),
               ROOT / 'README.md': render(context, ROOT / 'README.md', index=True)}
    for path, content in outputs.items():
        temporary = path.with_name(path.name + '.partial')
        temporary.write_text(content)
        temporary.replace(path)
    print('\n'.join(str(path) for path in outputs))


if __name__ == '__main__':
    main()
