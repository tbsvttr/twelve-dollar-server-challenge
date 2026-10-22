"""Present one current result per implementation; preserve the full archive."""
import argparse
from collections import defaultdict
import csv
import hashlib
import json
from pathlib import Path
import shutil
from urllib.parse import urlparse

import render
import single_goose_view as shared

HERE = Path(__file__).resolve().parent
ARCHIVE = 'a1c066b40856f021072747b26efda566039e00a6'
ORDER = {key: i for i, key in enumerate(shared.BATCHES)}
DERIVED = ['implementation_key', 'display_role', 'selection_reason', 'superseded_prs']


def key(row):
    parts = urlparse(row['source_url']).path.strip('/').split('/')
    assert parts[2] == 'tree' and parts[4] == 'submissions', row['source_url']
    return '/'.join(parts[:2] + parts[4:]).lower()


def select(all_rows, previous_view):
    groups = defaultdict(list)
    for row in previous_view:
        if row['role'] == 'current':
            groups[key(row)].append(row)
    assert len(groups) == 118
    visible = []
    for identity, revisions in groups.items():
        # An unchanged inherited folder stays attributed to its original PR.
        # Changed source revisions use the newest submitted implementation.
        if len({r['source_sha256'] for r in revisions}) == 1:
            primary = min(revisions, key=lambda r: r['pr'])
        else:
            primary = max(revisions, key=lambda r: r['pr'])
        matching = [r for r in all_rows if r.get('protocol') == render.STOCK and key(r) == identity
                    and all(r.get(k) == primary.get(k) for k in
                            ('commit', 'source_sha256', 'image_id'))
                    and r.get('protocol') == render.STOCK
                    and r.get('measurement_seconds') == 15 and r.get('warmup_seconds') == 2
                    and r.get('trials_recorded') == 3
                    and r.get('status') in ('measured', 'measured_with_errors', 'ineligible_reference')]
        chosen = max(matching, key=lambda r: ORDER[r['measurement_batch']]) if matching else primary
        assert chosen['pr'] == primary['pr']
        row = dict(chosen)
        row.update(implementation_key=identity, display_role='current',
                   selection_reason=('Latest complete stock-protocol batch for the current pinned source.'
                                     if chosen['row_id'] != primary['row_id']
                                     else 'Current source revision; unchanged inherited folders use their original PR.'),
                   superseded_prs=sorted({r['pr'] for r in revisions if r['pr'] != primary['pr']}))
        visible.append(row)
    visible.sort(key=lambda r: (r.get('successful_rps') is None,
                               -(r.get('successful_rps') or 0), r['row_id']))
    assert len(visible) == len({key(r) for r in visible}) == 118
    assert len([r for r in visible if r['pr'] == 82]) == 1
    assert len([r for r in visible if r['pr'] == 143]) == 1
    return visible


def csv_file(path, rows):
    fields = render.FIELDS + DERIVED
    with path.open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction='ignore')
        writer.writeheader()
        for row in rows:
            flat = dict(row)
            for name in render.SOCKETS:
                flat['socket_' + name] = (row.get('socket_errors') or {}).get(name)
            writer.writerow({k: json.dumps(v, sort_keys=True) if isinstance(v, (dict, list)) else v
                             for k, v in flat.items() if k in fields})


def markdown(rows, base, archive):
    header = ('**All-submission comparison — one current result per implementation, updated October 22, 2026.**\n\n'
              f'[Full report]({base}/2026-10-22/report.md) · [CSV]({base}/2026-10-22/comparison.csv) · '
              f'[Filterable HTML]({base}/2026-10-22/comparison.html) · '
              f'[Visible rows]({base}/2026-10-22/visible-rows.json) · '
              f'[All 129 retained records]({base}/2026-10-22/comparison-rows.json)\n\n'
              '**118 implementations, each appearing once.** The table shows one current source revision and one complete '
              'stock-wrk batch per implementation. Separate controls, confirmations and previous revisions remain in '
              f'the [measurement archive]({archive}/2026-10-22/report.md). Latest complete batches are selected by date/protocol, '
              'without choosing the highest throughput. Rust #82 uses the same fresh recheck batch as Goose #143.\n\n')
    display_rows = [dict(r, role=r['display_role']) for r in rows]
    table = shared.markdown_table(display_rows, base)
    notes = ('\n<details>\n<summary>Selection, history and measurement notes</summary>\n\n'
             'One implementation means one repository owner and submission folder. The newer Rust revision #82 replaces '
             '#19 in this view. The unchanged c-iouring folder inherited by #121 is represented once under its original '
             '#112 submission; #121\'s distinct c-libco implementation remains present. Multi-implementation PRs retain '
             'one row for each distinct folder. The selected Rust #82 record was originally measured as a control; '
             'its origin remains in the raw data and CSV, while it now supplies the current comparison result.\n\n'
             'Every measurement, original role, source identity, error counter and condition label remains intact in '
             'the 129-record JSON archive. This presentation runs no new benchmark and changes no score or status. '
             'Values are medians of all three runs; the second throughput line is min–max. Errors total HTTP and '
             'socket connect/read/write/timeout counters. Both the current Goose and Rust rechecks have zero measured '
             'and warmup errors; API, dynamic-data and committed-SQLite checks passed.\n\n'
             'The separate longer corrected-driver experiment remains historical evidence; the stable ≥5% comparative '
             'target remains **UNMET**. Local ARM64 throughput establishes no official x86-64 k6 maximum-user capacity.\n\n'
             f'[Full prior presentation]({archive}/2026-10-22/report.md) · '
             f'[Recheck evidence audit]({base}/2026-10-22/recheck-audit.json) · '
             f'[Current-view audit]({base}/2026-10-22/current-only-audit.json)\n\n</details>\n')
    return header + shared.scope_markdown() + table + notes


def html(rows, archive):
    page = shared.render_html(rows, archive)
    start = page.index('<p>126 rows:')
    end = page.index('<p><strong>PASS means', start)
    page = (page[:start] + '<p><strong>118 implementations, one current result each.</strong> '
            'Each submission folder appears once, with its current source and latest complete stock-wrk batch. '
            'Repeated controls, confirmations and older revisions remain in the '
            f'<a href="{archive}/2026-10-22/report.md">measurement archive</a> and '
            '<a href="comparison-rows.json">all 129 retained records</a>. '
            'The selection uses source revisions and complete batches, without choosing the highest throughput. '
            'The stable ≥5% confirmation target remains <strong>UNMET</strong>.</p>\n' + page[end:])
    page = page.replace("['role','role']", "['role','display_role']")
    old = "plain(e,row.role+(row.confirmation_role?' · '+row.confirmation_role:''));"
    assert old in page
    page = page.replace(old, "plain(e,row.display_role);")
    return page


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, default=HERE / 'current-only-view')
    args = parser.parse_args()
    original = HERE / 'current-view/comparison-rows.json'
    all_rows = shared.read(original)
    assert len(all_rows) == 129
    previous = shared.read(HERE / 'current-view/visible-rows.json')
    rows = select(all_rows, previous)
    out = args.output_dir
    out.mkdir(exist_ok=True, parents=True)
    base = 'https://github.com/tbsvttr/twelve-dollar-server-challenge/blob/benchmark-2026-10-22/benchmarks'
    archive = base.replace('benchmark-2026-10-22', ARCHIVE)
    shutil.copy2(original, out / 'comparison-rows.json')
    shared.write_json(out / 'visible-rows.json', rows)
    csv_file(out / 'comparison.csv', rows)
    (out / 'comparison.html').write_text(html(rows, archive))
    body = markdown(rows, base, archive)
    assert len(body) < 65536
    (out / 'issue-comment.md').write_text(body)
    shared.write_json(out / 'issue-comment.json', {'body': body})
    history = (HERE / 'report.md').read_text()
    marker = '\n<details>\n<summary>Retained methodology, setup and source provenance</summary>'
    (out / 'report.md').write_text(body + history[history.index(marker):])
    (out / 'README.md').write_text(
        '# Current implementation comparison — October 22, 2026\n\n'
        '[One table](report.md) · [CSV](comparison.csv) · [HTML](comparison.html) · '
        '[Visible rows](visible-rows.json) · [All 129 records](comparison-rows.json)\n\n'
        '**118 implementations, each appearing once.** Current source revisions and latest complete stock-protocol '
        'batches determine this view. Rust #82 replaces its older #19 revision and uses the fresh recheck measured '
        'alongside Goose. The inherited unchanged c-iouring folder in #121 is represented by its original #112 '
        'submission; #121 c-libco remains separate. Older revisions and repeated controls/confirmations stay in '
        f'the [archive]({archive}/2026-10-22/report.md). No source, measurement, counter or condition label changed.\n\n'
        + shared.scope_markdown()
        + '[Current-view audit](current-only-audit.json) · [Recheck evidence audit](recheck-audit.json). '
        'Historical summary.json/current-outcomes.csv and earlier audits describe their original snapshots. '
        'The stable ≥5% target remains unmet.\n')
    shared.write_json(out / 'current-only-proof.json', {
        'visible_rows': len(rows), 'unique_implementations': len({key(r) for r in rows}),
        'all_records': len(all_rows), 'all_records_sha256': shared.sha(original),
        'old_records_unchanged': (out / 'comparison-rows.json').read_bytes() == original.read_bytes(),
        'goose_rows': sum(r['pr'] == 143 for r in rows),
        'rust82_rows': sum(r['pr'] == 82 for r in rows),
        'new_benchmarks': 0, 'generator_sha256': shared.sha(Path(__file__)),
        'outputs': {p.name: shared.sha(p) for p in sorted(out.iterdir()) if p.is_file()
                    and p.name != 'current-only-proof.json'}})
    print(json.dumps({'visible_rows': len(rows), 'unique_implementations': len({key(r) for r in rows}),
                      'all_129_records_unchanged': True, 'new_benchmarks': 0}))


if __name__ == '__main__':
    main()
