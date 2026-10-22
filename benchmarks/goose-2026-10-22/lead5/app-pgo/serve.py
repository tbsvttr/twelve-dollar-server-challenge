"""Start one submission on a fresh database inside its restricted server container."""
import hashlib
import contextlib
import json
import os
import re
import select
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

ROOT = Path('/suite')
EVIDENCE = Path('/evidence')


def emit(value):
    print(json.dumps(value), flush=True)


def process_metrics(roots):
    processes = {}
    for directory in Path('/proc').iterdir():
        if not directory.name.isdigit():
            continue
        try:
            fields = (directory / 'stat').read_text().rsplit(')', 1)[1].split()
            status = dict(re.findall(r'^(VmRSS|VmHWM|Threads):\s+(\d+)',
                                     (directory / 'status').read_text(), re.M))
            ticks = os.sysconf('SC_CLK_TCK')
            cpu_self = (int(fields[11]) + int(fields[12])) / ticks
            cpu_waited = (int(fields[13]) + int(fields[14])) / ticks
            processes[int(directory.name)] = {
                'ppid': int(fields[1]),
                'cpu_s': cpu_self + cpu_waited,
                'cpu_self_s': cpu_self,
                'cpu_waited_children_s': cpu_waited,
                'rss_kib': int(status.get('VmRSS', 0)),
                'hwm_kib': int(status.get('VmHWM', 0)),
                'threads': int(status.get('Threads', 0)),
            }
        except (OSError, ValueError):
            continue
    selected = set(roots)
    while True:
        children = {pid for pid, value in processes.items() if value['ppid'] in selected}
        if children <= selected:
            break
        selected.update(children)
    chosen = {str(pid): processes[pid] for pid in sorted(selected) if pid in processes}
    return dict(monotonic=time.monotonic(), processes=chosen,
                **{key: sum(value[key] for value in chosen.values())
                   for key in ('cpu_s', 'cpu_self_s', 'cpu_waited_children_s', 'rss_kib', 'hwm_kib')})


def stop(process):
    if process is None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=3)


def nginx_config(directory, port):
    site = (EVIDENCE / 'bench/nginx.conf').read_text()
    site = site.replace('listen 80 default_server;', f'listen {port} default_server;')
    site = site.replace('/var/log/nginx/bench.access.log', str(directory / 'access.log'))
    site = site.replace('/var/log/nginx/bench.error.log', str(directory / 'error.log'))
    config = Path('/etc/nginx/nginx.conf').read_text()
    config = re.sub(r'(?m)^user\s+[^;]+;', '', config)
    config = re.sub(r'(?m)^worker_processes\s+[^;]+;', 'worker_processes 1;', config)
    config = re.sub(r'(?m)^pid\s+[^;]+;', f'pid {directory}/nginx.pid;', config)
    config = re.sub(r'(?m)^error_log\s+[^;]+;', f'error_log {directory}/master-error.log warn;', config)
    config = re.sub(r'worker_connections\s+[^;]+;', 'worker_connections 16384;', config)
    config = 'worker_rlimit_nofile 65535;\n' + config
    config = re.sub(r'include\s+/etc/nginx/sites-enabled/\*;', site, config)
    config = re.sub(r'include\s+/etc/nginx/conf\.d/\*\.conf;', '', config)
    config = config.replace('/var/log/nginx/access.log', str(directory / 'default-access.log'))
    temp_paths = '\n'.join(f'{kind}_temp_path {directory}/{kind};'
                           for kind in ('client_body', 'proxy', 'fastcgi', 'uwsgi', 'scgi'))
    config = config.replace('http {', 'http {\n' + temp_paths)
    path = directory / 'nginx.conf'
    path.write_text(config)
    return path


def interrupted(signum, _frame):
    raise InterruptedError(signum)


def main():
    case_id, port = sys.argv[1], int(sys.argv[2])
    rows = json.loads((EVIDENCE / 'manifest.json').read_text())
    row = next(row for row in rows if str(row.get('id', row['pr'])) == case_id)
    app = Path(row.get('source_dir', str(ROOT / 'sources' / f'pr{case_id}')))
    if not app.is_absolute():
        app = ROOT / app
    expected = json.loads((EVIDENCE / row['source_hashes']).read_text())
    mismatches = [name for name, digest in expected.items()
                  if not (app / name).is_file() or
                  hashlib.sha256((app / name).read_bytes()).hexdigest() != digest]
    if mismatches:
        raise RuntimeError('Pinned source mismatch: ' + ', '.join(mismatches))
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, interrupted)
    server = proxy = None
    log_path = Path('/tmp') / f'current-pr{case_id}-{port}.log'
    with tempfile.TemporaryDirectory(prefix=f'current-pr{case_id}-') as name:
        directory = Path(name)
        database = directory / 'feed.db'
        shutil.copyfile(EVIDENCE / 'seed/feed.db', database)
        # sqlite3's connection context manager commits but does not close.
        # An idle open handle prevents submissions from taking EXCLUSIVE WAL locks.
        with contextlib.closing(sqlite3.connect(database)) as connection:
            initial_posts = connection.execute('SELECT count(*) FROM posts').fetchone()[0]
        env = dict(os.environ, SQLITE_PATH=str(database), JWT_SECRET='twelve-dollar-challenge',
                   HOST='127.0.0.1', PORT=str(3000 if row.get('nginx') else port),
                   DOTNET_CLI_HOME='/home/bench', DOTNET_CLI_TELEMETRY_OPTOUT='1')
        with log_path.open('w+') as log:
            try:
                server = subprocess.Popen(['bash', str(app / 'start.sh')], cwd=app, env=env,
                                          stdout=log, stderr=log, start_new_session=True)
                if row.get('nginx'):
                    proxy = subprocess.Popen(['nginx', '-c', str(nginx_config(directory, port)),
                                              '-g', 'daemon off;'], stdout=log, stderr=log,
                                             start_new_session=True)
                deadline = time.monotonic() + 60
                while True:
                    if server.poll() is not None or (proxy and proxy.poll() is not None):
                        log.seek(0)
                        raise RuntimeError('Server exited: ' + log.read()[-8000:])
                    try:
                        with urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=1) as response:
                            health = json.load(response)
                        if health.get('status') == 'ok' and health.get('db') == 'ok':
                            break
                    except (OSError, ValueError, AttributeError):
                        pass
                    if time.monotonic() > deadline:
                        log.seek(0)
                        raise TimeoutError('Health timeout: ' + log.read()[-8000:])
                    time.sleep(.05)
                roots = [server.pid] + ([proxy.pid] if proxy else [])
                emit(dict(ready=True, roots=roots, port=port, log=str(log_path),
                          nginx=bool(row.get('nginx')), initial_post_count=initial_posts,
                          source_files_verified=len(expected), source_sha256=row['source_sha256'],
                          start_script=str(app / 'start.sh')))
                while True:
                    readable, _, _ = select.select([sys.stdin], [], [], 180)
                    if not readable:
                        raise TimeoutError('Controller silent for 180 seconds')
                    command = sys.stdin.readline().strip()
                    if command in ('measure', 'stop'):
                        if server.poll() is not None or (proxy and proxy.poll() is not None):
                            raise RuntimeError('Service process exited during workload')
                        emit(process_metrics(roots))
                        if command == 'stop':
                            break
                    elif not command:
                        break
                    else:
                        raise ValueError(command)
            finally:
                stop(proxy)
                stop(server)
            try:
                with contextlib.closing(sqlite3.connect(database, timeout=1)) as connection:
                    emit({'database_after': {
                        'initial_post_count': initial_posts,
                        'post_count': connection.execute('SELECT count(*) FROM posts').fetchone()[0],
                        'max_post_id': connection.execute('SELECT max(id) FROM posts').fetchone()[0],
                        'integrity': connection.execute('PRAGMA quick_check').fetchone()[0],
                    }})
            except sqlite3.Error as error:
                emit({'database_after_error': str(error)})


if __name__ == '__main__':
    main()
