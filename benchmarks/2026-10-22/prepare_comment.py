"""Prepare the exact GitHub comparison-comment replacement, without posting."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('artifact_commit')
    args=parser.parse_args()
    assert len(args.artifact_commit)==40 and all(c in '0123456789abcdef' for c in args.artifact_commit)
    summary=json.loads((ROOT/'summary.json').read_text())
    assert summary['complete']
    base=f'https://github.com/tbsvttr/twelve-dollar-server-challenge/blob/{args.artifact_commit}/benchmarks/2026-10-22'
    lines=['**Updated comparison — 2026-10-22: fixed-submission rerun.**', '',
           f'[Full combined results and evidence]({base}/README.md) · [All 119 outcomes]({base}/report.md) · [CSV]({base}/comparison.csv) · [Filterable HTML (download)]({base}/comparison.html) · [Before/after table]({base}/before-after.csv) · [Independent audit]({base}/audit-final.json)', '',
           'Retried current pinned revisions of **#32, #92, #103, #123 (all three D servers), #127 and #132**, following the fixes reported in this thread. **Seven of the eight implementations now pass all 42 official API checks, dynamic round-trip checks, SQLite integrity/committed-write checks, and three error-free measured runs.** #132 replaces closed #120.', '',
           '| PR / implementation | Pinned source | API checks | Median successful req/s | Range, 3 runs | p99 ms | RSS MiB | Result |',
           '|---|---|---|---:|---:|---:|---:|---|']
    for row in sorted((r for r in summary['followup_rows'] if r['role']!='control'),key=lambda r:(r['pr'],r['case_id'])):
        link=f"[#{row['pr']}]({row['url']}) `{row['folder']}`"
        commit=f"[`{row['commit'][:12]}`]({row['source_url']})"
        if row['ranked']:
            metrics=[f"{row['successful_rps']:,.0f}",f"{row['rps_min']:,.0f}–{row['rps_max']:,.0f}",f"{row['p99_ms']:.3f}",f"{row['rss_mib']:,.2f}"]
            lines.append(f'| {link} | {commit} | 42/42 | '+ ' | '.join(metrics)+' | clean |')
        else:
            lines.append(f'| {link} | {commit} | not run | — | — | — | — | startup failed |')
    lines += ['', '**#127 still fails at startup:** `start.sh` invokes the package start command, which sets `SQLITE_PATH=./feed.db` and overrides the supplied fresh database path. That file does not exist, so SQLite exits with `SQLITE_CANTOPEN` before the health check. Its native SQLite binding loaded; the failure established here is the forced database path. '
              +f'[Exact diagnostic and source evidence]({base}/diagnostics-pr127.json). No application or launch-script edits were made to bypass this.', '',
              '**Conditions:** same native Linux ARM64 host/harness, one server CPU, 2 GiB RAM, no container swap, 65,535 FDs; separate load container, `wrk -t2 -c64`; three 15-second measurements after two-second warm-ups, fresh process/database each time. All **21 targeted trials plus three unchanged-control trials** completed with zero HTTP/socket errors. Native toolchain setup substitutions are disclosed in the evidence.', '',
              '**Combined table:** 119 implementation outcomes: **98 clean ranked, seven diagnostic/reference, 14 without a valid three-trial measurement**. The eight updated cases use October 22 data; **111 unaffected cases retain their October 20 revisions and measurements**, explicitly labelled by batch. This was a targeted rerun. Unchanged control #82 measured 105,569.55 versus 108,275.04 req/s (-2.50%); its old ranking result is retained, and no scores were rescaled. Cross-batch ordering and small differences remain subject to session variation.', '',
              '**Scope:** local saturation throughput, with latency/RAM/errors shown above; this does not determine the challenge’s official x86-64 five-minute k6 maximum-user score. '
              +f'[Previous October 20 report](https://github.com/tbsvttr/twelve-dollar-server-challenge/blob/{args.artifact_commit}/benchmarks/2026-10-20/report.md) retains the full original results and creator follow-up video reference.']
    body='\n'.join(lines)+'\n'
    assert len(body)<65536
    target=ROOT/'publication'
    (target/'issue-comment.md').write_text(body)
    (target/'issue-comment.json').write_text(json.dumps({'body':body},indent=2)+'\n')
    print(json.dumps({'characters':len(body),'sha256':hashlib.sha256(body.encode()).hexdigest()}))

if __name__=='__main__':main()
