package borg.trikeshed.loadgen

import java.io.ByteArrayOutputStream
import java.io.File
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicLong
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * The workload against a stub server that leaves every fourth request unanswered, with one receive window per worker
 * and a 1 s deadline: requests time out, connections drop and users reconnect (after load.js think time, within the
 * 12 s establishing window) while others wait for the one window.
 * Each worker checks at every RECV that the user neither watches, reads nor waits in the queue already; a breach ends
 * the worker, which the summary reports.
 */
class TinyRxReconnectTest {
    val dir: File = Files.createTempDirectory("loadgen-tinyrx").toFile()
    val sockets = ConcurrentLinkedQueue<Socket>()
    val threads = ConcurrentLinkedQueue<Thread>()
    var listener: ServerSocket? = null

    @AfterTest
    fun clean() {
        listener?.close()
        for (s in sockets) runCatching { s.close() }
        for (t in threads) t.join(5_000)
        dir.deleteRecursively()
    }

    fun serve(requests: AtomicLong) {
        val server = ServerSocket(0).also { listener = it }
        threads.add(Thread {
            while (!server.isClosed) {
                val s = runCatching { server.accept() }.getOrNull() ?: break
                sockets.add(s)
                threads.add(Thread { connection(s, requests) }.apply { isDaemon = true; start() })
            }
        }.apply { isDaemon = true; start() })
    }

    fun connection(s: Socket, requests: AtomicLong) = runCatching {
        val input = s.getInputStream()
        val output = s.getOutputStream()
        val pending = ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (true) {
            val n = input.read(buffer)
            if (n < 0) return@runCatching
            pending.write(buffer, 0, n)
            while (true) {
                val text = String(pending.toByteArray(), Charsets.ISO_8859_1)
                val head = text.indexOf("\r\n\r\n")
                if (head < 0) break
                val length = Regex("(?i)content-length: *(\\d+)").find(text.substring(0, head))?.groupValues?.get(1)?.toInt() ?: 0
                if (text.length < head + 4 + length) break
                val line = text.substring(0, text.indexOf("\r\n"))
                val rest = pending.toByteArray().copyOfRange(head + 4 + length, pending.size())
                pending.reset()
                pending.write(rest)
                if (requests.incrementAndGet() % 4 == 0L) continue // unanswered: the client's deadline will pass
                val path = line.split(' ')[1]
                val (status, body) = when {
                    path == "/feed" -> 200 to (1..20).joinToString(",", "{\"posts\":[", "]}") { "{\"id\":$it}" }
                    path.endsWith("/like") -> 200 to "{\"liked\":true,\"already_liked\":false,\"post_id\":${path.split('/')[2]}}"
                    path.startsWith("/posts/") -> 200 to "{\"post\":{\"id\":${path.substringAfter("/posts/")},\"body\":\"x\"}}"
                    else -> 201 to "{\"post\":{\"id\":1,\"author\":\"u\",\"like_count\":0}}"
                }
                val bytes = body.toByteArray()
                output.write("HTTP/1.1 $status OK\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\n\r\n".toByteArray() + bytes)
            }
        }
    }

    @Test
    fun timeoutsAndReconnectsUnderOneReceiveWindowKeepOneReadPerUser() {
        val requests = AtomicLong()
        serve(requests)
        val tokens = File(dir, "tokens.json").apply {
            writeText((1..8).joinToString(",", "[", "]") { "{\"username\":\"u$it\",\"token\":\"t$it\"}" })
        }
        val out = File(dir, "out")
        runLoad(mapOf("host" to "127.0.0.1", "ports" to "${listener!!.localPort}", "tls" to "false", "vus" to "64", "ramp" to "1",
            "hold" to "3", "threads" to "1", "timeout" to "1", "tokens" to tokens.path, "out" to out.path, "establish" to "12",
            "drain" to "3", "rxWindows" to "1"))
        val summary = File(out, "summary.json").readText()
        val failed = Regex("\"failed\":\\[(.*)]}}").find(summary)?.groupValues?.get(1).orEmpty()
        assertTrue("loadgen-" !in failed, "no worker ended on an ownership breach: $failed")
        val disconnects = Regex("\"disconnects\":(\\d+)").find(summary)!!.groupValues[1].toLong()
        val timeouts = Regex("\"requestTimeout\":(\\d+)").find(summary)!!.groupValues[1].toLong()
        val connects = Regex("\"handshakes\":(\\d+)").find(summary)!!.groupValues[1].toLong()
        println("tiny RX reconnect: $timeouts request timeouts, $disconnects disconnects, $connects connections for 64 users, ${requests.get()} requests seen")
        assertTrue(timeouts > 0 && disconnects >= timeouts, "deadlines passed and dropped their connections")
        assertTrue(connects > 64, "users reconnected after their timeouts")
    }
}
