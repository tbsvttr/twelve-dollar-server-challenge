#!/usr/bin/env bash
# The tester's walk through this submission, each command printed before it runs:
#   git       the challenge checkout; the TrikeShed commit build.sh pins at trikeshed/TrikeShed (reified when empty, at
#             the recorded commit); whether the subrepo remote's default branch holds that commit
#   linkage   every TrikeShed file trikeshed/sources.txt names: present at the recorded commit, unchanged in the
#             subrepo's working tree; the client's own sources beside them
#   scaffold  seed database, leaf corpus, and the tools each edition needs
#   editions  each built, tested and run into build/editions/<os>-<arch>/<edition>/ (status, logs, artifacts)
#   summary   one line per edition, also written to build/editions/<os>-<arch>/summary.txt
# No commit is named here: the TrikeShed commit is the TRIKESHED_COMMIT pinned in build.sh.
#
#   bash tester.sh                    every step and every edition (an edition this host cannot build is skipped)
#   bash tester.sh git linkage        those steps only
#   bash tester.sh leaf-kn summary    one edition, then the summary
#
# Editions:
#   server-jvm     the entry: build.sh, then test/run.sh (starts it on a copy of the seed, 42 checks); CI and the
#                  benchmark box run this one only
#   leaf-jvm       the leaf codec permutation on the JVM (liblz4/liblzo2 through FFM), plus :trikeshed:jvmTest
#   leaf-graal-bt  native-image of the same jar with the jar's native-image config: FFM handles made at image build time
#   leaf-graal-rt  native-image with the jar's config excluded: FFM handles made at image run time
#   leaf-kn        Kotlin/Native for this host (macosArm64 or linuxX64; the Kotlin LZ4 and LZO codecs), plus
#                  :trikeshed:<target>Test. Kotlin/Native has no linux-aarch64 compiler, so a linux-arm64 host skips it
#   leaf-wasi      Kotlin/Wasm for WASI under wasmtime (kotlin codecs only)
#
# Environment, all optional: JAVA_HOME (a GraalVM JDK 25 with native-image), GRADLE, WASMTIME, TRIKESHED_URL,
# PORT (test/run.sh, default 3000), GRADLE_HEAP (Gradle heap for the leaf editions, default 3g).
# Host packages the leaf editions use: python3; Linux zlib1g-dev (native-image links -lz). The JVM editions (leaf-jvm,
# leaf-graal-*) load liblz4 and liblzo2 through FFM (Linux liblz4-1 liblzo2-2; macOS Homebrew lz4 lzo); leaf-kn and
# leaf-wasi use no C library and no C header.
set -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here" || exit 1
top=$(git rev-parse --show-toplevel 2> /dev/null)
[ -n "$top" ] || { echo "not inside a git checkout: the subrepo's commit comes from git"; exit 1; }
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
# Kotlin/Native compiler hosts (kotlin-native-prebuilt): linux-x86_64, macos-aarch64, macos-x86_64, windows-x86_64.
case "$os-$arch" in
  darwin-arm64) kt=macosArm64 ;;
  linux-x86_64) kt=linuxX64 ;;
  *) kt= ;;
esac
E=$here/build/editions/$os-$arch
SUB=trikeshed/TrikeShed
mkdir -p "$E"

if [ -z "$JAVA_HOME" ] && [ -x /opt/graalvm/bin/java ]; then export JAVA_HOME=/opt/graalvm; fi # install.sh's JDK
if [ -n "$JAVA_HOME" ]; then JBIN=$JAVA_HOME/bin/; else JBIN=; fi
JAVA=${JBIN}java
NATIVE_IMAGE=${JBIN}native-image
if [ -z "$GRADLE" ]; then if [ -x /opt/gradle/bin/gradle ]; then GRADLE=/opt/gradle/bin/gradle; else GRADLE=gradle; fi; fi
WASMTIME=${WASMTIME:-wasmtime}
HEAP=${GRADLE_HEAP:-3g}
failed=0

say() { printf '\n== %s\n' "$*"; }
run() { printf '+ %s\n' "$*"; "$@"; }
pipe() { printf '+ %s\n' "$1"; eval "$1"; }
# log <file> <command...>: the command's output goes to <file>; its last 3 lines are shown
log() {
  local out=$1 rc
  shift
  printf '+ %s > %s\n' "$*" "${out#"$here"/}"
  "$@" > "$out" 2>&1
  rc=$?
  tail -n 3 "$out" | sed 's/^/  | /'
  return $rc
}
mark() { # mark <edition> <status line>
  mkdir -p "$E/$1"
  printf '%s\n' "$2" > "$E/$1/status"
  printf -- '-> %s: %s\n' "$1" "$2"
  case $2 in FAIL*) failed=1 ;; esac
}
gradle_run() { "$GRADLE" --no-daemon --console=plain "$@"; }
recorded() { sed -n 's/^TRIKESHED_COMMIT=//p' "$here/build.sh"; }
junit() { # junit <test-results dir>: totals over its TEST-*.xml
  cat "$1"/TEST-*.xml 2> /dev/null | grep -o '<testsuite [^>]*>' | awk '{
    for (i = 1; i <= NF; i++) if (split($i, kv, "=") == 2) { gsub(/"/, "", kv[2]); s[kv[1]] += kv[2] } }
    END { printf "tests=%d failures=%d errors=%d skipped=%d", s["tests"], s["failures"], s["errors"], s["skipped"] }'
}
done_line() { grep -m1 ' done \[' "$1" 2> /dev/null | sed 's/^PERMUTATION //'; }

reify() {
  [ -d "$SUB/src" ] && return 0
  local commit
  commit=$(recorded)
  [ -n "$commit" ] || { echo "build.sh pins no commit for $SUB"; return 1; }
  say "reify $SUB at the commit git records for it"
  run mkdir -p "$SUB" || return 1
  run git -C "$SUB" init -q || return 1
  git -C "$SUB" remote get-url origin > /dev/null 2>&1 ||
    run git -C "$SUB" remote add origin "${TRIKESHED_URL:-https://github.com/jnorthrup/TrikeShed.git}"
  run git -C "$SUB" fetch -q --depth 1 origin "$commit" || return 1
  run git -C "$SUB" checkout -q --detach FETCH_HEAD
}

step_git() {
  local commit head url branch
  say "git: the challenge checkout"
  run git -C "$top" log -1 --format='HEAD %h %cd %s'
  run git -C "$top" status --short -- "$here"
  say "git: the commit build.sh pins for $SUB"
  commit=$(recorded)
  [ -n "$commit" ] || { echo "build.sh pins no commit for $SUB"; failed=1; return; }
  reify || { failed=1; return; }
  say "git: the subrepo's checkout"
  run git -C "$SUB" log -1 --format='%H %cd %an%n  %s'
  run git -C "$SUB" status --short --branch
  head=$(git -C "$SUB" rev-parse HEAD)
  if [ "$head" = "$commit" ]; then
    echo "the subrepo's HEAD is the recorded commit"
  else
    echo "the subrepo's HEAD $head is not the recorded commit $commit"
  fi
  say "git: the recorded commit on the subrepo's remote"
  url=$(git -C "$SUB" remote get-url origin)
  branch=$(git ls-remote --symref "$url" HEAD | awk '$1 == "ref:" { sub("refs/heads/", "", $2); print $2 }')
  run git ls-remote "$url" "refs/heads/$branch"
  if [ "$(git -C "$SUB" rev-parse --is-shallow-repository)" = true ]; then
    run git -C "$SUB" fetch -q --unshallow origin "$branch"
  else
    run git -C "$SUB" fetch -q origin "$branch"
  fi
  if git -C "$SUB" merge-base --is-ancestor "$commit" FETCH_HEAD; then
    echo "the recorded commit is in $url $branch"
  else
    echo "the recorded commit is not in $url $branch"
    failed=1
  fi
}

step_linkage() {
  local commit p n=0 missing=0 changed=0
  reify || { failed=1; return; }
  commit=$(recorded)
  say "linkage: the TrikeShed files trikeshed/sources.txt names, at the recorded commit $commit"
  while IFS= read -r p; do
    case "$p" in '' | '#'*) continue ;; esac
    n=$((n + 1))
    if ! git -C "$SUB" cat-file -e "$commit:$p" 2> /dev/null; then
      echo "missing at the recorded commit: $p"
      missing=$((missing + 1))
    elif ! git -C "$SUB" diff --quiet "$commit" -- "$p"; then
      echo "changed in the subrepo's working tree: $p"
      changed=$((changed + 1))
    fi
  done < trikeshed/sources.txt
  echo "$n files: $missing missing, $changed changed"
  [ $missing = 0 ] && [ $changed = 0 ] || failed=1
  say "linkage: files per TrikeShed source set"
  pipe "grep -v '^#' trikeshed/sources.txt | awk -F/ 'NF { print \$2 }' | sort | uniq -c"
  say "linkage: the client's own sources (module :server)"
  pipe "find server/src -name '*.kt' | sort"
  say "linkage: Kotlin files under trikeshed/ outside the subrepo (none expected)"
  pipe "find trikeshed -path $SUB -prune -o -path trikeshed/build -prune -o -name '*.kt' -print"
}

need_corpus() {
  [ -s "$E/corpus-4k.bin" ] && return 0
  [ -f "$top/seed/feed.db" ] || run bash "$top/seed/make-seed.sh" || return 1
  say "scaffold: leaf corpus, every 16th b-tree leaf page of a copy of seed/feed.db"
  run cp "$top/seed/feed.db" "$E/feed-copy.db" || return 1
  printf '+ python3 - %s %s 16   (the sampler is inline below)\n' "$E/feed-copy.db" "$E/corpus-4k.bin"
  python3 - "$E/feed-copy.db" "$E/corpus-4k.bin" 16 << 'PY'
import collections, struct, sys
db, out, every = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(db, 'rb') as f:
    header = f.read(100)
    assert header[:16] == b'SQLite format 3\x00', 'not a SQLite database'
    page_size = struct.unpack('>H', header[16:18])[0]
    page_size = 65536 if page_size == 1 else page_size
    pages = struct.unpack('>I', header[28:32])[0]
    picked, leaves = collections.Counter(), 0
    with open(out, 'wb') as o:
        for p in range(2, pages + 1):  # page 1 starts with the 100-byte file header
            f.seek((p - 1) * page_size)
            page = f.read(page_size)
            if page[0] in (0x0D, 0x0A):  # table and index b-tree leaves
                if leaves % every == 0:
                    o.write(page)
                    picked[page[0]] += 1
                leaves += 1
print(f'page_size={page_size} pages={pages} leaves={leaves} sampled={dict(picked)}')
PY
  local rc=$?
  run rm -f "$E/feed-copy.db"
  return $rc
}

tool() { # tool <label> <command...>: the command's first output line, or absent
  local line
  printf '%-36s ' "$1"
  shift
  if line=$("$@" 2>&1 | grep -m1 -v '^[[:space:]]*$'); then echo "$line"; else echo "absent ($*)"; fi
}

step_scaffold() {
  say "scaffold: seed database"
  [ -f "$top/seed/feed.db" ] || run bash "$top/seed/make-seed.sh"
  run ls -l "$top/seed/feed.db"
  need_corpus || failed=1
  run ls -l "$E/corpus-4k.bin"
  say "scaffold: tools (editions: tool)"
  tool "all: git" git --version
  tool "all: gradle ($GRADLE)" "$GRADLE" --version
  tool "server-jvm, leaf-*: java" "$JAVA" -version
  tool "server-jvm: cc" cc --version
  tool "server-jvm: curl" curl --version
  tool "server-jvm: jq" jq --version
  tool "server-jvm: openssl" openssl version
  tool "leaf-graal-*: native-image" "$NATIVE_IMAGE" --version
  tool "leaf-wasi: wasmtime" "$WASMTIME" --version
  tool "scaffold: python3" python3 --version
  say "scaffold: liblz4 / liblzo2 (leaf-jvm, leaf-graal-*: run time, through FFM; leaf-kn, leaf-wasi: none); libz (native-image link)"
  case $os in
    linux) pipe "ldconfig -p | grep -E 'liblz4\\.so|liblzo2\\.so'; ls -l /usr/lib/*-linux-gnu/libz.so" ;;
    darwin) pipe "ls -l /opt/homebrew/lib/liblz4.dylib /opt/homebrew/lib/liblzo2.dylib" ;;
  esac
}

ed_server_jvm() {
  local d=$E/server-jvm s=$SECONDS
  mkdir -p "$d"
  reify || { mark server-jvm "FAIL subrepo"; return; }
  say "server-jvm: build.sh (the box's build: :server:app, :server:sqliteLib)"
  log "$d/build.log" bash build.sh || { mark server-jvm "FAIL build.sh"; return; }
  pipe "ls -l server/build/app server/build/sqlite > '$d/artifacts.txt'"
  say "server-jvm: test/run.sh (CI's command: build, start on a copy of the seed, 42 checks)"
  log "$d/test.txt" env PORT="${PORT:-3000}" bash "$top/test/run.sh" "$here" ||
    { mark server-jvm "FAIL test/run.sh $(grep -m1 'passed=' "$d/test.txt")"; return; }
  mark server-jvm "ok $(grep -m1 'passed=' "$d/test.txt"), $((SECONDS - s)) s"
}

ed_leaf_jvm() {
  local d=$E/leaf-jvm s=$SECONDS tests
  mkdir -p "$d"
  reify && need_corpus || { mark leaf-jvm "FAIL scaffold"; return; }
  say "leaf-jvm: the jars (server/build/app: trikeshed-jvm.jar, the Kotlin stdlib)"
  log "$d/build.log" gradle_run :server:app || { mark leaf-jvm "FAIL gradle"; return; }
  say "leaf-jvm: :trikeshed:jvmTest (commonTest and jvmTest)"
  if log "$d/test.log" gradle_run :trikeshed:jvmTest; then tests="jvmTest $(junit trikeshed/build/test-results/jvmTest)"
  else tests="jvmTest FAIL (test.log)"; failed=1; fi
  say "leaf-jvm: the permutation"
  log "$d/run.txt" "$JAVA" --enable-native-access=ALL-UNNAMED -cp "server/build/app/*" \
    borg.trikeshed.tilting.leaf.LeafPermutationMainKt "$E/corpus-4k.bin" || { mark leaf-jvm "FAIL run; $tests"; return; }
  mark leaf-jvm "ok $tests, $(done_line "$d/run.txt"), $((SECONDS - s)) s"
}

ed_leaf_graal() { # bt | rt
  local name=leaf-graal-$1 d=$E/leaf-graal-$1 s=$SECONDS stdlib
  mkdir -p "$d"
  command -v "$NATIVE_IMAGE" > /dev/null || { mark "$name" "SKIP no native-image ($NATIVE_IMAGE)"; return; }
  reify && need_corpus || { mark "$name" "FAIL scaffold"; return; }
  [ -f server/build/app/trikeshed-jvm.jar ] || log "$d/gradle.log" gradle_run :server:app || { mark "$name" "FAIL gradle"; return; }
  stdlib=$(ls "$here"/server/build/app/kotlin-stdlib-*.jar | head -1)
  local args=()
  [ "$os" = darwin ] && args+=(-ESDKROOT)
  if [ "$1" = rt ]; then
    args+=(--exclude-config '.*trikeshed-jvm\.jar' 'META-INF/native-image/.*' --enable-native-access=ALL-UNNAMED
      "-H:ConfigurationFileDirectories=$here/$SUB/src/jvmMain/resources/META-INF/native-image/borg.trikeshed/tilting")
  fi
  args+=(-march=native -cp "$here/server/build/app/trikeshed-jvm.jar:$stdlib" -o leafPermutation
    borg.trikeshed.tilting.leaf.LeafPermutationMainKt)
  say "$name: native-image, in $d"
  (cd "$d" && log "$d/build.log" "$NATIVE_IMAGE" "${args[@]}") ||
    { mark "$name" "FAIL native-image: $(grep -m1 -E 'Caused by|Error: |cannot find' "$d/build.log" | cut -c1-150)"; return; }
  say "$name: the permutation"
  log "$d/run.txt" "$d/leafPermutation" "$E/corpus-4k.bin" || { mark "$name" "FAIL run"; return; }
  mark "$name" "ok $(wc -c < "$d/leafPermutation" | tr -d ' ') B image, $(done_line "$d/run.txt"), $((SECONDS - s)) s"
}

ed_leaf_kn() {
  [ -n "$kt" ] || { mark leaf-kn "SKIP no Kotlin/Native compiler for $os-$arch"; return; }
  local name=leaf-kn-$kt d=$E/leaf-kn-$kt s=$SECONDS T props=("-Ptrike.targets=$kt")
  mkdir -p "$d"
  reify && need_corpus || { mark "$name" "FAIL scaffold"; return; }
  T=$(printf '%s' "${kt:0:1}" | tr '[:lower:]' '[:upper:]')${kt:1}
  say "$name: the executable (the first Kotlin/Native build downloads its toolchain into ~/.konan)"
  log "$d/build.log" gradle_run "-Dorg.gradle.jvmargs=-Xmx$HEAP -XX:+UseSerialGC" "${props[@]}" \
    ":trikeshed:linkLeafPermutationReleaseExecutable$T" || { mark "$name" "FAIL gradle"; return; }
  run cp "trikeshed/build/bin/$kt/leafPermutationReleaseExecutable/leafPermutation.kexe" "$d/"
  say "$name: :trikeshed:${kt}Test (commonTest and lzNativeTest)"
  if log "$d/test.log" gradle_run "-Dorg.gradle.jvmargs=-Xmx$HEAP -XX:+UseSerialGC" "${props[@]}" ":trikeshed:${kt}Test"
  then tests="${kt}Test $(junit "trikeshed/build/test-results/${kt}Test")"
  else tests="${kt}Test FAIL (test.log)"; failed=1; fi
  say "$name: the permutation"
  log "$d/run.txt" "$d/leafPermutation.kexe" "$E/corpus-4k.bin" || { mark "$name" "FAIL run; $tests"; return; }
  mark "$name" "ok $tests, $(done_line "$d/run.txt"), $((SECONDS - s)) s"
}

ed_leaf_wasi() {
  local d=$E/leaf-wasi s=$SECONDS w
  mkdir -p "$d"
  command -v "$WASMTIME" > /dev/null || { mark leaf-wasi "SKIP no wasmtime (WASMTIME=<path>)"; return; }
  reify && need_corpus || { mark leaf-wasi "FAIL scaffold"; return; }
  say "leaf-wasi: the WASI executable"
  log "$d/build.log" gradle_run "-Dorg.gradle.jvmargs=-Xmx$HEAP -XX:+UseSerialGC" -Ptrike.targets=wasmWasi \
    :trikeshed:compileProductionExecutableKotlinWasmWasi || { mark leaf-wasi "FAIL gradle"; return; }
  w=$(ls trikeshed/build/compileSync/wasmWasi/main/productionExecutable/kotlin/*.wasm 2> /dev/null | head -1)
  [ -n "$w" ] || { mark leaf-wasi "FAIL no .wasm"; return; }
  run cp "$w" "$d/trikeshed.wasm"
  say "leaf-wasi: the permutation (the corpus is read from the preopened directory /data)"
  log "$d/run.txt" "$WASMTIME" run --dir "$E::/data" "$d/trikeshed.wasm" || { mark leaf-wasi "FAIL run"; return; }
  mark leaf-wasi "ok $(done_line "$d/run.txt"), $((SECONDS - s)) s"
}

step_summary() {
  local f
  say "summary: $os-$arch, TrikeShed $(recorded) (build/editions/$os-$arch)"
  for f in "$E"/*/status; do
    [ -f "$f" ] && printf '%-22s %s\n' "$(basename "$(dirname "$f")")" "$(cat "$f")"
  done | tee "$E/summary.txt"
}

[ $# -gt 0 ] || set -- git linkage scaffold server-jvm leaf-jvm leaf-graal-bt leaf-graal-rt leaf-kn leaf-wasi summary
for step in "$@"; do
  case $step in
    git) step_git ;;
    linkage) step_linkage ;;
    scaffold) step_scaffold ;;
    server-jvm) ed_server_jvm ;;
    leaf-jvm) ed_leaf_jvm ;;
    leaf-graal-bt) ed_leaf_graal bt ;;
    leaf-graal-rt) ed_leaf_graal rt ;;
    leaf-kn) ed_leaf_kn ;;
    leaf-wasi) ed_leaf_wasi ;;
    summary) step_summary ;;
    *) echo "unknown step: $step"; exit 2 ;;
  esac
done
exit $failed
