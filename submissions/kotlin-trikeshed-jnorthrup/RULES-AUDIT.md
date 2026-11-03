# Rules audit of other entries (read-only)

This page records rule and SPEC breaks found by reading other entries' code. Nothing was built or run for it, and
nothing was posted on any other PR. Every finding names the commit, the file and line, and quotes the code. The
organizer's rulings already on record (LEADERBOARD.md) are cited where they apply.

Commits read: `upstream/main` 8e166b2 (merged entries) and the open PR heads named below. Rules: README.md "Rules"
1-11. API contract: SPEC.md ("Verify the signature and `exp`, and accept HS256 only. The user id is the integer in
`sub`").

## 1. Every JVM and Kotlin entry (16 merged, 10 open PRs)

Checked for each: R2 (SQLite only), R3 (no schema change), R5 (no caching across requests, every JWT verified), R6
(WAL, synchronous NORMAL or stronger, 201 after commit), R7 (no benchmark-only behaviour), R9 (Nginx or direct
stated), R10 (built from source, pinned, no prebuilt binaries), R11 (no tuning or pinning), and the SPEC's JWT rules.

### SPEC break: a signed token without `exp` is accepted

| Entry | Where | Score | Code |
|---|---|---|---|
| kotlin-nio-3x3xX3N0N | merged | 120,000 | `src/main/kotlin/nio/Jwt.kt:82` `if (exp != null && (exp !is Double \|\| exp <= nowSec.toDouble())) return INVALID` |
| scala-netty-jacksonhoran | merged | 90,000 | `src/main/scala/server/Jwt.scala:46-47` `payload.get("exp") match` / `case null =>` (PR #149, 4430836, removes the `case null` line; not merged) |
| java-nio-stohirov | merged | 102,000 | `src/challenge/Jwt.java:47` `if (exp != null && exp != Json.NULL && !(exp instanceof Double e && now < e)) return INVALID;` |
| java-springboot-reactor-mohkamfer | PR #138, 2183f4a | 71,000 | `Jwt.java:59` `if (exp != null && !(exp instanceof Double e && now < e)) throw INVALID_TOKEN;` |
| java-raw-agrison | PR #101, 5f28c96 | 65,000 | `Jwt.java:96` `if (js.expFound) {` |
| java-netty-lfeagan | PR #63, 4c86f79 | 65,000 | `src/main/java/challenge/Jwt.java:92` `if (exp != null && !(exp instanceof Double d && now < d)) return INVALID;` |
| java-netty-itsnaveenk | PR #57, d30247d | 58,000 | `src/main/java/server/util/FastJwt.java:118-119` `Long exp = extractNumberField(payloadJson, "exp"); if (exp != null && now >= exp) {` |
| kotlin-ktor-C-Hatton | PR #45, a550cad | 65,000 | `src/main/kotlin/Main.kt:216` with `Main.kt:226` `if (claim == null) return true` |
| kotlin-ktor-graalvm-noamm9 | PR #53, 7e92d12 | 10,500 | `src/main/kotlin/dev/noamm9/velox/plugins/Authentication.kt:50` `if (payload["exp"]?.jsonPrimitive?.long?.let { now > it } == true) return null` |
| kotlin-ktor-jvm-syorito-hatsuki | PR #36, 9036881 | 14,000 | `src/main/kotlin/dev/syoritohatsuki/tdsck/plugins/Authentication.kt:16` `JWT.require(Algorithm.HMAC256(JWT_SECRET)).build()` (java-jwt checks `exp` only when present) |
| java-virtualthreads-Ahosan1Siam | PR #85, 00f7e75 | not scored | `JwtAuth.java:82` `if (exp != null && exp < nowSec) {` |

The organizer lists most of these under "Tokens without `exp` accepted (SPEC requires rejecting them)" in
LEADERBOARD.md:460-464, held open until fixed. The merged code of kotlin-nio-3x3xX3N0N, scala-netty-jacksonhoran and
java-nio-stohirov still has the break at 8e166b2.

### Other breaks

| Entry | Where | Finding |
|---|---|---|
| java-vertx-super-horst | PR #92, c1bbd84 | R9: the entry folder has no README; `app/README.md:1` is `# Vert.x Submission` and does not say Nginx or direct. SPEC: an all-digit string body such as `{"body":"42"}` gets 400 (`ApiHandler.java:89-92`), a workaround for the test's `{"body":123}` case; `sub` "0" or "-1" passes (`ApiHandler.java:161` `Integer.parseInt(user.get("sub"))`). |
| java-virtualthreads-Ahosan1Siam | PR #85, 00f7e75 | SPEC: `sub` is not checked as a positive integer string; "0", "-5" and a JSON number pass (`JwtAuth.java:89-90`). R10 (healthy in 60 s), needs a run: `start.sh:12` passes `-XX:+UseCompactObjectHeaders` (JDK 24 and later) while `install.sh` installs JDK 21. |
| java-helidon-dglynch | merged | SPEC error paths, need a run: after a SQL error the writer rolls back but leaves the batch pending, so those requests get no 500 (`DatabaseModel.java:184-190`); a read error on `/feed` returns 200 with an empty list (`DatabaseModel.java:95-97`). |
| java-quarkus-wolches | merged | SPEC: a failed health check returns 200, not 503 (`HealthService.java:24`); post ids above 2^31 get 400, not 404 (`PostId.java:16`). |

No JVM or Kotlin entry breaks R2, R3, R5, R6, R7 or R11 in its code. None tracks a prebuilt binary except the
standard `gradle-wrapper.jar`, which the organizer ruled allowed (LEADERBOARD.md:465-466).

## 2. Package managers and pinning, every entry (150 merged, 70 open PRs)

Each entry's manifests, lockfiles and install/build/start scripts were scanned for dependency managers (cargo, npm,
yarn, pnpm, bun, pip, uv, poetry, go, bundler, composer, NuGet, Maven, Gradle, mix, deno, zig, cabal, stack, swift,
conan, vcpkg, nimble, apt), unpinned versions (`latest`, `*`, ranges, `curl | sh` installers without a version) and
tracked files with ELF, Mach-O, PE, ar, jar or wasm magic. Each hit below was then read by hand; scanner hits that were
words in comments, or ranges fixed by a committed lockfile (composer.lock in the three PHP entries), are not listed.

| Entry | Where | Finding |
|---|---|---|
| ailang-native-2paws | PR #115, 4029d8e | R10: tracks a prebuilt ELF binary, `compiler/ailang-opt11.x` (6,492,317 bytes), and `build.sh:7` compiles the server with it (`COMPILER="${AILANG_COMPILER:-$PWD/compiler/ailang-opt11.x}"`); `.gitignore` excludes `*.x` but un-ignores this file. |
| rust-hyper-dannie203 | PR #178, 6aa144b | R10 pinning: `install.sh:6` `curl ... https://sh.rustup.rs \| sh -s -- -y` installs whatever Rust is current (no `--default-toolchain` version, no rust-toolchain file). Crates are pinned by Cargo.lock. |
| python-pyrustapi-rajboopathiking | PR #147, 82abaab | R10 pinning: `install.sh:15` `--default-toolchain stable` (current Rust, not a version). Python packages are pinned with `==`. |
| python-granian-hoopengo | PR #109, ea29475 | R10 pinning: `install.sh:23` `curl -LsSf https://astral.sh/uv/install.sh \| sh` installs the current uv. Packages are pinned with `==` (`build.sh:21-24`). |

Apt packages are installed without versions in 212 of 218 scanned entries, ours included; the organizer has not
treated that as a break.

## 3. This entry, by the same checks

- JWT: signature, HS256 and `exp` on every request; a token without `exp` is a 401
  (`server/src/commonMain/kotlin/borg/trikeshed/feed/Jwt.kt:44`).
- SQLite: the 3.54.0 amalgamation is downloaded, checked against sqlite.org's SHA3-256, and compiled unchanged on the
  box; `feedbt.c` includes it whole.
- R10: the submission tracks no file with ELF, Mach-O, PE, ar, jar or wasm magic. TrikeShed is compiled on the box
  from its source at the commit pinned in `build.sh`.
