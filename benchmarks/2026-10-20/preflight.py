"""One short end-to-end diagnostic, kept separate from ranked measurements."""
import fcntl
import hashlib
import json
import os
import subprocess
import time

from run import ROOT, command, image_id, parse_wrk, receive, save


def main():
    lock = (ROOT / 'controller.lock').open('a')
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    server_id = image_id('twelve-current-pr4:2026-10-20')
    load_id = image_id('twelve-unified:2026-10-07')
    suffix = str(os.getpid())
    server, load = 'twelve-current-preflight-s-' + suffix, 'twelve-current-preflight-l-' + suffix
    evidence = dict(diagnostic_only=True, excluded_from_measurements_and_ranking=True,
                    recorded_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                    case_id='4', image_id=server_id, load_image_id=load_id,
                    configuration=dict(threads=2, connections=64, warmup_seconds=1, measurement_seconds=1),
                    shared_hashes={name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                                   for name in json.loads((ROOT / 'shared-sha256.json').read_text())})
    process = None
    try:
        command(['docker', 'run', '-d', '--name', server, '--platform', 'linux/arm64',
                 '--cpuset-cpus', '0', '--cpus', '1', '--memory', '2g', '--memory-swap', '2g',
                 '--ulimit', 'nofile=65535:65535', '--security-opt',
                 'seccomp=' + str(ROOT / 'seccomp-io-uring.json'), '--mount',
                 f'type=bind,src={ROOT},dst=/evidence,readonly', server_id, 'sleep', 'infinity'])
        command(['docker', 'run', '-d', '--name', load, '--platform', 'linux/arm64',
                 '--cpuset-cpus', '1,2', '--cpus', '2', '--memory', '2g', '--memory-swap', '2g',
                 '--network', 'container:' + server, '--mount',
                 f'type=bind,src={ROOT},dst=/evidence,readonly', load_id, 'sleep', 'infinity'])
        process = subprocess.Popen(['docker', 'exec', '-i', '--user', 'bench', server,
                                    'python3', '/evidence/serve.py', '4', '24000'],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, bufsize=1)
        evidence['service'] = receive(process)
        assert evidence['service'].get('ready')
        wrk = ['docker', 'exec', '-w', '/evidence', load, 'wrk', '-t2', '-c64', '--latency',
               '-s', '/evidence/mixed.lua', '-d1s', 'http://127.0.0.1:24000/feed']
        evidence['warmup_output'] = command(wrk, timeout=30).stdout
        process.stdin.write('measure\n')
        process.stdin.flush()
        evidence['before'] = receive(process, 15)
        measured = command(wrk, timeout=30)
        evidence['output'], evidence['stderr'] = measured.stdout, measured.stderr
        evidence.update(parse_wrk(measured.stdout))
        process.stdin.write('stop\n')
        process.stdin.flush()
        evidence['after'] = receive(process, 15)
        tail, error = process.communicate(timeout=30)
        evidence['final'] = [json.loads(line) for line in tail.splitlines() if line.strip()]
        assert process.returncode == 0, error
        database = next(value['database_after'] for value in evidence['final'] if 'database_after' in value)
        evidence['database_valid'] = database['integrity'] == 'ok' and database['post_count'] > database['initial_post_count']
        evidence['checks'] = dict(
            response_count_positive=evidence['requests'] > 0,
            no_http_errors=evidence['http_errors'] == 0,
            no_socket_errors=not any(evidence['socket_errors'].values()),
            p95_histogram_parsed=0 <= evidence['p50_ms'] <= evidence['p95_ms'] <= evidence['p99_ms'],
            service_rss_sampled=evidence['after']['rss_kib'] > 0,
            service_cpu_sampled=evidence['after']['cpu_s'] > evidence['before']['cpu_s'],
            database_writes_and_integrity=evidence['database_valid'])
        evidence['passed_all'] = all(evidence['checks'].values())
        assert evidence['passed_all'], evidence['checks']
    except Exception as error:
        evidence.update(error=str(error), passed_all=False)
        raise
    finally:
        if process is not None and process.poll() is None:
            try:
                process.communicate(input='stop\n', timeout=20)
            except (subprocess.TimeoutExpired, BrokenPipeError):
                process.kill()
                process.communicate(timeout=5)
        subprocess.run(['docker', 'cp', server + ':/tmp/current-pr4-24000.log',
                        str(ROOT / 'server-logs/preflight-4.log')], capture_output=True, timeout=20)
        subprocess.run(['docker', 'rm', '-f', load, server], capture_output=True, timeout=30)
        save(ROOT / 'preflight.json', evidence)
        (ROOT / 'logs/preflight-wrk.log').write_text(evidence.get('output', '') + evidence.get('stderr', ''))
    print('Preflight passed; diagnostic data kept separate from measurements.json.')


if __name__ == '__main__':
    main()
