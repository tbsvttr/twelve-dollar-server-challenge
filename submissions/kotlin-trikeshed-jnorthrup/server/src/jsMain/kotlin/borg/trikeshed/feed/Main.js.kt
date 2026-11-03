package borg.trikeshed.feed

/** Configured by SQLITE_PATH, JWT_SECRET, HOST and PORT: the Xio states over Node's sockets ([Poller]), node:sqlite. */
fun main() {
    val env: dynamic = js("process.env")
    fun get(name: String): String? = (env[name] as String?)
    val store = SqliteStore(get("SQLITE_PATH") ?: error("SQLITE_PATH is not set"))
    val feed = Feed(store, Bearer((get("JWT_SECRET") ?: error("JWT_SECRET is not set")).encodeToByteArray()), epochSeconds())
    Xio(Poller(get("HOST") ?: "127.0.0.1", (get("PORT") ?: "3000").toInt()), feed, store).init()
}
