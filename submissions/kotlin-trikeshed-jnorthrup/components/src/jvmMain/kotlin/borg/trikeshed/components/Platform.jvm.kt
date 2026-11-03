package borg.trikeshed.components

import java.io.File

actual val platformName: String = "jvm ${System.getProperty("java.vm.name")} ${System.getProperty("java.version")} " +
    (if (System.getProperty("org.graalvm.nativeimage.imagecode") != null) "native-image" else "JIT")

actual val capabilities: String = "JVM: the central userspace ring (FFM io_uring on Linux, emulated elsewhere), JSSE TLS and sockets are built in the submission's trikeshed module; this binary runs the common components and java.io files"

actual fun scratchPath(name: String): String = File(System.getProperty("java.io.tmpdir"), name).path

actual fun fileRoundTrip(path: String, bytes: ByteArray, rounds: Int): Long? {
    val f = File(path)
    var sum = 0L
    repeat(rounds) {
        f.writeBytes(bytes)
        val back = f.readBytes()
        sum += back[it % back.size]
    }
    f.delete()
    return sum
}
