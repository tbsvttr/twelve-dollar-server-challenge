package borg.trikeshed.feed

/** Response bytes, written front to back into one reused array. */
class Out(var bytes: ByteArray = ByteArray(1 shl 16)) {
    var size: Int = 0

    fun room(n: Int) {
        if (size + n > bytes.size) bytes = bytes.copyOf(maxOf(bytes.size * 2, size + n))
    }

    fun byte(b: Int) {
        room(1)
        bytes[size++] = b.toByte()
    }

    fun raw(src: ByteArray, from: Int = 0, to: Int = src.size) {
        val n = to - from
        room(n)
        src.copyInto(bytes, size, from, to)
        size += n
    }

    fun long(v: Long) {
        if (v < 0) {
            if (v == Long.MIN_VALUE) return raw("-9223372036854775808".encodeToByteArray())
            byte('-'.code)
            return long(-v)
        }
        var digits = 1
        var t = v
        while (t >= 10) { t /= 10; digits++ }
        room(digits)
        var at = size + digits
        t = v
        do { bytes[--at] = ('0'.code + (t % 10).toInt()).toByte(); t /= 10 } while (t != 0L)
        size += digits
    }

    /** The bytes from [from] were copied raw from UTF-8 text: quote, backslash and control bytes become JSON escapes. */
    fun escapeFrom(from: Int) {
        var extra = 0
        for (i in from until size) extra += escapeWidth(bytes[i].toInt() and 0xFF) - 1
        if (extra == 0) return
        room(extra)
        var w = size + extra
        var r = size
        size = w
        while (r > from) {
            val c = bytes[--r].toInt() and 0xFF
            when (escapeWidth(c)) {
                1 -> bytes[--w] = c.toByte()
                2 -> { bytes[--w] = escapeLetter(c).toByte(); bytes[--w] = '\\'.code.toByte() }
                else -> {
                    bytes[--w] = HEX[c and 0xF]; bytes[--w] = HEX[c shr 4]
                    bytes[--w] = '0'.code.toByte(); bytes[--w] = '0'.code.toByte()
                    bytes[--w] = 'u'.code.toByte(); bytes[--w] = '\\'.code.toByte()
                }
            }
        }
    }

    /** [text] as a JSON string body. */
    fun jsonText(text: ByteArray) {
        val at = size
        raw(text)
        escapeFrom(at)
    }
}

val HEX: ByteArray = "0123456789abcdef".encodeToByteArray()

fun escapeWidth(c: Int): Int = when {
    c == '"'.code || c == '\\'.code -> 2
    c >= 0x20 -> 1
    c == 0x08 || c == 0x0C || c == 0x0A || c == 0x0D || c == 0x09 -> 2
    else -> 6
}

fun escapeLetter(c: Int): Int = when (c) {
    0x08 -> 'b'.code
    0x0C -> 'f'.code
    0x0A -> 'n'.code
    0x0D -> 'r'.code
    0x09 -> 't'.code
    else -> c
}
