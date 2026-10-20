"""Read installed native tools and detect temporary nproc shims in root images."""
import concurrent.futures
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT / 'compiler-observations-1-40.json'

PROBE = r'''
import json,os,pathlib,shutil,subprocess,sys
key,folder=sys.argv[1:]
os.environ.update(PATH='/opt/twelve-rust/cargo/bin:/opt/twelve-go-1.27.1/bin:/opt/ruby/bin:/usr/local/bin:/usr/bin:/bin', RUSTUP_HOME='/opt/twelve-rust/rustup', CARGO_HOME='/opt/twelve-rust/cargo',DOTNET_CLI_HOME='/home/bench',DOTNET_CLI_TELEMETRY_OPTOUT='1',DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1')
app=pathlib.Path('/suite/sources')/('pr'+key)
commands=[]
if folder.startswith(('c-','cpp-','fortran-','zig-')):commands+=[['gcc','--version'],['clang','--version']]
if folder.startswith('fortran-'):commands+=[['gfortran','--version']]
if folder.startswith('zig-'):commands+=[['zig','version']]
if folder.startswith('rust-'):commands+=[['rustc','--version'],['cargo','--version']]
if folder.startswith('go-'):commands+=[['go','version']]
if folder.startswith('python-'):commands+=[[str(app/'.venv/bin/python'),'--version']]
if folder.startswith('ruby-'):commands+=[['ruby','--version']]
if folder.startswith('typescript-'):commands+=[['bun','--version']]
if folder.startswith('csharp-'):commands+=[['dotnet','--version'],['dotnet','--list-runtimes']]
if folder.startswith('php-'):commands+=[['php','--version'],['frankenphp','version']]
if folder.startswith('r-'):commands+=[['Rscript','--version']]
if folder.startswith(('java-','kotlin-')):
 commands+=[['java','--version']]
 commands += [[str(path),'--version'] for path in pathlib.Path('/opt').glob('*/bin/java')]
if folder.startswith('baml-'):commands+=[['env','RUSTUP_HOME=/opt/baml-rust/rustup','CARGO_HOME=/opt/baml-rust/cargo','/opt/baml-rust/cargo/bin/rustc','+1.98.0','--version']]
tools=[]
for command in commands:
 if not shutil.which(command[0]):continue
 try:
  result=subprocess.run(command,cwd=app,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=20)
  tools.append(dict(command=command,exit_code=result.returncode,output=result.stdout.strip()[:1600]))
 except Exception as error:tools.append(dict(command=command,error=str(error)))
shim=pathlib.Path('/usr/local/bin/nproc')
version_files={str(path):path.read_text().strip() for path in pathlib.Path('/opt/erlang').glob('*/lib/erlang/releases/*/OTP_VERSION')} if folder.startswith('erlang-') else {}
print(json.dumps(dict(tools=tools,version_files=version_files,nproc_local_exists=shim.exists(),nproc_local_prefix=shim.read_bytes()[:200].decode(errors='replace') if shim.exists() else None)))
'''
PROBE_HASH = hashlib.sha256(PROBE.encode()).hexdigest()


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    builds = json.loads((ROOT / 'build-status-1-40.json').read_text())
    observations = json.loads(OUTPUT.read_text()) if OUTPUT.exists() else {}
    candidates = [row for row in manifest if row['pr'] <= 40
                  and builds.get(row['id'], {}).get('exit_code') == 0]

    def probe(row):
        key = row['id']
        image = builds[key]['image_id']
        if (observations.get(key, {}).get('image_id') == image and
                observations.get(key, {}).get('probe_sha256') == PROBE_HASH):
            return key, observations[key]
        result = subprocess.run(['docker', 'run', '--rm', '--cpus', '1', '--memory', '512m',
                                 '--entrypoint', 'python3', image, '-c', PROBE, key, row['folder']],
                                capture_output=True, text=True, timeout=120)
        if result.returncode:
            return key, dict(image_id=image, error=result.stderr[-2000:])
        return key, dict(image_id=image, probe_sha256=PROBE_HASH, **json.loads(result.stdout))

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        for key, value in pool.map(probe, candidates):
            observations[key] = value
            OUTPUT.write_text(json.dumps(observations, indent=2) + '\n')
    shims = [key for key, value in observations.items() if value.get('nproc_local_exists')]
    print(f'{len(observations)} root image observations; nproc shim candidates: {shims}')


if __name__ == '__main__':
    main()
