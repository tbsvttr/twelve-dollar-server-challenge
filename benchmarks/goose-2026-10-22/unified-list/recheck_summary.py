"""Normalize every attempt in the explicitly requested complete stock recheck."""
import hashlib
import importlib.util
import json
from pathlib import Path

from conditions import classify
from render import common

HERE = Path(__file__).resolve().parent
GOOSE = HERE.parent
BATCH = GOOSE / 'recheck-3x15-2026-10-22'


def read(path):
    return json.loads(path.read_text())


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    helper = load('recheck_followup', GOOSE.parent / 'fixes-2026-10-22/analyze_followup.py')
    integration = load('recheck_integration', GOOSE / 'list-integration/integrate.py')
    integration.PUBLIC_GOOSE = '../goose-2026-10-22/' + BATCH.name + '/'
    manifest = read(BATCH / 'manifest.json')
    builds = read(BATCH / 'build-status.json')
    verification = read(BATCH / 'verification.json')
    measurements = read(BATCH / 'measurements.json')
    shared = read(BATCH / 'shared-sha256.json')
    assert len(verification) == 2 and len(measurements) == 6
    rows = []
    for candidate in manifest:
        case = str(candidate['id'])
        trials = [r for r in measurements if str(r['case_id']) == case]
        tests = [r for r in verification if str(r['case_id']) == case]
        assert len(tests) == 1 and len(trials) == 3
        assert sorted(r['trial'] for r in trials) == [1, 2, 3]
        role = 'current' if case == '143' else 'control'
        source = integration.new_row(helper, candidate, builds[case], verification,
                                     measurements, shared, BATCH, role)
        limits = {k: trials[0]['container_host_config'][k] for k in
                  ('CpusetCpus', 'NanoCpus', 'Memory', 'MemorySwap')}
        assert all(all(r['container_host_config'][k] == v for k, v in limits.items())
                   for r in tests + trials)
        assert limits == dict(CpusetCpus='0', NanoCpus=1000000000,
                              Memory=2147483648, MemorySwap=2147483648)
        source.update(container_host_config=limits, server_cpu_quota=1,
                      server_memory_bytes=2147483648, server_memory_swap_bytes=2147483648,
                      container_swap_available_bytes=0)
        row_id = ('current:143:' + BATCH.name if case == '143'
                  else 'control:' + BATCH.name + ':82')
        row = common(source, row_id, role)
        warmups = [helper.controller.parse_wrk(r['warmup_output']) for r in trials]
        row.update(warmup_http_errors=sum(r['http_errors'] for r in warmups),
                   warmup_socket_errors=sum(sum(r['socket_errors'].values()) for r in warmups),
                   raw_trials_ref=dict(path=integration.PUBLIC_GOOSE + 'measurements.json',
                       sha256=hashlib.sha256((BATCH / 'measurements.json').read_bytes()).hexdigest(),
                       case_id=case, trials=[1, 2, 3]),
                   previous_evidence_preserved=True)
        row.update(classify(row))
        rows.append(row)
    (HERE / 'recheck-rows.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps([dict(pr=r['pr'], status=r['requirements_status'],
                           successful_rps=r['successful_rps'], http_errors=r['http_errors'],
                           socket_errors=r['socket_errors']) for r in rows], indent=2))


if __name__ == '__main__':
    main()
