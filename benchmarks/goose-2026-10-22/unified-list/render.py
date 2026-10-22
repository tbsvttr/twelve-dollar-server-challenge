#!/usr/bin/env python3
"""Render one shared table of current, historical, control and confirmation rows.

Reads retained evidence only; writes rows.json, comparison.csv, comparison.html
and renderer-proof.json in this directory. No source, benchmarks or publication.
"""
import argparse
import collections
import copy
import csv
import hashlib
import json
from pathlib import Path


HERE = Path(__file__).resolve().parent
GOOSE = HERE.parent
PUBLIC = Path('/private/tmp/twelve-goose-results-20261022/benchmarks')
SUMMARY = PUBLIC / '2026-10-22/summary.json'
ADDITION = GOOSE / 'publication-additive-draft/goose-addition.json'
HOLDOUT = GOOSE / 'lead5/holdout-hmac'
ARCHIVE_COMMIT = '643a55e26853341feac6fbcb168ad4c9a909ee9d'
SOCKETS = ('connect', 'read', 'write', 'timeout')
STOCK = 'stock-wrk-3x15s'
MONOTONIC = 'monotonic-wrk-10x45s'


def read(path):
    return json.loads(path.read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def primary_evidence(source):
    paths = source.get('evidence') or []
    if isinstance(paths, str):
        paths = [paths]
    for path in paths:
        if path.endswith('/measurements.json') or path == 'measurements.json':
            return path
    return (paths[0] if paths else source.get('verification_log') or source.get('build_log'))


def common(source, row_id, role):
    """Normalization adds display aliases; source_record remains byte-value exact."""
    row = copy.deepcopy(source)
    row['source_record'] = copy.deepcopy(source)
    row['source_role'] = source.get('role')
    row['source_rank'] = source.get('rank')
    row.update(row_id=row_id, role=role,
               rank=source.get('rank') if role == 'current' else None,
               measurement_batch=source.get('measurement_batch', source.get('batch')),
               protocol=STOCK, protocol_label='stock wrk · 3×15s · 2s warmup · 2t/64c',
               measurement_seconds=15, warmup_seconds=2,
               pr_url=source.get('url', source.get('pr_url')),
               label=source.get('folder') or source.get('label'),
               evidence_url=primary_evidence(source),
               warmup_http_errors=source.get('warmup_http_errors'),
               warmup_socket_errors=source.get('warmup_socket_errors'))
    if role != 'current':
        row['ranked'] = False
    return row


def build_rows(summary):
    rows = [common(record, 'current:' + record['case_id'], 'current') for record in summary['rows']]
    history = [item['before'] for item in summary['before_after']
               if item['before'].get('successful_rps') is not None]
    rows += [common(record, f"historical:{record['case_id']}:{record['commit']}", 'historical') for record in history]
    controls = [r for r in summary['followup_rows'] if r.get('role') == 'control'] + summary['additional_controls']
    rows += [common(record, f"control:{record['batch']}:{record['case_id']}", 'control') for record in controls]
    addition = read(ADDITION)
    long_raw = read(HOLDOUT / 'measurements.json')
    long_summary = read(HOLDOUT / 'holdout-summary.json')
    for record in addition['submission_additions'] + addition['reference_controls']:
        case = record['case_id']
        row = common(record, 'confirmation:' + case, 'confirmation')
        trials = [trial for trial in long_raw if trial['case_id'] == case]
        assert len(trials) == 10 and sorted(r['trial'] for r in trials) == list(range(1, 11))
        assert all(r['http_errors'] == 0 and not any(r['socket_errors'].values()) for r in trials)
        row.update(protocol=MONOTONIC,
                   protocol_label='monotonic wrk · 10×45s · 2s warmup · 2t/64c',
                   measurement_seconds=45, warmup_seconds=2, trials_recorded=10,
                   status='measured; target UNMET' if case == 'goose' else 'measured reference',
                   confirmation_role='candidate' if case == 'goose' else 'matched control',
                   target_outcome='UNMET',
                   measurement_date='2026-10-22',
                   pr=143 if case == 'goose' else 82 if case == '82' else None,
                   pr_url='https://github.com/arjaythedev/twelve-dollar-server-challenge/pull/143' if case == 'goose' else record.get('pr_url'),
                   rps_min=record['successful_rps_min'], rps_max=record['successful_rps_max'],
                   http_errors=record['measured_http_errors'],
                   socket_errors={key: sum(r['socket_errors'][key] for r in trials) for key in SOCKETS},
                   evidence_url='../goose-2026-10-22/lead5/holdout-hmac/measurements.json',
                   tests_passed=42, tests_failed=0,
                   source_url=f'https://github.com/tbsvttr/twelve-dollar-server-challenge/tree/{ARCHIVE_COMMIT}/benchmarks/goose-2026-10-22/lead5/holdout-hmac/sources/pr{case}',
                   reason='Separate corrected-driver confirmation; stable ≥5% target UNMET. Not part of the three-trial clean ranking.',
                   raw_trials_ref=dict(path='../goose-2026-10-22/lead5/holdout-hmac/measurements.json',
                       sha256=sha(HOLDOUT / 'measurements.json'), case_id=case,
                       trials=list(range(1, 11))),
                   summary_ref=dict(path='../goose-2026-10-22/lead5/holdout-hmac/holdout-summary.json',
                       sha256=sha(HOLDOUT / 'holdout-summary.json')))
        assert long_summary['identities'][case]['source_sha256'] == row['source_sha256']
        rows.append(row)
    rows.sort(key=lambda row: (row.get('successful_rps') is None,
                              -(row.get('successful_rps') or 0), row['row_id']))
    assert len(rows) == len({row['row_id'] for row in rows}) == 127
    assert collections.Counter(row['role'] for row in rows) == dict(current=120, historical=2, control=2, confirmation=3)
    assert sum(row.get('rank') is not None for row in rows) == 98
    return rows


FIELDS = ['row_id', 'rank', 'pr', 'case_id', 'label', 'role', 'confirmation_role', 'status',
          'measurement_batch', 'measurement_date', 'protocol', 'protocol_label',
          'measurement_seconds', 'warmup_seconds', 'trials_recorded',
          'successful_rps', 'rps_min', 'rps_max', 'p50_ms', 'p95_ms', 'p99_ms', 'rss_mib', 'cpu_percent',
          'http_errors', 'socket_connect', 'socket_read', 'socket_write', 'socket_timeout',
          'warmup_http_errors', 'warmup_socket_errors', 'tests_passed', 'tests_failed',
          'app_loc', 'own_loc', 'reason', 'target_outcome', 'commit', 'source_sha256',
          'image_id', 'binary_sha256', 'source_url', 'pr_url', 'evidence_url']


def csv_rows(rows):
    with (HERE / 'comparison.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=FIELDS, extrasaction='ignore')
        writer.writeheader()
        for row in rows:
            flat = dict(row)
            for key in SOCKETS:
                flat['socket_' + key] = (row.get('socket_errors') or {}).get(key)
            writer.writerow({key: json.dumps(value, sort_keys=True) if isinstance(value, (dict, list)) else value
                             for key, value in flat.items() if key in FIELDS})


def html(rows):
    data = [{key: value for key, value in row.items() if key != 'source_record'} for row in rows]
    encoded = json.dumps(data, ensure_ascii=False).replace('<', '\\u003c')
    headers = ['PR / pinned source', 'Role / status / checks', 'Batch / protocol',
               'Req/s (min–max)', 'p95 / p99 ms', 'RSS MiB / CPU %',
               'HTTP; C/R/W/T (warmup)', 'App / Own LOC', 'Evidence / reason']
    return '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>All measurements — one comparison table</title><style>
body{font:14px system-ui,sans-serif;margin:1.5rem;color:#172b36;background:#f7fafc}h1{font-size:1.6rem}p{max-width:110ch;line-height:1.5}a{color:#075c8b}input,select,button{font:inherit;padding:.45rem;margin:0 .6rem .7rem 0;border:1px solid #a9bcc7;border-radius:4px}table{border-collapse:collapse;background:#fff;width:100%}th,td{text-align:left;padding:.6rem;border-bottom:1px solid #dbe4ea;vertical-align:top}th{background:#e8f1f5;position:sticky;top:0;white-space:nowrap}td{font-variant-numeric:tabular-nums}td:first-child,td:last-child{min-width:15rem}small{display:block;color:#4c6270;font-size:.85em}code{overflow-wrap:anywhere}.wrap{overflow:auto}.reference{background:#fffaf0}#count{font-weight:600}
</style><h1>All measurements — one comparison table</h1>
<p>127 rows: 120 current outcomes, two previous measured revisions, two separate short-run controls and three long-confirmation medians. Every measurement is placed by recorded throughput with role, status and errors alongside it. Original source and protocol remain explicit; the shared sort does not pool batches. Stock wrk 3×15-second ranking runs and corrected-driver 10×45-second confirmation runs are separate protocols. The stable ≥5% confirmation target remains <strong>UNMET</strong>.</p>
<p>Native Linux ARM64 on the local Mac/Docker host, one server CPU quota and 2 GiB RAM with no swap. These are local saturation measurements, not official x86-64 k6 user capacity. <a href="comparison.csv">CSV</a> · <a href="comparison-rows.json">Canonical row data</a> · <a href="report.md">Report and evidence</a></p>
<input id="search" aria-label="Search" placeholder="Search PR, language, source or reason"><select id="protocol"><option value="">All protocols</option></select><select id="batch"><option value="">All batches</option></select><select id="status"><option value="">All statuses</option></select><select id="role"><option value="">All roles</option></select><select id="sort"><option value="successful_rps">Successful req/s descending</option><option value="rss_mib">RSS ascending</option><option value="p99_ms">p99 ascending</option><option value="pr">PR ascending</option></select><span id="count"></span><div class="wrap"><table><thead><tr>''' + ''.join('<th>' + value + '</th>' for value in headers) + '''</tr></thead><tbody></tbody></table></div><script>
const rows=''' + encoded + ''';
const $=id=>document.getElementById(id),body=document.querySelector('tbody');
function batchLabel(value){return {'current-2026-10-20':'20 Oct','fixes-2026-10-22':'22 Oct · fixes','ranking-3x15-2026-10-22':'22 Oct · Goose','goose-hmac-2026-10-22-10x45s-monotonic':'22 Oct · confirmation'}[value]||value}
function protocolLabel(value){return value==='stock-wrk-3x15s'?'stock 3×15s':value==='monotonic-wrk-10x45s'?'mono 10×45s':value}
function statusLabel(value){return {'measured':'Clean','measured_with_errors':'Errors','ineligible_reference':'Non-SQLite reference','unsupported_architecture':'ARM64 unsupported','database_check_failed':'Database check failed','source_missing_start':'Missing start script','runtime_failed':'Startup failed','test_failed':'API checks failed','semantic_test_failed':'Semantic checks failed','build_failed':'Build failed','measured; target UNMET':'Target UNMET','measured reference':'Clean reference'}[value]||value}
const selects=[['protocol','protocol'],['batch','measurement_batch'],['status','status'],['role','role']];
for(const[id,key]of selects)for(const value of [...new Set(rows.map(r=>r[key]).filter(Boolean))].sort()){const o=document.createElement('option');o.value=value;o.textContent=id==='batch'?batchLabel(value):id==='protocol'?protocolLabel(value):id==='status'?statusLabel(value):value;o.title=value;$(id).append(o)}
function n(v,d=2){return typeof v==='number'?v.toLocaleString(undefined,{maximumFractionDigits:d}):'—'}
function plain(node,value,small=false){const e=document.createElement(small?'small':'span');e.textContent=value==null?'—':String(value);node.append(e);return e}
function link(node,label,url){if(!url)return plain(node,label);const a=document.createElement('a');a.href=url;a.textContent=label;node.append(a);return a}
function add(row){const tr=document.createElement('tr');if(row.role!=='current')tr.className='reference';const td=()=>{const e=document.createElement('td');tr.append(e);return e};
let e=td();link(e,(row.pr?'#'+row.pr+' ':'')+(row.label||row.case_id),row.pr_url||row.source_url);const revision=row.commit||row.source_sha256;const s=document.createElement('small');link(s,(revision||'').slice(0,12),row.source_url);s.title=revision||'';e.append(s);
e=td();plain(e,row.role+(row.confirmation_role?' · '+row.confirmation_role:''));plain(e,statusLabel(row.status),true).title=row.status;plain(e,row.tests_passed==null?'checks not run':row.tests_passed+'/42 checks',true);
e=td();plain(e,batchLabel(row.measurement_batch)).title=row.measurement_batch;plain(e,protocolLabel(row.protocol),true).title=row.protocol_label;
e=td();plain(e,n(row.successful_rps));plain(e,n(row.rps_min)+'–'+n(row.rps_max),true);
plain(td(),n(row.p95_ms,3)+' / '+n(row.p99_ms,3));plain(td(),n(row.rss_mib)+' / '+n(row.cpu_percent));
e=td();const errors=row.socket_errors;plain(e,n(row.http_errors,0)+'; '+['connect','read','write','timeout'].map(k=>n(errors&&errors[k],0)).join('/'));if(row.warmup_http_errors!=null&&row.warmup_socket_errors!=null)plain(e,'warmup '+row.warmup_http_errors+' / '+row.warmup_socket_errors,true);
plain(td(),n(row.app_loc,0)+' / '+n(row.own_loc,0));e=td();link(e,'evidence',row.evidence_url);if(row.reason)plain(e,row.reason,true);body.append(tr)}
function draw(){const query=$('search').value.trim().toLowerCase(),numbered=/^#?([0-9]+)$/.exec(query);let shown=rows.filter(r=>selects.every(([id,key])=>!$(id).value||r[key]===$(id).value)&&(!query||(numbered?String(r.pr)===numbered[1]:[r.label,r.case_id,r.source_sha256,r.commit,r.reason].some(v=>String(v||'').toLowerCase().includes(query)))));const key=$('sort').value;shown.sort((a,b)=>{const x=a[key],y=b[key];if(x==null)return y==null?a.row_id.localeCompare(b.row_id):1;if(y==null)return-1;return(key==='successful_rps'?y-x:x-y)||a.row_id.localeCompare(b.row_id)});body.replaceChildren();for(const row of shown)add(row);$('count').textContent=shown.length+' of '+rows.length+' rows'}
$('search').addEventListener('input',draw);for(const[id]of selects)$(id).addEventListener('change',draw);$('sort').addEventListener('change',draw);draw();
</script></html>'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--summary', type=Path, default=SUMMARY)
    parser.add_argument('--html-only', action='store_true', help='Preserve canonical JSON/CSV and regenerate HTML plus its proof only.')
    args = parser.parse_args()
    summary = read(args.summary)
    assert len(summary['rows']) == 120 and summary['counts']['ranked'] == 98
    rows = read(HERE / 'rows.json') if args.html_only else build_rows(summary)
    if not args.html_only:
        save(HERE / 'rows.json', rows)
        csv_rows(rows)
    (HERE / 'comparison.html').write_text(html(rows))
    save(HERE / 'renderer-proof.json', dict(
        row_count=len(rows), roles=dict(collections.Counter(r['role'] for r in rows)),
        current_ranked=98, default_sort='successful_rps descending; unmeasured last',
        source_summary_sha256=sha(args.summary), source_addition_sha256=sha(ADDITION),
        long_raw_sha256=sha(HOLDOUT / 'measurements.json'),
        generator_sha256=sha(Path(__file__)),
        outputs={p.name:sha(p) for p in (HERE/'rows.json', HERE/'comparison.csv', HERE/'comparison.html')}))
    print(json.dumps({'rows':len(rows),'roles':dict(collections.Counter(r['role'] for r in rows)),
                      'current_ranked':98,'rows_file':str(HERE/'rows.json')}))


if __name__ == '__main__':
    main()
