import org.jetbrains.kotlin.gradle.ExperimentalKotlinGradlePluginApi
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinVersion

plugins {
    kotlin("multiplatform")
}

// The load generator: bench/load.js's workload over the same central ring and TLS record path as the server.
kotlin {
    @OptIn(ExperimentalKotlinGradlePluginApi::class)
    compilerOptions {
        apiVersion.set(KotlinVersion.KOTLIN_2_4)
        languageVersion.set(KotlinVersion.KOTLIN_2_4)
        freeCompilerArgs.addAll("-opt-in=kotlin.RequiresOptIn", "-Xsuppress-version-warnings")
    }

    jvm {
        @OptIn(ExperimentalKotlinGradlePluginApi::class)
        compilerOptions { jvmTarget.set(JvmTarget.JVM_25) }
    }

    // -Ptrike.targets=macosArm64: the Kotlin/Native client (commonMain ReactorLoad over the kqueue reactor),
    // build/bin/macosArm64/loadgenReleaseExecutable/loadgen.kexe. No JVM descriptor cap, no JVM heap per process.
    if ("macosArm64" in providers.gradleProperty("trike.targets").orNull.orEmpty().split(',').map { it.trim() }) {
        macosArm64 {
            compilerOptions { optIn.add("kotlinx.cinterop.ExperimentalForeignApi") }
            binaries.executable("loadgen") { entryPoint = "borg.trikeshed.loadgen.reactor.main" }
        }
    }

    sourceSets {
        val commonMain by getting {
            dependencies {
                implementation(project(":trikeshed"))
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
            }
        }
        val jvmMain by getting {
            dependencies { implementation(project(":trikeshed")) }
        }
        val jvmTest by getting {
            dependencies { implementation(kotlin("test")) }
        }
    }
}

// The generator's jars, flat in build/app.
// RxPlacesTest, TinyRxReconnectTest: the client ring is FFM where the kernel's io_uring is available.
tasks.withType<Test>().configureEach {
    jvmArgs("--enable-native-access=ALL-UNNAMED")
    testLogging { showStandardStreams = true }
}

tasks.register<Sync>("app") {
    from(tasks.named("jvmJar"))
    from(configurations.named("jvmRuntimeClasspath"))
    into(layout.buildDirectory.dir("app"))
}
