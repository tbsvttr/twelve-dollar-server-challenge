package borg.trikeshed.feed

import borg.trikeshed.job.hmacSha256
import borg.trikeshed.parse.confix.KnownKind
import borg.trikeshed.parse.confix.KnownSchema
import borg.trikeshed.parse.confix.KnownShape

/** Bearer verification outcome. */
enum class BearerState { VALID, MISSING, INVALID, PAYLOAD }

val HEADER_KEYS: Array<String> = arrayOf("alg")
val PAYLOAD_KEYS: Array<String> = arrayOf("sub", "username", "exp")

/** The JWT header and payload members read, as known-schema plans: one strict pass each, no generic values. */
val HEADER_SCHEMA: KnownSchema = KnownSchema(*HEADER_KEYS)
val PAYLOAD_SCHEMA: KnownSchema = KnownSchema(*PAYLOAD_KEYS)
val HS256: ByteArray = "HS256".encodeToByteArray()

/** HS256 JWT verification, every token, every request: signature, alg, exp, then sub and username. */
class Bearer(val secret: ByteArray) {
    var user: Long = 0
    var name: String = ""
    val header = HEADER_SCHEMA.reader()
    val claims = PAYLOAD_SCHEMA.reader()

    /** The Authorization value at [from, to) of [src]; null range for an absent header. */
    fun verify(src: ByteArray, from: Int, to: Int, nowSeconds: Long): BearerState {
        if (from < 0 || to - from < 7 || !src.startsWith(from, BEARER)) return BearerState.MISSING
        val t = from + 7
        val d1 = src.indexOf('.'.code.toByte(), t, to)
        val d2 = if (d1 < 0) -1 else src.indexOf('.'.code.toByte(), d1 + 1, to)
        if (d2 < 0 || src.indexOf('.'.code.toByte(), d2 + 1, to) >= 0) return BearerState.INVALID
        val head = base64Url(src, t, d1) ?: return BearerState.INVALID
        if (header.scan(head) != KnownShape.OBJECT || !header.textEquals(0, HS256)) return BearerState.INVALID
        val signature = base64Url(src, d2 + 1, to) ?: return BearerState.INVALID
        val expected = hmacSha256(secret, src.copyOfRange(t, d2))
        if (signature.size != expected.size) return BearerState.INVALID
        var diff = 0
        for (i in expected.indices) diff = diff or (expected[i].toInt() xor signature[i].toInt())
        if (diff != 0) return BearerState.INVALID
        val payload = base64Url(src, d1 + 1, d2) ?: return BearerState.INVALID
        if (claims.scan(payload) != KnownShape.OBJECT) return BearerState.INVALID
        // exp is required: a JSON number (fraction and exponent allowed) not yet reached. Absent, it is a 401 (SPEC).
        if (claims.kind(2) != KnownKind.NUMBER || nowSeconds >= claims.number(2)) return BearerState.INVALID
        if (claims.kind(0) != KnownKind.STRING || claims.kind(1) != KnownKind.STRING) return BearerState.PAYLOAD
        user = claims.positiveDecimal(0)
        if (user <= 0) return BearerState.PAYLOAD
        name = claims.text(1)!!
        return BearerState.VALID
    }
}

val BEARER: ByteArray = "Bearer ".encodeToByteArray()

fun ByteArray.startsWith(at: Int, prefix: ByteArray): Boolean {
    if (at + prefix.size > size) return false
    for (i in prefix.indices) if (this[at + i] != prefix[i]) return false
    return true
}

fun ByteArray.indexOf(b: Byte, from: Int, to: Int): Int {
    for (i in from until to) if (this[i] == b) return i
    return -1
}

/** A positive decimal integer of at most 18 digits; 0 when the text is anything else. */
fun positiveId(s: String): Long {
    if (s.isEmpty() || s.length > 18) return 0
    var v = 0L
    for (c in s) {
        if (c !in '0'..'9') return 0
        v = v * 10 + (c - '0')
    }
    return v
}

fun base64UrlValue(c: Int): Int = when (c.toChar()) {
    in 'A'..'Z' -> c - 'A'.code
    in 'a'..'z' -> c - 'a'.code + 26
    in '0'..'9' -> c - '0'.code + 52
    '-' -> 62
    '_' -> 63
    else -> -1
}

/** Unpadded base64url at [from, to) of [src]; null when any byte is outside the alphabet or the length is impossible. */
fun base64Url(src: ByteArray, from: Int, to: Int): ByteArray? {
    val n = to - from
    if (n % 4 == 1) return null
    val out = ByteArray(n * 3 / 4)
    var acc = 0
    var bits = 0
    var w = 0
    for (i in from until to) {
        val v = base64UrlValue(src[i].toInt())
        if (v < 0) return null
        acc = (acc shl 6) or v
        bits += 6
        if (bits >= 8) {
            bits -= 8
            out[w++] = (acc shr bits).toByte()
        }
    }
    return if (w == out.size) out else out.copyOf(w)
}
