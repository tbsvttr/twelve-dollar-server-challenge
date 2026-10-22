#!/usr/bin/env python3
"""Render one current Goose entry while retaining every previous raw record.

This is a presentation over the unchanged 127-row historical snapshot plus two
fully normalized/classified recheck rows. It runs no benchmark and changes no
classification or measurement. The previous renderers remain reproducible.
"""
import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import urlparse

import render
from conditions import classify
from render_markdown import number, safe


HERE = Path(__file__).resolve().parent
ARCHIVE_REF = 'bb2f2def4f6c2e2ef2eb1262f406a754b5757844'
RECHECK_BATCH = 'recheck-3x15-2026-10-22'
SUPERSEDED = {'current:143', 'confirmation:goose', 'confirmation:baseline'}
BATCHES = {
    'current-2026-10-20': '20 Oct',
    'fixes-2026-10-22': '22 Oct · fixes',
    'ranking-3x15-2026-10-22': '22 Oct · earlier control',
    'goose-hmac-2026-10-22-10x45s-monotonic': '22 Oct · confirmation',
    RECHECK_BATCH: '22 Oct · recheck',
}
CONDITIONS = {'PASS': '✓ PASS', 'FAIL': '✗ FAIL',
              'UNVERIFIED': '? UNVERIFIED', 'DIFFERENT_PROTOCOL': '↔ OTHER PROTOCOL'}
STATUS = {
    'measured': 'measured', 'measured_with_errors': 'errors',
    'ineligible_reference': 'non-SQLite', 'unsupported_architecture': 'ARM64 unsupported',
    'runtime_failed': 'startup failed', 'source_missing_start': 'no start script',
    'database_check_failed': 'DB check failed', 'build_failed': 'build failed',
    'measured; target UNMET': 'target unmet', 'measured reference': 'measured reference',
}
ROLES = {'current': 'current', 'historical': 'previous',
         'control': 'control', 'confirmation': 'confirmation'}


def read(path):
    return json.loads(path.read_text())


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def is_goose(row):
    return (row.get('pr') == 143 or 'goose' in str(row.get('label', '')).lower()
            or row.get('case_id') in ('goose', 'baseline'))


def validate_rows(history, additions):
    assert len(history) == len({row['row_id'] for row in history}) == 127
    assert len(additions) == len({row['row_id'] for row in additions}) == 2
    assert {row['row_id'] for row in history if is_goose(row)} == SUPERSEDED
    assert {row['role'] for row in additions} == {'current', 'control'}
    assert len([row for row in additions if is_goose(row)]) == 1
    for row in additions:
        assert row['measurement_batch'] == RECHECK_BATCH, row['row_id']
        assert row['protocol'] == render.STOCK, row['row_id']
        assert row['measurement_seconds'] == 15 and row['warmup_seconds'] == 2
        assert row['trials_recorded'] == 3, row['row_id']
        # Classification is evidence-derived by the shared classifier, never
        # upgraded by this view. A failed recheck must remain visibly failed.
        derived = classify(row)
        for field, value in derived.items():
            assert row.get(field) == value, (row['row_id'], field)
        if is_goose(row):
            assert row['role'] == 'current' and row['pr'] == 143
        else:
            assert str(row['case_id']) == '82' and row['role'] == 'control'
    all_rows = history + additions
    assert len({row['row_id'] for row in all_rows}) == 129
    visible = [row for row in history if row['row_id'] not in SUPERSEDED] + additions
    visible.sort(key=lambda row: (row.get('successful_rps') is None,
                                 -(row.get('successful_rps') or 0), row['row_id']))
    assert len(visible) == 126
    assert Counter(row['role'] for row in visible) == {
        'current': 120, 'historical': 2, 'control': 3, 'confirmation': 1}
    assert sum(is_goose(row) for row in visible) == 1
    return all_rows, visible


def write_csv(path, rows):
    with path.open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=render.FIELDS, extrasaction='ignore')
        writer.writeheader()
        for row in rows:
            flat = dict(row)
            for key in render.SOCKETS:
                flat['socket_' + key] = (row.get('socket_errors') or {}).get(key)
            writer.writerow({key: json.dumps(value, sort_keys=True)
                             if isinstance(value, (dict, list)) else value
                             for key, value in flat.items() if key in render.FIELDS})


def evidence_url(path, base):
    if not path:
        return base + '/2026-10-22/report.md'
    if urlparse(path).scheme in ('http', 'https'):
        return path
    # Evidence paths are relative to benchmarks/2026-10-22 in all normalized
    # source records. Resolve without requiring that publication files exist.
    root = Path('/benchmarks')
    relative = (root / '2026-10-22' / path).resolve().relative_to(root)
    return base + '/' + relative.as_posix()


def markdown_table(rows, base):
    lines = ['| PR / implementation / pinned source | Local conditions | Role / status | Batch / protocol | Req/s · min–max | p95 / p99 ms | RSS MiB / CPU % | Errors HTTP; C/R/W/T | App / Own LOC | Evidence |',
             '|---|---|---|---|---:|---:|---:|---|---:|---|']
    refs = {}
    for row in rows:
        pr = f"#{row['pr']} " if row.get('pr') is not None else 'local '
        source_url = row.get('source_url') or row.get('pr_url')
        label = pr + f"[{safe(row['label'])}]({source_url})"
        kind = ROLES[row['role']] + '<br>' + STATUS.get(row['status'], row['status'])
        condition = '**' + CONDITIONS[row['requirements_status']] + '**'
        if row['requirements_status'] != 'PASS':
            condition += '<br>' + safe(row['requirements_reason'])
        protocol = 'mono 10×45s' if row['protocol'] == render.MONOTONIC else 'stock 3×15s'
        batch = BATCHES[row['measurement_batch']] + '<br>' + protocol
        rps = number(row.get('successful_rps'))
        if row.get('successful_rps') is not None:
            rps += '<br>' + number(row.get('rps_min')) + '–' + number(row.get('rps_max'))
        latency = number(row.get('p95_ms'), 3) + ' / ' + number(row.get('p99_ms'), 3)
        resource = number(row.get('rss_mib'), 2) + ' / ' + number(row.get('cpu_percent'), 1)
        sockets = row.get('socket_errors')
        errors = number(row.get('http_errors')) + '; ' + (
            '/'.join(str(sockets[key]) for key in render.SOCKETS) if sockets else '—')
        loc = number(row.get('app_loc')) + ' / ' + number(row.get('own_loc'))
        url = evidence_url(row.get('evidence_url'), base)
        ref = 'raw' + hashlib.sha256(url.encode()).hexdigest()[:12]
        assert refs.get(ref, url) == url
        refs[ref] = url
        evidence = ('[raw]' if row.get('successful_rps') is not None else '[details]') + f'[{ref}]'
        evidence += f"<!-- row:{row['row_id']} -->"
        lines.append('| ' + ' | '.join([label, condition, kind, batch, rps,
                                      latency, resource, errors, loc, evidence]) + ' |')
    definitions = '\n'.join(f'[{key}]: {value}' for key, value in refs.items())
    return '\n'.join(lines) + '\n\n' + definitions + '\n'


def scope_markdown():
    return ("**Local conditions:** **✓ PASS** requires SQLite with committed data, 42/42 API and dynamic/database checks, "
            "three stock-wrk 15s runs with 2s warmups and zero measured HTTP/socket errors, and one server CPU / 2 GiB / no swap. "
            "**✗ FAIL** names an observed failure; **? UNVERIFIED** means insufficient applicable evidence; "
            "**↔ OTHER PROTOCOL** identifies a corrected-driver 10×45s reference. Throughput order does not qualify "
            "a failed or different-protocol row.\n\n"
            "**Original challenge conditions are not reproduced here:** these are ARM64 Docker/wrk runs with CPU affinity, "
            "rather than the official x86-64 droplet/k6 runs without affinity. PASS confirms the documented local runtime "
            "checks only; full challenge-rule compliance and the source-build resource budget are not uniformly verified.\n\n")


def render_markdown(rows, base, archive):
    intro = ("**All-submission comparison — one table, updated October 22, 2026.**\n\n"
             f"[Full report]({base}/2026-10-22/report.md) · [CSV]({base}/2026-10-22/comparison.csv) · "
             f"[Filterable HTML]({base}/2026-10-22/comparison.html) · "
             f"[Visible row data]({base}/2026-10-22/visible-rows.json) · "
             f"[All retained records]({base}/2026-10-22/comparison-rows.json)\n\n"
             "**One current Goose entry, using the complete new stock-wrk recheck.** The table has **126 rows**: "
             "120 current outcomes, two previous measured revisions, three separate short-run Rust controls and one "
             "longer Rust reference. All other implementations retain their previous measurements. The previous "
             f"Goose measurements remain in the [complete prior table]({archive}/2026-10-22/report.md) and "
             f"[retained raw records]({base}/2026-10-22/comparison-rows.json); they are superseded in this view. "
             "Rows are sorted by successful req/s; unmeasured outcomes follow.\n\n")
    notes = ("\n<details>\n<summary>Reading the table, validation and measurement notes</summary>\n\n"
             "Values are per-case medians; the second throughput line is the min–max range. p95/p99 are milliseconds. "
             "RSS is end-of-load service-process memory; CPU 100% means one server core. Error counters are totals "
             "over all measured runs: HTTP; socket connect/read/write/timeout. Stock-driver warmups are excluded "
             "from the measured totals and remain in the raw records. All three trials of the complete new batch "
             "are retained. The recheck uses the same stock-wrk three-by-15-second protocol, 2-second warmups, "
             "server source/image and one-CPU / 2-GiB / no-swap limits; it does not change the timeout threshold "
             "or substitute the corrected driver.\n\n"
             "Earlier results, including their errors, remain intact in the archived table and full row history. "
             "The canonical JSON contains the original 127 records plus the two new records; the CSV, HTML and "
             "visible-row JSON contain the 126 rows displayed here. This selects the complete new Goose batch "
             "as its current result; it does not pool runs or remove failed attempts from a batch.\n\n"
             "The separate 45-second paired confirmation had a +13.72% geometric mean, a +1.85% one-sided 95% "
             "lower bound and 8/10 pairs above 5%; the stable ≥5% target remains **UNMET**. The clean local "
             "runtime qualification and that comparative statistical target are separate claims. Local ARM64 "
             "throughput establishes no official x86-64 k6 maximum-user capacity.\n\n"
             f"[Original October 20 evidence]({base}/2026-10-20/report.md) · "
             f"[Fixed-target before/after history]({base}/2026-10-22/before-after.csv) · "
             f"[Long confirmation report]({base}/goose-2026-10-22/lead5/holdout-hmac/RESULT.md) · "
             f"[Previous complete table]({archive}/2026-10-22/report.md)\n\n</details>\n")
    return intro + scope_markdown() + markdown_table(rows, base) + notes


def render_html(rows, archive):
    page = render.html(rows)
    start = page.index('<p>127 rows:')
    end = page.index('<p><strong>PASS means', start)
    intro = ('<p>126 rows: 120 current outcomes, two previous measured revisions, three separate short-run Rust '
             'controls and one long Rust reference. There is one current Goose entry, from the complete new stock '
             '3×15-second recheck. Its prior measurements remain in the '
             f'<a href="{archive}/2026-10-22/report.md">complete previous table</a> and '
             '<a href="comparison-rows.json">all retained records</a>. All other implementation results remain '
             'visible. The stable ≥5% confirmation target remains <strong>UNMET</strong>.</p>\n')
    page = page[:start] + intro + page[end:]
    page = page.replace('<title>All measurements — one comparison table</title>',
                        '<title>Server comparison — one current entry per submission</title>')
    page = page.replace('<h1>All measurements — one comparison table</h1>',
                        '<h1>Server comparison — one current entry per submission</h1>')
    page = page.replace('<a href="comparison-rows.json">Canonical row data</a>',
                        '<a href="visible-rows.json">Visible row data</a> · '
                        '<a href="comparison-rows.json">All retained records</a>')
    page = page.replace("'ranking-3x15-2026-10-22':'22 Oct · Goose'",
                        "'ranking-3x15-2026-10-22':'22 Oct · earlier control',"
                        "'recheck-3x15-2026-10-22':'22 Oct · recheck'")
    return page


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history-rows', type=Path, default=HERE / 'rows.json')
    parser.add_argument('--history-report', type=Path, default=HERE / 'report.md')
    parser.add_argument('--recheck-rows', type=Path, default=HERE / 'recheck-rows.json')
    parser.add_argument('--output-dir', type=Path, default=HERE / 'current-view')
    parser.add_argument('--artifact-ref', default='benchmark-2026-10-22')
    parser.add_argument('--archive-ref', default=ARCHIVE_REF)
    args = parser.parse_args()
    assert re.fullmatch(r'[A-Za-z0-9._/-]+', args.artifact_ref)
    assert re.fullmatch(r'[0-9a-f]{40}', args.archive_ref)
    history, additions = read(args.history_rows), read(args.recheck_rows)
    all_rows, visible = validate_rows(history, additions)
    out = args.output_dir
    out.mkdir(parents=True, exist_ok=True)
    base_prefix = 'https://github.com/tbsvttr/twelve-dollar-server-challenge/blob/'
    base = base_prefix + args.artifact_ref + '/benchmarks'
    archive = base_prefix + args.archive_ref + '/benchmarks'
    write_json(out / 'comparison-rows.json', all_rows)
    write_json(out / 'visible-rows.json', visible)
    write_csv(out / 'comparison.csv', visible)
    (out / 'comparison.html').write_text(render_html(visible, archive))
    body = render_markdown(visible, base, archive)
    assert len(body) < 65536, len(body)
    (out / 'issue-comment.md').write_text(body)
    write_json(out / 'issue-comment.json', {'body': body})
    history_report = args.history_report.read_text()
    retained_marker = '\n<details>\n<summary>Retained methodology, setup and source provenance</summary>'
    retained_notes = history_report[history_report.index(retained_marker):]
    (out / 'report.md').write_text(body + retained_notes)
    index = ("# Server comparison — October 22, 2026\n\n"
             "[One comparison table](report.md) · [Filterable HTML](comparison.html) · [CSV](comparison.csv) · "
             "[Visible row JSON](visible-rows.json) · [All retained records](comparison-rows.json)\n\n"
             "The main table contains **126 rows**, including **one current Goose result** from the complete new "
             "stock-wrk recheck: 120 current outcomes, two previous measured revisions, three separate short-run "
             "Rust controls and one longer Rust reference. CSV, HTML and visible-row JSON contain the same view. "
             "The canonical row JSON preserves every original record and appends the two recheck records "
             "(129 total). All previous Goose measurements and error counters remain available in the "
             f"[previous complete table]({archive}/2026-10-22/report.md).\n\n"
             + scope_markdown()
             + "The recheck uses the unchanged three-by-15-second stock-wrk protocol with 2-second warmups and "
             "the same source/image, one server CPU, 2 GiB RAM and no swap. All six new trials (three per case) "
             "are retained. No prior run or error counter was changed. Full-precision statistics, source/image "
             "identities, local conditions and raw evidence links remain in the exports.\n\n"
             "The stable ≥5% Goose/Rust confirmation target remains **unmet**. Local runtime qualification does "
             "not establish that statistical claim or official x86-64 k6 user capacity.\n\n"
             "`summary.json` and `current-outcomes.csv` retain the previous 120-current-outcome inventory unchanged. "
             "Earlier audits describe their recorded historical snapshots. [Before/after history](before-after.csv), "
             "[original fixed-target trials](trials.csv) and [the October 20 report](../2026-10-20/report.md) "
             "remain unchanged.\n")
    (out / 'README.md').write_text(index)
    proof = {
        'canonical_rows': len(all_rows), 'visible_rows': len(visible),
        'visible_goose_rows': sum(is_goose(row) for row in visible),
        'visible_roles': dict(Counter(row['role'] for row in visible)),
        'visible_conditions': dict(Counter(row['requirements_status'] for row in visible)),
        'superseded_from_main_view_only': sorted(SUPERSEDED),
        'historical_rows_unchanged': all_rows[:len(history)] == history,
        'history_rows_sha256': sha(args.history_rows),
        'recheck_rows_sha256': sha(args.recheck_rows),
        'generator_sha256': sha(Path(__file__)),
        'archive_ref': args.archive_ref, 'artifact_ref': args.artifact_ref,
        'issue_comment_characters': len(body), 'new_benchmark_commands_run': 0,
        'outputs': {path.name: sha(path) for path in out.iterdir() if path.is_file()
                    and path.name != 'single-goose-view-proof.json'},
    }
    write_json(out / 'single-goose-view-proof.json', proof)
    print(json.dumps(proof, ensure_ascii=False))


if __name__ == '__main__':
    main()
