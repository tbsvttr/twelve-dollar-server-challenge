# Leaderboard

Every submission, scored on the same box with the same load test. New PRs are benchmarked as they come in and
added here, so this is the only leaderboard.

**The machine.** A **Synteq 1 vCPU / 2 GB VPS** (KVM, Xeon Platinum 8260 @ 2.4 GHz with AVX-512, 1,967 MB RAM, no
swap, Ubuntu 24.04, kernel 6.8), stock: no UFW (so no conntrack table) and no kernel tuning.

**How each entry is scored.** Built from source with its own install.sh (root) / build.sh (user `deploy`), started by
systemd as `deploy` with LimitNOFILE=65535 and CAP_NET_BIND_SERVICE on a fresh copy of the seed, and checked with the
42-check test suite before any load. Load comes from separate 16-core load generators in the same datacenter (0.25 ms
RTT) running the `bench/load.js` user model (feed → think → post → think → 15 % like, 2 % post). Search: 2-minute probes
doubling, then bisecting to ~5 %, then a 5-minute hold, stepping down 5 % until one passes. **Score = most users that
passed a 5-minute hold** with p95 < 500 ms, p99 < 1 s, errors < 1 %. Every probe restarts the app on a fresh database.

**Commits scored.** Each PR's head at the time of its run. zig-iouring-marler8997 #125 was updated afterwards, and
its merged code is newer than what was scored (`a08923d`). go-epoll-MegaPanchamZ is scored at its follow-up PR #144
(`e66a931`, not merged yet); its earlier #72 run (`9df7449`) held 165,000. c-iouring-meros is scored at its follow-up PR #199 (`097ef9b`, not
merged yet); its merged #137 code (`b2a5207`) held 235,000. fsharp-kestrel-delneg is scored at its follow-up PR #201
(`a8bf27f`); its earlier #142 run (`45ebea5`) held 260,000. c-iouring-moneebullah25 is scored at its follow-up PR
#244 (`aad9c34`); its #228 run (`f07f17f`) held 228,000, its #203 run (`3f0c2c1`) 230,000 and its earlier #156 run
(`065c235`) 209,000. v-epoll-i098
is scored at its follow-up PR #191 (`47a4cbb`); its earlier #113 run held 100,000. crystal-rayo-faustinoaq is scored at
its follow-up PR #218 (`15b3d62`); its earlier #202 run (`cc1105c`) held 60,000 (it refused connections past ~60k at
30 % CPU). asm-epoll-HauLTCE is scored at its follow-up PR #207
(`d273c86`); its earlier #130 run (`8c3c277`) held 120,000. ada-native-visseranalytics is scored at its follow-up PR
#237 (`7ce1623`, the same code as #216's `ee683db`; 260,000 and 280,000 failed the 2-minute probe on p99 at 0 % errors);
its #229 run (`f0fb733`) held 232,000, its #216 run (`ee683db`) and #211 run (`7ff01df`) 270,000, its #223 run
(`5eebfe2`) 257,000 and its earlier #198 run (`bb6aee1`) 226,000. dexlang-iouring-ensamuel7 is scored at its follow-up PR #251
(`c53ff1f`); its #236 run (`9ed9f2e`) held 157,000, its #226 run (`a343a03`) held 140,000 and its earlier #205 run (`6271ee8`) held 133,000. c-iouring-shivanshthapliyal is scored at its follow-up PR
#250 (`051f03c`); its #230 run (`b32c4ee`) held 270,000 and its earlier #214 run (`9844f31`) held 238,000. sql-sqlite3cli-public is scored at its follow-up PR
#232 (`1319a07`); its earlier #219 run (`3f7cab9`) held 6,000. c-iouring-pavlyhalim is scored at its follow-up PR #245
(`7387a31`); its earlier #233 run (`3f5c305`) held 270,000. Its later follow-up #278 (`088cc44`, `db.h` tuning; held,
not merged: it didn't beat the merged row) scored 290,000 (27,513 req/s, p95 78 / p99 345 ms, 0 err, 87 % CPU, 28 µs/req,
654 MB, 2026-11-02; 300,000 failed the 2-minute probe on p99 4.0 s). rust-iouring-kensac is scored at its follow-up PR #264
(`4298101`, not merged yet); its merged #248 code (`3bd2352`, merged as rebased `551ff3a`) held 270,000 and its earlier
#247 run (`d42783b`) 257,000. php-symfony-gnugat is scored at its follow-up PR #256 (`4a11a5d`); its
earlier #136 run (`48e3783`) held 15,500. mojo-iouring-oh-meh is scored at its follow-up PR #257 (`a9df151`); its merged
#224 code (`ef45beb`) held 280,000, and its earlier #224 runs held 280,000 (`29024f3`) and 290,000 (`1f4eb0b`).
java-jdkhttpserver-razorree is scored at its follow-up PR #262 (`d1268e6`); its merged #209 code (`89e75e0`) held 38,000
(0.89 % dropped writes below full CPU) and its earlier #209 run (`d2286fa`) 9,500. rust-native-M3M0KA is scored at
#265 (`412c71a`), which replaces its closed #222; the #222 run (`13151f2`) held 135,000. rust-native-scooter1337 is scored at its follow-up PR #267 (`908ea75`); its
earlier #238 run (`9cbd120`) held 210,000. wat-wasmedge-delneg is scored at its merged follow-up PR #272 (`7792fa9`);
its earlier #272 runs held 247,000 (`c193a82`) and 270,000 (`f220565`), and its #259 code (`48942ac`) 60,000.
lean-verified-soonhokong is scored at #286 (`fe89683`), which replaces its closed #271; the #271 run (`30d259c`) held
290,000. c-iouring-unorig-username is scored at its follow-up PR #290 (`97d0470`); its earlier #184 run (`e157f0c`) held
250,000.

**Re-runs.** The first submissions (#2–#29) were scored on a DigitalOcean $12 droplet, which is about 2× slower for
CPU-bound servers, so those numbers aren't comparable. All of them have now been re-run on this box (finished
2026-10-27). The old numbers are in [`benchmarks/batch-1.md`](benchmarks/batch-1.md).

## Results

CPU % and µs/request are the app's own cgroup over the scored hold (µs = app CPU time ÷ requests). RAM = app cgroup peak.

| # | Submission | PR | Language | Users held 5 min | req/s | p95 ms | p99 ms | err % | CPU % | µs/req | RAM MB | Scored |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | rust-iouring-kensac | #264 | Rust (io_uring, SQLite B-tree reads) | **310,000** | 29,284 | 62 | 190 | 0.00 | 82 | 25 | 1,114 | 2026-11-02 |
| 2 | mojo-iouring-oh-meh | #257 | Mojo (io_uring, SQLite B-tree reads) | **304,000** | 28,705 | 159 | 545 | 0.00 | 82 | 26 | 726 | 2026-11-01 |
| 3 | c-iouring-pavlyhalim | #245 | C (io_uring, SQLite B-tree reads) | **295,000** | 28,013 | 28 | 117 | 0.00 | 81 | 26 | 1,536 | 2026-11-01 |
| 4 | rust-native-scooter1337 | #267 | Rust (io_uring, SQLite B-tree reads) | **290,000** | 27,580 | 26.5 | 514 | 0.00 | 80 | 26 | 1,035 | 2026-11-02 |
| 5 | lean-verified-soonhokong | #286 | Lean 4 (verified handlers, io_uring, SQLite B-tree reads) | **280,000** | 26,678 | 44.9 | 359 | 0.00 | 74 | 25 | 1,390 | 2026-11-03 |
| 5 | lean-derive-hargup | #153 | Lean 4 (generated C, io_uring) | **280,000** | 26,683 | 141 | 316 | 0.00 | 92 | 31 | 836 | 2026-10-28 |
| 5 | objc-uring-delneg | #154 | Objective-C (GNUstep, io_uring, SQLite B-tree reads) | **280,000** | 26,741 | 35 | 227 | 0.00 | 79 | 27 | 1,245 | 2026-10-31 |
| 5 | c-iouring-unorig-username | #290 | C (io_uring, SQLite B-tree reads) | **280,000** | 26,688 | 56.4 | 713 | 0.00 | 78 | 26 | 1,357 | 2026-11-03 |
| 9 | c-iouring-shivanshthapliyal | #250 | C (io_uring, SQLite B-tree reads) | **276,000** | 26,403 | 23 | 147 | 0.00 | 77 | 26 | 638 | 2026-11-01 |
| 10 | c-iouring-public | #158 | C (io_uring, SQLite B-tree reads) | **275,000** | 26,227 | 128 | 672 | 0.00 | 80 | 28 | 625 | 2026-10-31 |
| 11 | crystal-epoll-faustinoaq | #193 | Crystal (io_uring) | **270,000** | 25,693 | 348 | 879 | 0.00 | 92 | 32 | 1,160 | 2026-10-29 |
| 11 | lexlean-iouring-humuhumu33 | #287 | C (LexLean/Lean 4-generated core, io_uring, SQLite B-tree reads) | **270,000** | 25,873 | 40.2 | 206 | 0.00 | 78 | 27 | 1,067 | 2026-11-03 |
| 11 | goose-iouring-ahmadsh2007 | #291 | Goose (compiles to C, io_uring, SQLite B-tree reads) | **270,000** | 25,854 | 84.8 | 349 | 0.00 | 78 | 27 | 1,190 | 2026-11-03 |
| 14 | rust-epoll-scooter1337 | #82 | Rust (io_uring) | **264,000** ˣ | 25,147 | 259 | 499 | 0.00 | 84 | 30 | 630 | 2026-10-21 |
| 15 | c-rawsqlite-larvance | #210 | C (io_uring, SQLite B-tree reads) | **260,000** | 24,914 | 241 | 962 | 0.00 | 88 | 32 | 744 | 2026-11-03 |
| 16 | v-epoll-i098 | #191 | V (io_uring, SQLite B-tree reads) | **257,000** | 24,766 | 13.5 | 29 | 0.00 | 74 | 27 | 732 | 2026-10-30 |
| 17 | asm-iouring-unorig-username | #206 | x86-64 asm (io_uring) | **250,000** | 24,053 | 141 | 397 | 0.00 | 91 | 34 | 1,486 | 2026-10-30 |
| 17 | ada-native-visseranalytics | #237 | Ada (GNAT, io_uring) | **250,000** | 24,119 | 84 | 286 | 0.00 | 77 | 29 | 1,169 | 2026-11-01 |
| 17 | c-rawuring-thehimalayanleo | #269 | C (io_uring, SQLite B-tree reads) | **250,000** | 24,014 | 220 | 359 | 0.00 | 79 | 30 | 970 | 2026-11-02 |
| 20 | fsharp-kestrel-delneg | #201 | F# (Kestrel, io_uring) | **247,000** | 23,884 | 14 | 72 | 0.00 | 71 | 27 | 750 | 2026-10-30 |
| 20 | lisp-sbcl-heyitstony97-max | #283 | Common Lisp (SBCL, io_uring, SQLite B-tree reads) | **247,000** | 23,772 | 251 | 596 | 0.00 | 79 | 30 | 1,187 | 2026-11-03 |
| 22 | asm-epoll-umitaltintas | #152 | x86-64 asm (io_uring) | **240,000** | 22,985 | 366 | 633 | 0.00 | 83 | 33 | 545 | 2026-10-28 |
| 22 | cider-iouring-pomilon-v5 | #273 | Cider (native x86-64, io_uring, SQLite B-tree reads) | **240,000** | 23,198 | 145 | 236 | 0.02 | 92 | 36 | 706 | 2026-11-02 |
| 24 | c-iouring-meros | #199 | C (io_uring) | **238,000** | 22,796 | 417 | 750 | 0.00 | 78 | 31 | 1,567 | 2026-10-30 |
| 25 | zig-iouring-unorig-username | #190 | Zig (io_uring) | **235,000** | 22,785 | 34 | 160 | 0.00 | 80 | 32 | 1,019 | 2026-10-29 |
| 25 | cider-iouring-pomilon-v4 | #249 | Cider (native x86-64, io_uring, SQLite B-tree reads) | **235,000** | 22,817 | 10.5 | 29 | 0.00 | 88 | 35 | 908 | 2026-11-01 |
| 27 | c-uring-curvynes | #217 | C (io_uring, SQLite B-tree reads) | **230,000** | 22,287 | 259 | 374 | 0.00 | 82 | 34 | 773 | 2026-10-30 |
| 27 | c-iouring-moneebullah25 | #244 | C (io_uring, SQLite B-tree reads) | **230,000** | 22,289 | 51 | 470 | 0.00 | 67 | 28 | 828 | 2026-11-01 |
| 27 | go-iouring-rkkautsar | #260 | Go (io_uring, cgo SQLite B-tree reads) | **230,000** | 22,069 | 66.8 | 438 | 0.00 | 93 | 39 | 799 | 2026-11-03 |
| 27 | rust-native-M3M0KA | #265 | Rust (no crates, epoll/io_uring, 5 worker processes, SQLite B-tree reads) | **230,000** ʳ | 22,304 | 150 | 352 | 0.00 | 90 | 37 | 1,350 | 2026-11-02 |
| 27 | nelua-iouring-tbsvttr | #281 | Nelua (io_uring, SQLite B-tree reads) | **230,000** | 22,379 | 11.8 | 49.6 | 0.00 | 69 | 28 | 938 | 2026-11-02 |
| 32 | cider-iouring-pomilon-v3 | #234 | Cider (native x86-64, io_uring, SQLite B-tree reads) | **228,000** | 21,945 | 370 | 853 | 0.00 | 86 | 36 | 668 | 2026-10-31 |
| 33 | dexlang-iouring-tuned-ensamuel7 | #279 | DexLang (generated C, io_uring, SQLite B-tree reads) | **226,000** | 21,876 | 297 | 633 | 0.00 | 84 | 35 | 873 | 2026-11-02 |
| 34 | swift-iouring-Tabonx | #173 | Swift (io_uring, SQLite) | **219,000** | 21,284 | 135 | 352 | 0.00 | 80 | 35 | 1,128 | 2026-10-29 |
| 35 | cpp-eastl-io_uring-pgo-hendy643 | #32 | C++ (io_uring, EASTL) | **210,000** | 20,436 | 322 | 672 | 0.00 | 73 | 33 | 633 | 2026-10-26 |
| 35 | csharp-epoll-gichamba | #174 | C# (Native AOT, io_uring) | **210,000** | 20,411 | 277 | 853 | 0.00 | 76 | 35 | 632 | 2026-10-29 |
| 35 | c-epoll-unorig-username | #183 | C (epoll) | **210,000** | 20,425 | 300 | 713 | 0.00 | 95 | 43 | 808 | 2026-10-29 |
| 35 | cider-iouring-pomilon-v2 | #225 | Cider (native x86-64, io_uring) | **210,000** | 20,404 | 348 | 504 | 0.00 | 86 | 39 | 611 | 2026-10-31 |
| 39 | csharp-iouring-jit-gichamba | #175 | C# (JIT, io_uring) | **209,000** | 20,265 | 366 | 735 | 0.00 | 84 | 38 | 633 | 2026-10-31 |
| 40 | zig-epoll-unorig-username | #189 | Zig (epoll) | **200,000** | 19,661 | 54 | 154 | 0.00 | 94 | 44 | 1,155 | 2026-10-29 |
| 40 | crystal-rayo-faustinoaq | #218 | Crystal (Rayo, io_uring, SQLite B-tree reads) | **200,000** | 19,615 | 236 | 596 | 0.00 | 82 | 39 | 1,198 | 2026-10-31 |
| 40 | c-epoll-patrickryankenneth | #246 | C (io_uring, epoll fallback) | **200,000** ᵉ | 19,464 | 447 | 692 | 0.00 | 81 | 39 | 762 | 2026-11-02 |
| 40 | wat-wasmedge-delneg | #272 | WebAssembly (hand-written WAT, WasmEdge AOT, io_uring, SQLite B-tree reads) | **200,000** ᵒ | 19,678 | 13.1 | 189.9 | 0.00 | 63 | 30 | 1,072 | 2026-11-03 |
| 44 | dexlang-iouring-ensamuel7 | #251 | DexLang (generated C, io_uring) | **199,000** | 19,425 | 316 | 579 | 0.00 | 89 | 43 | 713 | 2026-11-01 |
| 45 | sql-oneselect-grMLEqomlkkU5Eeinz4brIrOVCUCkJuN | #243 | SQL (one SELECT over a virtual table, C io_uring) | **190,000** | 18,653 | 129 | 573 | 0.00 | 94 | 47 | 1,205 | 2026-11-02 |
| 46 | csharp-iouring-oswaldosierra | #157 | C# (Native AOT, io_uring) | **189,000** | 18,592 | 20 | 51 | 0.00 | 88 | 44 | 1,176 | 2026-10-28 |
| 46 | csharp-iouring-AlexandruLT | #196 | C# (Native AOT, io_uring) | **189,000** | 18,599 | 19.5 | 212 | 0.00 | 84 | 42 | 693 | 2026-10-29 |
| 48 | go-epoll-MegaPanchamZ | #144 | Go (raw epoll) | **185,000** | 18,086 | 288 | 479 | 0.00 | 99 | 51 | 1,286 | 2026-10-28 |
| 49 | go-epoll-kaikegm | #151 | Go (raw epoll, cgo SQLite) | **175,000** | 16,616 | 37 | 253 | 0.61 | 98 | 55 | 749 | 2026-10-28 |
| 49 | kotlin-trikeshed-jnorthrup | #128 | Kotlin (Kotlin/Native, io_uring, SQLite B-tree reads) | **175,000** | 17,052 | 209.8 | 256 | 0.00 | 64 | 35 | 756 | 2026-11-03 |
| 51 | c-iouring-raoz | #26 | C (io_uring) | **172,000** | 16,875 | 98 | 125 | 0.00 | 69 | 38 | 419 | 2026-10-27 |
| 52 | asm-nasm-melroy89 | #86 | x86-64 asm (io_uring) | **171,000** | 16,777 | 87 | 142 | 0.00 | 78 | 43 | 358 | 2026-10-21 |
| 53 | go-epoll-unorig-username | #186 | Go (raw epoll, cgo SQLite) | **165,000** | 16,020 | 479 | 952 | 0.00 | 97 | 56 | 665 | 2026-10-29 |
| 54 | asm-epoll-HauLTCE | #207 | x86-64 asm (epoll, forked workers) | **160,000** ᵃ | 15,682 | 291 | 757 | 0.61 | 95 | 56 | 1,307 | 2026-10-30 |
| 55 | java-uring-crux | #170 | Java (FFM io_uring, C row formatter) | **158,000** | 15,531 | 137 | 312 | 0.00 | 72 | 43 | 1,139 | 2026-10-29 |
| 56 | asm-epoll-unorig-username | #181 | x86-64 asm (epoll) | **155,000** | 15,256 | 14 | 55 | 0.00 | 87 | 53 | 858 | 2026-10-29 |
| 56 | python-pypy-iouring-kiwamizamurai | #284 | PyPy (io_uring, SQLite B-tree reads) | **155,000** | 15,201 | 120 | 277 | 0.00 | 80 | 49 | 525 | 2026-11-03 |
| 58 | holyphp-io-uring-elifoxcoder | #280 | HolyPHP (io_uring, SQLite B-tree reads) | **152,000** ᵘ | 14,892 | 208 | 672 | 0.00 | 62 | 39 | 703 | 2026-11-02 |
| 59 | c-iouring-ssmurfgg04-gif | #112 | C (io_uring) | **150,000** | 14,611 | 385 | 524 | 0.00 | 78 | 50 | 413 | 2026-10-21 |
| 60 | c-ammarserver-AmmarkoV | #54 | C (AmmarServer, io_uring) | **135,000** | 13,239 | 95 | 470 | 0.00 | 76 | 53 | 320 | 2026-10-27 |
| 60 | go-epoll-brady1408 | #111 | Go (raw epoll, cgo SQLite) | **135,000** | 13,169 | 366 | 962 | 0.00 | 100 | 70 | 296 | 2026-10-27 |
| 60 | cider-iouring-pomilon | #208 | Cider (native x86-64, io_uring) | **135,000** | 13,168 | 256 | 489 | 0.00 | 88 | 62 | 425 | 2026-10-30 |
| 63 | odin-odinhttp-wanderingaura | #139 | Odin (odin-http) | **130,000** | 12,644 | 429 | 924 | 0.00 | 82 | 60 | 624 | 2026-10-28 |
| 63 | ruby-uring-cicloid | #197 | Ruby (io_uring) | **130,000** | 12,625 | 366 | 573 | 0.00 | 90 | 66 | 679 | 2026-10-29 |
| 65 | go-epoll-champ3oy | #76 | Go (io_uring) | **128,000** | 12,604 | 3 | 23 | 0.00 | 77 | 57 | 385 | 2026-10-21 |
| 66 | cobol-gnucobol-unorig-username | #185 | COBOL (GnuCOBOL, epoll) | **126,000** | 12,398 | 34 | 125 | 0.00 | 93 | 70 | 607 | 2026-10-29 |
| 67 | cpp-uwebsockets-v2-tbsvttr | #15 | C++ (uWebSockets) | **125,000** | 12,188 | 204 | 306 | 0.00 | 89 | 68 | 182 | 2026-10-26 |
| 67 | go-epoll-Antheurus | #65 | Go (raw epoll, 3 processes) | **125,000** | 12,274 | 116 | 665 | 0.00 | 98 | 74 | 292 | 2026-10-27 |
| 67 | go-lowlevel-janso123 | #91 | Go (io_uring, PGO + ThinLTO) | **125,000** | 12,284 | 68 | 261 | 0.00 | 95 | 72 | 500 | 2026-10-27 |
| 67 | java-nio-unorig-username | #187 | Java (NIO, FFM SQLite) | **125,000** | 12,303 | 9.2 | 49 | 0.00 | 88 | 66 | 1,038 | 2026-10-29 |
| 71 | kotlin-nio-3x3xX3N0N | #83 | Kotlin (NIO, 2 JVMs) | **120,000** | 11,759 | 246 | 524 | 0.00 | 100 | 79 | 1,380 | 2026-10-21 |
| 71 | rust-iouring-unorig-username | #188 | Rust (io_uring) | **120,000** | 11,799 | 12 | 144 | 0.00 | 46 | 36 | 543 | 2026-10-29 |
| 73 | cpp-uwebsockets-tbsvttr | #6 | C++ (uWebSockets) | **115,000** | 10,940 | 261 | 652 | 0.00 | 87 | 74 | 215 | 2026-10-26 |
| 74 | d-iouring-cyrusmsk | #163 | D (io_uring, during) | **114,000** | 11,158 | 248 | 567 | 0.00 | 87 | 73 | 475 | 2026-11-01 |
| 75 | zig-usockets-tbsvttr | #25 | Zig (uSockets) | **110,000** | 10,442 | 335 | 721 | 0.00 | 90 | 80 | 188 | 2026-10-26 |
| 76 | c-epoll-TheFirstIstari | #64 | C (epoll) | **107,000** | 10,493 | 212 | 409 | 0.94 | 78 | 69 | 169 | 2026-10-21 |
| 77 | java-nio-stohirov | #88 | Java (FFM epoll) | **102,000** | 10,023 | 86 | 128 | 0.85 | 66 | 61 | 555 | 2026-10-21 |
| 78 | d-eventcore-cyrusmsk | #165 | D (eventcore) | **98,000** | 9,610 | 109 | 750 | 0.00 | 85 | 82 | 475 | 2026-11-01 |
| 79 | node-uwebsockets-zahidcakici | #102 | Node (uWebSockets) | **97,000** | 9,471 | 264 | 484 | 0.00 | 92 | 90 | 336 | 2026-10-21 |
| 80 | typescript-bun-xxmohamed012 | #3 | Bun | **90,000** | 8,826 | 140 | 359 | 0.00 | 83 | 87 | 301 | 2026-10-21 |
| 80 | scala-netty-jacksonhoran | #107 | Scala (Netty) | **90,000** ʸ | 8,801 | 484 | 757 | 0.00 | 87 | 92 | 825 | 2026-10-21 |
| 80 | python-pypy-epoll-pranavds-codes | #84 | PyPy (epoll) | **90,000** | 8,801 | 280 | 474 | 0.00 | 89 | 94 | 270 | 2026-10-21 |
| 80 | java-springboot-bogdan-blaj | #124 | Java (Spring Boot, Netty, FFM SQLite) | **90,000** | 8,804 | 342 | 888 | 0.00 | 85 | 90 | 1,172 | 2026-10-28 |
| 84 | lua-openresty-yar0slav | #94 | Lua (OpenResty) | **88,000** | 8,477 | 434 | 591 | 0.04 | 92 | 101 | 267 | 2026-10-21 |
| 84 | asm-epoll-FlavouredTux | #75 | x86-64 asm (epoll) | **88,000** | 8,628 | 170 | 438 | 0.00 | 85 | 92 | 189 | 2026-10-27 |
| 84 | go-gnet-kaikegm | #180 | Go (gnet) | **88,000** ⁿ | 8,633 | 236 | 363 | 0.00 | 77 | 83 | 313 | 2026-10-29 |
| 87 | archbtw-epoll-BlueFill | #200 | ArchBTW (transpiled to C, epoll) | **85,000** | 8,284 | 349 | 562 | 0.02 | 88 | 99 | 525 | 2026-10-30 |
| 88 | rust-axum-tbsvttr | #17 | Rust (Axum) | **76,000** | 7,434 | 280 | 551 | 0.00 | 85 | 106 | 1,118 | 2026-10-26 |
| 89 | python-stdlib-shawal-mbalire | #118 | Python (stdlib, PGO CPython) | **75,000** | 7,327 | 342 | 514 | 0.00 | 90 | 114 | 326 | 2026-10-27 |
| 90 | zig-iouring-marler8997 ᵖ | #125 | Zig (io_uring) | **71,000** ᶠ | 6,559 | 1.0 | 1.5 | 0.93 | 31 | 44 | 199 | 2026-10-21 |
| 90 | typescript-deno-JakeAve | #119 | Deno | **71,000** ᶠ | 6,558 | 5.6 | 13 | 0.93 | 47 | 67 | 412 | 2026-10-21 |
| 90 | dart-rawsocket-C-Hatton | #46 | Dart | **71,000** ᶠ | 6,550 | 34 | 80 | 0.93 | 94 | 134 | 475 | 2026-10-21 |
| 90 | cpp-epoll-khalefa-ow | #8 | C++ (epoll) | **71,000** ᶠ | 6,558 | 19 | 37 | 0.93 | 94 | 134 | 184 | 2026-10-21 |
| 90 | go-fib-sirkostya009 | #34 | Go (fib, epoll) | **71,000** ᶠ | 6,552 | 109 | 248 | 0.93 | 61 | 87 | 674 | 2026-10-26 |
| 90 | cpp-epoll_inmem-khalefa-ow | #9 | C++ (epoll) | **71,000** ᶠ | 6,555 | 30 | 148 | 0.93 | 92 | 131 | 353 | 2026-10-26 |
| 90 | c-h2o-einhornimmond | #39 | C (H2O) | **71,000** ᶠ | 6,558 | 0.8 | 4.9 | 0.93 | 39 | 56 | 331 | 2026-10-26 |
| 90 | c-epoll-benclawbot | #42 | C (epoll) | **71,000** ᶠ | 6,555 | 29 | 53 | 0.93 | 94 | 134 | 409 | 2026-10-26 |
| 90 | go-stdlib-vkrishna03 | #44 | Go (stdlib, epoll) | **71,000** ᶠ | 6,547 | 74 | 251 | 0.93 | 38 | 54 | 231 | 2026-10-26 |
| 90 | php-swoole-mattsplat | #24 | PHP (Swoole) | **71,000** ᶠ | 6,552 | 45 | 102 | 0.93 | 66 | 94 | 1,025 | 2026-10-26 |
| 90 | go-epoll-damianoneill | #52 | Go (raw epoll) | **71,000** ᶠ | 6,551 | 50 | 78 | 0.93 | 41 | 59 | 157 | 2026-10-26 |
| 90 | c-iouring-einhornimmond | #55 | C (io_uring) | **71,000** ᶠ | 6,556 | 2.7 | 10 | 0.92 | 36 | 51 | 190 | 2026-10-27 |
| 90 | php-swoole-tzimpel | #28 | PHP (Swoole) | **71,000** ᶠ | 6,552 | 17 | 175 | 0.93 | 71 | 101 | 325 | 2026-10-27 |
| 90 | c-iouring-27bhd | #68 | C (io_uring) | **71,000** ᶠ | 6,554 | 30 | 44 | 0.93 | 84 | 120 | 186 | 2026-10-27 |
| 90 | go-nethttp-mattn-vedic | #100 | Go (raw epoll, cgo SQLite) | **71,000** ᶠ | 6,552 | 36 | 50 | 0.93 | 55 | 78 | 332 | 2026-10-27 |
| 90 | rust-axum-mjc | #114 | Rust (Axum) | **71,000** ᶠ | 6,556 | 2.2 | 3.5 | 0.93 | 40 | 57 | 1,551 | 2026-10-27 |
| 90 | java-micronaut-Clickin | #116 | Java (Micronaut, JDBC SQLite) | **71,000** ᶠ | 6,546 | 78 | 148 | 0.93 | 85 | 121 | 1,293 | 2026-10-27 |
| 90 | c-libco-ssmurfgg04-gif | #121 | C (libco coroutines, epoll) | **71,000** ᶠ | 6,546 | 141 | 210 | 0.93 | 52 | 74 | 717 | 2026-10-27 |
| 90 | java-springboot-reactor-mohkamfer | #138 | Java (Spring Boot, Reactor Netty, FFM SQLite) | **71,000** ᶠ | 6,555 | 11 | 56 | 0.93 | 62 | 88 | 503 | 2026-10-28 |
| 90 | rust-axum-connorw-dev | #140 | Rust (Axum) | **71,000** ᶠ | 6,554 | 6.1 | 11 | 0.93 | 52 | 74 | 1,131 | 2026-10-28 |
| 90 | bun-yatta-psrockstar098 | #179 | Bun (Yatta JS, bun:sqlite) | **71,000** ᶠ | 6,545 | 54 | 133 | 0.93 | 91 | 130 | 213 | 2026-10-29 |
| 90 | rust-mqbridge-marcomq | #253 | Rust (mq-bridge, sqlx SQLite) | **71,000** ᶠ | 6,548 | 72 | 106 | 0.93 | 76 | 109 | 1,409 | 2026-11-01 |
| 90 | c-iouring-marwanabdelhameed | #270 | C (io_uring) | **71,000** ᶠ | 6,558 | 0.8 | 3.4 | 0.93 | 39 | 56 | 1,448 | 2026-11-02 |
| 90 | c-fio-tbsvttr | #5 | C (facil.io) | **71,000** | 6,959 | 130 | 621 | 0.00 | 81 | 108 | 646 | 2026-10-26 |
| 90 | ruby-async-cicloid | #71 | Ruby (async, YJIT) | **71,000** | 6,967 | 121 | 349 | 0.00 | 83 | 111 | 362 | 2026-10-27 |
| 90 | forth-gforth-FantasticForth | #171 | Forth (gforth, epoll) | **71,000** | 6,916 | 291 | 765 | 0.00 | 92 | 124 | 318 | 2026-10-29 |
| 116 | python-fastapi-granian-shawal-mbalire | #41 | Python (FastAPI, Granian) | **70,000** | 6,801 | 465 | 862 | 0.00 | 94 | 129 | 1,192 | 2026-10-26 |
| 116 | fortran-microhttpd-tbsvttr | #16 | Fortran (libmicrohttpd) | **70,000** | 6,866 | 141 | 401 | 0.00 | 89 | 120 | 1,134 | 2026-10-26 |
| 118 | trux-http-claudioscheer | #145 | Trux (io_uring) | **69,000** ᵗ | 6,514 | 1.6 | 234 | 0.59 | 49 | 70 | 1,043 | 2026-10-28 |
| 119 | fsharp-oxpecker-delneg | #108 | F# (Oxpecker) | **65,000** ᵍ | 6,392 | 84 | 229 | 0.00 | 55 | 80 | 1,255 | 2026-10-21 |
| 119 | go-gnet-Haris0059 | #38 | Go (gnet) | **65,000** ⁿ | 6,396 | 39 | 54 | 0.00 | 42 | 61 | 350 | 2026-10-26 |
| 119 | kotlin-ktor-C-Hatton | #45 | Kotlin (Ktor, Netty, FFM SQLite) | **65,000** | 6,374 | 198 | 713 | 0.00 | 65 | 95 | 1,273 | 2026-10-26 |
| 119 | go-fasthttp-b3nhard | #56 | Go (fasthttp, cgo SQLite) | **65,000** ⁿ | 6,399 | 4.8 | 19 | 0.00 | 77 | 112 | 547 | 2026-10-27 |
| 119 | cpp-drogon-hendy643 | #29 | C++ (Drogon) | **65,000** | 6,398 | 36 | 60 | 0.00 | 52 | 76 | 814 | 2026-10-27 |
| 119 | java-netty-lfeagan | #63 | Java (Netty, FFM SQLite) | **65,000** | 6,401 | 1.9 | 28 | 0.00 | 62 | 90 | 1,494 | 2026-10-27 |
| 119 | csharp-aspnetcore-vijay-highlo | #77 | C# (ASP.NET Core, Native AOT) | **65,000** | 6,389 | 87 | 319 | 0.00 | 56 | 82 | 1,278 | 2026-10-27 |
| 119 | node-net-barrard | #78 | Node (node:net, node:sqlite) | **65,000** | 6,383 | 133 | 312 | 0.00 | 75 | 109 | 483 | 2026-10-28 |
| 119 | cpp-iouring-edwin-2024 | #98 | C++ (io_uring) | **65,000** ˢ | 6,399 | 33 | 55 | 0.00 | 30 | 44 | 200 | 2026-10-27 |
| 119 | java-raw-agrison | #101 | Java (raw NIO, FFM SQLite) | **65,000** | 6,387 | 99 | 443 | 0.00 | 81 | 118 | 731 | 2026-10-27 |
| 119 | lean-c-iouring-loafecho | #239 | C (io_uring, SQLite B-tree reads) | **65,000** ᶜ | 6,399 | 32 | 56 | 0.00 | 28 | 41 | 605 | 2026-11-01 |
| 130 | bun-elysia-shashishsoni | #59 | Bun (Elysia) | **64,000** | 6,300 | 14 | 75 | 0.00 | 89 | 131 | 1,507 | 2026-10-27 |
| 131 | csharp-aspnetcore-maks-march | #27 | C# (ASP.NET Core) | **63,000** | 6,136 | 417 | 757 | 0.00 | 87 | 131 | 925 | 2026-10-27 |
| 131 | csharp-aspnetcore-devv-guru | #195 | C# (ASP.NET Core, Native AOT) | **63,000** | 6,156 | 202 | 679 | 0.00 | 79 | 119 | 1,081 | 2026-10-29 |
| 133 | pypy-twisted-perkinslr | #79 | PyPy (Twisted) | **62,000** | 6,017 | 474 | 757 | 0.00 | 73 | 113 | 563 | 2026-10-27 |
| 133 | go-nethttp-rkkautsar | #277 | Go (net/http, cgo SQLite) | **62,000** | 6,059 | 465 | 742 | 0.00 | 93 | 143 | 1,152 | 2026-11-03 |
| 135 | java-netty-itsnaveenk | #57 | Java (Netty) | **58,000** | 5,665 | 349 | 519 | 0.00 | 83 | 136 | 879 | 2026-10-27 |
| 136 | typescript-bun-tbsvttr | #4 | Bun | **57,000** | 5,593 | 103 | 291 | 0.00 | 86 | 143 | 301 | 2026-10-25 |
| 136 | java-quarkus-panama-raisinsfried | #73 | Java (Quarkus, FFM SQLite) | **57,000** | 5,607 | 9.6 | 359 | 0.00 | 60 | 100 | 725 | 2026-10-27 |
| 136 | typescript-fastify-melroy89 | #51 | TypeScript (Fastify, Node) | **57,000** | 5,582 | 212 | 614 | 0.00 | 77 | 128 | 1,072 | 2026-10-30 |
| 139 | haskell-warp-staticfx | #104 | Haskell (Warp) | **55,000** | 5,411 | 2.5 | 198 | 0.00 | 62 | 107 | 1,587 | 2026-10-21 |
| 139 | go-nethttp-fi5HiE | #99 | Go (net/http) | **55,000** | 5,382 | 425 | 679 | 0.00 | 90 | 156 | 1,465 | 2026-10-21 |
| 139 | java-jdkhttpserver-razorree | #262 | Java (JDK HttpServer, virtual threads) | **55,000** | 5,384 | 306 | 862 | 0.00 | 92 | 159 | 1,291 | 2026-11-02 |
| 142 | go-nethttp-tbsvttr | #18 | Go (net/http) | **53,000** | 5,165 | 374 | 659 | 0.00 | 93 | 168 | 624 | 2026-10-26 |
| 142 | python-pyrustapi-rajboopathiking | #147 | Python (PyRustAPI, Rust/Hyper core) | **53,000** | 5,185 | 294 | 429 | 0.00 | 90 | 162 | 1,232 | 2026-10-28 |
| 144 | csharp-aspnetcore-andrexx | #20 | C# (ASP.NET Core) | **49,000** | 4,815 | 84 | 234 | 0.00 | 88 | 170 | 846 | 2026-10-26 |
| 145 | python-fastapi-tejasnafde | #10 | Python (FastAPI) | **48,000** | 4,701 | 303 | 465 | 0.00 | 89 | 176 | 583 | 2026-10-21 |
| 145 | swift-hummingbird-denizak ᵖ | #43 | Swift (Hummingbird) | **48,000** | 4,700 | 210 | 300 | 0.00 | 97 | 191 | 1,269 | 2026-10-21 |
| 147 | java-helidon-dglynch | #159 | Java (Helidon) | **46,000** | 4,525 | 76 | 121 | 0.00 | 84 | 173 | 1,579 | 2026-10-29 |
| 148 | python-granian-tbsvttr | #13 | Python (Granian) | **45,000** | 4,400 | 202 | 812 | 0.00 | 93 | 197 | 709 | 2026-10-26 |
| 148 | go-nethttp-NaveedZahoorKhan | #129 | Go (net/http, cgo SQLite) | **45,000** ᵏ | 4,429 | 33 | 303 | 0.00 | 67 | 141 | 1,507 | 2026-10-28 |
| 150 | node-fastify-gmr458 | #61 | TypeScript (Fastify, Node) | **44,000** | 4,285 | 489 | 915 | 0.00 | 86 | 187 | 812 | 2026-10-27 |
| 151 | ruby-iodine-tbsvttr | #14 | Ruby (iodine) | **43,000** | 4,223 | 89 | 175 | 0.00 | 86 | 189 | 1,096 | 2026-10-26 |
| 152 | d-vibe-http-cyrusmsk | #162 | D (vibe.d) | **33,000** | 3,233 | 300 | 579 | 0.00 | 85 | 244 | 1,663 | 2026-10-29 |
| 153 | java-spring-boot-nb-99 | #33 | Java (Spring Boot WebFlux) | **32,000** | 3,151 | 9.9 | 27 | 0.00 | 81 | 239 | 763 | 2026-10-26 |
| 153 | goose-native-tbsvttr | #143 | Goose (native, epoll) | **32,000** | 3,150 | 0.6 | 148 | 0.00 | 15 | 44 | 384 | 2026-11-02 |
| 155 | java-quarkus-wolches | #67 | Java (Quarkus) | **29,000** ᵈ | 2,838 | 306 | 451 | 0.00 | 50 | 164 | 542 | 2026-10-21 |
| 155 | go-iouring-pmatteo | #168 | Go (io_uring, PGO) | **29,000** ʲ | 2,857 | 2.2 | 42 | 0.00 | 21 | 68 | 326 | 2026-10-29 |
| 157 | erlang-cowboy-tbsvttr | #11 | Erlang (Cowboy) | **28,000** | 2,751 | 76 | 174 | 0.00 | 85 | 287 | 1,214 | 2026-10-26 |
| 158 | go-gin-lincolng4 | #103 | Go (Gin) | **27,000** ᵐ | 2,658 | 1.2 | 4.8 | 0.00 | 42 | 147 | 1,600 | 2026-10-27 |
| 159 | java-flash-relism | #133 | Java (Flash) | **25,000** | 2,449 | 280 | 991 | 0.00 | 38 | 144 | 1,464 | 2026-10-28 |
| 160 | lua-lunet-simbo1905 | #126 | Lua (lunet), behind Nginx | **24,000** ˡ | 2,362 | 20 | 38 | 0.93 | 93 | 366 | 38 | 2026-10-28 |
| 160 | crystal-kemal-faustinoaq | #194 | Crystal (Kemal), behind Nginx | **24,000** ʷ | 2,362 | 24 | 70 | 0.96 | 51 | 201 | 126 | 2026-10-29 |
| 162 | typescript-effect-SeeThruHead | #49 | TypeScript (Effect, Node) | **23,000** | 2,229 | 413 | 765 | 0.00 | 96 | 399 | 623 | 2026-10-26 |
| 163 | d-arsd-hybridcgi-cyrusmsk | #160 | D (arsd hybrid cgi) | **22,000** ʰ | 2,167 | 10 | 97 | 0.00 | 37 | 159 | 1,688 | 2026-10-29 |
| 164 | php-symfony-pklebba | #40 | PHP (Symfony, FrankenPHP) | **21,000** | 2,061 | 186 | 274 | 0.00 | 95 | 428 | 915 | 2026-10-26 |
| 165 | pascal-horse-viniabreu | #134 | Pascal (Horse) | **20,000** | 1,966 | 81 | 111 | 0.00 | 90 | 426 | 270 | 2026-10-28 |
| 166 | csharp-aspnetcore-larsholm | #47 | C# (ASP.NET Core) | **19,000** | 1,854 | 381 | 943 | 0.00 | 57 | 286 | 439 | 2026-10-26 |
| 166 | crystal-kemal-krthr | #146 | Crystal (Kemal) | **19,000** ᵐ | 1,869 | 27 | 153 | 0.00 | 24 | 119 | 1,631 | 2026-10-28 |
| 168 | php-symfony-gnugat | #256 | PHP (Symfony, FrankenPHP) | **18,500** | 1,809 | 325 | 804 | 0.00 | 96 | 494 | 1,111 | 2026-11-01 |
| 169 | kotlin-springboot-Mindstorm1750 | #66 | Kotlin (Spring Boot, Tomcat, virtual threads) | **18,000** | 1,760 | 397 | 870 | 0.00 | 61 | 323 | 792 | 2026-10-27 |
| 170 | python-litestar-przwr | #23 | Python (Litestar) | **16,000** | 1,569 | 259 | 788 | 0.00 | 66 | 391 | 256 | 2026-10-26 |
| 171 | kotlin-ktor-jvm-syorito-hatsuki | #36 | Kotlin (Ktor, JVM) | **14,000** | 1,370 | 370 | 728 | 0.00 | 79 | 536 | 603 | 2026-10-26 |
| 172 | kotlin-ktor-graalvm-noamm9 | #53 | Kotlin (Ktor, GraalVM native) | **10,500** | 1,027 | 356 | 906 | 0.00 | 79 | 715 | 314 | 2026-10-26 |
| 173 | php-codeigniter-melroy89 | #50 | PHP (CodeIgniter, FrankenPHP) | **9,500** | 926 | 332 | 456 | 0.00 | 99 | 995 | 626 | 2026-10-30 |
| 173 | scala-http4s-sideeffffect | #172 | Scala (http4s Ember, Cats Effect), behind Nginx | **9,500** | 934 | 7.0 | 179 | 0.00 | 50 | 498 | 1,392 | 2026-11-01 |
| 175 | ruby-rails-gambitboy | #2 | Ruby (Rails), behind Nginx | **9,000** | 876 | 322 | 443 | 0.00 | 97 | 1,031 | 257 | 2026-10-25 |
| 175 | ruby-rails-tbsvttr | #12 | Ruby (Rails) | **9,000** | 875 | 409 | 562 | 0.00 | 98 | 1,043 | 305 | 2026-10-26 |
| 177 | sql-sqlite3cli-public | #232 | SQL (sqlite3 CLI, Bash accept), behind Nginx | **7,000** | 688 | 167 | 309 | 0.80 | 96 | 1,298 | 258 | 2026-10-31 |
| 178 | c-dreamcast-public | #221 | C (KallistiOS on an emulated Dreamcast in Flycast, SQLite on the SH-4), behind Nginx | **6,000** | 590 | 26.5 | 97.5 | 0.04 | 64 | 1,008 | 319 | 2026-11-02 |
| 179 | bash-socat-framegrace | #89 | Bash (socat, behind Nginx) | **3,500** | 344 | 18 | 43 | 0.00 | 64 | — | 107 | 2026-10-21 |
| 180 | r-plumber2-josiahparry | #242 | R (plumber2), behind Nginx | **2,000** | 195 | 300 | 924 | 0.00 | 86 | 4,103 | 279 | 2026-11-01 |
| 181 | spice-ngspice-public | #220 | SPICE (ngspice + Verilog chip, SQLite in the network card), behind Nginx | **500** | 49 | 246 | 519 | 0.00 | 82 | 15,675 | 29 | 2026-11-01 |
| — | nim-io_uring-NioHast | #132 | Nim (io_uring) | **failed** (hangs) | | | | | | | | 2026-10-21 |
| — | v-fasthttp-ulises-jeremias | #69 | V (fasthttp) | **failed** (install OOM) | | | | | | | | 2026-10-27 |
| — | v-epoll-quaesitor-scientiam | #166 | V (io_uring) | **failed** (install timeout) | | | | | | | | 2026-10-30 |
| — | rust-hyper-dannie203 | #178 | Rust (hyper) | **failed** (build: no cargo) | | | | | | | | 2026-10-29 |
| — | d-arsd-threadedcgi-cyrusmsk | #161 | D (arsd threaded cgi) | **failed** (0: timeouts at 500 users) | | | | | | | | 2026-10-31 |

ˣ **Rust #82 ran out of load generators first.** One target IP × 4 load generators caps at ~240,000 connections (source
ports). It passed 240,000 at 79 % CPU, so it was re-searched with 3 extra IPv4s on the box and a 5th load generator
(cap ~1.2M): 300,000 failed on latency (p99 888 ms 2-min, CPU 89 %), 293,000/278,000 failed the 5-minute hold on p99,
**264,000 passed**. 360k/480k probes got the app OOM-killed (2 GB box). The 240,000 run on the original setup is consistent
(23,166 req/s, 31 µs/req). Its follow-up **#141** (`b1efee9`, background WAL checkpoints; held, not merged: it
conflicts with the merged #82 folder) scored **230,000** on the standard 4-source-IP setup (22,384 req/s, p95 14 / p99
62 ms, 0 err, 91 % CPU, 37 µs/req, 931 MB, 2026-10-28) and is CPU-bound, not source-port-bound: 240,000 failed at 95 % CPU
(p99 1.5 s). The row above stays on #82's merged code until #141 is rebased and merged.

ᵘ **HolyPHP** is scored at its follow-up **#280** (`b074068`, generic io_uring runtime, merged 2026-11-02; 160,000
failed the 5-minute hold on p99 2.96 s at 64 % CPU, 0 errors), which replaces the merged #235 row (`1569472`, 145,000,
2026-11-01), which replaced the merged #204 row (epoll, 76,000, 2026-10-30). #235: 150,000 failed the 2-minute probe on
p95 (567 ms, 93 % CPU, 0 errors). Earlier follow-up heads (#213 / #227): `7a3f61e` scored 135,000 and `8ee9c5a` 130,000 (2026-10-31),
`c935dfe` 64,000 (timeouts at ~70 % CPU) and `96aa4f5` 110,000 (2026-10-30). Its later follow-up **#268**
(`56b5187`, CQE batching + epoll overflow + C record decoding; held, not merged: it didn't beat the merged row) scored
**100,000** (9,755 req/s, p95 421 / p99 943 ms, 0 err, 80 % CPU, 76 µs/req, 346 MB, 2026-11-02). 105,000–120,000 failed
the 2-minute probe on p95/p99 (83–94 % CPU, 0 errors). #268's next head `28db5bb` (generic io_uring runtime: direct
descriptors, multishot accept/recv, 5 rings) scored **157,000** (15,401 req/s, p95 198 / p99 352 ms, 0 err, 65 % CPU,
39 µs/req, 711 MB, 42/42, 2026-11-02; 165,000 failed the 5-minute hold on p99 1.23 s), but #268 was closed unmerged
during the run; its replacement #280 is the row above.

ʸ **scala-netty-jacksonhoran** stays on its merged #107 row. Its follow-up **#149** (`4430836`, rejects tokens
without `exp`; held, not merged: it didn't beat the merged row) scored **83,000** (8,128 req/s, p95 325 / p99 627 ms,
0 err, 85 % CPU, 97 µs/req, 820 MB, 2026-11-01). CPU-bound: 85,000 failed the 2-minute probe on p95 (665 ms, 88 % CPU).

ʳ **rust-native-M3M0KA** stays on its merged #265 row. Its follow-up **#266** (`6257d92`, off-loop WAL checkpointer;
held, not merged: it didn't beat the merged row) scored **155,000** (15,143 req/s, p95 389 / p99 820 ms, 0 err, 96 % CPU,
59 µs/req, 1,326 MB, 2026-11-02). CPU-bound: 200,000 passed the 2-minute probe but the 5-minute holds from 200,000 down to
163,000 all failed on p95/p99 at 96 % CPU. Its follow-up **#275** (`c520aa0`, one `SO_REUSEPORT` listener per worker,
rebase of #274; held, not merged: it didn't beat the merged row) scored **209,000** (20,445 req/s, p95 110 / p99 256 ms,
0 err, 89 % CPU, 40 µs/req, 1,176 MB, 2026-11-02). CPU-bound: 220,000 passed the 2-minute probe but failed the 5-minute
hold (p95 470 / p99 1,094 ms at 91 % CPU). Its follow-up **#276** (`5dc0b21`, POSTs on a dedicated SQLite writer thread;
held, not merged: it didn't beat the merged row) scored **220,000** (21,374 req/s, p95 208 / p99 665 ms, 0 err, 91 % CPU,
39 µs/req, 1,351 MB, 2026-11-02). CPU-bound: 230,000 failed the 2-minute probe on p95/p99 (509 ms / 1.43 s at 93 % CPU).
Its follow-up **#282** (`54ef366`, bounded writer queue on a second SQLite connection; held, not merged: it didn't beat
the merged row) scored **64,000** (6,096 req/s, p95 0.5 / p99 2.9 ms, 0.47 % err, 31 % CPU, 47 µs/req, 609 MB,
2026-11-03). Connection-capped, not CPU-bound: from 67,000 up the probes failed on TCP connect timeouts at ~31 % CPU.
Its follow-up **#285** (`f3d9412`, io_uring transport fixes on top of #282; held, not merged: it didn't beat the merged
row) scored **143,000** (14,074 req/s, p95 5.0 / p99 41 ms, 0 err, 69 % CPU, 46 µs/req, 1,359 MB, 2026-11-03).
Connection-capped, not CPU-bound: 150,000 passed the 2-minute probe but failed the 5-minute hold, and 155,000/160,000
failed the 2-minute probe, on refused connections at ~70 % CPU.

**Connection collapses in scored entries' failing probes.** v-epoll-i098 #191: 270,000 passed the 2-minute probe but
failed the 5-minute hold with 60 % errors, nearly all `connection refused` from mid-hold on (an earlier attempt at
`0ed86bf` hit the 1-hour install timeout). c-iouring-moneebullah25 #244: 240,000 failed the 2-minute probe on p99
(2.6 s at 70 % CPU, 0 errors) and 320,000 collapsed (78 % errors, nearly all `connection refused`); its earlier #228
run: 240,000 passed the 2-minute probe but failed
the 5-minute hold with 70 % errors, nearly all `connection refused` from mid-hold on; 250k–320k 2-minute probes failed
the same way. crystal-rayo #218: CPU-bound, 210,000 failed the 5-minute hold on p99 (1.2 s at 87 %); the 320,000
2-minute probe collapsed (85 % errors, mostly connection refused).

ᶠ **The 65,535 file-descriptor limit, not speed.** These twenty-three serve 65,535 keep-alive users and the rest wait in the
listen queue until mload's 60 s timeout. Each scored run shows exactly ~21,900 timeouts = 0.93 % of requests, just under the
1 % rule — so 71,000 is "full fd table + 1 % slack", and the same number for a C++ server at 94 % CPU and a Zig one at 31 %
(Go fib #34: 61 % CPU, flat from 70k to 78k users while timeouts grow; C H2O #39: 39 % CPU, 4.9 ms p99, and its README
says it doesn't shed connections at the limit; C epoll #42: 39 % CPU at 60k, 93 % from 70k as it accepts and closes
the connections past the limit; Go stdlib #44: 38 % CPU, flat from 70k to 78k users, and its README says accept
pauses at the limit; PHP Swoole #24: 66 % CPU, flat from 75k to 78k users while timeouts grow; Go epoll #52: 41 % CPU, 78 ms p99, it
stops accepting at the limit and never closes idle keep-alives; C io_uring #55: 36 % CPU, 10 ms p99, request latency
flat from 20k to 78k users while connect timeouts grow; PHP Swoole #28: 71 % CPU, flat from 75k to 78k users while
timeouts grow; C io_uring #68: 84 % CPU from 70k, 44 ms p99, request latency flat from 70k to 80k users while connect
timeouts grow; Go epoll #100: 55 % CPU, 50 ms p99, CPU and req/s flat from 70k to 78k users while timeouts grow; Rust Axum #114: 40 % CPU, 3.5 ms p99, CPU and request
latency flat from 70k to 80k users while connect timeouts grow; Java Micronaut #116: 85 % CPU, 148 ms p99, CPU and req/s
flat from 70k to 78k users while timeouts grow; C libco #121: 52–54 % CPU, 210 ms p99, CPU and req/s flat from 70k to 80k
users while timeouts grow; Java Reactor Netty #138: 62–65 % CPU, 56 ms p99, CPU and req/s flat from 70k to 78k users
while timeouts grow; Rust Axum #140: 52–54 % CPU, 11 ms p99, CPU and req/s flat from 70k to 80k users while timeouts grow; Bun Yatta #179:
65 % CPU at 60k, 91 % from 70k, req/s flat from 70k to 78k users while timeouts grow; Rust mq-bridge #253: 73–76 % CPU, 106 ms p99, CPU and
req/s flat from 70k to 80k users while timeouts grow; C io_uring #270: 36–39 % CPU, 3.4 ms p99, CPU and req/s flat from
70k to 78k users while connect timeouts grow).
Zig (1.5 ms p99) and Deno (13 ms p99, 47 % CPU) would go much further without the rule-mandated limit. Worth considering a
rules note: the < 1 % error budget lets an fd-capped server "hold" ~8 % more users than it can actually connect.

Entries above 71,000 get there by closing idle keep-alive connections (`Connection: close` or RST near the limit) so the
client reconnects — c-epoll, Java NIO and V show this as EOF/reset errors under 1 %; the io_uring entries manage up to
~524k fixed-file slots/rings.

ᵈ **Disk-bound, not CPU-bound.** Quarkus never sets `synchronous`, so SQLite defaults to FULL: an fsync per commit, one
commit per request — 26–39 % iowait during its probes (37 % over the scored hold).

ᵍ **F# crashes past ~65k connections.** At 68,000 and 70,000 users the .NET runtime aborts (`PAL_SEHException`, core dump)
about a minute into the ramp, as connections pass the 65,535 fd limit, and every later connection is refused (86 % errors).
Not disk-bound: iowait was 1–6 %; it sets `wal_autocheckpoint = 0` and checkpoints on its own thread (Db.fs:123).
*(Corrected 2026-10-22: an earlier version of this report misread the monitor columns — it reported idle time as iowait —
and blamed F#'s limit on auto-checkpoint I/O.)*

ⁿ **Go gnet #38 and #48 exit at the fd limit.** When `accept` fails with "too many open files", gnet v2.10.0 shuts the
engine down and `gnet.Run` returns, so the process exits (journal, 80k probe) and every later connection is refused
(86–90 % errors at 68k/70k/80k, 6–10 % CPU). At 65,000 both were clean at 42 % CPU. Go fasthttp #56 does the same
(`accept4: too many open files`, exit status 1, at 68k/70k/80k); at 65,000 it was clean at 77 % CPU, 19 ms p99.
go-gnet-kaikegm is now scored at its follow-up #180 (`372538d`, was 65,000 at #48): it closes the oldest idle
connections past 55k open, so it no longer hits the limit at 80–93k (88,000 held at 77 % CPU, CPU-bound: 93k failed the
5-minute hold on p99), but a fast ramp to 120k/160k still fills the fd table and the process exits the same way (89–94 %
connection refused).

ˢ **C++ io_uring #98 stalls at the fd limit.** At 65,000 it was clean at 30 % CPU (55 ms p99). At 68k/70k/80k it went to
100 % CPU and timed out 21–30 % of requests (~1,780 req/s), likely because a failed accept (EMFILE) ends the multishot
accept and the loop re-arms it straight away, so it spins on accept errors (server.cpp:281–326).

ᵐ **Go Gin #103 is memory-bound.** Latency stays low (4.8 ms p99 at 42 % CPU), but memory grows with users: 1.6 GB at
27,000. At 28,000+ (5-minute hold) and 29k/30k/40k it was OOM-killed and later connections were refused (50–75 %
errors). Its first run, before the rig capped the app at 1,750 MB, used all 2 GB at ~28k and froze the box.
Crystal Kemal #146 is the same: 27 ms p95 / 153 ms p99 at 24 % CPU, but 1.6 GB at 19,000; at 20,000+ (including the
20,000 5-minute hold) the app was OOM-killed and restarted every 1–4 minutes, and connections in between were refused
(40–93 % errors at 4–21 % CPU).

ˡ **Lua lunet #126's errors are writes cut off near full CPU.** The 0.93 % in its scored hold (93 % CPU) are EOFs
(connection closed with no response), almost all on POSTs: 12 % of likes and 10 % of new posts failed, 0 reads. They
grow with load (0.26 % at 23k, 1.45 % at 25k); at 30k+ Nginx also returns 502/504s.

ʷ **Crystal Kemal #194's errors are dropped writes at half CPU.** The 0.96 % in its scored hold (51 % CPU) are EOFs, all
on POSTs: 13 % of likes and 10 % of new posts failed, 0 reads. They grow with load (0.27 % at 23k, 1.44 % at 25k, 5.5 %
at 40k) while CPU stays at 50–79 %, so the write path, not CPU, is the limit.

ᵏ **Go net/http #129 is memory-bound.** At 45,000 it was clean at 67 % CPU (303 ms p99), but its cgroup peaked at 1.5 GB.
At 47k/48k/50k/60k/80k it was OOM-killed during the ramp (kernel log) and most later connections were refused (54–93 %
errors, 6–36 % CPU).

ᵗ **Trux #145 is connection-capped, not CPU-bound.** At 69,000 it ran at 49 % CPU with a 1.6 ms p95; its 0.59 % errors
are 60 s timeouts on `GET /feed` (new connections not served), and they grow with users while CPU stays at 48–52 %:
0.41 % at 70k, 0.68 % at 73k (2-min), 2.0 % at 75k. 73,000 failed the 5-minute hold at 1.26 %.

ʰ **D arsd hybrid #160 is connection-capped, not CPU-bound.** At 22,000 it ran at 37 % CPU (97 ms p99). From 23,000
up most new connections were refused (28 % errors at 23k, 32 % at 25k, 76–84 % at 30k/40k) while CPU stayed at
40–44 %, with no OOM kill in the kernel log.

ᵃ **asm-epoll #207's errors are rolled-back writes near full CPU.** It is the follow-up to #130 (120,000 at `8c3c277`),
scored at `d273c86`. The 0.61 % in its scored hold (95 % CPU) are all HTTP 500s (34,684), only on POSTs: 8 % of likes
and 8 % of new posts failed, 0 reads. Its group commit answers 500 when a batch rolls back. The 165k/170k 2-minute
probes had 0 errors but failed on p99 (3.9 s / 1.8 s). At 180,000 the app stopped mid-probe (73 % `connection
refused`, app cgroup memory down to 0).

ʲ **Go io_uring #168 stalls on open connections, not CPU.** At 29,000 it ran at 21 % CPU (2.2 ms p95, 42 ms p99, 326 MB).
Above that, requests on already-open connections hit mload's 60 s timeout while CPU stayed at 24–35 % and TCP connects
stayed fast (0.3 ms p99): 1.8 % timeouts in the 33,000 and 1.7 % in the 31,000 5-minute holds, 4.9 % at 35,000 (2-min),
and a 1.6 s p99 at 40,000.

ᶜ **C io_uring #239 is connection-capped at ~65k, not CPU-bound.** At 65,000 it ran at 28 % CPU (32 ms p95, 56 ms p99,
0 errors). From 68,000 up, connections past the cap got EOF / `connection reset by peer` (5.2 % at 68k, 9.1 % at 70k,
24.6 % at 80k) while CPU stayed at 37–51 %. Its fixed-file table is sized from `RLIMIT_NOFILE` (server.c:1117), one slot
per connection.

ᵒ **wat-wasmedge-delneg** is scored at its merged follow-up **#272** (`7792fa9`, io_uring transport). This head drops
the earlier writes to SQLite internals (`nBackfill`, `PCache1.iMaxKey`) for a `SQLITE_CONFIG_PCACHE2` wrapper and plain
`sqlite3_wal_checkpoint_v2` checkpoints. At `7792fa9` 200,000 held at 63 % CPU; from 210,000 up every probe failed on
`connection refused` (35 % errors at 210k–220k, 74–87 % at 240k–320k) while CPU stayed at 53–56 %. The earlier
`c193a82` run held 247,000 (79 % CPU) and `f220565` 270,000 (88 % CPU), both with the internals writes. Its follow-up
**#288** (`df9da40`, smaller checkpoint batches, code pages `mlock`ed; held, not merged: it tied the merged row, didn't
beat it) also scored **200,000** (19,619 req/s, p95 229 / p99 356 ms, 0 err, 68 % CPU, 32 µs/req, 712 MB, 2026-11-03):
210,000 and 220,000 failed on p99 (1.5 s / 4.5 s, 0 err, 69–75 % CPU), 240,000 and 320,000 on `connection refused`. Its **#259** code (`48942ac`,
epoll) held **60,000** (5,905 req/s, p95 3.1 / p99 204 ms, 0 err, 23 % CPU, 2026-11-01) and was not CPU-bound: from
63,000 up its probes failed on EOFs (1.5 % at 63k to 2.7 % at 80k) at 43–55 % CPU, because it closes sockets idle for
1.5 s or more once it holds over 60,000 (README) and requests landed on those closed keep-alive sockets.

ᵉ **c-epoll-patrickryankenneth** is scored at its merged #246 code (`f9cf266`). Its follow-up **#289** (`faf709c`,
batched ring-0 wait, smaller WAL checkpoints; held, not merged: it scored below the merged row) held **175,000** (17,146
req/s, p95 208 / p99 456 ms, 0 err, 72 % CPU, 39 µs/req, 379 MB, 2026-11-03): 180,000 and 200,000 failed on p99 (742 ms
/ 2.5 s, 0 err, 78–80 % CPU), 240,000 on p99 (9.1 s) and 320,000 on `connection refused`.

## Patches (ᵖ) and failures

Each patch is one line, doesn't touch runtime code, and was verified to build on the same Xeon first. All of them are
committed in this repo.

- **Zig #125** — build failed: `evaluation exceeded 10000 backwards branches` in `src/UringIo.zig` `clobbers()`. On an
  AVX-512 CPU it loops over 32 zmm registers at compile time (16 on AVX2, likely the author's machine). Patch:
  `@setEvalBranchQuota(10_000)` → `100_000`.
- **C# #74** — build failed: Native AOT `ilc` exits with `error : Vector256` when `IlcInstructionSet=native` on this
  AVX-512 Cascade Lake. Patch: `native` → `x86-64-v3` (AVX2) in Feed.csproj. Fixed by the author in the follow-up #174,
  whose 210,000 run was unpatched and replaced #74's row.
- **Swift #43** — install failed: the toolchain URL is missing the `swift-6.2.1-RELEASE/` folder → HTTP 404 (it can't have
  worked on a clean box). Patch: the corrected URL.
- **Nim #132 — failed, twice.** First run: passed /health, then wedged during the test suite — 0 s CPU, blocked in
  `io_uring_enter` (io_cqring_wait), 192 connections stuck in CLOSE-WAIT: its multishot accept stopped delivering. Retry
  (fresh build; its PGO build fell back to a plain build): stuck at the suite's first read. Kernel 6.8.0-117.
- **V #69 — install failed** (`913da3f`): `make v` bootstraps the V compiler from source, and its `v1` stage reached
  1.78 GB RSS and was OOM-killed on the 2 GB box (kernel log, exit 137), so `v` was never installed and the app
  couldn't build. CI passed on GitHub's bigger runner. Not patched (it isn't a one-line fix).
- **Goose #143 — install failed** (`1454fa6`): `install.sh` builds the pinned Goose compiler from source (cmake/ninja),
  and that build runs the 1 vCPU / 2 GB box out of memory: mu-c1 froze twice (07:47 and after the 09:02 re-run), and
  the install hit its 1-hour timeout, so the app never built (1/42 tests). Not patched. Re-run at `10667b8`
  (2026-11-02, compiler built with `--parallel 1` and lower GCC memory settings): install fit on the box, 42/42,
  scored 32,000 (row above). Above 32,768 connections it closes new sockets (`MAX_CONNECTIONS`), so 33,000+ fail.
- **V #166 — install failed** (`1bcfd37`): `install.sh` runs `make` on the pinned V checkout (bootstrap from source,
  like #69), and it ran the 1 vCPU / 2 GB box out of memory: mu-c1 stopped answering from 02:11 to 03:06 and the
  install hit its 1-hour timeout (exit 124), so the app never built (1/42 tests). Not patched. Re-run at `e872f75`
  (2026-10-30), which drops `make` and stops at `v2` (`vc/v.c` → `v1` → `v1 -no-parallel -gc none cmd/v`): no OOM kill
  and the box stayed up, but it was still compiling when the install hit the 1-hour timeout again (exit 124), so
  `/opt/twelve-v/v` was never installed (1/42 tests). Third try at `f120d65` (2026-10-30, V/vc fetched from upstream
  vlang by pinned commit, same `v1` → `v2` bootstrap): the install hit the 1-hour timeout again (exit 124), 1/42 tests.
- **Rust #178 — build failed** (`6aa144b`): `install.sh` installs Rust with rustup into root's `~/.cargo`, but
  `build.sh` runs as the `deploy` user, which has no `cargo` (exit 127), so the app never built (1/42 tests). CI passed
  because GitHub's runner has Rust preinstalled. Not patched.
- **SPICE #220 — scored 0 at `f84ba73`, now scored 500 at `665f4ba`**: the first run installed, built and passed
  42/42, but no probe passed (100 % CPU with Nginx 504s, 93 % errors at the 500-user floor). `665f4ba` replaced
  socat/conn.sh with a network card (nic.c) inside ngspice and held 500 users for 5 minutes (row above).
- **D #161 — scored 0** (`0c25b60`, arsd `embedded_httpd_threads`, direct): installed, built and passed 42/42, but no
  probe passed. From 20,000 down to the 500-user floor the app sat at 1–2 % CPU while 75–99 % of requests timed out
  (500 users: 5 req/s, p50 60 s, 11 MB RAM): its fixed worker-thread pool is held by idle keep-alive connections, as
  its README warns. Its sibling #160 (hybrid cgi) is the one scored above.
- **Go #277 — scored 0 at `26d1785`, then 45,000 at `d9d93f3`, 60,000 at `70145d4`, now 62,000 at `a1d2732`** (net/http, direct): the first run passed 42/42,
  but no probe passed. From 20,000 down to the 500-user floor ~7 % of requests failed with `EOF` (connection closed with
  no response) at 4–45 % CPU: every `POST /posts/:id/like` and ~75–86 % of `POST /posts`, 0 reads. It closed keep-alive
  sockets idle for 1 s (`IDLE_TIMEOUT_MS=1000`), and the POSTs landed on sockets it had just closed (reads are retried by
  the client, POSTs aren't). `d9d93f3` raised the timeout to 65 s and held 45,000; at 47,000+ connections were refused
  (47k passed 2 min but failed the 5-minute hold with 21.7 % refused, at 61 % CPU). `70145d4` (connection caps, Go memory
  limit, mmap off) held 60,000; 63k–80k failed on p95 at 95–99 % CPU, 0 errors. `a1d2732` (prepared single-row INSERT
  for small create batches) held 62,000 (row above); 65k passed 2 min but failed the 5-minute hold on p95 573 ms (96 % CPU).
- **C #246 — tests hung at `65dda48`, now scored 200,000 at `f9cf266`**: the first run installed and built, then hung
  on its io_uring path and never answered the suite's first read (exit 124). `f9cf266` added a 1 ms io_uring_enter
  timeout and passed 42/42 (row above).
- **D #123** (vibe.d) — dropped before the run: fails test.sh (HTML default 404 body; a bad `sub` crashes with 500).

## Rule flags from code review (nothing malicious found; please fix in a follow-up PR)

- **Tokens without `exp` accepted** (SPEC requires rejecting them): java-nio #88, quarkus #67 (SmallRye
  grace), kotlin #83, scala #107, node-uws #102, dart #46, go-champ3oy #76, pypy #84 (deliberately), bash #89,
  go-gnet #38, kotlin-ktor #36, python-fastapi-granian #41, go-stdlib #44, kotlin-ktor-C-Hatton #45, go-epoll-damianoneill #52,
  kotlin-ktor-graalvm #53, go-fasthttp #56, java-netty #57, bun-elysia #59, node-fastify #61, java-netty-lfeagan #63, c-iouring-27bhd #68, pypy-twisted #79, go-nethttp-mattn #100, java-raw #101, python-stdlib #118, java-springboot-reactor #138, trux-http #145, r-plumber2 #242, c-iouring-marwanabdelhameed #270 (all held open until fixed). cpp-eastl #32 fixed it in `4d5e225`, spice-ngspice #220 in `23d5dd7`, c-iouring-meros #137 in `b2a5207`, python-pyrustapi #147 in `82abaab`, node-net #78 in `5e7080d`, typescript-fastify #51 in `7820a24`, java-jdkhttpserver #209 in `89e75e0`, c-epoll-patrickryankenneth #246 in `f9cf266`, kotlin-trikeshed #128 in `2fb010a`, asm-epoll #117 in its follow-up #152 (`ad7a72c`) and csharp-epoll #74 in its follow-up #174 (`51de5a6`) (re-scored and merged).
- **Kotlin Ktor #36 (and #53, based on it) commit `gradle/wrapper/gradle-wrapper.jar`**. Arjay ruled (2026-10-26) that
  the standard Gradle wrapper jar is fine and not a prebuilt binary under rule 10. Kotlin Ktor #36 also returned a few HTTP 500s on writes under load (1–5 per probe,
  0 in the scored hold); its StatusPages handler doesn't log the exception. kotlin-springboot #66 commits the same
  jar and was merged on that ruling.
- **Past ~327k connections, cpp-eastl #32 evicts the connection it just served** because "the think-time loop visits
  users in the same order every time" (its README) — tuned to the load test's order (rule 7 question). Its score
  (210k) is below that point, so it doesn't affect the number.
- **go-lowlevel #91 builds with committed PGO profiles** (`profiles/go.pprof`, `profiles/sqlite.profraw`, on by default)
  that the author trained on their own load runs; the author asked for organizer review (rule 7/10 question: profile
  data tuned to the benchmark, and a non-source input to the build). Scored as submitted (125k); held open for Arjay.
- **Arjay's rulings on SQLite (2026-10-31).** Reading `/feed` and `/posts/:id` through SQLite's own B-tree/cursor API
  is allowed (rules 2/3), so the B-tree entries (lean-derive #153, mojo #224, v-epoll #191, c-uring-curvynes #217,
  crystal-rayo #218, c-iouring-moneebullah25 #244, rust-native #265 and others) carry no flag. Ordering routes or fast
  paths by observed traffic is fine too (rule 7), as long as every route works for any request, and so are SQLite's
public plugin APIs (a custom page cache through `SQLITE_CONFIG_PCACHE2`, a custom VFS). Not allowed (rule 2):
  - **an own engine for SQLite's file format**: none on the board now. c-rawsqlite-larvance #210 (`raw_sqlite.c`, no
    libsqlite3; scored 280k at `15e3271`) came off the board and is back since `d76e386`, which builds the stock SQLite
    3.54.1 amalgamation and reads through its B-tree cursor API (260k, row above).
  - **patching SQLite's source**: none on the board now. objc-uring-delneg #154 (dropped its patch in `1fe6941`) and
    c-iouring-public #158 (dropped its `pcache1-maxkey` patch in `68bb947`) were re-run on stock SQLite 3.54.1.
- **python-pyrustapi #147 serves its reads from the `pyrustapi` package's native SQL tier** (`sql=` route options),
  installed as a prebuilt PyPI wheel; the author says it's their own open-source framework and builds from source
  with `--no-binary` (rule 10 question). Scored as submitted (53k); held open for Arjay.
- **odin-odinhttp #139 drops the box's page cache at startup**: `pagecache.odin` walks /usr, /var, /etc (and its own
  folder) and calls `posix_fadvise(DONTNEED)` on each file (rule 11 question: it acts on files outside its folder).
  Scored as submitted (130k); held open for Arjay.
- **sql-oneselect #243 answers each batch of up to 256 requests with one SELECT** over an eponymous virtual table
  (`sqlite3_create_module`) that holds the parsed requests. Open question for Arjay: rule 3 (a virtual table as the
  request queue; probably covered by the public-plugin-API ruling). Since `57cf5b2` the `/feed` subquery is
  correlated, so each feed request does its own read (the earlier rule 5 question no longer applies). Scored as
  submitted (190k at `57cf5b2`); held open for Arjay.
- **go-iouring-rkkautsar #260 coalesces reads**: `GET /feed` and `GET /posts/:id` requests parked while a shard's
  previous read runs are answered together by one SQLite query (one feed query, or one `IN (...)` for the post ids),
  and nothing outlives the batch (rule 5 question, like #243). `READ_COALESCE=0` turns it off. Scored as submitted
  (230k at `d5d2a3f`, the current head again after the author reverted `0564d23`, which scored 219k; 220k at `a2bd826`, 195k at `81313ff`, 219k at `f404b06`, 210k at `26d0ab1`, 136k at `0062092`, 71k at `dfad91d`); held open for Arjay. The same author's go-nethttp #277 also
  coalesces `/feed` reads by default (`readGroup`, one read per write generation, 500 µs window; `READ_COALESCE=0`
  turns it off), and since `d9d93f3` also batches concurrent `/posts/:id` reads into one `IN` query by default
  (`POST_BATCH`); scored as submitted (62k at `a1d2732`; 60k at `70145d4`, 45k at `d9d93f3`, 0 at `26d1785`, see failures), held open.
- **lean-verified-soonhokong #286 (was #271) reuses c-iouring-pavlyhalim #245's B-tree helpers**: `runtime/db.c`'s record
  decoder, payload fetch, index seek and multi-key descent closely follow #245's `src/btree.h` (now credited in its
  README); the Lean handlers, HTTP/JWT/JSON code and the io_uring transport are new. Open question for Arjay: building
  on another entry vs. the copies rule. Scored as submitted (280k at `fe89683`; 290k at `30d259c` as #271); held open for Arjay.
- **c-rawsqlite-larvance #210 reuses c-iouring-pavlyhalim #245's B-tree helpers**: since `d76e386`, `src/db.c`'s record
  decoder, index seek, cursor helpers and rootpage/keyinfo lookups (~150 of ~2,350 lines) closely follow #245's
  `src/btree.h` with renamed identifiers; the io_uring transport, HTTP, JSON and JWT code are the author's own (from
  before #245). Same open question as #271: building on another entry vs. the copies rule. Scored as submitted (260k
  at `d76e386`); held open for Arjay.
- **goose-iouring-ahmadsh2007 #291 builds on rust-iouring-kensac #264's design**: at `204b6b0` its `net.c` was a C port
  of #264's io_uring transport and `db.c` adapted #264's B-tree helpers and checkpoint logic (credited). Since `67ef830`
  those files are gone: new `uring.c` (kernel plumbing only) and `sqlite.c`, with the event loop, connection table and
  checkpoint policy in `app.goose` (the request path was already new Goose code). Same open question as #271/#210:
  building on another entry vs. the copies rule. Scored as submitted (260k at `204b6b0`, 270k at `67ef830`); held open
  for Arjay.
- **Reads can see uncommitted writes** in the same batch: Deno #119 (also serves a snapshot up to 20 ms stale), Zig #125.
- **start.sh restart loops** (the app restarts itself instead of letting systemd see a crash): Deno #119, c-epoll #64,
  c-iouring-raoz #26 (restarts after a signal exit), go-epoll-Antheurus #65 (worker 0 re-spawns dead workers).
- **Unchecksummed toolchain downloads in install/build**: Deno (curl | sh), Go #72, Haskell (ghcup), Swift, .NET SDK,
  rustup (#82, also writes /usr/local/bin wrappers), Zig (anyzig).
- Bash #89 builds SQL by string concatenation (quotes doubled) — works, fragile.
- c-iouring #112's README describes a different design than the code (THREADSAFE=2, per-write commit); it sheds load
  based on /proc/meminfo (c-iouring-raoz #26 also reads /proc/meminfo, server.c:1314; c-libco #121 reads it once to pick its process count). python-fastapi-granian #41 likewise reads the box-wide `/proc/self/net/sockstat` to send
  `Connection: close`; the load test reconnected ~4.5× per user even at 40k users (180k dials), with 0 errors.

## Crashes during probes that failed anyway

The app journal showed OOM kills only in probes that failed anyway: Rust #82 at 360k/480k, asm-nasm #86 at 200k/240k,
go-nethttp #99 at 57k, Haskell #104 at 58k, php-symfony #40 at 40k (FrankenPHP at 1.5 GB), rust-axum #17 at 160k/120k, go-nethttp-tbsvttr #18 at 80k, csharp-aspnetcore-andrexx #20 at 80k (.NET "Out of memory." abort), csharp-aspnetcore-maks-march #27 at 80k/70k (.NET `PAL_SEHException` abort past the fd limit, like F# ᵍ), cpp-eastl #32 at 320k, c-iouring-raoz #26 at
320k/240k/200k and in the 190k/181k 5-minute holds. Scored holds were all clean.
