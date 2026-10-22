#!/usr/bin/env python3
"""Add PR143 to the frozen main list; write only this integration directory.

No server, Docker, network, source mutation, commit or publication is invoked.
The original 119 rows keep every field except their recomputed display rank.
"""
import argparse
import collections
import copy
import csv
import hashlib
import importlib.util
import json
from pathlib import Path
import re


HERE = Path(__file__).resolve().parent
GOOSE = HERE.parent
RESULTS = GOOSE.parent
FROZEN = RESULTS / 'fixes-2026-10-22'
DEFAULT_BATCH = GOOSE / 'ranking-3x15-2026-10-22'
DEFAULT_COMMENT = Path('/private/tmp/goose-list-current-20261022.json')
PUBLIC_GOOSE = '../goose-2026-10-22/ranking-3x15-2026-10-22/'
SOCKETS = ('connect', 'read', 'write', 'timeout')


def read(path):
    return json.loads(path.read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def new_row(helper, candidate, build, verification, measurements, shared, batch, role):
    row = helper.baseline_analyzer.summarize(
        candidate, build, helper.matching_source(verification, candidate),
        helper.matching_source(measurements, candidate), shared)
    if row['status'] not in ('measured', 'measured_with_errors'):
        raise ValueError(f"Cannot publish incomplete/invalid new case {row['case_id']}: {row['status']}: {row['reason']}")
    row.update(batch=batch.name, measurement_date='2026-10-22', role=role)
    for field in ('build_log', 'verification_log', 'runtime_setup', 'build_adapter'):
        value = row.get(field)
        row[field] = PUBLIC_GOOSE + value if value and (batch / value).is_file() else None
    paths = ['manifest.json', 'build-status.json', 'verification.json', 'measurements.json',
             'shared-sha256.json', 'environment-bench.json', 'environment-verify.json',
             'pr-documentation-image-proof.json']
    for trial in (1, 2, 3):
        paths += [f"logs/bench-{row['case_id']}-{trial}.log",
                  f"server-logs/bench-{row['case_id']}-{trial}.log"]
    paths += [f"logs/verify-{row['case_id']}-1.log", f"server-logs/verify-{row['case_id']}-1.log"]
    row['evidence'] = [PUBLIC_GOOSE + path for path in paths if (batch / path).is_file()]
    row['measurement_protocol'] = 'stock wrk 4.1.0; three 15-second runs; two-second warmups; 2 threads/64 connections'
    row['binary_sha256'] = build.get('proof', {}).get('binary_sha256')
    if row['case_id'] == '143':
        row['publication_source_note'] = ('The PR snapshot includes documentation and two result-metadata files. '
            'The 18 measured runtime/build/support files and production binary are byte-identical to the original HMAC-budget image; '
            'the retained pr-documentation-image-proof.json verifies this source-only publication overlay.')
    if role == 'control':
        row.update(rank=None, ranked=False)
    return row


def metric_cells(row):
    def number(value, digits=0):
        return '—' if value is None else f'{value:,.{digits}f}'
    return [number(row.get('successful_rps')),
            number(row.get('rps_min')) + '–' + number(row.get('rps_max')),
            number(row.get('p95_ms'), 3), number(row.get('p99_ms'), 3),
            number(row.get('rss_mib'), 2), number(row.get('cpu_percent'), 1),
            number(row.get('app_loc')) + ' / ' + number(row.get('own_loc'))]


def label(row):
    return f"#{row['pr']} [{row['folder']}]({row['source_url']})"


def comment_body(original, old, summary, addition, control, artifact_ref):
    """Preserve every old row's text except clean rank, plus the full addendum."""
    title = '**New Goose submission — separate October 22 local confirmation batch.**'
    position = original.find(title)
    if position < 0:
        raise ValueError('The current comment does not contain the preserved HMAC holdout addendum.')
    body, retained_addendum = original[:position], original[position:]
    start = body.index('**Combined clean ranking.**')
    end = body.index('**Measured diagnostic / reference results.**', start)
    section = body[start:end]
    current = {row['case_id']: row for row in summary['rows']}
    old_ranked = [row for row in old['rows'] if row['ranked']]
    old_lines = {}
    for row in old_ranked:
        matches = [line for line in section.splitlines()
                   if line.startswith('| ') and '| ' + label(row) + ' |' in line]
        if len(matches) != 1:
            raise ValueError('Expected exactly one existing clean row for ' + row['case_id'])
        old_lines[row['case_id']] = matches[0]
    rendered = []
    for row in sorted((r for r in summary['rows'] if r['ranked']), key=lambda r: r['rank']):
        if row['case_id'] in old_lines:
            line = re.sub(r'^\| \d+ \|', f"| {row['rank']} |", old_lines[row['case_id']], count=1)
        else:
            line = '| ' + ' | '.join([str(row['rank']), label(row), '10-22 Goose',
                    'Nginx + app' if row['nginx'] else 'Direct', *metric_cells(row)]) + ' |'
        rendered.append(line)
    lines = section.splitlines()
    row_positions = [i for i, line in enumerate(lines) if re.match(r'^\| \d+ \|', line)]
    if len(row_positions) != len(old_ranked):
        raise ValueError('Unexpected clean-table row coverage.')
    updated = lines[:row_positions[0]] + rendered + lines[row_positions[-1] + 1:]
    body = body[:start] + '\n'.join(updated) + '\n\n' + body[end:]
    counts = summary['counts']
    replacements = {
        'All 119 outcomes': f"All {counts['candidates']} outcomes",
        'Coverage: 119 implementation outcomes — 98 clean ranked':
            f"Coverage: {counts['candidates']} implementation outcomes — {counts['ranked']} clean ranked",
        'All 119 rows are in the same combined comparison':
            f"All {counts['candidates']} rows are in the same combined comparison",
        'All 98 rows passed 42/42': f"All {counts['ranked']} rows passed 42/42",
        'the 119 current outcomes': f"the {counts['candidates']} current outcomes",
    }
    for before, after in replacements.items():
        if before not in body:
            raise ValueError('Expected old coverage claim missing: ' + before)
        body = body.replace(before, after)
    if not addition['ranked']:
        diagnostic_start = body.index('**Measured diagnostic / reference results.**')
        diagnostic_end = body.index('**Build, runtime and test outcomes without a valid three-trial result.**')
        diagnostic_lines = body[diagnostic_start:diagnostic_end].splitlines()
        old_diagnostic = [r for r in old['rows'] if r.get('successful_rps') is not None and not r['ranked']]
        retained_lines = {}
        for row in old_diagnostic:
            matches = [line for line in diagnostic_lines if '| ' + label(row) + ' |' in line]
            if len(matches) != 1:
                raise ValueError('Expected one old diagnostic row: ' + row['case_id'])
            retained_lines[row['case_id']] = matches[0]
        diagnostic_rows = []
        for row in sorted(old_diagnostic + [addition], key=lambda r: r['successful_rps'], reverse=True):
            if row['case_id'] in retained_lines:
                diagnostic_rows.append(retained_lines[row['case_id']])
            else:
                errors = str(row['http_errors']) + '; ' + '/'.join(str(row['socket_errors'][k]) for k in SOCKETS)
                diagnostic_rows.append('| ' + ' | '.join([label(row), '10-22 Goose', row['status'], *metric_cells(row), errors]) + ' |')
        positions = [i for i, line in enumerate(diagnostic_lines) if line in retained_lines.values()]
        updated_diagnostic = diagnostic_lines[:positions[0]] + diagnostic_rows + diagnostic_lines[positions[-1] + 1:]
        body = body[:diagnostic_start] + '\n'.join(updated_diagnostic) + '\n\n' + body[diagnostic_end:]
        body = body.replace('seven measured diagnostic/reference rows', f"{counts['diagnostic']} measured diagnostic/reference rows", 1)
    base = f'https://github.com/tbsvttr/twelve-dollar-server-challenge/blob/{artifact_ref}/benchmarks'
    body = re.sub(r'https://github\.com/tbsvttr/twelve-dollar-server-challenge/blob/[0-9a-f]{40}/benchmarks/2026-10-22/(?=(?:README\.md|report\.md|comparison\.csv|comparison\.html|summary\.json)(?:[)\s]|$))',
                  base + '/2026-10-22/', body)
    paragraph = (f"**Goose main-list addition (PR #143):** the current list now includes the Goose submission, "
                 f"measured separately with the same stock-wrk three-by-15-second protocol. Its median is "
                 f"**{addition['successful_rps']:,.2f} successful req/s**; status **{addition['status']}**. "
                 f"The new unchanged #82 control measured {control['successful_rps']:,.2f} req/s with "
                 f"{control['socket_errors']['timeout']} reported wrk timeouts and remains separate; "
                 "its original main-list score is retained. Every previous outcome and both prior measured revisions remain. "
                 f"Goose recorded {addition['http_errors']} HTTP errors and {sum(addition['socket_errors'].values())} socket-error counters "
                 f"({addition['socket_errors']['timeout']} timeouts); it receives no clean rank when any counter is nonzero. "
                 f"[New raw batch]({base}/goose-2026-10-22/ranking-3x15-2026-10-22/measurements.json). "
                 "This stock-wrk batch supplies the main-list row; the separate corrected-driver 10×45-second "
                 "confirmation below remains UNMET and is not pooled into the ranking.\n\n")
    body = body.replace('**Batches:**', paragraph + '**Batches:**', 1)
    old_claim = 'The existing 119-outcome October 20/22 comparison and its historical rows remain unchanged.'
    new_claim = ('The original 119 outcome measurements and historical rows remain preserved. The main list above now includes PR #143 '
                 'as outcome 120 from the matching three-by-15-second stock-driver batch. The 45-second figures below remain a '
                 'separate protocol and are not pooled into that ranking.')
    if retained_addendum.count(old_claim) != 1:
        raise ValueError('Expected original holdout scope sentence missing.')
    clarified_addendum = retained_addendum.replace(old_claim, new_claim, 1)
    result = body + clarified_addendum
    if len(result) >= 65536:
        raise ValueError('Updated comment exceeds GitHub comment limit.')
    if not result.endswith(clarified_addendum):
        raise ValueError('Existing holdout addendum changed.')
    for comparison in old['before_after']:
        row = comparison['before']
        if row.get('successful_rps') is not None:
            matching = [line for line in original.splitlines() if label(row) in line]
            if len(matching) != 1 or matching[0] not in result:
                raise ValueError('Historical measured row changed: ' + row['case_id'])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--batch', type=Path, default=DEFAULT_BATCH)
    parser.add_argument('--current-comment', type=Path, default=DEFAULT_COMMENT)
    parser.add_argument('--artifact-commit', default='benchmark-2026-10-22',
                        help='Published evidence commit for comment URLs; a branch may be used for the initial draft.')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9._/-]+', args.artifact_commit):
        raise ValueError('Invalid artifact commit/ref.')
    batch = args.batch.resolve()
    helper = load('goose_list_followup', FROZEN / 'analyze_followup.py')
    old = read(FROZEN / 'summary.json')
    assert old['complete'] is True and len(old['rows']) == 119
    manifest = {str(row['id']): row for row in read(batch / 'manifest.json')}
    builds = read(batch / 'build-status.json')
    verification = read(batch / 'verification.json')
    measurements = read(batch / 'measurements.json')
    shared = read(batch / 'shared-sha256.json')
    assert set(manifest) == set(builds) == {'143', '82'}
    assert shared == old['shared_hashes']
    assert all(sha(batch / name) == digest for name, digest in shared.items())
    assert len(measurements) == 6 and all(
        sorted(row['trial'] for row in measurements if str(row['case_id']) == case) == [1, 2, 3]
        for case in manifest)
    environment = read(batch / 'environment-bench.json')
    assert environment['load_image_id'] == 'sha256:901ab577025cfdcf7abc716fb4158774615b881383529bb77163b5f07f963898', 'Main-list comparison requires the unchanged stock load image.'
    assert sha(batch / 'run.py') == sha(FROZEN / 'run.py')
    addition = new_row(helper, manifest['143'], builds['143'], verification, measurements, shared, batch, 'submission')
    control = new_row(helper, manifest['82'], builds['82'], verification, measurements, shared, batch, 'control')
    old_control = next(row for row in old['rows'] if row['case_id'] == '82')
    assert all(control.get(key) == old_control.get(key) for key in ('commit', 'source_sha256', 'image_id'))
    assert not any(row['case_id'] == '143' for row in old['rows'])
    summary = copy.deepcopy(old)
    summary['rows'].append(addition)
    ranked = sorted((row for row in summary['rows'] if row['ranked']), key=lambda row: row['successful_rps'], reverse=True)
    for row in summary['rows']:
        row['rank'] = None
    for rank, row in enumerate(ranked, 1):
        row['rank'] = rank
    summary['additional_controls'] = [control]
    counts = summary['counts']
    counts.update(candidates=len(summary['rows']), submission_prs=len({row['pr'] for row in summary['rows']}),
                  ranked=len(ranked), diagnostic=sum(row.get('successful_rps') is not None and not row['ranked'] for row in summary['rows']),
                  unmeasured=sum(row.get('successful_rps') is None for row in summary['rows']),
                  added_implementations=1, additional_controls=1,
                  states=dict(collections.Counter(row['status'] for row in summary['rows'])))
    summary['list_integration'] = dict(
        source_summary_sha256=sha(FROZEN / 'summary.json'), added_case_id='143',
        measurement_batch=batch.name, protocol='unchanged stock-wrk 3x15 seconds',
        batch_manifest_sha256=sha(batch / 'manifest.json'), measurements_sha256=sha(batch / 'measurements.json'),
        old_current_rows_preserved=119, historical_measured_rows_preserved=2,
        previous_rows_only_changed_field='rank', original_controls_unchanged=True,
        old_targeted_arrays_preserved=True, new_control_is_separate=True,
        corrected_driver_holdout_not_used_for_main_list=True)
    for before, after in zip(old['rows'], summary['rows']):
        assert {k: v for k, v in before.items() if k != 'rank'} == {k: v for k, v in after.items() if k != 'rank'}
    for key in ('followup_rows', 'before_after', 'control_comparisons', 'excluded'):
        assert summary[key] == old[key]
    save(HERE / 'summary.json', summary)
    with (FROZEN / 'comparison.csv').open() as stream:
        fields = next(csv.reader(stream))
    helper.write_csv(HERE / 'comparison.csv', fields,
                     sorted(summary['rows'], key=lambda row: (row['rank'] or 10**6, row['pr'], row['case_id'])))
    paragraph = (f"**Goose main-list addition.** PR #143 is included as current outcome 120, from a separate "
                 f"three-trial stock-wrk 15-second batch, with {addition['successful_rps']:,.2f} median successful req/s "
                 f"and status `{addition['status']}`. Every one of the previous 119 outcomes keeps all measurements "
                 "and source identities; only displayed ranks are recomputed. The two prior measured revisions remain in the before/after table. "
                 f"[New batch evidence]({PUBLIC_GOOSE}measurements.json). The unchanged new #82 control measured "
                 f"{control['successful_rps']:,.2f} req/s with {control['socket_errors']['timeout']} reported wrk timeouts; "
                 "its original main-list score remains unchanged. "
                 f"Goose recorded {addition['http_errors']} HTTP errors and {sum(addition['socket_errors'].values())} socket-error counters "
                 f"({addition['socket_errors']['timeout']} timeouts); any nonzero counter excludes it from clean ranking. "
                 "The separate monotonic-driver 10×45-second holdout is not used for this main-list row.\n\n")
    report = helper.report(summary)
    report = report.replace('**Common conditions.**', paragraph + '**Common conditions.**', 1)
    report += ('\n**Goose addition audit.** [Independent list-integration and six-trial audit](independent-audit.json). '
               'The original fixed-target audit remains separate and covers its original 119-outcome snapshot. '
               f'[PR documentation-only source/binary equivalence]({PUBLIC_GOOSE}pr-documentation-image-proof.json) '
               'records the added README/measurement metadata; runtime/build/support files and the production binary are unchanged.\n')
    (HERE / 'report.md').write_text(report)
    interactive_summary = copy.deepcopy(summary)
    interactive_summary['followup_rows'] += summary['additional_controls']
    content = helper.interactive(interactive_summary)
    html_intro = (f'<p><strong>Goose main-list addition.</strong> PR #143 is outcome 120: '
                  f'{addition["successful_rps"]:,.2f} median successful req/s; status {addition["status"]}; '
                  f'{addition["http_errors"]} HTTP errors and {addition["socket_errors"]["timeout"]} wrk timeouts. '
                  'All 119 earlier outcomes and the two historical measured revisions remain preserved. '
                  f'The new Rust rerun is a separate control with {control["socket_errors"]["timeout"]} reported wrk timeouts; '
                  'its original main-list score remains. '
                  f'<a href="{PUBLIC_GOOSE}measurements.json">New stock-wrk 3×15-second raw batch</a>. '
                  'The corrected-driver 45-second confirmation is not used for this row.</p>\n')
    content = content.replace('<label>Search', html_intro + '<label>Search', 1)
    # Show actual dated sub-batches, including the new control, in the table/filter.
    content = content.replace('<th data-key="measurement_date">Batch date</th>',
                              '<th data-key="measurement_date">Batch date</th><th data-key="batch">Measurement batch</th>')
    content = content.replace('["measurement_date", "Batch date"],', '["measurement_date", "Batch date"], ["batch", "Measurement batch"],')
    content = content.replace('[batch,\'measurement_date\']', '[batch,\'batch\']')
    content = content.replace('r.measurement_date===batch.value', 'r.batch===batch.value').replace('Both batches', 'All batches')
    (HERE / 'comparison.html').write_text(content)
    index = (FROZEN / 'README.md').read_text()
    index = index.replace('[Independent audit](audit-final.json)',
                          '[Original fixed-target audit](audit-final.json) · [Goose addition audit](independent-audit.json)')
    index = index.replace('**119 outcomes: 98 clean ranked, seven diagnostic/reference, and 14',
                          f"**{counts['candidates']} outcomes: {counts['ranked']} clean ranked, {counts['diagnostic']} diagnostic/reference, and {counts['unmeasured']}")
    index = index.replace('Retested eight implementations', paragraph + 'Retested eight implementations', 1)
    (HERE / 'README.md').write_text(index)
    original = read(args.current_comment)['body']
    body = comment_body(original, old, summary, addition, control, args.artifact_commit)
    (HERE / 'issue-comment.md').write_text(body)
    save(HERE / 'issue-comment.json', {'body': body})
    save(HERE / 'integration-audit.json', dict(
        complete=True, passed_all=True, prior_summary_sha256=sha(FROZEN / 'summary.json'),
        current_comment_source_sha256=sha(args.current_comment), old_rows_preserved=119,
        historical_measured_rows_preserved=2, current_rows=len(summary['rows']), clean_ranked=len(ranked),
        additional_controls=1, issue_comment_characters=len(body),
        original_targeted_and_control_arrays_unchanged=True, only_old_rank_fields_changed=True,
        outputs={name: sha(HERE / name) for name in ('summary.json', 'comparison.csv', 'comparison.html', 'report.md', 'README.md', 'issue-comment.md')},
        generator_sha256=sha(Path(__file__))))
    print(json.dumps({'rows': counts['candidates'], 'ranked': counts['ranked'],
                      'new_case_status': addition['status'], 'new_case_rank': addition['rank'],
                      'new_case_successful_rps': addition['successful_rps'], 'comment_characters': len(body)}))


if __name__ == '__main__':
    main()
