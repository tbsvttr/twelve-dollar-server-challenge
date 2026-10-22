"""Pin the current PR inventory and stage isolated benchmark source trees.

No submission code is executed here. Archives contain the exact API snapshot's
head commit, and extraction copies only regular files below a changed submission
folder. Download and source checksums make later changes independently auditable.
"""
import concurrent.futures
import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile
import threading
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent
REPO_ROOT = ROOT.parents[1]
UPSTREAM = "arjaythedev/twelve-dollar-server-challenge"
LOCK = threading.Lock()
ROWS = {}
EXCLUDED = {}
SOURCE_EXTENSIONS = {
    '.c', '.h', '.cpp', '.hpp', '.cc', '.cxx', '.hh', '.rs', '.go', '.py',
    '.rb', '.rake', '.erl', '.hrl', '.ex', '.exs', '.ts', '.tsx', '.js',
    '.jsx', '.mjs', '.cjs', '.php', '.f90', '.f95', '.f03', '.f08', '.f',
    '.zig', '.cs', '.fs', '.fsx', '.java', '.kt', '.kts', '.scala', '.sc',
    '.swift', '.dart', '.d', '.nim', '.nims', '.v', '.hs', '.lhs', '.lua',
    '.asm', '.s', '.S', '.sql', '.r', '.R', '.ail', '.baml', '.html', '.css',
}
CONFIG_EXTENSIONS = {'.sh', '.bash', '.json', '.toml', '.yaml', '.yml', '.xml', '.conf', '.config', '.gradle', '.properties', '.ini', '.mk'}
DEPENDENCY_PARTS = {'vendor', 'vendors', 'third_party', 'third-party', 'node_modules', '.venv', 'venv', 'deps', '_build', 'target', '.git', 'dist', 'build', 'packages'}
APP_EXCLUDE_PARTS = {'test', 'tests', 'check', 'checks', 'bench', 'benchmarks', 'examples', 'tools', 'scripts', 'ci', '.github', 'pgo', 'loadgen'}
APP_EXCLUDE_WORDS = ('test', 'bench', 'generate', 'seed', 'profile', 'probe', 'inventory')
ROOT_HELPERS = {'check.py', 'check.ts', 'verify.py', 'compare.py', 'transport_check.py',
                'idle_compare.py', 'verify.mjs', 'verify-sockets.mjs', 'build.py',
                'fix-fio.py', 'loadgen_pro.go'}
BUILD_FILES = {'build.rs', 'build.zig', 'build.d', 'build.nim', 'setup.py',
               'build.gradle.kts', 'settings.gradle.kts', 'config.nims'}
RESULT_METADATA = {'capacity-results.json', 'benchmark-results.json',
                   'validation-results.json', 'performance-results.json',
                   'source-inventory.json', 'scoring.json',
                   'qualification-evidence.json', 'source-artifact-manifest.json'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + '.partial')
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')
    temporary.replace(path)


def save():
    with LOCK:
        atomic_json(ROOT / 'manifest.json', sorted(ROWS.values(), key=lambda r: (r['pr'], r['id'])))
        atomic_json(ROOT / 'excluded.json', sorted(EXCLUDED.values(), key=lambda r: r['pr']))


def log(message):
    with LOCK:
        with (ROOT / 'prepare-progress.log').open('a') as handle:
            handle.write(message + '\n')
        print(message, flush=True)


def gh_json(endpoint):
    result = subprocess.run(['gh', 'api', '--paginate', '--slurp', endpoint], capture_output=True, timeout=180, check=True)
    pages = json.loads(result.stdout)
    return [item for page in pages for item in page]


def nginx_mode(directory):
    evidence = []
    for name in ['README.md', 'readme.md', 'start.sh']:
        path = directory / name
        if not path.exists():
            continue
        for line in path.read_text(errors='replace').splitlines():
            if re.search(r'nginx|\bdirect\b|:80\b|PORT.?=.?(80|3000|8080)\b', line, re.I):
                evidence.append({'file': name, 'line': line[:500]})
    readme = '\n'.join(item['line'] for item in evidence if item['file'].lower() == 'readme.md')
    # Explicit README declarations take precedence; scripts using port 3000
    # alone do not imply a proxy because the shared harness may override PORT.
    if re.search(r'\bno\s+nginx\b|\bwithout\s+nginx\b|\bdirect\b[^\n]{0,90}\b(?:80|HTTP)\b|\bnginx\b[^\n]{0,30}\bno\b', readme, re.I):
        return False, evidence
    if re.search(r'nginx\s*:\s*(?:yes|true)|behind\s+nginx|through\s+nginx|nginx\s+(?:reverse\s+)?proxy|nginx\s+in\s+front|uses?\s+nginx', readme, re.I):
        return True, evidence
    return False, evidence


def classification_context(directory):
    """Identify reviewed runtime entrypoints and recognizable vendored subtrees.

    Entire identifiable third-party forks are dependencies, including local
    modifications: these counts are not a claim about individually authored lines.
    """
    dependencies, evidence, runtime = [], [], []
    for manifest in directory.rglob('go.mod'):
        relative = manifest.parent.relative_to(directory).as_posix()
        if relative != '.' and re.search(r'^module\s+github\.com/mattn/go-sqlite3\s*$', manifest.read_text(errors='replace'), re.M):
            dependencies.append(relative)
            evidence.append({'path': relative, 'reason': 'Nested go.mod identifies the github.com/mattn/go-sqlite3 third-party fork; exclude whole subtree, including local patches.'})
    readme = '\n'.join((directory / n).read_text(errors='replace') for n in ['README.md', 'readme.md'] if (directory / n).exists())
    if (directory / 'src/libco/coctx_swap.S').is_file() and re.search(r'Tencent(?:/|\s+)libco', readme, re.I):
        dependencies.append('src/libco')
        evidence.append({'path': 'src/libco', 'reason': 'README identifies vendored Tencent libco and documents local patches; exclude whole third-party subtree.'})
    start = directory / 'start.sh'
    lines = start.read_text(errors='replace').splitlines() if start.exists() else []
    for script in directory.rglob('*.sh'):
        relative = script.relative_to(directory).as_posix()
        if relative in {'start.sh', 'build.sh', 'install.sh'}:
            continue
        if any(not line.lstrip().startswith('#') and script.name in line and
               re.search(r'(?:^|[;&|()\s])(?:exec|bash|sh)\s|EXEC:', line) for line in lines):
            runtime.append(relative)
    return {'dependency_roots': sorted(set(dependencies)), 'runtime_sources': sorted(runtime),
            'dependency_evidence': evidence}


def classify_detail(name, data, runtime_sources=(), dependency_roots=()):
    path = PurePosixPath(name)
    lower_parts = {part.lower() for part in path.parts[:-1]}
    filename = path.name.lower()
    if '\x00' in data[:8192].decode('latin1'):
        return 'binary', 'Binary content'
    if lower_parts & DEPENDENCY_PARTS or any(name == root or name.startswith(root + '/') for root in dependency_roots):
        return 'dependency_or_generated', 'Dependency/generated directory or provenance-identified third-party subtree'
    if (filename.endswith(('.lock', '-lock.json', '.lock.json', '.md', '.txt', '.csv', '.svg', '.sum'))
            or filename in {'pnpm-lock.yaml', 'dub.selections.json'}
            or filename.startswith(('.gitignore', '.dockerignore'))):
        return 'documentation_lock_or_metadata', 'Documentation, dependency lock, or metadata file'
    if (filename in RESULT_METADATA or filename.endswith('-summary.json')
            or ('benchmarks' in lower_parts and path.suffix == '.json')):
        return 'documentation_lock_or_metadata', 'Generated benchmark/validation report or source inventory, not helper source'
    if re.search(rb'(?im)^\s*//\s*Code generated[^\n]*DO NOT EDIT', data[:1000]):
        return 'dependency_or_generated', 'Explicit generated-code DO NOT EDIT header'
    if name in runtime_sources:
        return 'application', 'Runtime script directly executed by start.sh'
    source = path.suffix in SOURCE_EXTENSIONS
    root_helper = len(path.parts) == 1 and filename in ROOT_HELPERS
    specific_helper = name == 'src/loadgen.zig'
    development_helper = path.parts[0] == 'dev'
    if source and not (lower_parts & APP_EXCLUDE_PARTS) and not any(word in filename for word in APP_EXCLUDE_WORDS) and filename not in BUILD_FILES and not root_helper and not specific_helper and not development_helper:
        return 'application', 'Application source under the documented heuristic'
    if source or path.suffix in CONFIG_EXTENSIONS or filename in {'makefile', 'gnumakefile', 'gemfile', 'rakefile', 'dockerfile', 'procfile', 'cmakelists.txt', 'rebar.config'}:
        return 'own_support', 'Build/configuration, dedicated test/check/PGO/load-generator directory, or exact auxiliary helper filename'
    return 'other', 'Unrecognized non-source file'


def classify(name, data, **context):
    return classify_detail(name, data, **context)[0]


def prepare(pr):
    number = pr['number']
    common = dict(pr=number, id=str(number), case_id=str(number), title=pr['title'],
                  url=pr['html_url'], state=pr['state'], merged=bool(pr['merged_at']),
                  repo=(pr['head']['repo'] or {}).get('full_name', UPSTREAM),
                  commit=pr['head']['sha'], eligible=number != 21)
    if pr['state'] == 'closed' and not pr['merged_at']:
        EXCLUDED[number] = dict(common, status='excluded', exclusion_reason='Closed without merge; not a current submission. Duplicate/superseding open PRs remain included.')
        save()
        return
    if number in (37, 87):
        EXCLUDED[number] = dict(common, status='excluded', exclusion_reason='Repository rules formatting change.' if number == 37 else 'Load-generator contribution; no server submission.')
        save()
        return
    try:
        file_cache = ROOT / 'pull-files' / f'pr{number}-{common["commit"]}.json'
        if file_cache.exists():
            files = json.loads(file_cache.read_text())
        else:
            files = gh_json(f'repos/{UPSTREAM}/pulls/{number}/files?per_page=100')
            atomic_json(file_cache, files)
        folders = sorted({PurePosixPath(item['filename']).parts[1] for item in files
                          if item.get('status') != 'removed' and len(PurePosixPath(item['filename']).parts) > 2
                          and PurePosixPath(item['filename']).parts[0] == 'submissions'})
        if not folders:
            EXCLUDED[number] = dict(common, status='excluded', exclusion_reason='No changed submission folder in PR file inventory.')
            save()
            return
        archive = ROOT / 'archives' / f'pr{number}-{common["commit"]}.tar.gz'
        endpoint_used = None
        if not archive.exists():
            for repo in dict.fromkeys([UPSTREAM, common['repo']]):
                partial = archive.with_suffix('.partial')
                with partial.open('wb') as output:
                    response = subprocess.run(['gh', 'api', f'repos/{repo}/tarball/{common["commit"]}'], stdout=output, stderr=subprocess.PIPE, timeout=600)
                if response.returncode == 0:
                    partial.replace(archive)
                    endpoint_used = f'repos/{repo}/tarball/{common["commit"]}'
                    break
                partial.unlink(missing_ok=True)
            else:
                raise RuntimeError('Pinned tarball download failed: ' + response.stderr.decode(errors='replace')[-2000:])
        archive_sha256 = digest(archive.read_bytes())
        for folder in folders:
            ident = str(number)
            if len(folders) > 1:
                suffix = ('vibed' if 'vibe' in folder.lower() else
                          'arsd-hybridcgi' if 'arsd-hybridcgi' in folder.lower() else
                          'arsd-threadedcgi' if 'arsd-threadedcgi' in folder.lower() else
                          'arsd' if 'arsd' in folder.lower() else folder)
                ident += '-' + suffix
            row = dict(common, id=ident, case_id=ident, folder=folder, nginx=False,
                       status='preparing', archive=str(archive.relative_to(ROOT)),
                       archive_sha256=archive_sha256, archive_endpoint=endpoint_used or 'cached exact-SHA archive',
                       source_url=f'https://github.com/{common["repo"]}/tree/{common["commit"]}/submissions/{folder}')
            ROWS[ident] = row
            save()
            target = ROOT / 'sources' / f'pr{ident}'
            staging = ROOT / 'sources' / f'.pr{ident}-{common["commit"]}.partial'
            if staging.exists():
                shutil.rmtree(staging)
            staging.mkdir()
            hashes, inventory, skipped = {}, {}, []
            with tarfile.open(archive) as tar:
                for member in tar:
                    bits = PurePosixPath(member.name).parts
                    if len(bits) < 4 or bits[1:3] != ('submissions', folder):
                        continue
                    relative = PurePosixPath(*bits[3:])
                    if relative.is_absolute() or '..' in relative.parts:
                        raise RuntimeError(f'Unsafe archive member: {member.name}')
                    if member.isdir():
                        continue
                    if not member.isfile():
                        skipped.append({'path': str(relative), 'type': str(member.type), 'reason': 'Only regular files are extracted.'})
                        continue
                    content = tar.extractfile(member).read()
                    destination = staging / str(relative)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(content)
                    destination.chmod(member.mode & 0o777)
                    name = str(relative)
                    hashes[name] = digest(content)
                    category = classify(name, content)
                    inventory[name] = dict(sha256=hashes[name], bytes=len(content), physical_lines=len(content.splitlines()), classification=category)
            if not hashes:
                raise RuntimeError(f'No regular files for {folder} in pinned source archive')
            if target.exists():
                shutil.rmtree(target)
            staging.rename(target)
            context = classification_context(target)
            for name, item in inventory.items():
                item['classification'] = classify(name, (target / name).read_bytes(),
                                                  runtime_sources=context['runtime_sources'],
                                                  dependency_roots=context['dependency_roots'])
            atomic_json(ROOT / 'archives' / f'pr{ident}-sha256.json', hashes)
            atomic_json(ROOT / 'source-inventories' / f'pr{ident}.json', dict(files=inventory, skipped_members=skipped))
            row.update(source_sha256=digest(json.dumps(hashes, sort_keys=True).encode()), source_file_count=len(hashes),
                       source_hashes=str((ROOT / 'archives' / f'pr{ident}-sha256.json').relative_to(ROOT)),
                       app_loc=sum(item['physical_lines'] for item in inventory.values() if item['classification'] == 'application'),
                       own_loc=sum(item['physical_lines'] for item in inventory.values() if item['classification'] in {'application', 'own_support'}),
                       loc_method='Physical lines including blanks/comments; heuristic file classification retained in source-inventories, excluding docs, lockfiles, binary/generated/dependency folders.',
                       start_sh=(target / 'start.sh').is_file(), build_sh=(target / 'build.sh').is_file(),
                       install_sh=(target / 'install.sh').is_file(), skipped_members=skipped)
            row['nginx'], row['nginx_evidence'] = nginx_mode(target)
            # The original established Rails setup declares Nginx in its README
            # table; retain the prior verified launch mode for these identities.
            if number in (2, 12):
                row['nginx'] = True
            row['status'] = 'prepared' if row['start_sh'] else 'source_missing_start'
            save()
            log(f'PR {ident}: {len(hashes)} regular files, {common["commit"][:12]}, {folder}, {row["status"]}')
    except Exception as error:
        ident = str(number)
        ROWS[ident] = dict(common, folder=None, nginx=False, status='source_failed', source_error=f'{type(error).__name__}: {error}')
        save()
        log(f'PR {number}: SOURCE FAILED: {type(error).__name__}: {error}')


def main():
    ROOT.mkdir(exist_ok=True)
    for name in ['archives', 'sources', 'pull-files', 'source-inventories', 'seed', 'bench']:
        (ROOT / name).mkdir(exist_ok=True)
    data = json.loads(Path('/tmp/tdsc-current-prs.json').read_text())
    prs = sum(data, []) if data and isinstance(data[0], list) else data
    prs.sort(key=lambda pr: pr['number'])
    atomic_json(ROOT / 'prs-snapshot.json', prs)
    atomic_json(ROOT / 'source-snapshot-metadata.json', dict(captured_at_utc=datetime.now(timezone.utc).isoformat(), upstream=UPSTREAM, pr_count=len(prs), selection='All open server submission PRs and merged submission PRs in API snapshot; closed unmerged and non-server contributions are excluded.', loc_unit='Physical source lines including blank/comment lines.'))
    for name in ['feed.db', 'tokens.json']:
        shutil.copyfile(REPO_ROOT / 'seed' / name, ROOT / 'seed' / name)
    shutil.copytree(REPO_ROOT / 'test', ROOT / 'test', dirs_exist_ok=True)
    for name in ['nginx.conf', 'load.js']:
        shutil.copyfile(REPO_ROOT / 'bench' / name, ROOT / 'bench' / name)
    shutil.copyfile(REPO_ROOT / 'results/unified-comparison-2026-10-07/mixed.lua', ROOT / 'mixed.lua')
    shared = {str(path.relative_to(ROOT)): digest(path.read_bytes()) for name in ['seed', 'test', 'bench'] for path in (ROOT / name).rglob('*') if path.is_file()}
    shared['mixed.lua'] = digest((ROOT / 'mixed.lua').read_bytes())
    atomic_json(ROOT / 'shared-sha256.json', shared)
    # Complete the original cohort first so builds can begin while subsequent
    # submission archives download. Each cohort uses at most six concurrent GH requests.
    for group in [[pr for pr in prs if pr['number'] <= 25], [pr for pr in prs if pr['number'] > 25]]:
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(prepare, group))
        log(f'Cohort complete through PR {max(pr["number"] for pr in group)}: {len(ROWS)} source rows; {len(EXCLUDED)} exclusions')
    save()
    log(f'COMPLETE: {len(ROWS)} source rows; {len(EXCLUDED)} excluded PRs; {len(prs)} total PRs inventoried')


if __name__ == '__main__':
    main()
