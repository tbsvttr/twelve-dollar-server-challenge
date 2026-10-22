"""Describe every discovery attempt; discovery never proves the target."""
import argparse
import json
import math
from pathlib import Path
import statistics


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('batch', type=Path)
    args = ap.parse_args()
    root = args.batch
    rows = json.loads((root/'measurements.json').read_text())
    result = {'purpose': 'discovery only; all attempts retained', 'cases': {}}
    for case in dict.fromkeys(row['case_id'] for row in rows):
        attempts = [row for row in rows if row['case_id'] == case]
        completed = [row for row in attempts if row.get('completed')]
        entry = {
            'attempts': len(attempts),
            'rps': [{'trial': row['trial'], 'rps': row.get('successful_rps'),
                     'http_errors': row.get('http_errors'), 'socket_errors': row.get('socket_errors'),
                     'error': row.get('error'), 'database_valid': row.get('database_valid')}
                    for row in attempts],
            'median_rps_all_completed_attempts': statistics.median(row['successful_rps'] for row in completed) if completed else None,
            'median_p99_ms_all_completed_attempts': statistics.median(row['p99_ms'] for row in completed) if completed else None,
            'median_rss_mib': statistics.median(row['rss_mib'] for row in completed) if completed else None,
        }
        for control in ('82', 'baseline'):
            ratios = []
            for row in completed:
                partner = next((other for other in rows if other['case_id'] == control and
                                other['trial'] == row['trial'] and other.get('completed')), None)
                if partner is not None:
                    ratios.append(row['successful_rps']/partner['successful_rps'])
            if ratios:
                entry['paired_geomean_ratio_to_'+control] = math.exp(statistics.mean(map(math.log, ratios)))
        result['cases'][case] = entry
    (root/'discovery-summary.json').write_text(json.dumps(result, indent=2)+'\n')
    for case, entry in result['cases'].items():
        print(case, json.dumps(entry, separators=(',', ':')))


if __name__ == '__main__':
    main()
