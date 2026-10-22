"""Render completed HMAC-only holdout evidence; never run a workload.

Invoke only after final JSON, completion marker and aggregate audit are frozen:
    python3 results/goose-2026-10-22/lead5/render_next_report.py
Only holdout-hmac/RESULT.md and lead5/README.md are written.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import statistics

ROOT = Path(__file__).resolve().parent
BATCH = ROOT / 'holdout-hmac'
FIRST = ROOT / 'holdout-selected'
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


def link(label, path, destination):
    return f'[{label}](<{Path(os.path.relpath(path, destination.parent)).as_posix()}>)'


def table(headers, rows):
    def cell(value):
        return str(value).replace('|', '\\|').replace('\n', ' ')
    result = ['| ' + ' | '.join(map(cell, headers)) + ' |',
              '| ' + ' | '.join('---' for _ in headers) + ' |']
    result += ['| ' + ' | '.join(map(cell, row)) + ' |' for row in rows]
    return '\n'.join(result)


def socket_errors(row):
    value = row.get('socket_errors', {})
    return sum(value.values()) if isinstance(value, dict) else value or 0


def median(values):
    values = [value for value in values if finite(value)]
    return statistics.median(values) if values else None


def load_completed():
    summary = read(BATCH / 'finalholdout-summary.json')
    marker = read(BATCH / 'holdout-complete.json')
    audit = read(BATCH / 'independent-audit.json')
    raw = read(BATCH / 'measurements.json')
    if marker.get('complete') is not True:
        raise ValueError('Holdout is unfinished; no report was written')
    if marker.get('attempt_count') != len(raw) or summary.get('all_attempts') != len(raw):
        raise ValueError('Completion marker, primary summary and raw attempt counts differ')
    if marker.get('selected_rounds') != summary.get('selected_rounds'):
        raise ValueError('Completion marker selected rounds differ from the final summary')
    raw_sha, summary_sha = sha(BATCH / 'measurements.json'), sha(BATCH / 'finalholdout-summary.json')
    if marker.get('measurements_sha256') != raw_sha or marker.get('summary_sha256') != summary_sha:
        raise ValueError('Completion marker does not bind current raw measurements and final summary')
    if audit.get('complete') is not True or audit.get('measurement_count') != len(raw):
        raise ValueError('Aggregate independent audit is unfinished or describes different attempts')
    if audit.get('measurements_sha256') != raw_sha or audit.get('primary_summary', {}).get('sha256') != summary_sha:
        raise ValueError('Independent audit does not bind the current raw measurements and displayed summary')
    manifest = {str(row['id']): row for row in read(BATCH / 'manifest.json')}
    if len(manifest) != 3 or not {'goose', '82'} <= set(manifest):
        raise ValueError('Expected candidate, unchanged Rust and exactly one explicit Goose control')
    control = next(case for case in manifest if case not in ('goose', '82'))
    names = {'goose': 'HMAC-only Goose', '82': 'Rust PR 82',
             control: 'Goose control: ' + manifest[control]['source_sha256'][:12]}
    builds = read(BATCH / 'build-status.json')
    selection_record = read(BATCH / 'selection.json')
    budget_path = ROOT / selection_record['resource_budget_build_proof']
    if sha(budget_path) != selection_record['resource_budget_build_proof_sha256']:
        raise ValueError('Selection does not bind the displayed normal-build resource proof')
    budget = read(budget_path)
    budget_ok = (budget.get('exit_code') == 0 and budget.get('build_uid') == 1001
                 and budget.get('normal_build') is True and budget.get('sqlite_object_reuse') is False
                 and budget.get('limits', {}).get('cpu.max') == '100000 100000'
                 and budget.get('limits', {}).get('memory.max') == '2147483648'
                 and budget.get('limits', {}).get('memory.swap.max') == '0'
                 and budget.get('memory_peak_bytes', math.inf) < 2147483648
                 and budget.get('bin/server', {}).get('sha256') == builds['goose']['proof']['binary_sha256'])
    gates = summary.get('gates', {})
    passed = (summary.get('passed_all') is True
              and all(gates.get(key) is True for key in REQUIRED_GATES)
              and all(value is True for value in gates.values())
              and audit.get('audit_passed') is True and audit.get('target_passed') is True and budget_ok)
    return dict(summary=summary, marker=marker, audit=audit, raw=raw, manifest=manifest,
                builds=builds, control=control, names=names, budget=budget, budget_path=budget_path, budget_ok=budget_ok,
                cases=('82', 'goose', control), passed=passed,
                environment=read(BATCH / 'environment-bench.json'), selection=selection_record)


def headline(context):
    s = context['summary']
    wins = sum(pair.get('candidate_rust_ratio', 0) > 1.05 for pair in s.get('paired_rounds', []))
    return (f"**Predeclared stable ≥5% target: {'MET' if context['passed'] else 'UNMET'}.** "
            f"Paired Goose/Rust geometric mean: **{ratio(s.get('geometric_mean_ratio'))}**; "
            f"one-sided 95% lower bound: **{ratio(s.get('one_sided_95_percent_lower_ratio'))}**; "
            f"pairs above 5%: **{wins}/{len(s.get('paired_rounds', []))}**.")


def first_holdout(destination):
    old = read(FIRST / 'finalholdout-summary.json')
    wins = sum(pair.get('candidate_rust_ratio', 0) > 1.05 for pair in old.get('paired_rounds', []))
    return ('The first independent ten-round holdout **failed** the stable 5% target: '
            + ratio(old.get('geometric_mean_ratio')) + ' paired geometric mean, '
            + ratio(old.get('one_sided_95_percent_lower_ratio')) + f' lower bound and {wins}/10 pairs above 5%. '
            + 'Its ' + link('report', FIRST / 'RESULT.md', destination) + ', '
            + link('raw measurements', FIRST / 'measurements.json', destination) + ' and '
            + link('audit', FIRST / 'independent-audit.json', destination)
            + ' remain preserved. Those measurements are not pooled with this new holdout.')


def selection(destination, context):
    record = context['selection']
    path = ROOT / record['selection_diagnostic']
    if record.get('diagnostic_scope') != 'selection only; sequential one-server budget':
        raise ValueError('Expected the declared sequential single-server selection scope')
    if sha(path) != record.get('selection_diagnostic_sha256'):
        raise ValueError('Selection diagnostic hash differs from its frozen declaration')
    data = read(path)
    if not isinstance(data, list) or len(data) != 6:
        raise ValueError('Sequential selection must retain exactly six server attempts')
    records = []
    for trial in (1, 2):
        group = [row for row in data if row.get('trial') == trial]
        if sorted(row.get('case_id') for row in group) != ['82', 'goose', 'previous']:
            raise ValueError('Sequential selection contains an incomplete or duplicate triplet')
        rates = {row['case_id']: row['successful_rps'] for row in group}
        records.append([trial, number(rates['goose']), number(rates['82']), number(rates['previous']),
                        ratio(rates['goose'] / rates['82']), ratio(rates['goose'] / rates['previous']),
                        sum(row.get('http_errors', 0) + socket_errors(row) for row in group)])
    return ('The normal-build binary was selected using exactly two sequential 15-second matched triplets '
            '(six server attempts), with only one server instance running at a time. There was no new A/A or shared-server diagnostic. '
            'These samples are selection evidence only and are excluded from confirmation statistics.\n\n'
            + table(['Trial', 'New Goose req/s', 'Rust req/s', 'Previous09 Goose req/s', 'New / Rust', 'New / previous09', 'HTTP/socket errors'], records)
            + '\n\n' + link('Complete sequential selection records', path, destination)
            + '. The fused-feed/HMAC candidate was rejected after both side-swapped comparisons were slower than source 09e695; '
            + link('its six diagnostic pairs', ROOT / 'paired-diagnostic-feed-hmac/summary.json', destination)
            + ' and ' + link('HMAC-only declaration', ROOT / 'PROTOCOL-hmac-only.md', destination)
            + ' preserve that decision. The rejected fused feed is not installed. Earlier discovery also remains available: '
            + ', '.join(link(name, ROOT / name / 'summary.json', destination)
                        for name in ('paired-diagnostic-first', 'paired-diagnostic-second', 'paired-diagnostic-final-selection'))
            + '; ' + link('cache grid', ROOT / 'cache-grid/measurements.json', destination)
            + ' and ' + link('isolated screen', ROOT / 'isolated-screen/measurements.json', destination)
            + '. All 32 earlier sequential attempts and 18 earlier shared pairs remain selection-only evidence; '
            + link('the first index', ROOT / 'README-first-holdout.md', destination) + ' retains their comparison matrix.')


def render_result(context, destination):
    s, raw, names = context['summary'], context['raw'], context['names']
    chosen = set(s.get('selected_rounds', []))
    gates = s.get('gates', {})
    wins = sum(pair.get('candidate_rust_ratio', 0) > 1.05 for pair in s.get('paired_rounds', []))
    p99 = s.get('median_p99_ms', {})
    failed = [key for key in REQUIRED_GATES if gates.get(key) is not True]
    if context['audit'].get('audit_passed') is not True:
        failed.append('independent evidence audit')
    if context['audit'].get('target_passed') is not True:
        failed.append('independent target audit')
    if not context['budget_ok']:
        failed.append('normal source build resource budget')
    chunks = ['# Goose HMAC-only follow-up', headline(context)]
    if failed:
        chunks.append('Failed gates: ' + ', '.join(key.replace('_', ' ') for key in failed) + '.')
    chunks += ['The target requires all primary and independent audit gates. A positive point estimate alone is insufficient. '
               + link('Final summary', BATCH / 'finalholdout-summary.json', destination) + '; '
               + link('independent audit', BATCH / 'independent-audit.json', destination) + '; '
               + link('selection and declaration', BATCH / 'selection.json', destination) + '.',
               first_holdout(destination)]
    errors = s.get('all_attempt_error_totals', {})
    candidate_errors = sum(errors.get('goose', {}).values())
    criteria = [
        ['Clean normal source build: one CPU, 2 GiB, no swap', 'Fresh SQLite and application PGO', status(context['budget_ok'])],
        ['Identity/correctness/database/resource evidence', 'All recorded checks', status(gates.get('evidence_checks'))],
        ['Ten clean matched rounds', f'{len(chosen)}/10', status(gates.get('ten_clean_rounds'))],
        ['At most two invalid-round replacements', len(s.get('excluded_rounds', [])), status(gates.get('replacement_limit'))],
        ['No candidate errors in any attempt, including warmup', candidate_errors, status(gates.get('zero_candidate_errors_in_all_attempts'))],
        ['Every candidate attempt valid', str(s.get('candidate_invalid_attempt_trials', [])), status(gates.get('candidate_valid_in_all_attempts'))],
        ['Geometric mean ≥1.05', ratio(s.get('geometric_mean_ratio')), status(gates.get('geometric_mean_at_least_5_percent'))],
        ['One-sided 95% Student-t lower bound ≥1.05', ratio(s.get('one_sided_95_percent_lower_ratio')), status(gates.get('one_sided_95_percent_lower_bound_at_least_5_percent'))],
        ['At least nine of ten pairs above 5%', f'{wins}/{len(chosen)}', status(gates.get('nine_of_ten_pairs_at_least_5_percent'))],
        ['Median p99 ≤1.05× Rust', f"Goose {number(p99.get('goose'))} ms; Rust {number(p99.get('82'))} ms", status(gates.get('median_p99_within_5_percent_of_rust'))],
    ]
    chunks += ['## Confirmation', table(['Requirement', 'Observed', 'Gate'], criteria),
               f"All {len(raw)} attempts in {len(s.get('attempted_rounds', []))} rounds are retained. "
               'Invalid rounds are excluded for all three implementations; low throughput alone is never an exclusion. '
               'The success test uses the first ten clean paired log ratios and a one-sided 95% Student-t bound with nine degrees of freedom.']
    if s.get('excluded_rounds'):
        chunks.append('Whole-round exclusions: ' + json.dumps(s['excluded_rounds'], sort_keys=True) + '.')
    if s.get('protocol_issues'):
        chunks.append('Protocol/evidence issues: ' + '; '.join(map(str, s['protocol_issues'])) + '.')
    grouped = {}
    for row in raw:
        grouped.setdefault(row['trial'], {})[row['case_id']] = row
    round_rows = []
    for trial, group in sorted(grouped.items()):
        values = {case: group.get(case, {}).get('successful_rps') for case in context['cases']}
        relative = values['goose'] / values['82'] if finite(values['goose']) and finite(values['82']) and values['82'] > 0 else None
        round_rows.append([trial, 'yes' if trial in chosen else 'no', *(number(values[case]) for case in context['cases']), ratio(relative)])
    chunks.append(table(['Round', 'Selected', 'Rust req/s', 'New Goose req/s', names[context['control']] + ' req/s', 'New / Rust'], round_rows))
    medians = []
    for case in context['cases']:
        rows = [row for row in raw if row['case_id'] == case and row['trial'] in chosen]
        medians.append([names[case], *(number(median([row.get(field) for row in rows]))
                                      for field in ('successful_rps', 'p95_ms', 'p99_ms', 'rss_mib', 'cpu_percent'))])
    chunks.append(table(['Selected-round medians', 'Req/s', 'p95 ms', 'p99 ms', 'RSS MiB', 'CPU %'], medians))
    info = {(row['trial'], row['case_id']): row for row in s.get('attempts', [])}
    attempts = []
    for row in raw:
        trial, case = row['trial'], row['case_id']
        warmup = info.get((trial, case), {}).get('warmup', {})
        attempts.append([trial, names.get(case, case), 'yes' if trial in chosen else 'no', number(row.get('successful_rps')),
                         number(row.get('duration_s')), number(row.get('p99_ms')),
                         f"{row.get('http_errors', 'n/a')}/{socket_errors(row)}",
                         f"{warmup.get('http_errors', 'n/a')}/{socket_errors(warmup)}",
                         link('raw', BATCH / 'logs' / f'bench-{case}-{trial}.log', destination)])
    chunks += ['## Every attempt', table(['Round', 'Case', 'Used', 'Req/s', 'Seconds', 'p99 ms', 'HTTP/socket', 'Warmup HTTP/socket', 'Output'], attempts),
               table(['All attempted runs', 'HTTP', 'Socket', 'Warmup HTTP', 'Warmup socket'],
                     [[names.get(case, case), *(values.get(key, 0) for key in ('http_errors', 'socket_errors', 'warmup_http_errors', 'warmup_socket_errors'))]
                      for case, values in errors.items()]),
               link('Raw measurements and all percentiles', BATCH / 'measurements.json', destination) + '; '
               + link('server logs', BATCH / 'server-logs', destination) + '.']
    identities = []
    for case in context['cases']:
        manifest, build = context['manifest'][case], context['builds'][case]
        proof = build.get('proof', {})
        identities.append([names[case], manifest['source_sha256'], build['image_id'], proof.get('binary_sha256')])
    proof = context['builds']['goose']['proof']
    chunks += ['## The server change',
               'HMAC/SHA256 uses owned keyed EVP_MAC state, reinitialized for each token; '
               'changed secrets replace state transactionally and crypto errors fail closed. Every token still receives a fresh signature computation. '
               'There is no token, response or query-result cache. The original three-query feed and its sparse fallback remain unchanged; '
               'Goose retains routing, validation, SQL and response structure.',
               'This change builds on source `09e695a0652cc4654e12d5382b423adf75b7ea7c5ef18978313ddff3cc9d13ed`: '
               'legacy SQLite PGO, four-unit application PGO/LTO, response-header/time batching, 8 MiB SQLite cache with mmap disabled, '
               'and bounded likes scanning. Commit-before-response behavior and durability settings remain.',
               table(['Implementation', 'Source SHA-256', 'Image SHA-256', 'Binary SHA-256'], identities),
               f"The frozen candidate contains {proof.get('source_files_verified', 'the recorded number of')} source files. Compiler: {proof.get('compiler')}; "
               f"{proof.get('goose_runtime')}. Rust Git commit: `{context['manifest']['82']['commit']}`. "
               + link('Build/source/binary proofs', BATCH / 'build-status.json', destination) + '; '
               + link('normal-build candidate image proof', ROOT / 'candidates/hmac-budget/image-proof.json', destination) + '. '
               'The measured candidate is a clean normal-user source build with fresh legacy SQLite PGO and fresh four-unit application PGO, '
               'using independent synthetic fixtures and no object reuse. The earlier unmeasured rebuild applies only to source 09e695 and is '
               + link('recorded separately', ROOT / 'candidates/selected-reproduction/comparison.json', destination) + '.']
    budget = context['budget']
    chunks.append(f"The normal build succeeded as UID {budget.get('build_uid')} in {number(budget.get('elapsed_seconds'), 3)} seconds. "
                  f"Recorded cgroup peak memory: {budget.get('memory_peak_bytes'):,} bytes "
                  f"({number(budget.get('memory_peak_bytes') / 1048576)} MiB). "
                  f"Limits: cpu.max=`{budget.get('limits', {}).get('cpu.max')}`, "
                  f"memory.max=`{budget.get('limits', {}).get('memory.max')}`, "
                  f"memory.swap.max=`{budget.get('limits', {}).get('memory.swap.max')}`. "
                  + link('Complete resource/build proof', context['budget_path'], destination) + '. '
                  'The initial attempt failed on stale root-owned generated artifacts; '
                  + link('that failure remains archived', ROOT / 'candidates/hmac-only/resource-budget-build-first-failure.json', destination) + '.')
    verification = read(BATCH / 'verification.json')
    check_rows = [[names[case], str(next((row.get('passed') for row in verification if row.get('case_id') == case), 'missing')) + '/42',
                   status(any(row.get('case_id') == case and row.get('passed_all') is True for row in verification))] for case in context['cases']]
    for filename, label, count in [('parser-checks.json', 'Parser', 18), ('edge-checks.json', 'Edge cases', 25), ('above-max-checks.json', 'Likes above maximum', 9)]:
        data = read(BATCH / filename)
        check_rows.append([label, f"{data.get('passed')}/{count}", status(data.get('passed_all'))])
    crypto = read(ROOT / 'candidates/feed-hmac/hmac-tests/results.json')
    chunks += ['## Correctness', table(['Evidence', 'Checks', 'Result'], check_rows),
               'Official checks are accompanied by dynamic create/read/like/feed semantic and committed SQLite integrity checks. '
               + link('Verification records', BATCH / 'verification.json', destination) + '. '
               + f"The crypto adapter passed {crypto.get('passed')}/139 differential and injected-failure checks against the frozen one-shot implementation and Python HMAC; "
               '10,000 valid and 10,000 invalid-signature calls passed ASAN/UBSAN/leak checks, including key changes and actual exit cleanup. '
               + link('Crypto results/proof', ROOT / 'candidates/feed-hmac/hmac-tests/proof.json', destination) + '; '
               + link('sanitizer log', ROOT / 'candidates/feed-hmac/hmac-tests/sanitizer.log', destination) + '. '
               'The unchanged transport retains its 2,320 byte-for-byte header comparisons and socket/clock sanitizer regressions in '
               + link('transport evidence', ROOT / 'transport/results.json', destination) + '.',
               '## Selection and measurement scope', selection(destination, context)]
    environment = context['environment']
    chunks.append('The comparison uses unchanged Rust and the explicitly pinned Goose control, identical fixtures and mixed workload, '
                  'two-second warmups and 45-second measurements. Servers use guest CPU 0, one CPU quota and 2 GiB RAM; '
                  'swap is disabled and only one server instance runs at a time. The external load generator uses CPUs 1–2, two threads and 64 connections. '
                  'Host: ' + str(environment.get('host_cpu', 'recorded Apple ARM64 Mac'))
                  + ', kept as-is with unrelated activity. All cases use the same declared monotonic-clock wrk driver; '
                  + link('driver declaration', ROOT / 'PROTOCOL-monotonic.md', destination) + ' and '
                  + link('runtime/clock proof', ROOT / 'wrk-monotonic/runtime-proof.json', destination) + '. '
                  'The clock correction preserves genuine timeout accounting; event-loop scheduling still uses wall time and host scheduling noise remains. '
                  'This is a complete-implementation comparison in native Linux ARM64 Docker on a local Mac, not an isolated language effect or official x86-64 k6 capacity result.')
    chunks.append('The first holdout already enforced one-CPU/2-GiB/no-swap limits on every confirmation server; its actual configurations remain in '
                  + link('all thirty original attempts', FIRST / 'measurements.json', destination) + '. '
                  'Earlier compilation and functional checks used extra CPUs. From the '
                  + link('resource-budget declaration', ROOT / 'PROTOCOL-resource-budget.md', destination)
                  + ' onward, server builds and functional checks also use one CPU, 2 GiB and no swap; '
                  'the clock monitor is stopped and shared-server diagnostics are discontinued. '
                  'The load generator remains outside the server budget, as official k6 runs on a separate machine; on this Mac it still shares the Docker host.')
    return '\n\n'.join(chunks) + '\n'


def render_index(context, destination):
    return '\n\n'.join([
        '# Goose server: HMAC-only follow-up', headline(context),
        'The runtime change reuses keyed HMAC state while preserving the original feed, fresh signature checks and commit-before-response behavior.',
        'The measured binary comes from a clean normal-user source build with fresh SQLite/application PGO under one CPU, 2 GiB and no swap. '
        'Only one server instance runs at a time; the load generator is external to its budget. '
        + link('Resource/build proof', context['budget_path'], destination) + '.',
        link('Latest complete report: every round, error and frozen identity', BATCH / 'RESULT.md', destination) + '; '
        + link('raw attempts', BATCH / 'measurements.json', destination) + '; '
        + link('independent audit', BATCH / 'independent-audit.json', destination) + '.',
        first_holdout(destination),
        'All earlier discovery results remain in ' + link('the first holdout index', ROOT / 'README-first-holdout.md', destination)
        + ' and ' + link('earlier experiment reports', ROOT.parent, destination) + '. Rejected SQL-inclusive LTO and trainer-v2 candidates remain unshipped.',
        'Scope: local Apple M2 Pro, native Linux ARM64 Docker, unchanged occupied host and the common declared monotonic wrk driver. '
        'These results compare complete implementations and do not establish official x86-64 k6 capacity.',
    ]) + '\n'


def main():
    context = load_completed()
    outputs = {BATCH / 'RESULT.md': render_result(context, BATCH / 'RESULT.md'),
               ROOT / 'README.md': render_index(context, ROOT / 'README.md')}
    for path, content in outputs.items():
        temporary = path.with_name(path.name + '.partial')
        temporary.write_text(content)
        temporary.replace(path)
    print('\n'.join(map(str, outputs)))


if __name__ == '__main__':
    main()
