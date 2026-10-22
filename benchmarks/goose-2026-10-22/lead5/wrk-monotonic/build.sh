#!/usr/bin/env bash
# PREPARED ONLY: run after the benchmark controller explicitly releases builds.
# Build matched Ubuntu-package sources; only src/wrk.c differs between variants.
set -euo pipefail
recipe=$(cd "$(dirname "$0")" && pwd)
output=${1:?Usage: build.sh NEW_ABSOLUTE_OUTPUT_DIRECTORY}
[[ $output == /* ]] || { echo 'Output directory must be absolute.' >&2; exit 1; }
[[ ! -e $output ]] || { echo 'Output directory already exists; preserving it.' >&2; exit 1; }
for tool in cc make patch pkg-config luajit dpkg-buildflags python3; do
  command -v "$tool" >/dev/null || { echo "Missing build dependency: $tool" >&2; exit 1; }
done
pkg-config --exists luajit openssl
cd "$recipe/source-archives"
printf '%s  %s\n' \
  52c2901729d02b1c348be18bf4ebf8a061f07e0dfdb27e2c84aa515235f5d0d2 wrk_4.1.0-4build2.dsc \
  d8f1ba8b70ae5e10aef63ef4d5b6520bc0da103f7f1c59c79f50e2efd6810f8f wrk_4.1.0.orig.tar.gz \
  3bbc69e3f1a50086110632f0e8e329a4240388e2e2477e70087a50f4b644c54e wrk_4.1.0-4build2.debian.tar.xz | sha256sum -c -
work=$(mktemp -d /tmp/wrk-clock-build.XXXXXX)
mkdir -p "$work/stock"
tar -xzf wrk_4.1.0.orig.tar.gz --strip-components=1 -C "$work/stock"
tar -xJf wrk_4.1.0-4build2.debian.tar.xz -C "$work/stock"
patch --batch --fuzz=0 -d "$work/stock" -p1 < "$work/stock/debian/patches/debian-changes"
cp -a "$work/stock" "$work/monotonic"
patch --batch --fuzz=0 -d "$work/monotonic" -p1 < "$recipe/monotonic-clock-only.patch"
mkdir -p "$output/stock" "$output/monotonic"
python3 - "$work" "$output" <<'PY'
from pathlib import Path
import hashlib,json,sys
work,out=map(Path,sys.argv[1:])
def inventory(folder):
    return {str(p.relative_to(folder)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(folder.rglob('*')) if p.is_file()}
a,b=inventory(work/'stock'),inventory(work/'monotonic')
changed=[name for name in sorted(set(a)|set(b)) if a.get(name)!=b.get(name)]
assert changed==['src/wrk.c'], changed
(out/'source-identities.json').write_text(json.dumps(dict(stock=a,monotonic=b,changed_files=changed),indent=2)+'\n')
PY
export DEB_BUILD_MAINT_OPTIONS=hardening=+all
export SOURCE_DATE_EPOCH=1711960617
compile_flags=$(dpkg-buildflags --get CFLAGS)
preprocess_flags=$(dpkg-buildflags --get CPPFLAGS)
link_flags=$(dpkg-buildflags --get LDFLAGS)
for variant in stock monotonic; do
  source="$work/$variant"
  CFLAGS="$compile_flags -ffile-prefix-map=$source=. -fdebug-prefix-map=$source=." \
    CPPFLAGS="$preprocess_flags" LDFLAGS="$link_flags" \
    make -C "$source" -j2 WITH_LUAJIT=/usr WITH_OPENSSL=/usr \
      VER=debian/4.1.0-4build2
  cp "$source/wrk" "$output/$variant/wrk"
  cp "$source/LICENSE" "$output/$variant/LICENSE"
  cp "$source/NOTICE" "$output/$variant/NOTICE"
done
python3 "$recipe/mock_clock_test.py" "$work/stock" "$work/monotonic" "$output"
python3 - "$work" "$output" <<'PY'
from pathlib import Path
import datetime,hashlib,json,subprocess,sys
work,out=map(Path,sys.argv[1:])
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def command(argv):
    r=subprocess.run(argv,text=True,capture_output=True)
    return dict(args=argv,exit_code=r.returncode,stdout=r.stdout,stderr=r.stderr)
objects={name:{str(p.relative_to(work/name/'obj')):sha(p) for p in sorted((work/name/'obj').rglob('*.o'))}
         for name in ['stock','monotonic']}
changed=[n for n in sorted(set(objects['stock'])|set(objects['monotonic']))
         if objects['stock'].get(n)!=objects['monotonic'].get(n)]
proof=dict(built_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
           source_package='wrk4.1.0-4build2',clock_only_source_change='src/wrk.c:time_us',
           variants={name:dict(binary_sha256=sha(out/name/'wrk'),
                               version=command([str(out/name/'wrk'),'--version']),
                               linkage=command(['ldd',str(out/name/'wrk')])) for name in objects},
           object_sha256=objects,changed_object_files=changed,
           mock_clock_test=json.loads((out/'mock-clock-results.json').read_text()),
           compiler=command(['cc','--version']),
           flags=command(['dpkg-buildflags']),
           dependencies=command(['dpkg-query','-W','gcc','make','libc6','libc6-dev','libssl-dev',
                                 'libssl3t64','libluajit-5.1-dev','libluajit-5.1-2','luajit']),
           limitation='Source/flags/dependencies are controlled; rebuilt binaries need not equal the historical Ubuntu package binary.')
(out/'build-proof.json').write_text(json.dumps(proof,indent=2)+'\n')
PY
printf 'Build products and provenance: %s\n' "$output"
