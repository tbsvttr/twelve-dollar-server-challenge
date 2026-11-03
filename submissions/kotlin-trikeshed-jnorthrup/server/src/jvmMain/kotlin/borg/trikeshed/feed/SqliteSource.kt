package borg.trikeshed.feed

import borg.trikeshed.job.Sha3
import borg.trikeshed.util.toLowerHex
import java.io.File
import java.net.URI
import java.util.zip.ZipInputStream

/** Fetches the SQLite amalgamation zip, checks the SHA3-256 sqlite.org publishes for it, unpacks sqlite3.c and sqlite3.h. */
fun main(args: Array<String>) {
    val (url, sha3, dir) = args
    val out = File(dir).apply { mkdirs() }
    if (File(out, "sqlite3.c").isFile && File(out, "sqlite3.h").isFile && File(out, "sha3").takeIf { it.isFile }?.readText() == sha3) return
    val zip = URI(url).toURL().openStream().use { it.readBytes() }
    val actual = Sha3(32).update(zip).digest().toLowerHex()
    check(actual == sha3) { "$url: SHA3-256 $actual, expected $sha3" }
    ZipInputStream(zip.inputStream()).use { z ->
        while (true) {
            val e = z.nextEntry ?: break
            val name = e.name.substringAfterLast('/')
            if (name == "sqlite3.c" || name == "sqlite3.h") File(out, name).writeBytes(z.readBytes())
        }
    }
    File(out, "sha3").writeText(sha3)
}
