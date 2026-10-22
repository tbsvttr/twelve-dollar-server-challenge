"""Classify retained LOCAL benchmark evidence without changing a source row.

PASS means the documented local ARM64/Docker/stock-wrk comparison checks only.
It does not certify every challenge rule or the official x86-64/k6 conditions.
"""

LOCAL_SCOPE = 'Local ARM64 Docker, 3×15s stock-wrk comparison only; not official challenge compliance.'
OFFICIAL_REASON = ('Not measured on the official Ubuntu x86-64 droplet with k6; '
                   'these are local ARM64 Docker/wrk runs with CPU affinity.')
SOCKETS = ('connect', 'read', 'write', 'timeout')
# These retained batches have audited controller/environment/actual server
# configuration records for one CPU quota, 2 GiB RAM and no container swap.
# Unknown batches receive no inherited budget assumption.
AUDITED_LOCAL_BATCHES = {
    'current-2026-10-20': '../2026-10-20/report.md',
    'fixes-2026-10-22': 'audit-final.json',
    'ranking-3x15-2026-10-22': '../goose-2026-10-22/list-integration/independent-audit.json',
}


def _budget(row):
    checks = []
    host = row.get('container_host_config')
    if isinstance(host, dict):
        for name, expected in (('NanoCpus', 1000000000), ('Memory', 2147483648), ('MemorySwap', 2147483648)):
            if name in host:
                checks.append(host[name] == expected)
    for name, expected in (('server_cpu_quota', 1), ('server_memory_bytes', 2147483648),
                           ('server_memory_swap_bytes', 2147483648), ('container_swap_available_bytes', 0)):
        if name in row and row[name] is not None:
            checks.append(row[name] == expected)
    if checks and not all(checks):
        return 'FAIL', 'Recorded server limits differ from one CPU / 2 GiB / no swap.'
    batch = row.get('measurement_batch', row.get('batch'))
    if batch in AUDITED_LOCAL_BATCHES:
        return 'PASS', 'Limits documented by retained batch audit: ' + AUDITED_LOCAL_BATCHES[batch]
    complete_host = isinstance(host, dict) and all(k in host for k in ('NanoCpus', 'Memory', 'MemorySwap'))
    complete_flat = all(row.get(k) is not None for k in ('server_cpu_quota', 'server_memory_bytes', 'server_memory_swap_bytes'))
    if checks and all(checks) and (complete_host or complete_flat):
        return 'PASS', 'Recorded limits are one CPU quota / 2 GiB / no swap.'
    return 'UNVERIFIED', 'No recognized audited local batch or complete server-limit record.'


def classify(row):
    """Return derived condition fields; never mutate row or source_record."""
    status = row.get('status')
    protocol = row.get('protocol')
    budget_status, budget_reason = _budget(row)
    eligible = row.get('eligible')
    official_api = (row.get('tests_passed') == 42 and row.get('tests_failed') == 0
                    and row.get('official_passed_all') is True)
    api_ran = type(row.get('tests_passed')) is int and type(row.get('tests_failed')) is int
    api_counts_failed = api_ran and (row['tests_passed'] != 42 or row['tests_failed'] != 0)
    dynamic = row.get('semantic_passed_all') is True
    database = row.get('database_valid') is True
    http = row.get('http_errors')
    sockets = row.get('socket_errors')
    counters_known = (type(http) is int and http >= 0 and isinstance(sockets, dict)
                      and all(type(sockets.get(k)) is int and sockets[k] >= 0 for k in SOCKETS))
    complete_three = (row.get('trials_recorded') == 3
                      and status in ('measured', 'measured_with_errors', 'ineligible_reference'))
    stock_protocol = (protocol == 'stock-wrk-3x15s' and row.get('measurement_seconds') == 15
                      and row.get('warmup_seconds') == 2)
    details = {
        'sqlite_eligibility': 'PASS' if eligible is True else 'FAIL' if eligible is False else 'UNVERIFIED',
        'official_api_42': 'PASS' if official_api else 'FAIL' if api_counts_failed or row.get('official_passed_all') is False else 'UNVERIFIED',
        'dynamic_live_data': 'PASS' if dynamic else 'FAIL' if row.get('semantic_passed_all') is False else 'UNVERIFIED',
        'committed_database': 'PASS' if database else 'FAIL' if status == 'database_check_failed' or row.get('database_valid') is False else 'UNVERIFIED',
        'three_completed_stock_trials': 'PASS' if complete_three and stock_protocol else 'UNVERIFIED',
        'zero_measured_errors': ('PASS' if http == 0 and not any(sockets.values()) else 'FAIL') if counters_known else 'UNVERIFIED',
        'runtime_budget': budget_status,
        'build_start_contract': 'FAIL' if status == 'source_missing_start' else 'PASS' if complete_three else 'UNVERIFIED',
        'runtime_startup': 'FAIL' if status == 'runtime_failed' else 'PASS' if complete_three else 'UNVERIFIED',
    }

    def result(value, reason):
        return {
            'requirements_status': value,
            'requirements_reason': reason,
            'benchmark_requirements_met': True if value == 'PASS' else False if value in ('FAIL', 'DIFFERENT_PROTOCOL') else None,
            'requirements_scope': LOCAL_SCOPE,
            'requirements_detail': details,
            'runtime_budget_reason': budget_reason,
            'official_conditions_status': 'UNVERIFIED',
            'official_conditions_reason': OFFICIAL_REASON,
        }

    if protocol == 'monotonic-wrk-10x45s' or row.get('measurement_seconds') == 45:
        return result('DIFFERENT_PROTOCOL', '10×45s with corrected wrk; not the stock 3×15s comparison. Stable ≥5% target UNMET.')
    if eligible is False or status == 'ineligible_reference':
        return result('FAIL', 'Custom memory store instead of SQLite; fails the local SQLite requirement.')
    if status == 'database_check_failed' or row.get('database_valid') is False:
        if str(row.get('case_id')) == '79' or 'uncommitted' in str(row.get('reason', '')).lower():
            return result('FAIL', 'Acknowledged writes were not committed; database validation failed.')
        return result('FAIL', 'Committed-write or SQLite integrity validation failed.')
    if status == 'runtime_failed':
        return result('FAIL', 'Local server startup failed before health/API readiness; official-host behavior unverified.')
    if status == 'unsupported_architecture':
        return result('UNVERIFIED', 'No native ARM64 execution; behavior on the official x86-64 host remains unverified.')
    if status == 'source_missing_start':
        return result('FAIL', 'Required build/start scripts are missing; the local submission contract is not met.')
    if status in ('test_failed', 'semantic_test_failed') or row.get('semantic_passed_all') is False:
        return result('FAIL', 'Local official API assertions or dynamic live-data checks failed.')
    if api_counts_failed or row.get('official_passed_all') is False:
        return result('FAIL', 'Local official API assertions did not pass 42/42.')
    if counters_known and (http or any(sockets.values())):
        causes = []
        if http:
            causes.append(f'{http:,} HTTP errors')
        for key in SOCKETS:
            if sockets[key]:
                causes.append(f"{sockets[key]:,} " + ('wrk timeouts' if key == 'timeout' else 'socket ' + key + ' errors'))
        return result('FAIL', '; '.join(causes) + ' across the local measured trials.')
    if status == 'measured_with_errors':
        return result('FAIL', 'The retained local measurement is marked with errors; zero-error qualification was not met.')
    if budget_status == 'FAIL':
        return result('FAIL', budget_reason)
    if not stock_protocol:
        if ((protocol is not None and protocol != 'stock-wrk-3x15s')
                or (row.get('measurement_seconds') is not None and row['measurement_seconds'] != 15)
                or (row.get('warmup_seconds') is not None and row['warmup_seconds'] != 2)):
            return result('DIFFERENT_PROTOCOL', 'Recorded protocol differs from stock wrk, three 15s trials and a 2s warmup.')
        return result('UNVERIFIED', 'Missing local protocol, 15s measurement or 2s warmup evidence.')
    missing = []
    if eligible is not True:
        missing.append('SQLite eligibility')
    if not official_api:
        missing.append('42/42 API assertions')
    if not dynamic:
        missing.append('dynamic live-data checks')
    if not database:
        missing.append('committed database validation')
    if not complete_three:
        missing.append('three completed trials')
    if not counters_known:
        missing.append('complete error counters')
    if budget_status != 'PASS':
        missing.append('server resource limits')
    if missing:
        return result('UNVERIFIED', 'Missing local evidence: ' + ', '.join(missing) + '.')
    return result('PASS', 'Local 42/42 + live-data/database checks; three stock 15s trials, zero errors; one CPU / 2 GiB / no swap.')
