#!/usr/bin/env python3
"""Read-only independent raw/statistics audit; never imports the main analyzer.

Only the named new audit JSON is written. No Docker, server, fixture database,
compiler, load, random simulation, or benchmark helper is invoked.
"""
import argparse
import datetime
import hashlib
import json
import math
from pathlib import Path
import re
import statistics

ROOT = Path(__file__).resolve().parent
SOCKETS = ('connect', 'read', 'write', 'timeout')
REVIEWED_ANALYZER_SHA256 = 'a759420725083ecc24e4a132eeb5633a2849faa8eb21152ca48641e30fa895d1'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def student_t9_cdf(value):
    # For df=9, x=3*tan(theta) reduces the density integral to cos(theta)^8.
    # Its exact elementary recurrence independently checks the hard-coded t.
    theta = math.atan(value / 3)
    integral = theta
    for power in (2, 4, 6, 8):
        integral = (math.sin(theta) * math.cos(theta) ** (power - 1) / power
                    + (power - 1) * integral / power)
    return .5 + 128 * integral / (35 * math.pi)


def student_t9_quantile(probability):
    low, high = 0., 16.
    for _ in range(60):
        middle = (low + high) / 2
        if student_t9_cdf(middle) < probability:
            low = middle
        else:
            high = middle
    return (low + high) / 2


def raw_output(text):
    def field(pattern):
        found = re.findall(pattern, text)
        if len(found) != 1:
            raise ValueError('Expected exactly one raw field: ' + pattern)
        return found[0]
    count, duration = field(r'(\d+) requests in ([0-9.]+)s,')
    result = dict(requests=int(count), duration_s=float(duration),
                  rps=float(field(r'Requests/sec:\s*([0-9.]+)')))
    if min(result.values()) <= 0:
        raise ValueError('Nonpositive count/duration/throughput')
    if abs(result['requests'] / result['rps'] - result['duration_s']) > .0052:
        raise ValueError('Count/rate disagree with rounded elapsed time')
    for percentile in (50, 95, 99):
        value, unit = field(r'\s' + str(percentile) + r'(?:\.0+)?%\s+([0-9.]+)(us|ms|s)')
        result[f'p{percentile}_ms'] = float(value) * {'us': .001, 'ms': 1., 's': 1000.}[unit]
    if not result['p50_ms'] <= result['p95_ms'] <= result['p99_ms']:
        raise ValueError('Latency percentile order')
    http = re.findall(r'Non-2xx or 3xx responses:\s*(\d+)', text)
    socket = re.findall(r'Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)', text)
    if (len(http) > 1 or len(socket) > 1 or ('Socket errors:' in text and not socket)
            or ('Non-2xx or 3xx responses:' in text and not http)):
        raise ValueError('Malformed/duplicate error-counter line')
    result['http_errors'] = int(http[0]) if http else 0
    result['socket_errors'] = dict(zip(SOCKETS, map(int, socket[0]) if socket else (0, 0, 0, 0)))
    result['successful_rps'] = result['rps'] - result['http_errors'] / result['duration_s']
    return result


def close(a, b):
    return (type(a) in (int, float) and type(b) in (int, float)
            and math.isfinite(a) and math.isfinite(b) and math.isclose(a, b, rel_tol=1e-11, abs_tol=1e-10))


def record_review(row, manifest, builds, shared, root):
    case = row.get('case_id')
    issues, evidence_issues = [], []
    result = dict(trial=row.get('trial'), case_id=case)
    if case not in manifest:
        return dict(result, issues=['unknown case'], evidence_issues=['unknown case'])
    expected = dict(case_id=case, pr=manifest[case]['pr'], commit=manifest[case]['commit'],
                    image=builds[case]['image'], image_id=builds[case]['image_id'],
                    source_sha256=manifest[case]['source_sha256'], shared_hashes=shared)
    for key, value in expected.items():
        if row.get(key) != value:
            evidence_issues.append('identity: ' + key)
    if row.get('fingerprint') != sha(json.dumps(expected, sort_keys=True).encode()):
        evidence_issues.append('identity: fingerprint')
    filename = f"{row.get('mode')}-{re.sub('[^a-zA-Z0-9_.-]', '-', case)}-{row.get('trial')}.log"
    log = root / 'logs' / filename
    if not log.is_file() or log.read_text() != row.get('output', '') + row.get('stderr', '') + row.get('error', ''):
        evidence_issues.append('missing/changed original raw log')
    try:
        result['raw'] = raw_output(row.get('output', ''))
        result['warmup'] = raw_output(row.get('warmup_output', ''))
        for key, value in result['raw'].items():
            agrees = value == row.get(key) if isinstance(value, dict) else close(value, row.get(key))
            if not agrees:
                evidence_issues.append('raw/stored mismatch: ' + key)
        for phase in ('raw', 'warmup'):
            raw = result[phase]
            if raw['http_errors'] or any(raw['socket_errors'].values()):
                issues.append(phase + ' HTTP/socket errors')
    except (ValueError, TypeError, ZeroDivisionError) as error:
        evidence_issues.append('unparseable raw/warmup: ' + str(error))
    if row.get('mode') != 'bench':
        issues.append('not a benchmark record')
    if row.get('error'):
        issues.append('controller error: ' + row['error'])
    for flag in ('completed', 'database_valid', 'valid_duration'):
        if row.get(flag) is not True:
            issues.append(flag + ' not true')
    duration = result.get('raw', {}).get('duration_s', 0)
    if not 44.5 <= duration <= 47:
        issues.append('45-second duration tolerance')
    config = row.get('configuration', {})
    if any(config.get(key) != value for key, value in dict(threads=2, connections=64, warmup_seconds=2, measurement_seconds=45).items()):
        issues.append('measurement configuration')
    host = row.get('container_host_config', {})
    if any(host.get(key) != value for key, value in dict(CpusetCpus='0', NanoCpus=10**9, Memory=2**31, MemorySwap=2**31).items()):
        issues.append('resource limits')
    state = row.get('container_state', {})
    if state.get('OOMKilled') or state.get('Dead') or state.get('Error'):
        issues.append('container OOM/death/error')
    startup = row.get('service', {})
    if any(startup.get(key) != value for key, value in dict(ready=True, initial_post_count=500000,
            source_sha256=manifest[case]['source_sha256'], source_files_verified=manifest[case]['source_file_count'],
            nginx=manifest[case].get('nginx', False)).items()):
        issues.append('startup/source/seed proof')
    databases = [value['database_after'] for value in row.get('final', []) if 'database_after' in value]
    db = databases[0] if len(databases) == 1 else {}
    if (db.get('integrity') != 'ok' or db.get('initial_post_count') != 500000
            or db.get('post_count', 0) <= 500000 or db.get('max_post_id', 0) <= 500000):
        issues.append('committed write growth/integrity')
    try:
        before, after = row['before'], row['after']
        def sample(value):
            processes = value['processes']
            cpu = math.fsum(item['cpu_s'] for item in processes.values())
            rss = sum(item['rss_kib'] for item in processes.values())
            if not processes or not close(cpu, value['cpu_s']) or not close(rss, value['rss_kib']):
                raise ValueError('sample aggregate differs')
            if any(not close(item['cpu_s'], item['cpu_self_s'] + item['cpu_waited_children_s']) for item in processes.values()):
                raise ValueError('self/waited-child CPU sum differs')
            return cpu, rss
        first, _ = sample(before)
        last, rss = sample(after)
        elapsed = after['monotonic'] - before['monotonic']
        if elapsed <= 0 or last < first or rss <= 0:
            raise ValueError('sample interval')
        if not close(row.get('cpu_percent'), 100 * (last-first) / elapsed) or not close(row.get('rss_mib'), rss/1024):
            raise ValueError('recorded CPU/RSS differs')
        if not 0 < rss/1024 < 2048:
            issues.append('2 GiB memory bound')
    except (KeyError, TypeError, ValueError, ZeroDivisionError) as error:
        evidence_issues.append('CPU/RSS samples: ' + str(error))
    return dict(result, issues=issues + evidence_issues, evidence_issues=evidence_issues)


def compute(rows, reviews, candidate):
    cases = {candidate, '82', 'baseline'}
    trials = sorted({row['trial'] for row in rows if type(row.get('trial')) is int and row['trial'] > 0})
    invalid_ids = [index for index, row in enumerate(rows) if type(row.get('trial')) is not int or row['trial'] < 1]
    clean, excluded, pending = [], [], []
    for trial in trials:
        group = [review for review in reviews if review['trial'] == trial]
        if len(group) != 3 or {item['case_id'] for item in group} != cases:
            if trial == max(trials) and len(group) < 3 and len({item['case_id'] for item in group}) == len(group):
                pending.append(trial)
            else:
                excluded.append(dict(trial=trial, reason='incomplete/duplicate triplet'))
        elif any(review['issues'] for review in group):
            excluded.append(dict(trial=trial, issues={review['case_id']: review['issues'] for review in group if review['issues']}))
        else:
            clean.append(group)
    first_ten = clean[:10]
    paired = []
    for group in first_ten:
        rps = {review['case_id']: review['raw']['successful_rps'] for review in group}
        paired.append(dict(trial=group[0]['trial'], rps=rps,
                           p99_ms={review['case_id']: review['raw']['p99_ms'] for review in group},
                           candidate_rust_ratio=rps[candidate]/rps['82']))
    ratios = [pair['candidate_rust_ratio'] for pair in paired]
    logs = [math.log(ratio) for ratio in ratios]
    mean = math.fsum(logs)/len(logs) if logs else None
    t = student_t9_quantile(.95)
    stdev = math.sqrt(math.fsum((value-mean)**2 for value in logs)/9) if len(logs) == 10 else None
    lower = math.exp(mean - t*stdev/math.sqrt(10)) if stdev is not None else None
    p99 = {case: statistics.median(pair['p99_ms'][case] for pair in paired) for case in cases} if paired else {}
    error_trials = [review['trial'] for review in reviews if review['case_id'] == candidate and
                    any(review.get(phase, {}).get('http_errors', 0) or any(review.get(phase, {}).get('socket_errors', {}).values())
                        for phase in ('raw', 'warmup'))]
    candidate_invalid = [review['trial'] for review in reviews if review['case_id'] == candidate and review['issues']]
    gates = dict(ten_clean_rounds=len(first_ten)==10,
        replacement_limit=len(excluded)<=2 and len(trials)<=12 and max(trials, default=0)<=12,
        zero_candidate_errors_in_all_attempts=not error_trials,
        candidate_valid_in_all_attempts=not candidate_invalid,
        geometric_mean_at_least_5_percent=mean is not None and math.exp(mean)>=1.05,
        one_sided_95_percent_lower_bound_at_least_5_percent=lower is not None and lower>=1.05,
        nine_of_ten_pairs_at_least_5_percent=sum(ratio>1.05 for ratio in ratios)>=9,
        median_p99_within_5_percent_of_rust=bool(p99) and p99[candidate]<=1.05*p99['82'])
    return dict(attempted_rounds=trials, selected_rounds=[pair['trial'] for pair in paired],
                clean_rounds_available=len(clean), excluded_rounds=excluded, pending_rounds=pending,
                invalid_trial_record_indices=invalid_ids,
                rounds_contiguous=trials==list(range(1,max(trials, default=0)+1)),
                paired_rounds=paired, ratios=ratios, geometric_mean_ratio=math.exp(mean) if mean is not None else None,
                log_ratio_sample_stdev=stdev, one_sided_95_percent_lower_ratio=lower,
                independent_t9_95_quantile=t, independent_t9_cdf_at_analyzer_constant=student_t9_cdf(1.833112932653633),
                median_p99_ms=p99, candidate_error_trials=error_trials,
                candidate_invalid_attempt_trials=candidate_invalid, gates=gates)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--batch', type=Path, default=ROOT/'holdout-selected')
    parser.add_argument('--candidate', default='goose')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--final', action='store_true', help='Require completed data and a matching primary summary')
    args = parser.parse_args()
    root = args.batch.resolve()
    raw = (root/'measurements.json').read_bytes()
    rows = json.loads(raw)
    manifest = {str(row['id']): row for row in json.loads((root/'manifest.json').read_text())}
    builds = json.loads((root/'build-status.json').read_text())
    shared = json.loads((root/'shared-sha256.json').read_text())
    reviews = [record_review(row, manifest, builds, shared, root) for row in rows]
    computed = compute(rows, reviews, args.candidate)
    totals = {case:dict(http_errors=0,socket_errors=0,warmup_http_errors=0,warmup_socket_errors=0,
                       socket_error_categories=dict.fromkeys(SOCKETS,0),warmup_socket_error_categories=dict.fromkeys(SOCKETS,0))
              for case in manifest}
    unknown = []
    for index, review in enumerate(reviews):
        if review['case_id'] not in totals:
            unknown.append(index)
            continue
        for phase, prefix in [('raw',''),('warmup','warmup_')]:
            if phase not in review:
                unknown.append(index)
                continue
            data, total = review[phase], totals[review['case_id']]
            total[prefix+'http_errors'] += data['http_errors']
            total[prefix+'socket_errors'] += sum(data['socket_errors'].values())
            for category,value in data['socket_errors'].items():
                total[prefix+'socket_error_categories'][category] += value
    primary_path = root/'holdout-summary.json'
    primary_raw = primary_path.read_bytes() if primary_path.is_file() else None
    primary = json.loads(primary_raw) if primary_raw is not None else None
    differences = []
    if primary:
        if primary.get('all_attempts') != len(rows):
            differences.append('all attempt count')
        for key in ['attempted_rounds','selected_rounds','clean_rounds_available','candidate_error_trials',
                    'candidate_invalid_attempt_trials','median_p99_ms','paired_rounds']:
            if primary.get(key)!=computed[key]: differences.append(key)
        for key in ['geometric_mean_ratio','one_sided_95_percent_lower_ratio']:
            a,b=primary.get(key),computed[key]
            if not (a is None and b is None) and not close(a,b): differences.append(key)
        if [item['trial'] for item in primary.get('excluded_rounds',[])] != [item['trial'] for item in computed['excluded_rounds']]+computed['pending_rounds']:
            differences.append('excluded/pending whole rounds')
        for key,value in computed['gates'].items():
            if primary.get('gates',{}).get(key)!=value: differences.append('gate:'+key)
        for case,total in totals.items():
            for key in ['http_errors','socket_errors','warmup_http_errors','warmup_socket_errors']:
                if primary.get('all_attempt_error_totals',{}).get(case,{}).get(key)!=total[key]:
                    differences.append('error total:'+case+':'+key)
        if primary.get('t_degrees_of_freedom')!=9 or primary.get('one_sided_confidence')!=.95:
            differences.append('t interval specification')
        if primary.get('analyzer_helper_sha256') != sha((ROOT.parent/'optimization/audit.py').read_bytes()):
            differences.append('analyzer helper identity')
    complete=(len(computed['selected_rounds'])==10 and not computed['pending_rounds'])
    evidence_issues=[dict(index=index,trial=review['trial'],case_id=review['case_id'],issues=review['evidence_issues'])
                     for index,review in enumerate(reviews) if review['evidence_issues']]
    audit_passed=(not differences and not evidence_issues and not unknown and computed['rounds_contiguous']
                  and not computed['invalid_trial_record_indices']
                  and sha((ROOT/'analyze_holdout.py').read_bytes())==REVIEWED_ANALYZER_SHA256
                  and abs(computed['independent_t9_95_quantile']-1.833112932653633)<1e-10
                  and abs(computed['independent_t9_cdf_at_analyzer_constant']-.95)<1e-10
                  and (not args.final or complete and primary is not None))
    target_passed=(all(computed['gates'].values()) and bool(primary) and primary.get('gates',{}).get('evidence_checks') is True)
    report=dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        complete=complete, audit_passed=audit_passed, target_passed=target_passed,
        analyzer_matches=primary is not None and not differences, analyzer_summary_present=primary is not None,
        primary_summary_file=primary_path.name,
        primary_summary_sha256=sha(primary_raw) if primary_raw is not None else None,
        primary_comparison_differences=differences, attempts_count=len(rows), measurements_sha256=sha(raw),
        analyzer_sha256=sha((ROOT/'analyze_holdout.py').read_bytes()),
        reviewed_analyzer_sha256=REVIEWED_ANALYZER_SHA256,
        reviewed_analyzer_unchanged=sha((ROOT/'analyze_holdout.py').read_bytes())==REVIEWED_ANALYZER_SHA256,
        auditor_sha256=sha(Path(__file__).read_bytes()),
        analyzer_helper_sha256=sha((ROOT.parent/'optimization/audit.py').read_bytes()),
        protocol_sha256=sha((ROOT/'PROTOCOL.md').read_bytes()), selection_sha256=sha((root/'selection.json').read_bytes()),
        computed_statistics=computed, all_attempt_error_totals=totals,
        unknown_error_counter_attempt_indices=sorted(set(unknown)), evidence_issues=evidence_issues,
        per_attempt_reviews=reviews,
        static_method_review=dict(log_ratio_geometric_mean=True,sample_standard_deviation_n_minus_one=True,
            one_sided_t9_95_quantile_independently_derived=True,first_ten_clean_complete_triplets=True,
            maximum_two_whole_replacement_rounds=True,all_candidate_attempts_error_and_validity_gate=True,
            individual_exceedance_strictly_greater_than_1_05=True,median_p99_candidate_le_1_05_times_rust=True,
            low_throughput_never_an_exclusion_reason=True),
        limitations=['This audit reads local evidence only; live Docker/host settings are not probed.',
            'Source/profile/driver/correctness identity proofs are audited independently by the handler agent.',
            'The predeclared Student-t interval treats ten paired log ratios as independent approximately normal observations; noisy host scheduling or temporal correlation may weaken coverage.',
            'A successful audit can report target_passed=false; accurate reporting is distinct from meeting the 5% target.',
            'Partial data are not a final target claim. No stopping or round selection is based on these interim values.'])
    output=args.output or root/'independent-statistics-audit.json'
    output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({key:report[key] for key in ['complete','audit_passed','target_passed','analyzer_matches','attempts_count','primary_comparison_differences']}))
    return 0 if audit_passed else 1


if __name__=='__main__':
    raise SystemExit(main())
