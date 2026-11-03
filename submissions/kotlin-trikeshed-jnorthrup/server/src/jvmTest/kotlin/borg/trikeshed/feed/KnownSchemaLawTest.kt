package borg.trikeshed.feed

import borg.trikeshed.job.hmacSha256
import borg.trikeshed.parse.confix.KnownKind
import borg.trikeshed.parse.confix.KnownSchema
import borg.trikeshed.parse.confix.KnownSchemaReader
import borg.trikeshed.parse.confix.KnownShape
import java.util.Base64
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The known-schema plan against the feed's generic scanner (JsonScan.members, the behavior it replaces at the
 * JWT and body call sites): the same shape for every text, and on objects the same last value of every planned
 * member, over hand-written edge cases and seeded random mutations of them.
 */
class KnownSchemaLawTest {
    // ASCII names, a non-ASCII name, the replacement character and a lone surrogate (which has no UTF-8 form).
    val keys = arrayOf("sub", "username", "exp", "body", "alg", "\u00e9", "\uFFFD", "\uD800")
    val schema = KnownSchema(*keys)
    val reader = schema.reader()
    val into = arrayOfNulls<Any>(keys.size)

    val corpus = listOf(
        """{"sub":"42","username":"u42","exp":1893456000}""",
        """{"sub":"42","username":"u42","exp":1.8934560e9}""",
        """{"sub":"42","username":"u42","exp":-0}""",
        """{"sub":"42","username":"u42","exp":null}""",
        """{"sub":"42","username":"u42","exp":"1893456000"}""",
        """{"sub":"1","sub":"2","username":"a","username":"b"}""",
        """{"s\u0075b":"\u0031\u0032","username":"\ud83d\ude00 \"x\" \\ \/ \b\f\n\r\t"}""",
        """{"username":"lone \ud800 surrogate","body":"caf\u00e9 é"}""",
        """{"body":"  trimmed  ","nested":{"a":[1,2,{"b":null}],"c":"d"},"alg":"HS256"}""",
        """{"alg":"HS256","typ":"JWT"}""",
        """{"alg":"HS\u0032\u0035\u0036"}""",
        """{"body":true,"sub":false,"exp":[],"username":{}}""",
        """ { "body" : "spaced" , "exp" : 12.5e-1 } """,
        """{}""", """[]""", """"just a string"""", """123""", """null""",
        """{"body":"x",}""", """{"body":"x" "y":1}""", """{"body":01}""", """{"body":1.}""", """{"body":-}""",
        """{"body":"\x"}""", """{"body":"\u12"}""", """{"body":"raw	tab"}""", """{"body":"x"} trailing""",
        """{"body":[1,2,]}""", """{"body":{"a":1,}}""", """{body:1}""", """{"body":tru}""", """{"body":nul}""",
        """{"exp":1e400}""", """{"exp":123456789012345678901234567890}""", """{"exp":-12.000}""",
        """{"sub":"123456789012345678","username":"max"}""", """{"sub":"1234567890123456789","username":"over"}""",
        """{"exp":-9223372036854775808,"body":9223372036854775807}""", """{"exp":9223372036854775808,"body":-9223372036854775809}""",
        """{"exp":-0,"body":0,"alg":-0.0}""", """{"exp":1E2,"body":1e-2,"alg":-1.5E+3}""",
        """{"\u00e9":1,"é":2}""", """{"é":3,"\u00e9":4}""", """{"\ud800":5}""", """{"\uFFFD":"r","body":"\ud800"}""",
        """{"username":"a","sub":"1"}""", """{"sub":"1"}""", """{"sub":null,"username":null}""",
    )

    /** Texts with bytes that are not UTF-8: a raw 0xFF key decodes to U+FFFD, a raw surrogate encoding to replacements. */
    val rawCorpus: List<ByteArray> = listOf(
        bytes("{\"", 0xFF, "\":1}"),
        bytes("{\"body\":\"", 0xFF, "x\"}"),
        bytes("{\"", 0xED, 0xA0, 0x80, "\":2,\"alg\":\"", 0xED, 0xA0, 0x80, "\"}"),
        bytes("{\"", 0xEF, 0xBF, 0xBD, "\":3}"),
        bytes("{\"", 0xC3, "\":4}"),
        bytes("{\"body\":\"caf", 0xC3, 0xA9, "\\n\"}"),
    )

    fun bytes(vararg parts: Any): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        for (p in parts) if (p is Int) out.write(p) else out.write((p as String).encodeToByteArray())
        return out.toByteArray()
    }

    fun check(text: ByteArray, from: Int, to: Int) {
        val expected = JsonScan(text, from, to).members(keys, into)
        val actual = reader.scan(text, from, to)
        assertEquals(expected.name, actual.name, "shape of ${text.decodeToString(from, to)}")
        for (k in keys.indices) {
            val want = if (actual == KnownShape.OBJECT) into[k] else null
            val kind = reader.kind(k)
            val where = "member ${keys[k]} of ${text.decodeToString(from, to)}"
            when (want) {
                null -> assertEquals(KnownKind.ABSENT, kind, where)
                is String -> {
                    assertEquals(KnownKind.STRING, kind, where)
                    assertEquals(want, reader.text(k), where)
                    // A lone surrogate has no UTF-8 form, so only texts that survive the round trip are compared as bytes.
                    val utf8 = want.encodeToByteArray()
                    if (utf8.decodeToString() == want) assertTrue(reader.textEquals(k, utf8), where)
                    assertEquals(positiveId(want), reader.positiveDecimal(k), where)
                }
                is Double -> {
                    assertEquals(KnownKind.NUMBER, kind, where)
                    assertEquals(want.toBits(), reader.number(k).toBits(), where)
                    // long(): exact for integer syntax within the Long range, null for fractions, exponents and overflow.
                    val literal = text.decodeToString(reader.from(k), reader.to(k))
                    val exact = if (Regex("-?[0-9]+").matches(literal)) literal.toLongOrNull() else null
                    assertEquals(exact, reader.long(k), where)
                }
                true -> assertEquals(KnownKind.TRUE, kind, where)
                false -> assertEquals(KnownKind.FALSE, kind, where)
                JsonNull -> assertEquals(KnownKind.NULL, kind, where)
                JsonNested -> assertTrue(kind == KnownKind.OBJECT || kind == KnownKind.ARRAY, where)
                else -> fail("unexpected generic value $want")
            }
        }
    }

    @Test
    fun thePlanAgreesWithTheGenericScannerOnEdgeCases() {
        for (doc in corpus) {
            val bytes = doc.encodeToByteArray()
            check(bytes, 0, bytes.size)
            // The same text inside a larger buffer: only [from, to) is read.
            val padded = "xx".encodeToByteArray() + bytes + "yy".encodeToByteArray()
            check(padded, 2, 2 + bytes.size)
        }
        for (raw in rawCorpus) check(raw, 0, raw.size)
    }

    @Test
    fun ndjsonLinesAreScannedOneByOneWithThePlan() {
        val lines = corpus.filter { '\n' !in it && '\r' !in it }
        val text = StringBuilder()
        for ((i, l) in lines.withIndex()) {
            text.append(l).append(if (i % 3 == 0) "\r\n" else "\n")
            if (i % 7 == 0) text.append(" \t\r\n")
        }
        text.append(lines.first())
        val bytes = text.toString().encodeToByteArray()
        fun record(r: KnownSchemaReader, shape: KnownShape): String = buildString {
            append(shape)
            for (k in keys.indices) {
                append('|').append(r.kind(k))
                when (r.kind(k)) {
                    KnownKind.STRING -> append('=').append(r.text(k))
                    KnownKind.NUMBER -> append('=').append(r.number(k).toBits())
                    else -> {}
                }
            }
        }
        val expected = ArrayList<String>()
        for (l in lines + lines.first()) {
            if (l.all { it == ' ' || it == '\t' }) continue
            val one = l.encodeToByteArray()
            expected.add(record(reader, reader.scan(one)))
        }
        val got = ArrayList<String>()
        reader.forEachLine(bytes) { shape, from, to ->
            got.add(record(reader, shape))
            assertTrue(from in 0..to && to <= bytes.size && bytes.copyOfRange(from, to).none { it == '\n'.code.toByte() })
        }
        assertEquals(expected.size, got.size, "one record per non-blank line, the last one without its LF included")
        for (i in expected.indices) assertEquals(expected[i], got[i], "line $i")
        // A range inside a larger buffer: only its lines.
        val padded = "zz\n".encodeToByteArray() + bytes + "\nyy".encodeToByteArray()
        var n = 0
        reader.forEachLine(padded, 3, 3 + bytes.size) { _, _, _ -> n++ }
        assertEquals(expected.size, n)
    }

    @Test
    fun rawNonUtf8KeysAndValuesMatchByTheirDecodedText() {
        val schema = KnownSchema("\uFFFD", "body", "\uD800")
        val r = schema.reader()
        val ff = bytes("{\"", 0xFF, "\":1,\"body\":\"", 0xFF, "\"}")
        assertEquals(KnownShape.OBJECT, r.scan(ff))
        assertEquals(KnownKind.NUMBER, r.kind(0), "raw 0xFF decodes to U+FFFD, which the plan names")
        assertEquals("\uFFFD", r.text(1))
        assertTrue(r.textEquals(1, "\uFFFD".encodeToByteArray()), "invalid byte vs U+FFFD's UTF-8: equal decoded texts")
        assertTrue(r.textEquals(1, byteArrayOf(0xFF.toByte())), "both sides decode to U+FFFD")
        assertTrue(!r.textEquals(1, "x".encodeToByteArray()))
        // The lone surrogate name matches only a key whose decoded text is that surrogate (an escape), never the
        // replacement its lossy UTF-8 encoding would produce.
        val surrogate = bytes("{\"\\ud800\":2}")
        assertEquals(KnownShape.OBJECT, r.scan(surrogate))
        assertEquals(KnownKind.NUMBER, r.kind(2))
        assertEquals(KnownKind.ABSENT, r.kind(0))
        val encoded = bytes("{\"", 0xED, 0xA0, 0x80, "\":3,\"?\":4}")
        assertEquals(KnownShape.OBJECT, r.scan(encoded))
        assertEquals(KnownKind.ABSENT, r.kind(2), "raw surrogate bytes are invalid UTF-8, not the surrogate")
    }

    @Test
    fun scanRejectsRangesOutsideItsBytesAndThePlanIsImmutable() {
        val bytes = "{}".encodeToByteArray()
        for ((from, to) in listOf(-1 to 2, 0 to 3, 2 to 1)) {
            try {
                reader.scan(bytes, from, to)
                fail("[$from, $to) of 2 bytes was accepted")
            } catch (_: IndexOutOfBoundsException) {
            }
        }
        val names = arrayOf("a", "b")
        val plan = KnownSchema(*names)
        names[0] = "z"
        assertEquals(listOf("a", "b"), plan.names)
        assertEquals(0, plan.column("a"))
        assertEquals(-1, plan.column("z"))
    }

    @Test
    fun thePlanAgreesWithTheGenericScannerOnSeededMutations() {
        val random = Random(20261017)
        val alphabet = "{}[]\":,\\ -+.eE0123456789tfnrulsabu\u00e9xyz\t\n".encodeToByteArray() +
            byteArrayOf(0xFF.toByte(), 0xED.toByte(), 0xA0.toByte(), 0x80.toByte())
        var objects = 0
        var malformed = 0
        repeat(40_000) {
            val pick = random.nextInt(corpus.size + rawCorpus.size)
            val seed = if (pick < corpus.size) corpus[pick].encodeToByteArray() else rawCorpus[pick - corpus.size]
            val text = seed.toMutableList()
            repeat(1 + random.nextInt(3)) {
                when (random.nextInt(3)) {
                    0 -> if (text.isNotEmpty()) text.removeAt(random.nextInt(text.size))
                    1 -> text.add(random.nextInt(text.size + 1), alphabet[random.nextInt(alphabet.size)])
                    else -> if (text.isNotEmpty()) text[random.nextInt(text.size)] = alphabet[random.nextInt(alphabet.size)]
                }
            }
            val bytes = text.toByteArray()
            check(bytes, 0, bytes.size)
            if (reader.scan(bytes, 0, bytes.size) == KnownShape.OBJECT) objects++ else malformed++
        }
        assertTrue(objects > 1000 && malformed > 1000, "the mutations reach both outcomes: $objects objects, $malformed others")
    }

    @Test
    fun nestingIsBoundedAsTheGenericScannerBoundsIt() {
        for (depth in listOf(510, 511, 512, 513)) {
            val doc = "{\"body\":" + "[".repeat(depth) + "]".repeat(depth) + "}"
            val bytes = doc.encodeToByteArray()
            check(bytes, 0, bytes.size)
        }
    }

    val secret = "twelve-dollar-challenge".encodeToByteArray()
    val encoder = Base64.getUrlEncoder().withoutPadding()

    fun token(header: String, payload: String): ByteArray {
        val signing = encoder.encodeToString(header.encodeToByteArray()) + "." + encoder.encodeToString(payload.encodeToByteArray())
        val signature = encoder.encodeToString(hmacSha256(secret, signing.encodeToByteArray()))
        return "Bearer $signing.$signature".encodeToByteArray()
    }

    fun verify(header: String, payload: String, now: Long = 1_800_000_000L): Pair<BearerState, Bearer> {
        val bearer = Bearer(secret)
        val t = token(header, payload)
        return bearer.verify(t, 0, t.size, now) to bearer
    }

    @Test
    fun bearerVerificationKeepsItsSchema() {
        val hs = """{"alg":"HS256","typ":"JWT"}"""
        val (ok, b) = verify(hs, """{"sub":"7","username":"seven","exp":1893456000}""")
        assertEquals(BearerState.VALID, ok)
        assertEquals(7L, b.user)
        assertEquals("seven", b.name)
        assertEquals(BearerState.INVALID, verify(hs, """{"sub":"7","username":"seven"}""").first, "exp is required")
        assertEquals(BearerState.VALID, verify(hs, """{"sub":"7","username":"s","exp":1800000000.5}""").first, "fractional exp not yet reached")
        assertEquals(BearerState.INVALID, verify(hs, """{"sub":"7","username":"s","exp":1800000000}""").first, "exp reached")
        assertEquals(BearerState.INVALID, verify(hs, """{"sub":"7","username":"s","exp":null}""").first, "explicit null exp")
        assertEquals(BearerState.INVALID, verify(hs, """{"sub":"7","username":"s","exp":"1893456000"}""").first, "string exp")
        assertEquals(BearerState.VALID, verify(hs, """{"sub":"7","username":"s","exp":1.9e9}""").first, "exponent exp")
        assertEquals(BearerState.PAYLOAD, verify(hs, """{"exp":1893456000,"sub":7,"username":"s"}""").first, "numeric sub")
        assertEquals(BearerState.PAYLOAD, verify(hs, """{"exp":1893456000,"sub":"7a","username":"s"}""").first)
        assertEquals(BearerState.PAYLOAD, verify(hs, """{"exp":1893456000,"sub":"1234567890123456789","username":"s"}""").first, "19 digits")
        assertEquals(BearerState.PAYLOAD, verify(hs, """{"exp":1893456000,"sub":"7"}""").first, "no username")
        val (escaped, e) = verify(hs, """{"exp":1893456000,"s\u0075b":"\u0031\u0032","username":"\u0041"}""")
        assertEquals(BearerState.VALID, escaped)
        assertEquals(12L, e.user)
        assertEquals("A", e.name)
        val (last, l) = verify(hs, """{"exp":1893456000,"sub":"1","username":"a","sub":"2","username":"b"}""")
        assertEquals(BearerState.VALID, last)
        assertEquals(2L, l.user, "the last duplicate wins")
        assertEquals("b", l.name)
        assertEquals(BearerState.INVALID, verify(hs, """{"exp":1893456000,"sub":"7","username":"s","x":[1,}""").first, "malformed ignored member")
        assertEquals(BearerState.INVALID, verify("""{"alg":"none"}""", """{"exp":1893456000,"sub":"7","username":"s"}""").first)
        assertEquals(BearerState.VALID, verify("""{"alg":"HS\u0032\u0035\u0036"}""", """{"exp":1893456000,"sub":"7","username":"s"}""").first)
        assertEquals(BearerState.INVALID, verify("""["HS256"]""", """{"exp":1893456000,"sub":"7","username":"s"}""").first)
    }
}
