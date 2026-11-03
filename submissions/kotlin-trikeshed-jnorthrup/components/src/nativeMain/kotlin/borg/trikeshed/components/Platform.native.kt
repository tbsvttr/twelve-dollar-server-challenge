package borg.trikeshed.components

import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.toKString
import kotlinx.cinterop.usePinned
import platform.posix.fclose
import platform.posix.fopen
import platform.posix.fread
import platform.posix.fwrite
import platform.posix.getenv
import platform.posix.remove

actual val platformName: String = "native ${Platform.osFamily} ${Platform.cpuArchitecture}"

actual val capabilities: String = when (Platform.osFamily) {
    OsFamily.WINDOWS -> "mingwX64: common components and C stdio files (msvcrt); the userspace ring, socket and TLS SPIs have no mingw actuals (only ISAM exists for mingw in TrikeShed), so none is claimed"
    else -> "Kotlin/Native posix: common components and C stdio files; the userspace ring/socket/TLS SPIs are not part of this binary"
}

actual fun scratchPath(name: String): String {
    val dir = getenv("TEMP")?.toKString() ?: getenv("TMPDIR")?.toKString() ?: "/tmp"
    return if (Platform.osFamily == OsFamily.WINDOWS) "$dir\\$name" else "$dir/$name"
}

actual fun fileRoundTrip(path: String, bytes: ByteArray, rounds: Int): Long? {
    val back = ByteArray(bytes.size)
    var sum = 0L
    repeat(rounds) { round ->
        val out = fopen(path, "wb") ?: error("fopen $path for writing")
        val wrote = bytes.usePinned { fwrite(it.addressOf(0), 1.convert(), bytes.size.convert(), out) }
        fclose(out)
        check(wrote.toLong() == bytes.size.toLong()) { "short write" }
        val input = fopen(path, "rb") ?: error("fopen $path for reading")
        val read = back.usePinned { fread(it.addressOf(0), 1.convert(), back.size.convert(), input) }
        fclose(input)
        check(read.toLong() == back.size.toLong()) { "short read" }
        sum += back[round % back.size]
    }
    remove(path)
    return sum
}
