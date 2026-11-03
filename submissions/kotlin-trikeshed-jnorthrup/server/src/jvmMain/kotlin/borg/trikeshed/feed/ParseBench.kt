package borg.trikeshed.feed

import borg.trikeshed.parse.confix.KnownShape
import java.lang.management.ManagementFactory
import java.util.SplittableRandom

/**
 * Component benchmark of the feed's JSON call sites, generic scanner (JsonScan.members: decoded Strings, Double,
 * generic slots) against the known-schema plan (KnownSchemaReader: one validating pass, typed reads), over a varied
 * seeded corpus rather than one repeated document: [CORPUS] JWT payloads (ids, names with and without non-ASCII,
 * exp, member order, unplanned and nested members), [CORPUS] POST bodies (8 to about 300 characters of whole pieces: plain, escaped, raw UTF-8)
 * and the same bodies as one NDJSON block. Both readers consume the same values (ids, exp, a hash of every decoded
 * text), checked equal before timing. Prints ns and bytes allocated (the thread's counter) per document after
 * warmup, one JSON line per case. Single-threaded, bounded by PASSES over the corpus.
 * usage: java -cp <the server/build/app jars> borg.trikeshed.feed.ParseBenchKt [PASSES] [SEED]
 */
const val CORPUS = 1024

fun main(args: Array<String>) {
    val passes = args.getOrNull(0)?.toInt() ?: 2000
    val random = SplittableRandom(args.getOrNull(1)?.toLong() ?: 17L)
    val names = arrayOf("user", "usér", "ユーザー", "user_\\u00e9", "u")
    val payloads = Array(CORPUS) {
        val sub = 1 + random.nextInt(999_999)
        val name = "\"${names[random.nextInt(names.size)]}$sub\""
        val exp = 1_800_000_000L + random.nextInt(100_000_000)
        val members = mutableListOf("\"sub\":\"$sub\"", "\"username\":$name", "\"iat\":1760000000", "\"exp\":$exp")
        if (random.nextInt(4) == 0) members.add("\"role\":\"reader\"")
        if (random.nextInt(8) == 0) members.add("\"meta\":{\"tags\":[1,2,{\"k\":null}],\"ok\":true}")
        if (random.nextInt(2) == 0) members.shuffle(java.util.Random(random.nextLong()))
        members.joinToString(",", "{", "}").encodeToByteArray()
    }
    val pieces = arrayOf("Lorem ipsum dolor sit amet", "consectetur", "caf\\u00e9", "\\\"quoted\\\"", "line\\nbreak", "naïve", "日本語", "tab\\t")
    val bodies = Array(CORPUS) {
        val target = 8 + random.nextInt(273)
        val text = StringBuilder()
        while (text.length < target) text.append(pieces[random.nextInt(pieces.size)]).append(' ')
        // Whole pieces only, so no escape is ever cut in half.
        "{\"body\":\"${text.toString().trimEnd()}\"}".encodeToByteArray()
    }
    val block = bodies.joinToString("\n") { it.decodeToString() }.encodeToByteArray()
    val threads = ManagementFactory.getThreadMXBean() as com.sun.management.ThreadMXBean
    val into = arrayOfNulls<Any>(3)
    val claims = PAYLOAD_SCHEMA.reader()
    val bodyReader = BODY_SCHEMA.reader()

    fun genericPayload(d: ByteArray): Long {
        check(JsonScan(d, 0, d.size).members(PAYLOAD_KEYS, into) == JsonShape.OBJECT)
        return positiveId(into[0] as String) + (into[1] as String).hashCode() + (into[2] as Double).toLong()
    }
    fun plannedPayload(d: ByteArray): Long {
        check(claims.scan(d) == KnownShape.OBJECT)
        return claims.positiveDecimal(0) + claims.text(1)!!.hashCode() + claims.number(2).toLong()
    }
    fun genericBody(d: ByteArray, from: Int, to: Int): Long {
        check(JsonScan(d, from, to).members(BODY_KEYS, into) == JsonShape.OBJECT)
        return (into[0] as String).hashCode().toLong()
    }
    fun plannedBody(d: ByteArray): Long {
        check(bodyReader.scan(d) == KnownShape.OBJECT)
        return bodyReader.text(0)!!.hashCode().toLong()
    }
    fun genericBlock(): Long {
        var sum = 0L
        var at = 0
        while (at < block.size) {
            var end = at
            while (end < block.size && block[end] != '\n'.code.toByte()) end++
            sum += genericBody(block, at, end)
            at = end + 1
        }
        return sum
    }
    fun plannedBlock(): Long {
        var sum = 0L
        bodyReader.forEachLine(block) { shape, _, _ ->
            check(shape == KnownShape.OBJECT)
            sum += bodyReader.text(0)!!.hashCode()
        }
        return sum
    }
    val agree = payloads.all { genericPayload(it) == plannedPayload(it) } && bodies.all { genericBody(it, 0, it.size) == plannedBody(it) } &&
        genericBlock() == plannedBlock()
    check(agree) { "the readers disagree on the corpus" }
    var sink = 0L
    fun bench(name: String, docsPerPass: Int, bytesPerPass: Long, pass: () -> Long) {
        repeat(passes / 4 + 1) { sink += pass() }
        val bytes0 = threads.currentThreadAllocatedBytes
        val t0 = System.nanoTime()
        for (i in 0 until passes) sink += pass()
        val nanos = System.nanoTime() - t0
        val bytes = threads.currentThreadAllocatedBytes - bytes0
        val docs = docsPerPass.toLong() * passes
        println("{\"case\":\"$name\",\"documents\":$docs,\"meanBytesPerDocument\":${bytesPerPass / docsPerPass},\"nsPerDocument\":${"%.1f".format(nanos.toDouble() / docs)}," +
            "\"bytesAllocatedPerDocument\":${"%.1f".format(bytes.toDouble() / docs)}}")
    }
    val payloadBytes = payloads.sumOf { it.size.toLong() }
    val bodyBytes = bodies.sumOf { it.size.toLong() }
    bench("jwt-payload generic JsonScan", CORPUS, payloadBytes) { var s = 0L; for (d in payloads) s += genericPayload(d); s }
    bench("jwt-payload known-schema plan", CORPUS, payloadBytes) { var s = 0L; for (d in payloads) s += plannedPayload(d); s }
    bench("post-body generic JsonScan", CORPUS, bodyBytes) { var s = 0L; for (d in bodies) s += genericBody(d, 0, d.size); s }
    bench("post-body known-schema plan", CORPUS, bodyBytes) { var s = 0L; for (d in bodies) s += plannedBody(d); s }
    bench("ndjson-bodies generic JsonScan per line", CORPUS, block.size.toLong()) { genericBlock() }
    bench("ndjson-bodies known-schema forEachLine", CORPUS, block.size.toLong()) { plannedBlock() }
    println("{\"agree\":$agree,\"corpus\":$CORPUS,\"passes\":$passes,\"sink\":$sink,\"java\":\"${java.lang.System.getProperty("java.vm.name")} ${java.lang.System.getProperty("java.version")}\"," +
        "\"jvmFlags\":\"${ManagementFactory.getRuntimeMXBean().inputArguments.filter { it.startsWith("-XX") || it.startsWith("-Xm") }}\"}")
}
