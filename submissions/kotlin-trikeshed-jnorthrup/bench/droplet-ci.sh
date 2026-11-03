#!/usr/bin/env bash
# droplet-ci.sh TARGET: one clean ubuntu:24.04 run of one runtime, as CI does it (CI tools, install.sh as root,
# test/run.sh as a normal user), with build.sh's Gradle line replaced by TARGET's build and start.sh run with
# RUNTIME=TARGET. TREE is the challenge repository root (seed/feed.db made, the TrikeShed checkout in place). Run as
#   docker run --rm --cpus=1 --memory=2g --memory-swap=2g --security-opt seccomp=unconfined -v TREE:/src:ro -v OUT:/out \
#     ubuntu:24.04 bash /src/submissions/kotlin-trikeshed-jnorthrup/bench/droplet-ci.sh TARGET
# (seccomp unconfined: the droplet has no seccomp filter, and Docker's default one refuses io_uring).
# Writes /out/TARGET.txt: per-phase wall time, anon memory peak, the serving runtime, disk use, the test result.
set -uo pipefail
T=${1:?target: graal-jit graal-static kn node wasi}
S=submissions/kotlin-trikeshed-jnorthrup
R=/out/$T.txt; : > "$R"
log() { echo "$*" | tee -a "$R"; }
# anon (not page cache) sampled every second; each phase reports its own peak.
( while sleep 1; do a=$(awk '/^anon / {print $2}' /sys/fs/cgroup/memory.stat); m=$(cat /tmp/anonmax 2>/dev/null || echo 0)
    [ "$a" -gt "$m" ] && echo "$a" > /tmp/anonmax; done ) &
phase() { local name=$1; shift; local t0; t0=$(date +%s); echo 0 > /tmp/anonmax; "$@" > "/out/$T-$name.log" 2>&1; local rc=$?
  log "$name rc=$rc wall=$(( $(date +%s) - t0 ))s anon.peak=$(( $(cat /tmp/anonmax) >> 20 ))MB"; return $rc; }

# Same as CI's workflow: tools for test/test.sh.
phase ci-tools bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sqlite3 jq curl openssl xz-utils sudo' || exit 1
cp -a /src /w && cd /w
phase install bash $S/install.sh || exit 1

# node and wasi need runtimes install.sh does not fetch: bench/install-extra.sh (aria2c, sha256 from bench/DEPS.tsv).
case $T in node|wasi) phase extra bash $S/bench/install-extra.sh || exit 1 ;; esac

# TARGET's build in place of build.sh (the TrikeShed checkout is already in the tree, so build.sh's fetch is skipped).
G='"$GRADLE" --no-daemon --quiet --console=plain'
case $T in
  graal-jit)    B="$G :server:app :server:sqliteLib" ;;
  graal-static) B="$G :server:app :server:sqliteLib && mkdir -p server/build/native && /opt/graalvm/bin/native-image -J-Xmx1400m --no-fallback --gc=serial -march=native --enable-native-access=ALL-UNNAMED --initialize-at-build-time=borg.trikeshed.feed.SqliteCalls -cp 'server/build/app/*' -o server/build/native/feed-static borg.trikeshed.feed.MainKt" ;;
  kn)           B="$G -Ptrike.targets=linuxX64 :server:linkFeedReleaseExecutableLinuxX64" ;;
  node)         B="$G -Ptrike.targets=js :server:nodeDist" ;;
  wasi)         B="$G -Ptrike.targets=wasmWasi :server:wasiDist" ;;
esac
B="$B" awk '/^"\$GRADLE" --no-daemon/ { print ENVIRON["B"]; next } { print }' $S/build.sh > /tmp/b && mv /tmp/b $S/build.sh
grep -qxF "$B" $S/build.sh || { log "build.sh edit failed"; exit 1; }

useradd -m u && chown -R u:u /w
phase test sudo -u u -H env RUNTIME=$T bash test/run.sh $S
rc=$?
log "test: $(tail -2 /out/$T-test.log | tr '\n' ' ')"
# Which runtime served: start.sh again on a fresh copy, then the executable of the process it exec'd.
mkdir -p /tmp/rt && cp seed/feed.db /tmp/rt/ && chown -R u:u /tmp/rt
setpriv --reuid=u --regid=u --init-groups env HOME=/home/u RUNTIME=$T SQLITE_PATH=/tmp/rt/feed.db \
  JWT_SECRET=twelve-dollar-challenge HOST=127.0.0.1 PORT=3001 bash $S/start.sh > /out/$T-start.log 2>&1 &
P=$!
for _ in $(seq 60); do curl -sf http://127.0.0.1:3001/health > /dev/null && break; sleep 1; done
log "served by: $(grep -m1 'start.sh: RUNTIME' /out/$T-start.log) exe=$(readlink /proc/$P/exe) health=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3001/health)"
kill $P 2>/dev/null; wait $P 2>/dev/null
log "disk: /opt $(du -sh /opt | cut -f1), /home/u $(du -sh /home/u | cut -f1), tree $(du -sh /w | cut -f1)"
exit $rc
