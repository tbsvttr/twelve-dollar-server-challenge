"""Merge completed independent holdout audits without changing any evidence."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('batch', type=Path)
    args = parser.parse_args()
    batch = args.batch.resolve()
    identity_path = batch / 'independent-identity-audit.json'
    statistics_path = batch / 'independent-statistics-audit.json'
    identity, statistics = read(identity_path), read(statistics_path)
    summary_path = batch / statistics['primary_summary_file']
    summary = read(summary_path)
    marker_path = batch / 'holdout-complete.json'
    marker = read(marker_path)
    rows = read(batch / 'measurements.json')
    digest = sha(batch / 'measurements.json')
    problems = []

    def require(condition, message):
        if not condition:
            problems.append(message)

    require(identity.get('complete') is True and statistics.get('complete') is True, 'Both independent audits must be complete')
    require(identity.get('measurement_count') == statistics.get('attempts_count') == summary.get('all_attempts') == len(rows), 'Attempt counts must agree across final raw evidence and all audits')
    require(identity.get('measurements_sha256') == statistics.get('measurements_sha256') == digest, 'Both independent audits must reference the exact current raw measurements')
    require(statistics.get('primary_summary_sha256') == sha(summary_path), 'Independent statistics must bind the exact final primary summary')
    require(marker.get('complete') is True and marker.get('attempt_count') == len(rows)
            and marker.get('selected_rounds') == summary.get('selected_rounds'), 'Final controller completion marker must match all attempts and selected rounds')
    require(marker.get('summary_sha256') == sha(summary_path) and marker.get('measurements_sha256') == digest,
            'Completion marker must bind the exact audited summary and raw measurements')
    require((batch / 'finalholdout-summary.json').read_bytes() == summary_path.read_bytes(),
            'Frozen final summary must be byte-identical to the canonical audited summary')
    require(statistics.get('analyzer_matches') is True, 'Independent statistics must reproduce the primary summary')
    require(identity.get('identities') == summary.get('identities'), 'Independent source/image/binary identities must agree with the primary summary')
    require(identity.get('selection_sha256') == statistics.get('selection_sha256') == sha(batch / 'selection.json'), 'Both audits must bind the same immutable pre-holdout selection')
    require(identity.get('auditor_sha256') == sha(ROOT / 'independent_identity_audit.py'), 'Identity auditor source must remain unchanged after its final run')
    require(statistics.get('auditor_sha256') == sha(ROOT / 'audit_holdout_statistics.py'), 'Statistics auditor source must remain unchanged after its final run')
    require(identity.get('evidence_passed_all') is True and not identity.get('issues'), 'Independent identity/correctness evidence audit must pass')
    require(statistics.get('audit_passed') is True, 'Independent raw/selection/statistical reproduction audit must pass')
    complete = (identity.get('complete') is True and statistics.get('complete') is True
                and identity.get('measurement_count') == statistics.get('attempts_count') == len(rows))
    audit_passed = complete and not problems
    target_passed = bool(audit_passed and statistics.get('target_passed') is True
                         and summary.get('passed_all') is True
                         and summary.get('gates') and all(summary['gates'].values()))
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        complete=complete, audit_passed=audit_passed, target_passed=target_passed,
        purpose='Completed independent source/identity/correctness and raw/statistics audit; accurate audit success is distinct from meeting the performance target',
        measurement_count=len(rows), measurements_sha256=digest, identities=identity.get('identities'),
        selection_sha256=sha(batch / 'selection.json'),
        primary_summary=dict(path=summary_path.name, sha256=sha(summary_path), target_passed=summary.get('passed_all')),
        completion_marker=dict(path=marker_path.name, sha256=sha(marker_path)),
        identity_audit=dict(path=identity_path.name, sha256=sha(identity_path), evidence_passed_all=identity.get('evidence_passed_all')),
        statistics_audit=dict(path=statistics_path.name, sha256=sha(statistics_path),
            audit_passed=statistics.get('audit_passed'), target_passed=statistics.get('target_passed'), analyzer_matches=statistics.get('analyzer_matches')),
        geometric_mean_ratio=summary.get('geometric_mean_ratio'),
        one_sided_95_percent_lower_ratio=summary.get('one_sided_95_percent_lower_ratio'),
        selected_rounds=summary.get('selected_rounds'), excluded_rounds=summary.get('excluded_rounds'),
        all_attempt_error_totals=statistics.get('all_attempt_error_totals'),
        protocol_gates=summary.get('gates'),
        normal_reproduction=identity.get('normal_reproduction'),
        merger_sha256=sha(Path(__file__)), issues=problems,
        limitations=list(dict.fromkeys(identity.get('limitations', []) + statistics.get('limitations', []) + [
            'This local ARM64 experiment compares complete pinned implementations; it does not establish official x86-64 capacity or isolate language speed.'])))
    output = batch / 'independent-audit.json'
    temporary = output.with_suffix('.json.partial')
    temporary.write_text(json.dumps(result, indent=2) + '\n')
    temporary.replace(output)
    print(json.dumps({key: result[key] for key in ('complete', 'audit_passed', 'target_passed', 'measurement_count', 'issues')}, indent=2))
    return 0 if audit_passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
