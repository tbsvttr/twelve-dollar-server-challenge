"""Run the normal source build inside its externally imposed server budget."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

root = Path('/suite/sources/prgoose')
cgroup = Path('/sys/fs/cgroup')

def limits():
    return {name: (cgroup/name).read_text().strip() for name in
            ['cpu.max', 'memory.max', 'memory.swap.max', 'cpuset.cpus.effective']}

before = limits()
assert before['cpu.max'].split() == ['100000', '100000'], before
assert before['memory.max'] == str(2 * 1024**3), before
assert before['memory.swap.max'] == '0', before
if os.getuid() == 0:
    # Images from earlier builds contain root-owned generated artifacts. Start
    # clean, then perform every build/training operation as the normal user.
    for directory in ['.build', 'bin']:
        path = root/directory
        if path.exists():
            shutil.rmtree(path)
    os.chown(root, 1001, 1001)
    os.setgroups([])
    os.setgid(1001)
    os.setuid(1001)
started = time.monotonic()
result = subprocess.run(['bash', 'build.sh'], cwd=root)
proof = dict(exit_code=result.returncode, elapsed_seconds=time.monotonic()-started,
             build_uid=os.getuid(), clean_generated_directories=True,
             normal_build=True, sqlite_object_reuse=False, limits=before,
             memory_peak_bytes=int((cgroup/'memory.peak').read_text()),
             memory_events=(cgroup/'memory.events').read_text(),
             cpu_stat=(cgroup/'cpu.stat').read_text())
for name in ['bin/server', '.build/sqlite-pgo.o', '.build/app.c']:
    path = root/name
    if path.exists():
        proof[name] = dict(sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                           bytes=path.stat().st_size)
(root/'.build/resource-budget-build.json').write_text(json.dumps(proof, indent=2)+'\n')
print(json.dumps(proof, indent=2), flush=True)
raise SystemExit(result.returncode)
