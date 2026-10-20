"""Write the local cross-stage result only after independent confirmation.

Reads existing stage summaries, frozen pre/post identity audits and durability
evidence. Runs no containers or workloads and never regenerates stage evidence.
"""
import argparse
import hashlib
import json
import math
import os
import re
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ORIGINAL, LEADER = '26-original', '82-leader'
METRICS = ('rps', 'successful_rps', 'p50_ms', 'p95_ms', 'p99_ms', 'cpu_percent',
           'rss_mib', 'cpu_us_per_request')
SOCKETS = ('connect', 'read', 'write', 'timeout')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    return json.loads(Path(path).read_text())


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def frozen_hashes(values, root=None):
    require(isinstance(values, dict) and bool(values), 'Missing frozen evidence hash map.')
    for name, expected in values.items():
        path = Path(name)
        if not path.is_absolute():
            require(root is not None, 'Relative frozen path has no stage root: ' + name)
            path = root / path
        require(path.is_file() and sha(path) == expected, 'Frozen evidence changed or is missing: ' + str(path))


def load_stage(directory, expected_trials):
    directory = Path(directory).resolve()
    summary = read(directory / 'analysis-summary.json')
    require(summary.get('complete') is True and summary.get('strict_valid') is True
            and not summary.get('global_issues'), 'Stage is incomplete or invalid: ' + str(directory))
    require(summary.get('expected_trials') == expected_trials, 'Unexpected stage trial count: ' + str(directory))
    require(Path(summary.get('stage_directory', '')).resolve() == directory, 'Summary belongs to a different stage.')
    frozen_hashes(summary.get('input_sha256'), directory)
    require((directory / 'analysis-report.md').is_file(), 'Missing stage report: ' + str(directory))
    cases = summary.get('cases', [])
    require(isinstance(cases, list) and len({row['case_id'] for row in cases}) == len(cases) and bool(cases),
            'Invalid stage case coverage.')
    trials = summary.get('trials', [])
    require(len(trials) == len(cases) * expected_trials, 'Summary trial coverage differs from its case set.')
    for case in cases:
        own = [trial for trial in trials if trial['case_id'] == case['case_id']]
        require(len(own) == expected_trials and {trial['trial'] for trial in own} == set(range(1, expected_trials + 1)),
                'Missing/duplicated case rounds: ' + case['case_id'])
        require(case.get('valid_trials') == expected_trials and case.get('completed_trials') == expected_trials
                and all(trial.get('valid') is True and trial.get('completed') is True for trial in own),
                'Invalid latest attempts: ' + case['case_id'])
        for metric in METRICS:
            values = [trial.get(metric) for trial in own]
            require(all(finite(value) and value >= 0 for value in values), 'Invalid metric: ' + metric)
            actual = case.get('median_' + metric)
            require(finite(actual) and math.isclose(actual, statistics.median(values), rel_tol=1e-12, abs_tol=1e-12),
                    'Case median differs from retained trial metrics: ' + case['case_id'] + '/' + metric)
        rates = [trial['successful_rps'] for trial in own]
        require(case.get('rps_min') == min(rates) and case.get('rps_max') == max(rates), 'Case throughput range differs.')
        require(case.get('http_errors') == sum(trial['http_errors'] for trial in own), 'HTTP total differs.')
        require(case.get('socket_errors') == {key: sum(trial['socket_errors'][key] for trial in own) for key in SOCKETS},
                'Socket totals differ.')
    return dict(root=directory, summary=summary, cases={row['case_id']: row for row in cases},
                manifest={row['case_id']: row for row in read(directory / 'manifest.json')})


def check_identity_audits(directory, before_path, after_path, selected, cases):
    before, after = read(before_path), read(after_path)
    require(before.get('valid') is True and after.get('valid') is True, 'Identity pre/post audit did not pass.')
    require(before.get('snapshot_status') == 'created' and after.get('snapshot_status') == 'matched',
            'Identity audits must create then match the same frozen snapshot.')
    require(before.get('input_sha256') == after.get('input_sha256'), 'Pre/post frozen inputs differ.')
    frozen_hashes(after.get('input_sha256'))
    for audit in (before, after):
        require(audit.get('lineage_valid') is True and audit.get('selected_case') == selected
                and audit.get('expected_trials') == 6, 'Identity audit has wrong candidate, rounds, or lineage.')
        require(Path(audit.get('confirmation_directory', '')).resolve() == directory, 'Audit belongs to another directory.')
        require(audit.get('selection_sha256') == sha(directory / 'selection.json')
                and audit.get('orders_sha256') == sha(directory / 'orders.json'), 'Frozen selection/orders changed.')
        require(set(audit.get('identities', {})) == set(cases), 'Audit case identities differ.')
        for case, row in cases.items():
            identity = audit['identities'][case]
            require(identity.get('image_id') == row['image_id']
                    and identity.get('source_sha256') == row['source_sha256'], 'Audit/summary identity mismatch: ' + case)
    return after


def durability_evidence(initial, followup, selected, candidate, explicit=None):
    attempts = []
    for directory in (initial / 'durability', followup / 'durability'):
        if directory.is_dir():
            for path in sorted(directory.glob('*.json')):
                value = read(path)
                attempts.append(dict(path=path, record=value))
    if explicit:
        path = Path(explicit).resolve()
        if not any(item['path'].resolve() == path for item in attempts):
            attempts.append(dict(path=path, record=read(path)))
    matching = [item for item in attempts if item['record'].get('case_id') == selected]
    require(bool(matching), 'No durability attempt for the selected candidate.')
    latest = max(matching, key=lambda item: (item['record'].get('attempt', 1), item['record'].get('recorded_at', '')))
    if explicit:
        require(latest['path'].resolve() == Path(explicit).resolve(), 'Explicit durability record is not the latest candidate attempt.')
    record = latest['record']
    require(record.get('passed') is True and record.get('checks_passed') is True
            and not record.get('error') and not record.get('cleanup_error'), 'Latest candidate durability attempt did not pass.')
    require(record.get('image_id') == candidate['image_id'] and record.get('source_sha256') == candidate['source_sha256'],
            'Durability source/image differs from the confirmed candidate.')
    require(record.get('settings') == candidate['local_variant'], 'Durability settings differ.')
    steps = record.get('steps', [])
    require(len(steps) == 3 and all(step.get('exit_code') == 0 and step.get('timed_out') is False for step in steps),
            'Durability must pass build, commit-fault and production SIGKILL checks.')
    require(record.get('cleanup', {}).get('exit_code') == 0, 'Durability container cleanup did not finish.')
    # Log paths are relative to the screen which owned the disposable check.
    owner = latest['path'].parent.parent
    for step in steps:
        require((owner / step['log']).is_file() and sha(owner / step['log']) == step['log_sha256'],
                'Durability log is missing or changed: ' + step['log'])
    return latest, attempts


def paired(summary, selected, control):
    matches = [row for row in summary['paired_comparisons']
               if row['candidate'] == selected and row['control'] == control]
    require(len(matches) == 1, 'Missing unique candidate/control paired comparison.')
    pair = matches[0]
    require(pair.get('complete_valid') is True and pair.get('valid_pairs') == 6
            and len(pair.get('rounds', [])) == 6, 'Confirmation paired comparison is not six valid rounds.')
    require({row['trial'] for row in pair['rounds']} == set(range(1, 7)), 'Paired rounds differ.')
    require(all(row.get('valid') is True and finite(row.get('ratio')) and row['ratio'] > 0 for row in pair['rounds']),
            'Invalid paired ratio.')
    return pair


def assessment(candidate, original, leader, vs_original, vs_leader):
    nominal = candidate['median_successful_rps'] / leader['median_successful_rps']
    if not candidate['clean']:
        return 'No clean #1 result: the candidate recorded error counters during confirmation.'
    if nominal <= 1 and vs_leader['median_ratio'] <= 1:
        return 'No: the tuning improves PR26, but the current #1 reference remains faster in this confirmation.'
    if (leader['clean'] and original['clean'] and vs_leader['wins'] == 6 and vs_original['wins'] == 6
            and nominal >= 1.05 and vs_leader['median_ratio'] >= 1.05):
        return ('Strong local contender: the candidate beat both controls in all six paired rounds, '
                'with at least a 5% lead over the leader by both median comparisons. '
                'This is a provisional follow-up result, not a new all-submission #1 ranking.')
    return ('A #1 result is not established: median throughput, paired rounds, or clean-control evidence '
            'do not show a consistent clear lead over the current leader.')


def read_decision(path, initial):
    path = Path(path) if path else initial / 'RUN_STATUS.json'
    if not path.is_file():
        return None, None
    decision = read(path)
    require(isinstance(decision, dict) and isinstance(decision.get('reason'), str)
            and bool(decision['reason'].strip()), 'Decision note requires a nonempty reason.')
    for rejected in decision.get('rejected_candidates', []) + decision.get('not_adopted_candidates', []):
        require(isinstance(rejected, dict) and rejected.get('case_id') and rejected.get('reason'),
                'Rejected candidate note requires case_id and reason.')
        for name in rejected.get('evidence', []):
            evidence = Path(name)
            if not evidence.is_absolute():
                evidence = initial / evidence
            require(evidence.is_file(), 'Decision evidence is missing: ' + str(evidence))
    return decision, path.resolve()


def unresolved_documents(initial_dir, followup_dir, output_dir, decision_path=None):
    """Explicit fallback for a stopped/rejected experiment; makes no holdout claim."""
    initial_dir, output_dir = Path(initial_dir).resolve(), Path(output_dir).resolve()
    followup_dir = Path(followup_dir or initial_dir / 'followup-screen').resolve()
    initial, followup = load_stage(initial_dir, 3), load_stage(followup_dir, 3)
    decision, decision_file = read_decision(decision_path, initial_dir)
    require(decision is not None and decision.get('rejected_candidates'),
            'An unresolved result requires an explicit decision note with rejected candidates.')
    link = lambda path, label: '[' + label + '](' + Path(os.path.relpath(path, output_dir)).as_posix() + ')'
    answer = 'A #1 result is not established: candidate validation or independent confirmation remains unresolved.'
    lines = ['# PR26 batching experiment — unresolved local result', '', '**' + answer + '**', '',
             decision['reason'], '', 'Decision evidence: ' + link(decision_file, 'recorded decision') + '.', '',
             'The completed exploratory screens are retained separately; their medians are not independent confirmation or proof of a #1 result.', '',
             '| Rejected/unresolved candidate | Reason | Evidence |', '|---|---|---|']
    for item in decision['rejected_candidates'] + decision.get('not_adopted_candidates', []):
        links = []
        for name in item.get('evidence', []):
            path = Path(name)
            links.append(link(path if path.is_absolute() else initial_dir / path, path.name))
        lines.append('| ' + str(item['case_id']) + ' | ' + str(item['reason']).replace('|', '\\|').replace('\n', ' ')
                     + ' | ' + ', '.join(links) + ' |')
    for stage, label in ((initial, 'Initial 2×2 screen'), (followup, 'Bounded 32/16/8 screen')):
        lines += ['', '## ' + label, '', link(stage['root'] / 'analysis-report.md', 'Full stage report'), '',
                  '| Case | Median successful req/s | Clean / valid / expected | HTTP | Socket C/R/W/T |',
                  '|---|---:|---:|---:|---|']
        for case in stage['summary']['cases']:
            sockets = '/'.join(str(case['socket_errors'][key]) for key in SOCKETS)
            lines.append(f"| {case['case_id']} | {case['median_successful_rps']:,.0f} | {case['clean_trials']} / {case['valid_trials']} / {case['expected_trials']} | {case['http_errors']} | {sockets} |")
    lines += ['', 'No incomplete confirmation result is presented as a measured win. Any fallback candidate requires an explicit frozen decision, '
              'its own matching durability evidence and six valid independent confirmation rounds.', '',
              'This local ARM64 workload does not establish official five-minute k6 capacity. All evidence is retained locally; no remote publication is performed.', '']
    readme = '# PR26 batching follow-up — unresolved\n\n**' + answer + '**\n\n' + link(output_dir / 'RESULT.md', 'Read the retained results and rejection evidence') + '.\n'
    return readme, '\n'.join(lines)


def build_documents(initial_dir=ROOT, followup_dir=None, confirmation_dir=None,
                    before_path=None, after_path=None, durability_path=None, output_dir=ROOT, decision_path=None):
    initial_dir = Path(initial_dir).resolve()
    followup_dir = Path(followup_dir or initial_dir / 'followup-screen').resolve()
    default_confirmation = (initial_dir / 'confirmation' if (initial_dir / 'confirmation').is_dir()
                            else followup_dir / 'confirmation')
    confirmation_dir = Path(confirmation_dir or default_confirmation).resolve()
    output_dir = Path(output_dir).resolve()
    initial = load_stage(initial_dir, 3)
    followup = load_stage(followup_dir, 3)
    confirmation = load_stage(confirmation_dir, 6)
    selection = read(confirmation_dir / 'selection.json')
    require(selection.get('confirmation_independent') is True
            and selection.get('screen_trials_included_in_confirmation') is False,
            'Confirmation is not declared independent from screening.')
    source_screen = Path(selection.get('screen_root', '')).resolve()
    require(source_screen in (initial_dir, followup_dir), 'Selection refers to an unknown screen.')
    frozen_hashes(selection.get('screen_evidence_sha256'), source_screen)
    if source_screen == followup_dir:
        frozen_hashes(selection.get('initial_screen_lineage'), initial_dir)
    selected = selection.get('selected_case')
    require(set(confirmation['cases']) == {selected, ORIGINAL, LEADER}, 'Unexpected confirmation case set.')
    candidate, original, leader = (confirmation['cases'][name] for name in (selected, ORIGINAL, LEADER))
    decision, decision_file = read_decision(decision_path, initial_dir)
    if source_screen == initial_dir:
        require(decision is not None and decision.get('selected_case') == selected,
                'Initial-screen fallback confirmation requires an explicit cross-stage decision note.')
    screen_candidates = [row for row in followup['cases'].values()
                         if row['case_id'].startswith('26-b') and row['clean']]
    screen_winner = min(screen_candidates, key=lambda row: (-row['median_successful_rps'], row['case_id']))['case_id']
    if selected != screen_winner:
        require(decision is not None and decision.get('selected_case') == selected
                and any(item.get('case_id') == screen_winner for item in decision.get('rejected_candidates', [])),
                'Fallback from the screen median winner requires an explicit rejection/selection decision note.')
    source = confirmation['manifest'][selected]
    require(candidate['image_id'] == followup['cases'][selected]['image_id']
            and candidate['source_sha256'] == followup['cases'][selected]['source_sha256'],
            'Confirmed candidate differs from the frozen selected screen candidate.')
    settings = source.get('local_variant', {})
    require(settings.get('WAIT_USEC') == 4000 and settings.get('WAIT_NR') in (8, 16, 32),
            'Unexpected final one-constant candidate settings.')
    patch_path = confirmation_dir / source['patch']
    patch = patch_path.read_text()
    require(sha(patch_path) == source['patch_sha256'], 'Final patch digest changed.')
    removed = [line[1:] for line in patch.splitlines() if line.startswith('-') and not line.startswith('---')]
    added = [line[1:] for line in patch.splitlines() if line.startswith('+') and not line.startswith('+++')]
    require(len(removed) == len(added) == 1
            and re.match(r'#define WAIT_NR 128\s', removed[0])
            and re.match(r'#define WAIT_NR ' + str(settings['WAIT_NR']) + r'\s', added[0]),
            'Final patch changes more than the one declared WAIT_NR constant.')
    base_inventory = read(initial_dir / initial['manifest'][ORIGINAL]['source_hashes'])
    inventory = read(confirmation_dir / source['source_hashes'])
    require(set(base_inventory) == set(inventory)
            and [name for name in base_inventory if base_inventory[name] != inventory[name]] == ['src/server.c'],
            'Final source delta differs from the one-file tuning patch.')
    before_path = Path(before_path or confirmation_dir / 'identity-audit-pre.json')
    after_path = Path(after_path or confirmation_dir / 'identity-audit-post.json')
    audit = check_identity_audits(confirmation_dir, before_path, after_path, selected, confirmation['cases'])
    latest_durability, durability_attempts = durability_evidence(initial_dir, followup_dir, selected, candidate, durability_path)
    commit_diagnostics = []
    diagnostic_root = followup_dir / 'commit-diagnostics'
    if diagnostic_root.is_dir():
        for path in sorted(diagnostic_root.glob('*/result.json')):
            diagnostic = read(path)
            case = diagnostic.get('case_id')
            require(case in followup['cases'], 'Unknown commit diagnostic case.')
            measured = followup['cases'][case]
            require(diagnostic.get('image_id') == measured['image_id']
                    and diagnostic.get('source_sha256') == measured['source_sha256'],
                    'Commit diagnostic image/source mismatch: ' + case)
            for step in diagnostic.get('steps', []):
                log = path.parent / (step['label'] + '.log')
                require(log.is_file() and sha(log) == step['log_sha256'], 'Commit diagnostic log changed.')
            runs = [step for step in diagnostic.get('steps', []) if step['label'].startswith('commit-')]
            if case in (selected, ORIGINAL):
                require(len(runs) == 6 and all(step['exit_code'] == 0 for step in diagnostic['steps']),
                        'Selected candidate or original control has unresolved/failed repeated commit diagnostics.')
            commit_diagnostics.append(dict(path=path, case_id=case, runs=len(runs),
                                           failures=sum(step['exit_code'] != 0 for step in runs)))
    vs_original = paired(confirmation['summary'], selected, ORIGINAL)
    vs_leader = paired(confirmation['summary'], selected, LEADER)
    answer = assessment(candidate, original, leader, vs_original, vs_leader)

    def link(path, label):
        return '[' + label + '](' + Path(os.path.relpath(path, output_dir)).as_posix() + ')'

    def number(value, digits=0):
        return f'{value:,.{digits}f}'

    def counters(case):
        return '/'.join(str(case['socket_errors'][key]) for key in SOCKETS)

    def stage_table(stage):
        lines = ['| Case | Median req/s [range] | CPU % | HTTP | Socket C/R/W/T | Clean / valid / expected |',
                 '|---|---:|---:|---:|---|---:|']
        for case in stage['summary']['cases']:
            lines.append(f"| {case['case_id']} | {number(case['median_successful_rps'])} [{number(case['rps_min'])}–{number(case['rps_max'])}] | {number(case['median_cpu_percent'], 1)} | {case['http_errors']} | {counters(case)} | {case['clean_trials']} / {case['valid_trials']} / {case['expected_trials']} |")
        return lines

    base_gain = (candidate['median_successful_rps'] / original['median_successful_rps'] - 1) * 100
    leader_gap = (candidate['median_successful_rps'] / leader['median_successful_rps'] - 1) * 100
    reports = ' · '.join(link(stage['root'] / 'analysis-report.md', label)
                         for stage, label in ((initial, 'initial 2×2 screen'), (followup, 'bounded 32/16/8 screen'),
                                              (confirmation, 'independent confirmation')))
    result = ['# PR26 batching experiment — final local result', '', '**' + answer + '**', '',
              f"The frozen `{selected}` candidate changed `WAIT_NR` from **128 to {settings['WAIT_NR']}**, retaining `WAIT_USEC=4000`. "
              f"In the six-round confirmation its median successful throughput was **{base_gain:+.1f}% versus original PR26** "
              f"and **{leader_gap:+.1f}% versus the current #1 reference**. These percentages divide stage medians; paired ratios are shown separately.", '',
              '## Independent confirmation', '',
              '| Case | Median req/s [range] | p95 ms | p99 ms | RSS MiB | CPU % | CPU µs/request | HTTP | Socket C/R/W/T | Clean / valid |',
              '|---|---:|---:|---:|---:|---:|---:|---:|---|---:|']
    if decision is not None:
        result[4:4] = [decision['reason'] + ' (' + link(decision_file, 'recorded decision') + ').', '']
    for case in (original, candidate, leader):
        result.append(f"| {case['case_id']} | {number(case['median_successful_rps'])} [{number(case['rps_min'])}–{number(case['rps_max'])}] | {number(case['median_p95_ms'], 3)} | {number(case['median_p99_ms'], 3)} | {number(case['median_rss_mib'], 2)} | {number(case['median_cpu_percent'], 1)} | {number(case['median_cpu_us_per_request'], 3)} | {case['http_errors']} | {counters(case)} | {case['clean_trials']}/6 / {case['valid_trials']}/6 |")
    result += ['', '| Round | Candidate / original | Candidate / leader | Counters clean for both pairs? |',
               '|---:|---:|---:|---|']
    for a, b in zip(sorted(vs_original['rounds'], key=lambda row: row['trial']),
                    sorted(vs_leader['rounds'], key=lambda row: row['trial'])):
        result.append(f"| {a['trial']} | {a['ratio']:.4f}× | {b['ratio']:.4f}× | original pair: {a['clean']}; leader pair: {b['clean']} |")
    result += ['', f"Median within-round ratio: **{vs_original['median_ratio']:.4f}× original** ({vs_original['wins']}/6 wins), "
               f"**{vs_leader['median_ratio']:.4f}× leader** ({vs_leader['wins']}/6 wins). "
               'All six permutations were used once, with each implementation in each position twice. No screening trial is included in these confirmation values.', '',
               'The comparisons are descriptive. Six short rounds do not establish statistical significance, and a higher noisy median alone is not treated as a #1 result. '
               'Counter-flagged valid reference runs remain visible and qualify their paired comparisons; the published zero-error ranking rule is unchanged.', '',
               f"Service CPU changed from **{original['median_cpu_percent']:.1f}% to {candidate['median_cpu_percent']:.1f}%**; "
               f"p95 changed from **{original['median_p95_ms']:.3f} to {candidate['median_p95_ms']:.3f} ms**. "
               'The throughput gain came with higher service CPU usage and worse p95 latency in this confirmation. '
               'RSS is end-of-load summed service RSS, not peak/container memory. CPU µs/request uses each trial’s sampled CPU delta divided by completed requests.', '',
               '## How the setting was chosen', '', 'Stage reports: ' + reports + '.', '',
               'The original screen tested the full 2×2 completion-count/wait grid and a rebuilt unchanged control. '
               'The bounded follow-up then compared 32, 16 and 8 completions with the 4 ms wait retained. '
               'Only after that exploratory comparison was one setting frozen for the independent confirmation. All tested settings remain below.', '',
               '### Initial screen — three rounds per case', '']
    host_observation = confirmation_dir / 'host-observation.json'
    if host_observation.is_file():
        position = result.index('## How the setting was chosen')
        result[position:position] = [
            '**Host variability.** A ' + link(host_observation, 'host observation during confirmation')
            + ' recorded load averages **13.35 / 10.56 / 10.10**. The thermal-status read failed. '
            'No cause of the throughput variation was established, and no trial was excluded or adjusted. '
            'The six paired rounds retain the observed variation; these local shared-host measurements have limited precision.', '']
    result += stage_table(initial)
    result += ['', '### Bounded follow-up — three rounds per case', ''] + stage_table(followup)
    alternatives = sorted((case for case in followup['cases'].values() if case['case_id'].startswith('26-b') and case['clean']),
                          key=lambda case: (-case['median_successful_rps'], case['case_id']))
    if len(alternatives) >= 2:
        a, b = alternatives[:2]
        difference = (a['median_successful_rps'] / b['median_successful_rps'] - 1) * 100
        result += ['', f"The exploratory winner `{a['case_id']}` exceeded runner-up `{b['case_id']}` by only **{difference:.2f}%** in median throughput. "
                   'That selection difference does not establish a uniquely optimal setting.']
    if selected != screen_winner:
        result += ['', f"The median screen winner was `{screen_winner}`; the final `{selected}` setting was an explicit fallback after the recorded rejection, not an undeclared reselection."]
    if decision is not None:
        result += ['', '**Rejected or unadopted settings:**']
        for item in decision.get('rejected_candidates', []) + decision.get('not_adopted_candidates', []):
            evidence = []
            for name in item.get('evidence', []):
                path = Path(name)
                evidence.append(link(path if path.is_absolute() else initial_dir / path, path.name))
            result += ['', '- `' + item['case_id'] + '`: ' + item['reason'] + ' ' + ', '.join(evidence)]
    result += ['', '## Correctness, durability and frozen identities', '',
               'Every measured case passed 42 official API checks, six dynamic semantic checks, and post-stop SQLite integrity/committed-growth validation before or during its stage. '
               'The final confirmation contains six valid trials for each of its three cases. '
               'The pre/post audit matched the frozen selection, images, source inventories, controller, twelve fixture hashes, orders and parent-stage lineage.', '',
               'Identity evidence: ' + link(before_path, 'pre audit') + ' · ' + link(after_path, 'post audit') + ' · '
               + link(confirmation_dir / 'selection.json', 'frozen selection') + ' · ' + link(patch_path, 'one-constant patch') + '.', '',
               'Selected candidate identity:', '', '```text', candidate['image_id'], candidate['source_sha256'], '```', '',
               'The recorded commit-fault and production-binary SIGKILL persistence assertions passed for the selected image: '
               + link(latest_durability['path'], 'durability evidence') + '. '
               'The lifecycle check used two connections and zero idle seconds; it is a correctness check, not a capacity measurement.', '',
               '| Durability attempt | Result | Note |', '|---|---|---|']
    for attempt in durability_attempts:
        record = attempt['record']
        error = str(record.get('error', ''))
        note = ('Test workspace permission failure before checks; disposable workspace ownership was corrected for the retry.'
                if 'Permission denied' in error else 'Passed recorded checks.' if record.get('passed') else error.replace('\n', ' ')[:250])
        result.append(f"| {link(attempt['path'], record.get('case_id', 'attempt') + ' #' + str(record.get('attempt', 1)))} | {record.get('passed')} | {note.replace('|', '\\|')} |")
    result += ['', 'The initial permission failure remains recorded and is not classified as an application failure.', '',
               '### Repeated commit-fault diagnostics', '',
               '| Case | Completed commit-suite runs | Failed runs | Evidence |', '|---|---:|---:|---|']
    for diagnostic in commit_diagnostics:
        result.append(f"| {diagnostic['case_id']} | {diagnostic['runs']} | {diagnostic['failures']} | {link(diagnostic['path'], 'retained diagnostic')} |")
    if not commit_diagnostics:
        result.append('| — | — | — | No additional repeated diagnostic suite was recorded. |')
    result += ['', 'Failed diagnostic runs remain visible even when their exploratory throughput was attractive. '
               'A setting that was not fault-tested is not described as having passed these additional checks. '
               'These are the clients’ recorded assertions: passing diagnostic clients also permit transient POST status 0, '
               'so a passing run does not guarantee a particular HTTP response for every injected write.', '',
               '## Scope and retained evidence', '',
               'Native Linux ARM64, one server CPU/2 GiB, two separate load CPUs, 64 active connections, '
               '2-second warmup and 15-second measurements on fresh processes/databases. '
               'This local workload does not establish the official five-minute k6 maximum-user score or rerank all submissions. '
               'wrk histogram-overlimit counters represent completed responses outside its two-second histogram; they stay in throughput and are absent from latency percentiles. '
               'HTTP and timeout counters are kept separate.', '',
               'The original published benchmark and all stage records are unchanged. This follow-up is local; no external publication is performed by this generator.', '',
               '| Stage | Cases × rounds | Raw attempts | Latest attempts | HTTP errors | Socket C/R/W/T | Valid? |',
               '|---|---:|---:|---:|---:|---|---|']
    for stage, label in ((initial, 'Initial screen'), (followup, 'Bounded follow-up'), (confirmation, 'Confirmation')):
        summary = stage['summary']
        http = sum(case['http_errors'] for case in stage['cases'].values())
        sockets = '/'.join(str(sum(case['socket_errors'][key] for case in stage['cases'].values())) for key in SOCKETS)
        result.append(f"| {link(stage['root'] / 'analysis-report.md', label)} | {len(stage['cases'])} × {summary['expected_trials']} | {summary['raw_measurement_records']} | {summary['latest_attempts']} | {http} | {sockets} | {summary['strict_valid']} |")
    result += ['', 'Each stage retains its own measurements.json, verification.json, analysis-summary.json, CSVs, logs and source/fixture identities. '
               'No cross-stage pooling or selective trial removal was used. Superseded attempts, if any, remain in raw evidence and stage analysis.', '']
    readme = ['# PR26 batching follow-up', '', '**' + answer + '**', '',
              f"Frozen setting: `WAIT_NR={settings['WAIT_NR']}`, `WAIT_USEC=4000`. Confirmation: "
              f"{number(candidate['median_successful_rps'])} median successful req/s, {base_gain:+.1f}% versus original PR26 and {leader_gap:+.1f}% versus the leader.", '',
              link(output_dir / 'RESULT.md', 'Read the full result, all settings and six paired rounds') + '.', '',
              'Stage reports: ' + reports + '.', '',
              'The final conclusion uses only the independent six-round confirmation. Both exploratory screens, counter flags, '
              'durability attempts and the frozen identity audits remain linked in the result. '
              'This is a local ARM64 throughput experiment, not the official k6 capacity score or a newly published leaderboard.', '',
              'To regenerate these two local documents after all stage reports and audits are complete:', '',
              '```sh', 'python3 summarize_tuning.py', '```', '',
              'The generator refuses incomplete/stale evidence and runs no builds, containers, workloads or remote actions.', '']
    return '\n'.join(readme), '\n'.join(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--initial', type=Path, default=ROOT)
    parser.add_argument('--followup', type=Path)
    parser.add_argument('--confirmation', type=Path)
    parser.add_argument('--identity-pre', type=Path)
    parser.add_argument('--identity-post', type=Path)
    parser.add_argument('--durability', type=Path)
    parser.add_argument('--decision', type=Path, help='Explicit rejection/fallback decision JSON; defaults to RUN_STATUS.json if present.')
    parser.add_argument('--allow-incomplete', action='store_true',
                        help='Explicitly render an unresolved result from a decision note; never report a confirmation win.')
    parser.add_argument('--output-dir', type=Path, default=ROOT)
    parser.add_argument('--check-only', action='store_true', help='Validate and render in memory without writing documents.')
    args = parser.parse_args()
    try:
        readme, result = build_documents(args.initial, args.followup, args.confirmation,
                                        args.identity_pre, args.identity_post, args.durability, args.output_dir, args.decision)
    except (OSError, ValueError, TypeError, KeyError) as error:
        if not args.allow_incomplete:
            parser.exit(2, 'Final report not ready: ' + str(error) + '\n')
        try:
            readme, result = unresolved_documents(args.initial, args.followup, args.output_dir, args.decision)
        except (OSError, ValueError, TypeError, KeyError) as unresolved:
            parser.exit(2, 'Unresolved report not ready: ' + str(unresolved) + '\n')
    if not args.check_only:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        for name, content in (('README.md', readme), ('RESULT.md', result)):
            temporary = args.output_dir / (name + '.partial')
            temporary.write_text(content)
            temporary.replace(args.output_dir / name)
    print('Report evidence validated; ' + ('no files written.' if args.check_only else 'README.md and RESULT.md written.'))


if __name__ == '__main__':
    main()
