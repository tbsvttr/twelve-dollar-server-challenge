"""Diagnose acknowledged writes using an independent reader before shutdown."""
import fcntl
import json
import os
import subprocess

from run import ROOT, command, image_id, receive, save

READER = r'''
import contextlib,json,pathlib,sqlite3,sys,urllib.request
pid=sys.argv[1]
database=next(value.split(b'=',1)[1].decode() for value in pathlib.Path('/proc/'+pid+'/environ').read_bytes().split(b'\0') if value.startswith(b'SQLITE_PATH='))
with contextlib.closing(sqlite3.connect('file:'+database+'?mode=ro',uri=True)) as connection:
 count,maximum=connection.execute('select count(*),max(id) from posts').fetchone()
with urllib.request.urlopen('http://127.0.0.1:24000/feed',timeout=10) as response:
 feed=json.load(response)
print(json.dumps(dict(database_path=database,independent_post_count=count,independent_max_post_id=maximum,api_top_post_id=feed['posts'][0]['id'])))
'''


def main():
    lock = (ROOT / 'controller.lock').open('a')
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    image = image_id('twelve-current-pr79:2026-10-20')
    name = 'twelve-current-durability79-' + str(os.getpid())
    result = dict(diagnostic_only=True, case_id='79', image_id=image)
    process = None
    try:
        command(['docker', 'run', '-d', '--name', name, '--platform', 'linux/arm64',
                 '--cpuset-cpus', '0', '--cpus', '1', '--memory', '2g', '--memory-swap', '2g',
                 '--security-opt', 'seccomp=' + str(ROOT / 'seccomp-io-uring.json'),
                 '--mount', f'type=bind,src={ROOT},dst=/evidence,readonly', image, 'sleep', 'infinity'])
        process = subprocess.Popen(['docker', 'exec', '-i', '--user', 'bench', name,
                                    'python3', '/evidence/serve.py', '79', '24000'],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, bufsize=1)
        result['service'] = receive(process)
        root = str(result['service']['roots'][0])
        reader = ['docker', 'exec', '--user', 'bench', name, 'python3', '-c', READER, root]
        result['before'] = json.loads(command(reader).stdout)
        result['semantic'] = json.loads(command(['docker', 'exec', '--user', 'bench', name,
                                                'python3', '/evidence/semantic.py',
                                                'http://127.0.0.1:24000']).stdout)
        result['after_acknowledged_write_before_shutdown'] = json.loads(command(reader).stdout)
        process.stdin.write('stop\n')
        process.stdin.flush()
        result['metrics'] = receive(process, 15)
        tail, error = process.communicate(timeout=30)
        assert process.returncode == 0, error
        result['final'] = [json.loads(line) for line in tail.splitlines() if line.strip()]
        after = result['after_acknowledged_write_before_shutdown']
        result['uncommitted_write_confirmed'] = (
            result['semantic']['passed_all'] and
            after['api_top_post_id'] > result['before']['api_top_post_id'] and
            after['independent_post_count'] == result['before']['independent_post_count'] and
            after['independent_max_post_id'] < after['api_top_post_id'])
        assert result['uncommitted_write_confirmed'], result
    finally:
        if process is not None and process.poll() is None:
            try:
                process.communicate(input='stop\n', timeout=20)
            except (subprocess.TimeoutExpired, BrokenPipeError):
                process.kill()
                process.communicate(timeout=5)
        subprocess.run(['docker', 'rm', '-f', name], capture_output=True, timeout=30)
        save(ROOT / 'durability-pr79.json', result)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
