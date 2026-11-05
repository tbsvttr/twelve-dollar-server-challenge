using System.Buffers;
using System.Buffers.Text;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Feed;

/// <summary>
/// The arena all responses of a pass are written into. It lives on the pinned heap, because sends point straight into it.
/// One instance is reused for every pass, so the steady state allocates nothing.
/// </summary>
internal sealed unsafe class Out(int capacity) {
    // Bytes a JSON string must escape: '"', '\' and the control characters.
    private static readonly SearchValues<byte> Escaped = SearchValues.Create(
        "\"\\\u0000\u0001\u0002\u0003\u0004\u0005\u0006\u0007\u0008\u0009\u000A\u000B\u000C\u000D\u000E\u000F\u0010\u0011\u0012\u0013\u0014\u0015\u0016\u0017\u0018\u0019\u001A\u001B\u001C\u001D\u001E\u001F"u8);
    private static readonly byte[] Hex = "0123456789abcdef"u8.ToArray();

    /// <summary>The backing array. Replaced when it grows, so do not hold on to it across writes.</summary>
    public byte[] Buf = GC.AllocateUninitializedArray<byte>(capacity, pinned: true);

    /// <summary>Bytes written so far. Callers may set it lower to drop output they no longer want.</summary>
    public int Len;

    /// <summary>The address of the first byte. Changes when the array grows.</summary>
    public byte* Ptr => (byte*)Unsafe.AsPointer(ref MemoryMarshal.GetArrayDataReference(Buf));

    public void Reset() => Len = 0;

    private void Ensure(int extra) {
        if (Len + extra > Buf.Length) {
            byte[] bigger = GC.AllocateUninitializedArray<byte>(Math.Max(Buf.Length * 2, Len + extra), pinned: true);
            Buf.AsSpan(0, Len).CopyTo(bigger);
            Buf = bigger;
        }
    }

    /// <summary>Takes <paramref name="count"/> bytes at the end, to be filled in later, and returns where they start.</summary>
    public int Grow(int count) {
        Ensure(count);
        int start = Len;
        Len += count;
        return start;
    }

    public void Bytes(ReadOnlySpan<byte> bytes) {
        Ensure(bytes.Length);
        bytes.CopyTo(Buf.AsSpan(Len));
        Len += bytes.Length;
    }

    public void Byte(byte b) {
        Ensure(1);
        Buf[Len++] = b;
    }

    public void Int(long value) {
        Ensure(20);
        Utf8Formatter.TryFormat(value, Buf.AsSpan(Len), out int written);
        Len += written;
    }

    /// <summary>
    /// A quoted JSON string from UTF-8 bytes. Only '"', '\' and control characters are escaped; other bytes,
    /// non-ASCII included, are copied as they are. SQLite holds the UTF-8 this server encoded, so it is valid.
    /// </summary>
    public void JsonString(ReadOnlySpan<byte> utf8) {
        Ensure(utf8.Length + 2);
        Buf[Len++] = (byte)'"';
        while (true) {
            int i = utf8.IndexOfAny(Escaped);
            if (i < 0) {
                Bytes(utf8);
                break;
            }

            Bytes(utf8[..i]);
            Escape(utf8[i]);
            utf8 = utf8[(i + 1)..];
        }

        Byte((byte)'"');
    }

    private void Escape(byte b) {
        Ensure(6);
        Buf[Len++] = (byte)'\\';
        switch (b) {
            case (byte)'"': Buf[Len++] = (byte)'"'; break;
            case (byte)'\\': Buf[Len++] = (byte)'\\'; break;
            case (byte)'\n': Buf[Len++] = (byte)'n'; break;
            case (byte)'\r': Buf[Len++] = (byte)'r'; break;
            case (byte)'\t': Buf[Len++] = (byte)'t'; break;
            case (byte)'\b': Buf[Len++] = (byte)'b'; break;
            case (byte)'\f': Buf[Len++] = (byte)'f'; break;
            default:
                Buf[Len++] = (byte)'u';
                Buf[Len++] = (byte)'0';
                Buf[Len++] = (byte)'0';
                Buf[Len++] = Hex[b >> 4];
                Buf[Len++] = Hex[b & 0xF];
                break;
        }
    }
}
