import org.jetbrains.kotlin.gradle.ExperimentalKotlinGradlePluginApi
import org.jetbrains.kotlin.gradle.ExperimentalWasmDsl
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinVersion
import org.jetbrains.kotlin.gradle.plugin.mpp.DisableCacheInKotlinVersion
import org.jetbrains.kotlin.gradle.plugin.mpp.KotlinNativeCacheApi
import org.jetbrains.kotlin.gradle.plugin.mpp.TestExecutable

plugins {
    kotlin("multiplatform")
    kotlin("plugin.serialization")
}

// Opt-in targets for the leaf permutation and the Kotlin/Native server, -Ptrike.targets=linuxX64,linuxArm64,macosArm64,
// wasmWasi; the box builds the JVM target only. A native target needs no C header and no C library for the leaf
// codecs: it compiles the Kotlin LZ4 and LZO of commonMain (nativeMain's LeafSpecialization binds nothing). Only the
// JVM's FFM specialization loads liblz4 and liblzo2, at run time.
val extraTargets = providers.gradleProperty("trike.targets").orNull.orEmpty().split(',').map { it.trim() }.toSet()

// TrikeShed linkage: this module compiles TrikeShed's own files, read from the git subrepo TrikeShed/ at the commit
// git records for it (build.sh reifies the subrepo when a checkout leaves it empty). sources.txt lists the paths;
// each source set reads src/<set>/kotlin and src/<set>/resources of the subrepo, restricted to the listed files.
val subrepo = file("TrikeShed")
val listed = file("sources.txt").readLines().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }
val linked = listed.filter { ':' !in it }
// "set:path" lines compile a TrikeShed file into another source set of this module: webMain (js and wasmWasi) takes
// commonMain expects whose JVM and posix actuals the other targets do not compile.
val routed = listed.filter { ':' in it }.map { it.substringBefore(':') to it.substringAfter(':') }
check(File(subrepo, "src").isDirectory) { "trikeshed/TrikeShed is not reified: build.sh (or tester.sh git) does that" }

kotlin {
    @OptIn(ExperimentalKotlinGradlePluginApi::class)
    compilerOptions {
        apiVersion.set(KotlinVersion.KOTLIN_2_4)
        languageVersion.set(KotlinVersion.KOTLIN_2_4)
        freeCompilerArgs.addAll(
            "-opt-in=kotlin.RequiresOptIn",
            "-opt-in=kotlin.ExperimentalUnsignedTypes",
            "-opt-in=kotlinx.cinterop.UnsafeNumber",
            "-opt-in=kotlinx.cinterop.ExperimentalForeignApi",
            "-Xsuppress-version-warnings",
            "-Xexpect-actual-classes",
            "-Xallow-kotlin-package",
        )
    }

    jvm {
        @OptIn(ExperimentalKotlinGradlePluginApi::class)
        compilerOptions { jvmTarget.set(JvmTarget.JVM_25) }
    }

    val natives = listOfNotNull(
        if ("linuxX64" in extraTargets) linuxX64() else null,
        if ("linuxArm64" in extraTargets) linuxArm64() else null,
        if ("macosArm64" in extraTargets) macosArm64() else null,
    )
    for (target in natives) {
        target.binaries.executable("leafPermutation") { entryPoint = "borg.trikeshed.tilting.leaf.main" }
        // posix_spawn.def: TrikeShed's POSIX cinterop (trikeshed_open, spawn, args), package borg.trikeshed.userspace.nio.posix.
        target.compilations.getByName("main").cinterops.create("posixSpawn") {
            definitionFile.set(File(subrepo, "src/posixMain/resources/META-INF/cinterop/posix_spawn.def"))
        }
        // Linux: TrikeShed's ring actuals (Liburing.linux.kt, NativeUringAdapter.linux.kt) call liburing through its
        // zlinux_uring cinterop, over the liburing the server module configures and builds (server/build/liburing).
        if (target.name.startsWith("linux")) target.compilations.getByName("main").cinterops.create("zlinux_uring") {
            definitionFile.set(File(subrepo, "src/linuxMain/resources/META-INF/cinterop/liburing.def"))
            packageName("zlinux_uring")
            val uring = rootProject.file("server/build/liburing")
            compilerOpts("-I$uring/src/include", "-I" + File(subrepo, "src/linuxMain/resources/liburing/src/include"),
                "-I" + File(subrepo, "src/linuxMain/resources/io_uring_interop"))
            extraOpts("-libraryPath", "$uring/src")
            tasks.named(interopProcessingTaskName).configure { dependsOn(":server:liburingLib") }
        }
        // Debug test binaries link without Kotlin/Native's compiler caches: on the macOS host the 2.4.21-RC
        // macos_arm64 stdlib cache in ~/.konan held objects built for iOS (LC_BUILD_VERSION platform 2), which ld rejected.
        if (target.name == "macosArm64") target.binaries.withType<TestExecutable>().configureEach {
            @OptIn(KotlinNativeCacheApi::class)
            disableNativeCache(DisableCacheInKotlinVersion.`2_4_21`, "macos_arm64 stdlib cache objects built for iOS")
        }
    }

    if ("wasmWasi" in extraTargets) {
        @OptIn(ExperimentalWasmDsl::class)
        wasmWasi {
            nodejs()
            binaries.executable()
        }
    }
    // js: Kotlin/JS for Node.js, the library side of the server's node build.
    if ("js" in extraTargets) {
        js { nodejs() }
    }

    sourceSets.configureEach {
        val into = routed.filter { it.first == name }.map { it.second }
        if (into.isNotEmpty()) {
            val root = into.first().substringBefore("/kotlin/") + "/kotlin"
            check(into.all { it.startsWith("$root/") }) { "$name: routed files must share one source root" }
            kotlin.setSrcDirs(listOf(File(subrepo, root)))
            kotlin.setIncludes(into.map { it.removePrefix("$root/") })
            resources.setSrcDirs(emptyList<File>())
            return@configureEach
        }
        val kotlinFiles = linked.filter { it.startsWith("src/$name/kotlin/") }.map { it.removePrefix("src/$name/kotlin/") }
        val resourceFiles =
            linked.filter { it.startsWith("src/$name/resources/") }.map { it.removePrefix("src/$name/resources/") }
        kotlin.setSrcDirs(if (kotlinFiles.isEmpty()) emptyList() else listOf(File(subrepo, "src/$name/kotlin")))
        kotlin.setIncludes(kotlinFiles)
        resources.setSrcDirs(if (resourceFiles.isEmpty()) emptyList() else listOf(File(subrepo, "src/$name/resources")))
        resources.setIncludes(resourceFiles)
    }

    sourceSets {
        // The userspace ring, reactor TLS and Confix closure: the versions TrikeShed's own build pins.
        val commonMain by getting {
            dependencies {
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
                // Synchronization's SynchronizedObject: the version TrikeShed's own build pins.
                api("org.jetbrains.kotlinx:atomicfu:0.33.0")
                implementation("org.jetbrains.kotlinx:kotlinx-serialization-core:1.11.0")
                implementation("org.jetbrains.kotlinx:kotlinx-datetime:0.8.0-0.6.x-compat")
            }
        }
        val commonTest by getting {
            dependencies {
                implementation(kotlin("test"))
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
            }
        }
        val nonPosixMain by creating { dependsOn(commonMain) }
        val jvmMain by getting { dependsOn(nonPosixMain) }
        if (natives.isNotEmpty()) {
            val nativeMain by creating { dependsOn(commonMain) }
            val posixMain by creating { dependsOn(nativeMain) }
            // lzNative{Main,Test}: the leaf permutation's main and its corpus reader, shared by every native target.
            val lzNativeMain by creating { dependsOn(posixMain) }
            val lzNativeTest by creating { dependsOn(commonTest) }
            // src/linuxMain and src/macosMain: TrikeShed's per-OS actuals (its ring facade, its host probes).
            val linuxMain by creating { dependsOn(lzNativeMain) }
            val macosMain by creating { dependsOn(lzNativeMain) }
            for (target in natives) {
                getByName("${target.name}Main") { dependsOn(if (target.name.startsWith("macos")) macosMain else linuxMain) }
                getByName("${target.name}Test") { dependsOn(lzNativeTest) }
            }
        }
        val web = "js" in extraTargets || "wasmWasi" in extraTargets
        val webMain = if (web) (findByName("webMain") ?: create("webMain")).apply { dependsOn(nonPosixMain) } else null
        if ("wasmWasi" in extraTargets) {
            // src/wasmMain: TrikeShed's actuals shared by its two wasm targets.
            val wasmMain = findByName("wasmMain") ?: create("wasmMain")
            wasmMain.dependsOn(webMain!!)
            val wasmWasiMain by getting { dependsOn(wasmMain) }
        }
        if ("js" in extraTargets) {
            val jsMain by getting { dependsOn(webMain!!) }
        }
    }
}

// FFM specializations (liblz4, liblzo2, libcrypto) need native access; -Pleaf.corpus=<pages file> feeds the permutation.
tasks.withType<Test>().configureEach {
    jvmArgs("--enable-native-access=ALL-UNNAMED")
    providers.gradleProperty("leaf.corpus").orNull?.let { systemProperty("leaf.corpus", it) }
    testLogging { showStandardStreams = true }
}
