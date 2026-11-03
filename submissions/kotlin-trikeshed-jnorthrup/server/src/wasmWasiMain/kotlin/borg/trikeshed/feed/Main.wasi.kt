package borg.trikeshed.feed

import borg.trikeshed.userspace.wasi.Wasi

/** Configured by SQLITE_PATH and JWT_SECRET (wasmtime --env): the Xio states over WASI sockets ([Poller]), sqlite.wasm. */
fun main() {
    try {
        serve()
    } catch (failure: Throwable) {
        println("wasi server: $failure")
        throw failure
    }
}

fun serve() {
    val env = Wasi.environment
    val store = SqliteStore(env["SQLITE_PATH"] ?: error("SQLITE_PATH is not set"))
    val feed = Feed(store, Bearer((env["JWT_SECRET"] ?: error("JWT_SECRET is not set")).encodeToByteArray()), epochSeconds())
    Xio(Poller(env["HOST"] ?: "127.0.0.1", (env["PORT"] ?: "3000").toInt()), feed, store).init()
}
