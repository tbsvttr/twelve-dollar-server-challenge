#!/usr/bin/env bash
# all1000.sh [TREE]: every runtime of the challenge server, built once in TREE (default: this submission) against the
# TrikeShed checkout there, then each in the box (CPU 1, 2 GB, no swap, LimitNOFILE=65535) on a fresh seed copy: the
# 42 checks, then VUS users (default 1,000) of the challenge load generator (k6's user model: feed, post, like, create)
# with RAMP and HOLD seconds. One row per runtime: requests/s, p50/p95/p99 of the hold, failures, server CPU per
# request (cgroup), anon memory peak, io_uring descriptors. Results: $W/results.tsv; logs in $W.
# Needs a Linux host with systemd, passwordless sudo (systemd-run puts each server in its own limited unit), 8 CPUs
# (server on CPU 1, client on 2-7), /opt/graalvm, node 24 and wasmtime 46 on PATH, wasi-sdk (WASI_SDK=<dir>, or
# wasm32-wasip1-clang on PATH); bench/install-extra.sh installs node, wasmtime and wasi-sdk.
set -u
T=$(cd "${1:-$(dirname "$0")/..}" && pwd); W=${W:-${TMPDIR:-/tmp}/a1k}; VUS=${VUS:-1000}; RAMP=${RAMP:-10}; HOLD=${HOLD:-30}
PORT=${PORT:-3920}; SEED=${SEED:-$T/../../seed}; TESTS=${TESTS:-$T/../../test/test.sh}
rm -rf $W && mkdir -p $W
cd "$T" || exit 2
export JAVA_HOME=/opt/graalvm
GW="bash trikeshed/TrikeShed/gradlew -p . --no-daemon --quiet --console=plain"
echo "TrikeShed $(git -C trikeshed/TrikeShed rev-parse HEAD 2>/dev/null || echo "${TS_COMMIT:-?}") in $T   load avg $(cut -d' ' -f1 /proc/loadavg)"

build() { local name=$1; shift; local t0; t0=$(date +%s); "$@" > $W/build-$name.log 2>&1; local rc=$?
  echo "build $name rc=$rc $(( $(date +%s) - t0 )) s"; [ $rc = 0 ] || grep -E "^e: |What went wrong|rror" -A2 $W/build-$name.log | head -8; }
build jvm    $GW :server:app :server:sqliteLib :loadgen:app
build kn     $GW -Ptrike.targets=linuxX64 :server:linkFeedReleaseExecutableLinuxX64
build node   $GW -Ptrike.targets=js :server:nodeDist
build wasi   $GW -Ptrike.targets=wasmWasi :server:wasiDist
mkdir -p server/build/native
build static /opt/graalvm/bin/native-image -J-Xmx1400m --no-fallback --gc=serial -march=native \
  --enable-native-access=ALL-UNNAMED --initialize-at-build-time=borg.trikeshed.feed.SqliteCalls \
  -cp "server/build/app/*" -o server/build/native/feed-static borg.trikeshed.feed.MainKt

printf "runtime\ttransport\texe\tchecks\tio_uring_fds\treq_s\tp50_ms\tp95_ms\tp99_ms\tfailed\tpass\tus_per_req\tanon_peak_mb\n" > $W/results.tsv
one() { # one NAME RUNTIME TRANSPORT
  local name=$1 rt=$2 tr=$3 U=a1k-$1 CG=/sys/fs/cgroup/system.slice/a1k-$1.service
  rm -rf $W/db-$name && mkdir $W/db-$name && cp $SEED/feed.db $W/db-$name/
  sudo -n systemctl stop $U 2>/dev/null; sudo -n systemctl reset-failed $U 2>/dev/null
  sudo -n systemd-run --quiet --unit=$U --uid=$(id -u) --gid=$(id -g) -p CPUQuota=100% -p MemoryMax=2G -p MemorySwapMax=0 \
    -p LimitNOFILE=65535 -E SQLITE_PATH=$W/db-$name/feed.db -E JWT_SECRET=twelve-dollar-challenge -E HOST=127.0.0.1 \
    -E PORT=$PORT -E RUNTIME=$rt ${tr:+-E TRANSPORT=$tr} -E PATH=$PATH -E HOME=$HOME \
    taskset -c 1 bash -c "cd $T && exec bash start.sh > $W/server-$name.log 2>&1"
  for _ in $(seq 120); do curl -sf http://127.0.0.1:$PORT/health > /dev/null && break; sleep 0.5; done
  local P; P=$(for p in $(cat $CG/cgroup.procs 2>/dev/null); do echo "$(ls /proc/$p/task 2>/dev/null | wc -l) $p"; done | sort -n | tail -1 | cut -d' ' -f2)
  local exe; exe=$(basename "$(readlink /proc/${P:-0}/exe 2>/dev/null)")
  if ! curl -sf http://127.0.0.1:$PORT/health > /dev/null; then
    printf "%s\t%s\t%s\tno health\n" $rt "${tr:--}" "${exe:-none}" >> $W/results.tsv; tail -5 $W/server-$name.log
    sudo -n systemctl stop $U 2>/dev/null; rm -rf $W/db-$name; return; fi
  local checks; checks=$(bash $TESTS http://127.0.0.1:$PORT 2>&1 | tail -1 | grep -o "passed=[0-9]* failed=[0-9]*")
  local ring; ring=$(ls -l /proc/$P/fd 2>/dev/null | grep -c io_uring)
  echo 0 > $W/anon-$name
  ( while sleep 1; do a=$(awk '/^anon / {print $2}' $CG/memory.stat 2>/dev/null) || break; [ -z "$a" ] && break
      [ "$a" -gt "$(cat $W/anon-$name)" ] && echo $a > $W/anon-$name; done ) &
  local S=$! u0; u0=$(awk '/usage_usec/ {print $2}' $CG/cpu.stat)
  ( ulimit -n 1048576; cd $W && taskset -c 2-7 /opt/graalvm/bin/java -Xms2g -Xmx6g -XX:+UseParallelGC -XX:-UsePerfData \
      --enable-native-access=ALL-UNNAMED -cp "$T/loadgen/build/app/*" borg.trikeshed.loadgen.MainKt run host=127.0.0.1 \
      ports=$PORT tls=false mode=native tokens=$SEED/tokens.json out=lg-$name vus=$VUS ramp=$RAMP hold=$HOLD threads=6 \
      guard=$CG sources=127.0.0.2,127.0.0.3,127.0.0.4,127.0.0.5,127.0.0.6,127.0.0.7,127.0.0.8,127.0.0.9 > $W/load-$name.out 2>&1 )
  local u1; u1=$(awk '/usage_usec/ {print $2}' $CG/cpu.stat)
  kill $S 2>/dev/null; wait $S 2>/dev/null
  python3 - "$W/load-$name.out" "$rt" "${tr:--}" "$exe" "$checks" "$ring" "$HOLD" "$(( u1 - u0 ))" "$(cat $W/anon-$name)" >> $W/results.tsv <<'PY'
import json, sys
f, rt, tr, exe, checks, ring, hold, cpu_us, anon = sys.argv[1:]
s = open(f).read()
try: j = json.loads(s[s.index("{"):s.rindex("}") + 1])
except ValueError: print("\t".join([rt, tr, exe, checks, ring, "no loadgen JSON"])); sys.exit()
r, h = j["scopes"]["run"], j["scopes"]["canonicalHold"]
lat = [round(h["latencyMicros"][k] / 1000, 1) for k in ("p50", "p95", "p99")]
print("\t".join(map(str, [rt, tr, exe, checks, ring, round(h["requests"] / int(hold)), *lat, r["failed"],
                          j["outcome"]["pass"], round(int(cpu_us) / max(r["requests"], 1)), int(anon) >> 20])))
PY
  sudo -n systemctl stop $U 2>/dev/null; rm -rf $W/db-$name
  tail -1 $W/results.tsv
}
one kn       kn ""
one static-r graal-static ring
one static-x graal-static xio
one jit-r    graal-jit ring
one jit-x    graal-jit xio
one node     node ""
one wasi     wasi ""
echo; python3 -c "
import sys; rows=[l.rstrip('\\n').split('\\t') for l in open(sys.argv[1])]
w=[max(len(r[i]) if i < len(r) else 0 for r in rows) for i in range(max(map(len, rows)))]
[print('  '.join(c.ljust(w[i]) for i, c in enumerate(r))) for r in rows]" $W/results.tsv
