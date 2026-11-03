import org.jetbrains.kotlin.gradle.ExperimentalKotlinGradlePluginApi
import org.jetbrains.kotlin.gradle.ExperimentalWasmDsl
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.plugin.mpp.KotlinNativeTarget

// TrikeShed components on every target this host can build: the module's own bench sources plus the TrikeShed files
// listed in sources.txt (read from the trikeshed/TrikeShed subrepo, not copied). JVM always; native and WASI targets by
// -Pcomponents.targets=macosArm64,linuxX64,mingwX64,wasmWasi.
plugins {
    kotlin("multiplatform")
}

val componentTargets = providers.gradleProperty("components.targets").orNull.orEmpty().split(',').map { it.trim() }.toSet()
val subrepo = file("../trikeshed/TrikeShed")
val linked = file("sources.txt").readLines().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }

kotlin {
    compilerOptions {
        freeCompilerArgs.addAll("-opt-in=kotlinx.cinterop.ExperimentalForeignApi", "-opt-in=kotlin.experimental.ExperimentalNativeApi",
            "-opt-in=kotlinx.cinterop.UnsafeNumber")
    }
    jvm {
        @OptIn(ExperimentalKotlinGradlePluginApi::class)
        compilerOptions { jvmTarget.set(JvmTarget.JVM_25) }
    }
    val natives = listOfNotNull<KotlinNativeTarget>(
        if ("macosArm64" in componentTargets) macosArm64() else null,
        if ("linuxX64" in componentTargets) linuxX64() else null,
        if ("mingwX64" in componentTargets) mingwX64() else null,
    )
    for (target in natives) target.binaries.executable("components") { entryPoint = "borg.trikeshed.components.main" }
    if ("wasmWasi" in componentTargets) {
        @OptIn(ExperimentalWasmDsl::class)
        wasmWasi {
            nodejs()
            binaries.executable()
        }
    }
    sourceSets.configureEach {
        val shared = linked.filter { it.startsWith("src/$name/kotlin/") }.map { it.removePrefix("src/$name/kotlin/") }
        if (shared.isNotEmpty()) {
            kotlin.srcDir(File(subrepo, "src/$name/kotlin"))
            kotlin.setIncludes(shared + "borg/trikeshed/components/**")
        }
    }
    sourceSets {
        if (natives.isNotEmpty()) {
            val nativeMain by creating { dependsOn(getByName("commonMain")) }
            for (target in natives) getByName("${target.name}Main") { dependsOn(nativeMain) }
        }
    }
}

tasks.register<Jar>("componentsJar") {
    archiveFileName.set("components-all.jar")
    destinationDirectory.set(layout.buildDirectory.dir("app"))
    manifest { attributes("Main-Class" to "borg.trikeshed.components.ComponentBenchKt") }
    val jvm = kotlin.jvm().compilations.getByName("main")
    from(jvm.output.allOutputs)
    from(configurations.getByName("jvmRuntimeClasspath").map { if (it.isDirectory) it else zipTree(it) })
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    dependsOn(jvm.compileTaskProvider)
}
