#!/usr/bin/env bash
# Builds as a normal user: the Kotlin/Native server (server/build/bin/linuxX64/feedReleaseExecutable/feed.kexe, the
# runtime start.sh serves by default) with SQLite 3.54.0 linked in from its amalgamation, which the build downloads and
# checks against the SHA3-256 sqlite.org publishes for it. TrikeShed is compiled here from source: the git checkout
# trikeshed/TrikeShed, fetched at the pinned commit below when empty (TRIKESHED_URL overrides the repository), built by
# the :trikeshed module. No prebuilt library and no Maven repository of ours is used.
# The other runtimes (graal-static, graal-jit, node, wasi) build from the same tree with bench/all1000.sh.
#
# Kotlin/Native only, no JVM target: the shell downloads SQLite and checks its SHA3-256 (the URL and hash are read from
# server/build.gradle.kts), then three single-use Gradle JVMs, so no JVM holds two compiles and clang and lld have room:
# TrikeShed's Kotlin/Native compile, the server's Kotlin/Native compile, the release link.
set -euo pipefail
# glibc keeps one malloc arena per thread; two bound the Gradle JVMs' and the Kotlin/Native compiler's native memory.
export MALLOC_ARENA_MAX=2
cd "$(dirname "$0")"
TRIKESHED_COMMIT=20280e86761b3df64cedd4579e311c04411d22b4
if [ ! -d trikeshed/TrikeShed/src ]; then
  commit=$TRIKESHED_COMMIT
  mkdir -p trikeshed/TrikeShed
  git -C trikeshed/TrikeShed init -q
  git -C trikeshed/TrikeShed fetch -q --depth 1 "${TRIKESHED_URL:-https://github.com/jnorthrup/TrikeShed.git}" "$commit"
  git -C trikeshed/TrikeShed checkout -q --detach FETCH_HEAD
fi
if [ -x /opt/graalvm/bin/java ]; then export JAVA_HOME=/opt/graalvm; fi
GRADLE=${GRADLE:-/opt/gradle/bin/gradle}; [ -x "$GRADLE" ] || GRADLE=gradle
url=$(sed -n 's/^val sqliteUrl = "\(.*\)"$/\1/p' server/build.gradle.kts)
sha3=$(sed -n 's/^val sqliteSha3 = "\(.*\)"$/\1/p' server/build.gradle.kts)
sq=server/build/sqlite
if [ ! -f "$sq/sqlite3.c" ] || [ ! -f "$sq/sqlite3.h" ] || [ "$(cat "$sq/sha3" 2>/dev/null)" != "$sha3" ]; then
  mkdir -p "$sq"
  curl -fsSL --retry 3 -o "$sq/amalgamation.zip" "$url"
  got=$(openssl dgst -sha3-256 -r "$sq/amalgamation.zip" | cut -d' ' -f1)
  [ "$got" = "$sha3" ] || { echo "build.sh: $url: SHA3-256 $got, expected $sha3" >&2; exit 1; }
  unzip -j -o -q "$sq/amalgamation.zip" '*/sqlite3.c' '*/sqlite3.h' -d "$sq"
  rm "$sq/amalgamation.zip"
  printf %s "$sha3" > "$sq/sha3"
fi
gradle=("$GRADLE" --no-daemon --console=plain --configure-on-demand -Ptrike.targets=linuxX64 -x :server:sqliteSource)
"${gradle[@]}" :trikeshed:compileKotlinLinuxX64
"${gradle[@]}" :server:compileKotlinLinuxX64
exec "${gradle[@]}" :server:linkFeedReleaseExecutableLinuxX64
