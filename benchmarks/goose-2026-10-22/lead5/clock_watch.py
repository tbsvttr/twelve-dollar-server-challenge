"""Observe CLOCK_REALTIME changes against monotonic time; never modify clocks.

Print JSONL start, confirmed jumps and a final summary. Ordinary samples remain
in counters only. Run on the separately allocated monitor CPU, for example:
  python3 /evidence/clock_watch.py --interval-ms 50 --duration-s 1200
SIGTERM/SIGINT emits the summary and exits. This does not alter wrk counters.
"""
import argparse
import datetime as dt
import json
import signal
import time


def sample():
    before = time.monotonic_ns()
    wall = time.time_ns()
    after = time.monotonic_ns()
    mono = (before + after) // 2
    return dict(monotonic_ns=mono, wall_ns=wall, offset_ns=wall - mono,
                uncertainty_ns=(after - before + 1) // 2)


def confirmed_change(previous, current, threshold):
    """A clock-call scheduling gap cannot masquerade as a confirmed step."""
    delta = current['offset_ns'] - previous['offset_ns']
    lower_bound = abs(delta) - current['uncertainty_ns'] - previous['uncertainty_ns']
    return (delta, lower_bound) if lower_bound > threshold else None


def emit(value):
    print(json.dumps(value, separators=(',', ':')), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--interval-ms', type=float, default=50)
    parser.add_argument('--threshold-ms', type=float, default=1)
    parser.add_argument('--duration-s', type=float, default=0, help='Zero means until SIGTERM/SIGINT')
    args = parser.parse_args()
    if not 50 <= args.interval_ms <= 100 or args.threshold_ms <= 0 or args.duration_s < 0:
        parser.error('Use interval 50–100 ms, positive threshold, and nonnegative duration')
    interval = int(args.interval_ms * 1000000)
    threshold = int(args.threshold_ms * 1000000)
    stopped = [None]
    def stop(number, _frame):
        stopped[0] = signal.Signals(number).name
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    first = sample()
    previous = first if first['uncertainty_ns'] <= threshold // 4 else None
    last = first
    started_cpu = time.process_time_ns()
    stats = dict(samples=1, reliable_samples=int(previous is not None), uncertain_samples=int(previous is None),
                 positive_jumps=0, negative_jumps=0,
                 min_offset_ns=first['offset_ns'] if previous else None,
                 max_offset_ns=first['offset_ns'] if previous else None,
                 max_call_uncertainty_ns=first['uncertainty_ns'], max_sample_gap_ns=0,
                 max_confirmed_change_ns=0, max_reliable_adjacent_delta_ns=0)
    emit(dict(event='clock-watch-start', utc=dt.datetime.fromtimestamp(first['wall_ns'] / 1e9, dt.timezone.utc).isoformat(),
              interval_ms=args.interval_ms, threshold_ms=args.threshold_ms, duration_limit_s=args.duration_s,
              clock_pair='time.time_ns (CLOCK_REALTIME) minus time.monotonic_ns',
              detection='Changes must exceed threshold plus both clock-call uncertainty bounds; pairs wider than threshold/4 are skipped',
              limitations='Does not observe changes smaller than threshold, steps that reverse between samples, or per-vCPU clock differences on other CPUs',
              sample=first))
    deadline = first['monotonic_ns'] + interval
    while not stopped[0]:
        remaining = deadline - time.monotonic_ns()
        if remaining > 0:
            time.sleep(remaining / 1e9)
        current = sample()
        stats['samples'] += 1
        stats['max_sample_gap_ns'] = max(stats['max_sample_gap_ns'], current['monotonic_ns'] - last['monotonic_ns'])
        stats['max_call_uncertainty_ns'] = max(stats['max_call_uncertainty_ns'], current['uncertainty_ns'])
        last = current
        if current['uncertainty_ns'] <= threshold // 4:
            stats['reliable_samples'] += 1
            stats['min_offset_ns'] = min(stats['min_offset_ns'], current['offset_ns']) if stats['min_offset_ns'] is not None else current['offset_ns']
            stats['max_offset_ns'] = max(stats['max_offset_ns'], current['offset_ns']) if stats['max_offset_ns'] is not None else current['offset_ns']
            if previous:
                stats['max_reliable_adjacent_delta_ns'] = max(stats['max_reliable_adjacent_delta_ns'],
                    abs(current['offset_ns'] - previous['offset_ns']))
            change = confirmed_change(previous, current, threshold) if previous else None
            if change:
                delta, lower_bound = change
                stats['positive_jumps' if delta > 0 else 'negative_jumps'] += 1
                stats['max_confirmed_change_ns'] = max(stats['max_confirmed_change_ns'], abs(delta))
                emit(dict(event='wall-clock-jump', monotonic_s=current['monotonic_ns'] / 1e9,
                          delta_ns=delta, lower_bound_change_ns=lower_bound,
                          previous=previous, current=current))
            previous = current
        else:
            stats['uncertain_samples'] += 1
        if args.duration_s and current['monotonic_ns'] - first['monotonic_ns'] >= args.duration_s * 1e9:
            stopped[0] = 'duration'
        deadline = max(deadline + interval, current['monotonic_ns'] + interval)
    elapsed = (last['monotonic_ns'] - first['monotonic_ns']) / 1e9
    cpu = (time.process_time_ns() - started_cpu) / 1e9
    emit(dict(event='clock-watch-summary', reason=stopped[0], duration_s=elapsed, process_cpu_s=cpu,
              process_cpu_percent=100 * cpu / elapsed if elapsed else 0,
              start=first, end=last, stats=stats))


if __name__ == '__main__':
    main()
