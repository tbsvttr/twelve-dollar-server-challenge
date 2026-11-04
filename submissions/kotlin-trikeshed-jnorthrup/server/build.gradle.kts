import org.jetbrains.kotlin.gradle.ExperimentalKotlinGradlePluginApi
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinVersion

plugins {
    kotlin("multiplatform")
}

val nativeTargets = providers.gradleProperty("trike.targets").orNull.orEmpty().split(',').map { it.trim() }.toSet()
val sqliteDir = layout.buildDirectory.dir("sqlite")
val liburingDir = layout.buildDirectory.dir("liburing")

kotlin {
    @OptIn(ExperimentalKotlinGradlePluginApi::class)
    compilerOptions {
        apiVersion.set(KotlinVersion.KOTLIN_2_4)
        languageVersion.set(KotlinVersion.KOTLIN_2_4)
        freeCompilerArgs.addAll("-opt-in=kotlin.RequiresOptIn", "-Xsuppress-version-warnings", "-Xexpect-actual-classes")
    }

    jvm {
        @OptIn(ExperimentalKotlinGradlePluginApi::class)
        compilerOptions { jvmTarget.set(JvmTarget.JVM_25) }
    }

    // -Ptrike.targets=linuxX64 (the same switch as the trikeshed module): the Kotlin/Native server over io_uring direct
    // descriptors, build/bin/linuxX64/feedReleaseExecutable/feed.kexe. Linux host only (liburing builds here).
    if ("linuxX64" in nativeTargets) {
        linuxX64 {
            compilerOptions { optIn.add("kotlinx.cinterop.ExperimentalForeignApi") }
            compilations.getByName("main").cinterops.create("feedc") {
                definitionFile.set(project.file("src/nativeInterop/cinterop/feedc.def"))
                // io_uring_interop: kernel headers (openat2.h, time_types.h) that Kotlin/Native's glibc 2.19 sysroot lacks.
                includeDirs(sqliteDir.get().asFile, liburingDir.get().dir("src/include").asFile,
                    rootProject.file("trikeshed/TrikeShed/src/linuxMain/resources/io_uring_interop"))
                extraOpts("-libraryPath", sqliteDir.get().asFile.path, "-libraryPath", liburingDir.get().dir("src").asFile.path)
                tasks.named(interopProcessingTaskName).configure { dependsOn("sqliteArchive", "liburingLib") }
            }
            binaries.executable("feed") { entryPoint = "borg.trikeshed.feed.main" }
        }
    }

    // -Ptrike.targets=js: Kotlin/JS on Node.js (node:net sockets, node:sqlite), build/dist/node/server.js (nodeDist).
    if ("js" in nativeTargets) {
        js {
            outputModuleName.set("server")
            nodejs()
            binaries.executable()
        }
    }

    // -Ptrike.targets=wasmWasi: Kotlin/Wasm on wasmtime 46 (WASI preview 1 sockets from -S tcplisten), with SQLite as a
    // second wasm module (sqliteWasm), build/dist/wasi (wasiDist).
    if ("wasmWasi" in nativeTargets) {
        @OptIn(org.jetbrains.kotlin.gradle.ExperimentalWasmDsl::class)
        wasmWasi {
            nodejs()
            binaries.executable()
        }
    }

    sourceSets {
        val commonMain by getting {
            dependencies {
                // TrikeShed, compiled on the box from the pinned checkout by the :trikeshed module.
                implementation(project(":trikeshed"))
                // SctpFeed's owner loop suspends in the reactor (TRANSPORT=sctp): the version the trikeshed slice pins.
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
            }
        }
        val jvmTest by getting {
            dependencies { implementation(kotlin("test")) }
        }
    }
}

// One jar of the app and every runtime jar, flat in build/app: what start.sh puts on -cp.
val app = tasks.register<Sync>("app") {
    from(tasks.named("jvmJar"))
    from(configurations.named("jvmRuntimeClasspath"))
    into(layout.buildDirectory.dir("app"))
}

// The node build: the production executable and the modules it requires, flat in build/dist/node.
if ("js" in nativeTargets) tasks.register<Sync>("nodeDist") {
    from(tasks.named("jsProductionExecutableCompileSync"))
    into(layout.buildDirectory.dir("dist/node"))
}

// The WASI build: the server module plus sqlite.wasm (the stock amalgamation with the options below and
// src/wasmWasiMain/c/sqlbridge.c, a WASI reactor that wasmtime preloads as "sqlite"), flat in build/dist/wasi.
// wasi-sdk's clang from PATH (install.sh links wasm32-wasip1-clang into /usr/local/bin); WASI_SDK=<dir> picks another.
val wasiClang = providers.environmentVariable("WASI_SDK").map { "$it/bin/wasm32-wasip1-clang" }.orElse("wasm32-wasip1-clang")
val sqliteExports = listOf("sqlite3_open_v2", "sqlite3_prepare_v2", "sqlite3_step", "sqlite3_reset", "sqlite3_bind_int64",
    "sqlite3_bind_text", "sqlite3_column_int64", "sqlite3_column_text", "sqlite3_column_bytes", "sqlite3_changes",
    "sqlite3_errmsg")
if ("wasmWasi" in nativeTargets) {
    val sqliteWasm = tasks.register<Exec>("sqliteWasm") {
        dependsOn(sqliteSource)
        val dir = sqliteDir.get().asFile
        val bridge = project.file("src/wasmWasiMain/c/sqlbridge.c")
        inputs.files(File(dir, "sqlite3.c"), bridge)
        outputs.file(File(dir, "sqlite.wasm"))
        workingDir(dir)
        commandLine(listOf(wasiClang.get(), "-O2", "-mexec-model=reactor") +
            sqliteOptions + listOf("sqlite3.c", bridge.path, "-o", "sqlite.wasm") +
            sqliteExports.map { "-Wl,--export=$it" })
    }
    tasks.register<Sync>("wasiDist") {
        from(tasks.named("compileProductionExecutableKotlinWasmWasi"))
        from(sqliteWasm)
        include("*.wasm")
        rename { if (it == "sqlite.wasm") it else "server.wasm" }
        into(layout.buildDirectory.dir("dist/wasi"))
    }
}

// The driver: SQLite 3.54.0 from its amalgamation, built here for this one-thread process.
val sqliteUrl = "https://sqlite.org/2026/sqlite-amalgamation-3540000.zip"
val sqliteSha3 = "7b670a62fdfbd672b75fef004cb703c8a3e87d3a5cc7d675b4a08337004a2d93"
val macHost = System.getProperty("os.name").startsWith("Mac")

val sqliteSource = tasks.register<JavaExec>("sqliteSource") {
    dependsOn("jvmMainClasses")
    mainClass.set("borg.trikeshed.feed.SqliteSourceKt")
    classpath(tasks.named("jvmJar"), configurations.named("jvmRuntimeClasspath"))
    args(sqliteUrl, sqliteSha3, sqliteDir.get().asFile.path)
    outputs.files(sqliteDir.map { it.file("sqlite3.c") }, sqliteDir.map { it.file("sqlite3.h") })
}

// compile.html#rcmd, plus no extension loading; SQLITE_THREADSAFE=2 (multi-thread): the loop thread and the checkpoint
// thread (feedbt_checkpointer) each own one connection.
// SQLITE_ENABLE_QPSG: binding a new post id no longer re-prepares the post statement (sqlite3ExprIsInteger).
val sqliteOptions = listOf(
    "-DSQLITE_DQS=0", "-DSQLITE_THREADSAFE=2", "-DSQLITE_DEFAULT_MEMSTATUS=0", "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
    "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS", "-DSQLITE_MAX_EXPR_DEPTH=0", "-DSQLITE_OMIT_DECLTYPE", "-DSQLITE_OMIT_DEPRECATED",
    "-DSQLITE_OMIT_PROGRESS_CALLBACK", "-DSQLITE_OMIT_SHARED_CACHE", "-DSQLITE_USE_ALLOCA", "-DSQLITE_OMIT_LOAD_EXTENSION",
    "-DSQLITE_ENABLE_QPSG",
)

val sqliteLib = tasks.register<Exec>("sqliteLib") {
    dependsOn(sqliteSource)
    val dir = sqliteDir.get().asFile
    val lib = File(dir, if (macHost) "libsqlite3.dylib" else "libsqlite3.so")
    inputs.file(File(dir, "sqlite3.c"))
    outputs.file(lib)
    workingDir(dir)
    commandLine(listOf("cc", "-O2", "-fPIC", if (macHost) "-dynamiclib" else "-shared") + sqliteOptions +
        listOf("sqlite3.c", "-o", lib.path) + (if (macHost) emptyList() else listOf("-lm")))
}

// The KN server links SQLite statically: the same options, one object in libsqlite3.a, built from the amalgamation's
// sqlite3.c as published (SQLite's source is not patched). The object is feedbt.c, which includes sqlite3.c whole and adds
// the B-tree read plans for GET /feed and GET /posts/:id (SQLite's B-tree functions are private to the amalgamation).
// SQLITE_DISABLE_LFS: the
// amalgamation's _FILE_OFFSET_BITS=64 makes glibc >= 2.28 name fcntl fcntl64, which Kotlin/Native's glibc 2.19 link
// sysroot lacks; off_t is 64 bits on x86_64 either way.
tasks.register<Exec>("sqliteArchive") {
    dependsOn(sqliteSource)
    val dir = sqliteDir.get().asFile
    val plans = project.file("src/nativeInterop")
    inputs.file(File(dir, "sqlite3.c"))
    inputs.files(File(plans, "feedbt.c"), File(plans, "feedbt.h"))
    outputs.file(File(dir, "libsqlite3.a"))
    workingDir(dir)
    commandLine("sh", "-c", (listOf("cc", "-O2", "-fPIC", "-c", "-DSQLITE_DISABLE_LFS") + sqliteOptions +
        listOf("-I.", "-I${plans.path}", File(plans, "feedbt.c").path, "-o", "sqlite3.o")).joinToString(" ") +
        " && rm -f libsqlite3.a && ar rcs libsqlite3.a sqlite3.o && rm sqlite3.o")
}

// liburing from the TrikeShed subrepo's pinned source tree, configured and built here (static only).
val liburingCopy = tasks.register<Copy>("liburingCopy") {
    from(rootProject.file("trikeshed/TrikeShed/src/linuxMain/resources/liburing")) {
        include("configure", "Makefile", "Makefile.common", "Makefile.quiet", "liburing.spec", "*.pc.in", "src/**")
    }
    into(liburingDir)
}
tasks.register<Exec>("liburingLib") {
    dependsOn(liburingCopy)
    inputs.dir(rootProject.file("trikeshed/TrikeShed/src/linuxMain/resources/liburing/src"))
    outputs.file(liburingDir.map { it.file("src/liburing.a") })
    workingDir(liburingDir)
    commandLine("sh", "-c", "sh ./configure --use-libc > /dev/null && make library ENABLE_SHARED=0 -j2 > /dev/null")
}

// RingServerTest: the built libsqlite3 and the challenge's seed database and tokens.
tasks.withType<Test>().configureEach {
    dependsOn(sqliteLib)
    jvmArgs("--enable-native-access=ALL-UNNAMED")
    systemProperty("sqlite.lib", File(sqliteDir.get().asFile, if (macHost) "libsqlite3.dylib" else "libsqlite3.so").path)
    systemProperty("feed.seed", rootProject.file("../../seed").path)
    testLogging { showStandardStreams = true }
}
