package borg.trikeshed.feed

/** A JSON null member value. */
object JsonNull

/** A JSON object or array member value; its content is not retained. */
object JsonNested

/** Outcome of [JsonScan.members]. */
enum class JsonShape { MALFORMED, VALUE, OBJECT }

/**
 * Strict RFC 8259 reader over UTF-8 bytes. [members] validates a whole JSON text and keeps the top-level object
 * members named in its keys: strings decoded, numbers as Double, true/false as Boolean, [JsonNull], [JsonNested].
 * A repeated member keeps its last value, as JSON.parse does.
 */
class JsonScan(val src: ByteArray, var at: Int, val end: Int) {
    var ok = true
    val text = StringBuilder()

    fun members(keys: Array<String>, into: Array<Any?>): JsonShape {
        into.fill(null)
        ws()
        val shape = if (at < end && src[at] == '{'.code.toByte()) {
            objectInto(keys, into)
            JsonShape.OBJECT
        } else {
            value(0)
            JsonShape.VALUE
        }
        ws()
        return if (ok && at == end) shape else JsonShape.MALFORMED
    }

    fun fail(): Any? { ok = false; at = end; return null }

    fun ws() {
        while (at < end) {
            val c = src[at].toInt()
            if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) at++ else return
        }
    }

    fun objectInto(keys: Array<String>, into: Array<Any?>) {
        at++ // '{'
        ws()
        if (at < end && src[at] == '}'.code.toByte()) { at++; return }
        while (ok) {
            ws()
            if (at >= end || src[at] != '"'.code.toByte()) { fail(); return }
            val key = string() ?: return
            ws()
            if (at >= end || src[at] != ':'.code.toByte()) { fail(); return }
            at++
            ws()
            val v = value(1)
            if (!ok) return
            val k = keys.indexOf(key)
            if (k >= 0) into[k] = v
            ws()
            if (at >= end) { fail(); return }
            when (src[at].toInt().toChar()) {
                ',' -> at++
                '}' -> { at++; return }
                else -> { fail(); return }
            }
        }
    }

    fun value(depth: Int): Any? {
        if (depth > 512 || at >= end) return fail()
        return when (src[at].toInt().toChar()) {
            '"' -> string()
            '{' -> { nested(depth, '}'); JsonNested }
            '[' -> { nested(depth, ']'); JsonNested }
            't' -> word("true", true)
            'f' -> word("false", false)
            'n' -> word("null", JsonNull)
            else -> number()
        }
    }

    fun nested(depth: Int, close: Char) {
        at++
        ws()
        if (at < end && src[at] == close.code.toByte()) { at++; return }
        while (ok) {
            ws()
            if (close == '}') {
                if (at >= end || src[at] != '"'.code.toByte()) { fail(); return }
                string() ?: return
                ws()
                if (at >= end || src[at] != ':'.code.toByte()) { fail(); return }
                at++
                ws()
            }
            value(depth + 1)
            if (!ok) return
            ws()
            if (at >= end) { fail(); return }
            val c = src[at].toInt().toChar()
            at++
            if (c == close) return
            if (c != ',') { fail(); return }
        }
    }

    fun word(w: String, v: Any): Any? {
        if (end - at < w.length) return fail()
        for (i in w.indices) if (src[at + i] != w[i].code.toByte()) return fail()
        at += w.length
        return v
    }

    fun number(): Any? {
        val from = at
        if (at < end && src[at] == '-'.code.toByte()) at++
        if (at >= end) return fail()
        if (src[at] == '0'.code.toByte()) at++
        else if (digit(src[at])) { while (at < end && digit(src[at])) at++ }
        else return fail()
        if (at < end && src[at] == '.'.code.toByte()) {
            at++
            if (at >= end || !digit(src[at])) return fail()
            while (at < end && digit(src[at])) at++
        }
        if (at < end && (src[at] == 'e'.code.toByte() || src[at] == 'E'.code.toByte())) {
            at++
            if (at < end && (src[at] == '+'.code.toByte() || src[at] == '-'.code.toByte())) at++
            if (at >= end || !digit(src[at])) return fail()
            while (at < end && digit(src[at])) at++
        }
        return src.decodeToString(from, at).toDouble()
    }

    fun digit(b: Byte): Boolean = b >= '0'.code.toByte() && b <= '9'.code.toByte()

    /** The string at [at] (opening quote), decoded; null when malformed. */
    fun string(): String? {
        at++
        text.setLength(0)
        var run = at
        while (at < end) {
            val c = src[at].toInt() and 0xFF
            when {
                c == '"'.code -> {
                    if (at > run) text.append(src.decodeToString(run, at))
                    at++
                    return text.toString()
                }
                c == '\\'.code -> {
                    if (at > run) text.append(src.decodeToString(run, at))
                    if (at + 1 >= end) { fail(); return null }
                    when (src[at + 1].toInt().toChar()) {
                        '"' -> text.append('"')
                        '\\' -> text.append('\\')
                        '/' -> text.append('/')
                        'b' -> text.append('\b')
                        'f' -> text.append('\u000C')
                        'n' -> text.append('\n')
                        'r' -> text.append('\r')
                        't' -> text.append('\t')
                        'u' -> {
                            if (at + 6 > end) { fail(); return null }
                            var u = 0
                            for (k in 2..5) {
                                val h = hexValue(src[at + k].toInt())
                                if (h < 0) { fail(); return null }
                                u = (u shl 4) or h
                            }
                            text.append(u.toChar())
                            at += 4
                        }
                        else -> { fail(); return null }
                    }
                    at += 2
                    run = at
                }
                c < 0x20 -> { fail(); return null }
                else -> at++
            }
        }
        fail()
        return null
    }
}

fun hexValue(c: Int): Int = when (c.toChar()) {
    in '0'..'9' -> c - '0'.code
    in 'a'..'f' -> c - 'a'.code + 10
    in 'A'..'F' -> c - 'A'.code + 10
    else -> -1
}

/** ECMAScript String.prototype.trim(): WhiteSpace and LineTerminator code points. */
fun isEcmaSpace(c: Char): Boolean = when (c) {
    '\t', '\n', '\u000B', '\u000C', '\r', ' ', '\u00A0', '\u1680', '\u2028', '\u2029', '\u202F', '\u205F', '\u3000', '\uFEFF' -> true
    else -> c in '\u2000'..'\u200A'
}

fun String.ecmaTrim(): String {
    var a = 0
    var b = length
    while (a < b && isEcmaSpace(this[a])) a++
    while (b > a && isEcmaSpace(this[b - 1])) b--
    return substring(a, b)
}

/** Unicode code points in this string, a lone surrogate counting as one. */
fun String.codePointLength(): Int {
    var n = 0
    var i = 0
    while (i < length) {
        val c = this[i]
        i += if (c.isHighSurrogate() && i + 1 < length && this[i + 1].isLowSurrogate()) 2 else 1
        n++
    }
    return n
}
