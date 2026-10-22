"""One shared measurement table for the issue and the full report."""
import argparse
import hashlib
import json
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
ROOT = Path('/private/tmp/twelve-goose-results-20261022/benchmarks')


def number(value, digits=0):
    return '—' if value is None else f'{value:,.{digits}f}'


def safe(text):
    return str(text).replace('|', '\\|').replace('\n', ' ').strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--artifact-ref', default='benchmark-2026-10-22')
    args = parser.parse_args()
    assert re.fullmatch(r'[A-Za-z0-9._/-]+', args.artifact_ref)
    base = f'https://github.com/tbsvttr/twelve-dollar-server-challenge/blob/{args.artifact_ref}/benchmarks'
    rows = json.loads((HERE / 'rows.json').read_text())
    original = json.loads(Path('/private/tmp/goose-unified-current-20261022.json').read_text())['body']
    assert len(rows) == 127 and len({r['row_id'] for r in rows}) == 127
    status_labels = {
        'measured': 'clean', 'measured_with_errors': 'errors',
        'ineligible_reference': 'non-SQLite', 'unsupported_architecture': 'ARM64 unsupported',
        'runtime_failed': 'startup failed', 'source_missing_start': 'no start script',
        'database_check_failed': 'DB check failed', 'build_failed': 'build failed',
        'measured; target UNMET': 'clean; target unmet', 'measured reference': 'clean reference',
    }
    role_labels = {'current': 'current', 'historical': 'previous',
                   'control': 'control', 'confirmation': 'confirmation'}
    batches = {
        'current-2026-10-20': '20 Oct',
        'fixes-2026-10-22': '22 Oct · fixes',
        'ranking-3x15-2026-10-22': '22 Oct · Goose',
        'goose-hmac-2026-10-22-10x45s-monotonic': '22 Oct · confirmation',
    }
    refs = {'details': base + '/2026-10-22/report.md'}
    lines = ['| Clean rank | PR / implementation / pinned source | Role / status | Batch / protocol | Req/s · min–max | p95 / p99 ms | RSS MiB / CPU % | Errors HTTP; C/R/W/T | App / Own LOC | Evidence |',
             '|---:|---|---|---|---:|---:|---:|---|---:|---|']
    for row in rows:
        assert row['measurement_batch'] in batches, row['measurement_batch']
        pr = f"#{row['pr']} " if row.get('pr') is not None else 'local '
        label = pr + f"[{safe(row['label'])}]({row['source_url']})"
        kind = role_labels[row['role']] + '<br>' + status_labels.get(row['status'], row['status'])
        protocol = 'mono 10×45s' if row['protocol'] == 'monotonic-wrk-10x45s' else 'stock 3×15s'
        batch = batches[row['measurement_batch']] + '<br>' + protocol
        rps = number(row.get('successful_rps'))
        if row.get('successful_rps') is not None:
            rps += '<br>' + number(row.get('rps_min')) + '–' + number(row.get('rps_max'))
        latency = number(row.get('p95_ms'), 3) + ' / ' + number(row.get('p99_ms'), 3)
        resource = number(row.get('rss_mib'), 2) + ' / ' + number(row.get('cpu_percent'), 1)
        sockets = row.get('socket_errors')
        errors = number(row.get('http_errors')) + '; ' + ('/'.join(str(sockets[k]) for k in ['connect', 'read', 'write', 'timeout']) if sockets else '—')
        loc = number(row.get('app_loc')) + ' / ' + number(row.get('own_loc'))
        if row.get('successful_rps') is None:
            evidence = '[details][details]'
        else:
            path = row['evidence_url']
            target = (ROOT / '2026-10-22' / path).resolve()
            relative = target.relative_to(ROOT.resolve())
            ref = 'raw' + str(list(batches).index(row['measurement_batch']))
            url = base + '/' + str(relative)
            assert refs.get(ref, url) == url
            refs[ref] = url
            evidence = f'[raw][{ref}]'
        evidence += f"<!-- row:{row['row_id']} -->"
        cells = [number(row.get('rank')), label, kind, batch, rps, latency, resource, errors, loc, evidence]
        lines.append('| ' + ' | '.join(cells) + ' |')
    table = '\n'.join(lines) + '\n'
    definitions = '\n'.join(f'[{name}]: {url}' for name, url in refs.items()) + '\n'
    intro = ("**All-submission comparison — one table, updated October 22, 2026.**\n\n"
             f"[Full report]({base}/2026-10-22/report.md) · [CSV]({base}/2026-10-22/comparison.csv) · "
             f"[Filterable HTML]({base}/2026-10-22/comparison.html) · [Exact row data]({base}/2026-10-22/comparison-rows.json)\n\n"
             "**120 current outcomes, all preserved, plus seven comparison rows:** two previous measured revisions, "
             "two short-run Rust controls and three longer confirmation measurements. All **127 rows** appear together, "
             "sorted by successful req/s; unmeasured outcomes follow.\n\n"
             "**Clean rank** retains the existing 98 eligible current ranks. A dash means unranked; the adjacent status "
             "shows errors, a rule exclusion, a previous revision or a reference measurement. **Stock 3×15s** uses "
             "the original driver; **mono 10×45s** uses the declared monotonic-clock correction. Their measurements "
             "remain separate. All servers use one CPU / 2 GiB RAM / no swap.\n\n")
    short_notes = ("\n<details>\n<summary>Reading the table, validation and measurement notes</summary>\n\n"
                   "Values are per-case medians; the second throughput line is the min–max range. p95/p99 are milliseconds; "
                   "RSS is end-of-load service-process memory, and CPU 100% means one server core. Error counters are totals "
                   "over measured runs: HTTP; socket connect/read/write/timeout. Warmups are excluded from stock-driver totals; "
                   "all three 45-second confirmation rows also had zero warmup errors. Full-precision values, check counts, "
                   "reasons, source/image identities and evidence links remain in CSV, row JSON and the report.\n\n"
                   "Current clean ranks require 42/42 official assertions, dynamic live-data checks, committed-write/SQLite "
                   "integrity checks, and zero measured HTTP/socket errors in all three trials. The Goose stock-driver row "
                   "retains its 38 reported timeouts; the new Rust control retains 34. No counters or historical scores were "
                   "discarded or rescaled. wrk timeout completions remain in throughput while outside its two-second latency "
                   "histogram; the raw records do not establish the cause of each timeout.\n\n"
                   "The separate 45-second Goose/Rust confirmation has a +13.72% paired geometric mean, +1.85% one-sided "
                   "95% lower bound and 8/10 pairs above 5%; the stable ≥5% target remains **UNMET**. It supplies reference "
                   "rows in this table and changes no clean rank. These local ARM64 saturation measurements establish "
                   "no official x86-64 k6 maximum-user capacity.\n\n"
                   f"[Original October 20 evidence]({base}/2026-10-20/report.md) · "
                   f"[Fixed-target before/after history]({base}/2026-10-22/before-after.csv) · "
                   f"[Long confirmation report]({base}/goose-2026-10-22/lead5/holdout-hmac/RESULT.md) · "
                   f"[Unified-table audit]({base}/2026-10-22/unified-audit.json)\n\n</details>\n")
    body = intro + table + '\n' + definitions + short_notes
    assert len(body) < 65536, len(body)
    (HERE / 'issue-comment.md').write_text(body)
    (HERE / 'issue-comment.json').write_text(json.dumps({'body': body}, indent=2) + '\n')

    # Retain the earlier detailed methodology and failures without a second table.
    original_lines = original.splitlines()
    retained = []
    starts = ['**October 22 update:', '**Common conditions.', '**Build and runtime adapters.',
              '**Validation and workload.', '**wrk timeout accounting.', '**Ranking.',
              '**October 22 evidence:', '**Diagnostic evidence.', '**Scope.']
    for line in original_lines:
        if any(line.startswith(marker) for marker in starts):
            retained.append(line)
    reasons = []
    failure_start = original.index('**Build, runtime and test outcomes without a valid three-trial result.**')
    failure_end = original.index('**Previous measured revisions', failure_start)
    failure_lines = original[failure_start:failure_end].splitlines()
    for row in rows:
        if row['role'] == 'current' and row.get('successful_rps') is None:
            checks = f"{row['tests_passed']}/42" if row.get('tests_passed') is not None else 'not run'
            matches = [line for line in failure_lines if line.startswith('| #') and f"[{row['label']}]" in line]
            assert len(matches) == 1, row['row_id']
            cells = [cell.strip() for cell in matches[0].strip('|').split('|')]
            assert len(cells) == 5, row['row_id']
            reasons.append(f"- #{row['pr']} **{safe(row['label'])}** — {row['status']}; checks {checks}. {cells[4].rstrip()}")
    excluded_start = original.index('**Excluded or superseded PRs.**')
    excluded_end = original.index('**Diagnostic evidence.**', excluded_start)
    excluded = []
    for line in original[excluded_start:excluded_end].splitlines():
        if line.startswith('| #'):
            cells = [c.strip() for c in line.strip('|').split('|')]
            assert len(cells) == 3
            excluded.append('- ' + cells[0] + ' — ' + cells[1] + '. ' + cells[2])
    full_notes = ('\n<details>\n<summary>Retained methodology, setup and source provenance</summary>\n\n'
                  'The notes below describe the original three-by-15-second batches. The table identifies the separate '
                  'ten-by-45-second monotonic-driver protocol explicitly; its complete declaration and all attempts remain linked above.\n\n'
                  + '\n\n'.join(retained) + '\n\n</details>\n\n'
                  '<details>\n<summary>Build/start/database failure reasons (the same 14 current rows above)</summary>\n\n'
                  + '\n'.join(reasons) + '\n\n</details>\n\n'
                  '<details>\n<summary>Excluded or superseded PRs</summary>\n\n'
                  + '\n'.join(excluded) + '\n\n</details>\n')
    (HERE / 'report.md').write_text(body + full_notes)
    index = ("# Server comparison — October 22, 2026\n\n"
             "[One combined table](report.md) · [Filterable HTML](comparison.html) · [CSV](comparison.csv) · "
             "[Exact row JSON](comparison-rows.json) · [Unified-table audit](unified-audit.json)\n\n"
             "The same **127 rows** appear in Markdown, HTML, CSV and row JSON, sorted by successful req/s: "
             "120 current outcomes plus two previous measured revisions, two short-run Rust controls and three longer "
             "confirmation measurements. Every earlier value, source identity and clean rank is preserved. "
             "`summary.json` retains the 120-current-outcome inventory; `current-outcomes.csv` retains its current-only export.\n\n"
             "Columns identify each row's role, status, batch and protocol. Stock-wrk 3×15-second trials and monotonic-wrk "
             "10×45-second confirmation stay distinct in the shared table. Only the existing 98 eligible current rows "
             "have a clean rank; errors, references, historical revisions and unmeasured outcomes remain visible alongside them.\n\n"
             "All measured servers use one CPU and 2 GiB RAM with no container swap. This presentation update runs no "
             "new benchmarks and changes no source code, measurement or ranking rule. Local ARM64 throughput does not "
             "determine official x86-64 k6 maximum-user capacity. The stable ≥5% Goose/Rust confirmation target remains unmet.\n\n"
             "[Original fixed-target audit](audit-final.json) and [previous 120-outcome integration audit](independent-audit.json) "
             "remain historical evidence. The unified-table audit checks this presentation against the same retained records. "
             "[Before/after history](before-after.csv), [original raw fixed-target trials](trials.csv) and "
             "[the October 20 report](../2026-10-20/report.md) remain available unchanged.\n")
    (HERE / 'README.md').write_text(index)
    proof = {'rows': len(rows), 'table_count_each_markdown': 1, 'issue_comment_characters': len(body),
             'source_rows_sha256': hashlib.sha256((HERE / 'rows.json').read_bytes()).hexdigest(),
             'artifact_ref': args.artifact_ref}
    (HERE / 'markdown-proof.json').write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps(proof))


if __name__ == '__main__':
    main()
