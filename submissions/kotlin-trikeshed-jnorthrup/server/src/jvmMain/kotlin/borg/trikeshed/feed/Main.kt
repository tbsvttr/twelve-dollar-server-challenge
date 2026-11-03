package borg.trikeshed.feed

/**
 * Configured by SQLITE_PATH, JWT_SECRET, HOST and PORT. TRANSPORT=ring serves through the central uring contract
 * instead of the java.nio Selector (see [serveRing]); without it this is the submitted plain-HTTP Xio path.
 */
fun main() {
    val env = System.getenv()
    val store = SqliteStore(env.getValue("SQLITE_PATH"))
    val feed = Feed(store, Bearer(env.getValue("JWT_SECRET").encodeToByteArray()), epochSeconds())
    if (env["TRANSPORT"] == "ring") {
        serveRing(env, feed, store)
        return
    }
    Xio(Poller(env["HOST"] ?: "127.0.0.1", (env["PORT"] ?: "3000").toInt()), feed, store).init()
}
