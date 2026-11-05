using System.Runtime.InteropServices;
using static Feed.Native;

namespace Feed;

/// <summary>
/// One connection's state, in native memory: the garbage collector has nothing to scan however many connections
/// are open. All three buffers are null while a connection is idle.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct Slot {
    public byte* In;     // the start of a partial or held request
    public byte* Own;    // output the kernel is sending; never moved or freed while a send is in flight
    public byte* Pend;   // output that waits for that send
    public int InLen, InCap, OwnOff, OwnLen, PendLen, PendCap;
    public uint Gen;     // changes on close, so a completion for an earlier connection in this slot is recognised
    public int RecPass;  // pass number + 1 of this slot's record in the arena
    public int RecIdx;
    public byte State;
    public byte Queued;  // read out of the kernel, and waiting in In for a pass with room to answer it
}

/// <summary>
/// One io_uring instance with its fixed-file table, receive buffers and slot table. Only the loop thread touches it,
/// as SINGLE_ISSUER requires. A table can be no larger than RLIMIT_NOFILE, so past ~60,000 connections the loop opens
/// another ring. Sockets accepted into the table never use a process fd.
/// </summary>
internal sealed unsafe class Ring {
    public const int SqEntries = 4096;
    public const int CqEntries = 16384;
    /// <summary>Receive buffers per ring, a power of 2. MB_NBUFS overrides it, for experiments.</summary>
    public static readonly int BufCount = int.TryParse(Environment.GetEnvironmentVariable("MB_NBUFS"), out int n) && n > 0 && (n & (n - 1)) == 0 ? n : 4096;
    public const int BufSize = 1024;

    public const int OpAccept = 1, OpRecv = 2, OpSendArena = 3, OpSendOwn = 4, OpIgnore = 5;

    public readonly int Index;
    public readonly int SlotCount;
    public readonly Slot* Slots;
    public int Open;
    public bool Accepting;
    public uint AcceptGen;
    public uint AcceptArmed; // bit per listener: its multishot accept of AcceptGen is running

    private readonly int _fd;
    private readonly uint* _sqHead, _sqTail, _cqHead, _cqTail;
    private readonly Sqe* _sqes;
    private readonly Cqe* _cqes;
    private readonly uint _sqMask, _cqMask;
    private uint _tail;
    private readonly BufRingEntry* _bufRing;
    private readonly byte* _bufBase;
    private ushort _bufTail, _bufPublished;

    // user_data: op (3 bits) | ring (3) | slot (16) | generation (24) | extra (18)
    public static ulong Tag(int op, int ring, int slot, uint gen, int extra = 0) =>
        (uint)op | ((ulong)(uint)ring << 3) | ((ulong)(uint)slot << 6) | ((ulong)(gen & 0xFFFFFF) << 22) | ((ulong)(uint)extra << 46);

    /// <summary>The part of a tag that names one connection: ring, slot and generation.</summary>
    public const ulong KeyMask = 0x3FFFFFFFFFF8UL;

    public Ring(int index, int slots) {
        if (sizeof(UringParams) != 120 || sizeof(Sqe) != 64 || sizeof(Cqe) != 16 || sizeof(RsrcRegister) != 32
            || sizeof(BufReg) != 40 || sizeof(BufRingEntry) != 16 || sizeof(GetEventsArg) != 24) {
            throw new InvalidOperationException("io_uring struct layout does not match the kernel ABI");
        }

        Index = index;
        SlotCount = slots;

        // Some kernels charge ring memory to RLIMIT_MEMLOCK: a smaller completion queue is tried before giving up.
        UringParams p;
        long fd;
        uint cq = CqEntries;
        while (true) {
            p = default;
            p.CqEntries = cq;
            p.Flags = IORING_SETUP_CQSIZE | IORING_SETUP_SUBMIT_ALL | IORING_SETUP_COOP_TASKRUN
                | IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN;
            fd = syscall_checked(SYS_io_uring_setup, SqEntries, (nint)(&p), 0, 0, 0, 0);
            if (fd >= 0 || Marshal.GetLastPInvokeError() != ENOMEM || cq <= SqEntries) {
                break;
            }

            cq /= 2;
        }

        if (fd < 0) {
            Fail("io_uring_setup");
        }

        _fd = (int)fd;
        byte* sq = Map((nuint)(p.Sq.Array + (p.SqEntries * 4)), IORING_OFF_SQ_RING);
        byte* cqm = Map((nuint)(p.Cq.Cqes + (p.CqEntries * (uint)sizeof(Cqe))), IORING_OFF_CQ_RING);
        _sqes = (Sqe*)Map((nuint)(p.SqEntries * (uint)sizeof(Sqe)), IORING_OFF_SQES);
        _sqHead = (uint*)(sq + p.Sq.Head);
        _sqTail = (uint*)(sq + p.Sq.Tail);
        _sqMask = *(uint*)(sq + p.Sq.RingMask);
        uint* array = (uint*)(sq + p.Sq.Array);
        for (uint i = 0; i <= _sqMask; i++) {
            array[i] = i;
        }

        _cqHead = (uint*)(cqm + p.Cq.Head);
        _cqTail = (uint*)(cqm + p.Cq.Tail);
        _cqMask = *(uint*)(cqm + p.Cq.RingMask);
        _cqes = (Cqe*)(cqm + p.Cq.Cqes);
        _tail = *_sqTail;

        RsrcRegister files = default;
        files.Nr = (uint)slots;
        files.Flags = IORING_RSRC_REGISTER_SPARSE;
        if (syscall_checked(SYS_io_uring_register, _fd, IORING_REGISTER_FILES2, (nint)(&files), sizeof(RsrcRegister), 0, 0) < 0) {
            Fail("io_uring_register files");
        }

        Slots = (Slot*)Anonymous((nuint)slots * (nuint)sizeof(Slot));
        _bufBase = (byte*)Anonymous((nuint)BufCount * BufSize);
        _bufRing = (BufRingEntry*)Anonymous((nuint)BufCount * (nuint)sizeof(BufRingEntry));
        BufReg reg = default;
        reg.RingAddr = (ulong)_bufRing;
        reg.RingEntries = (uint)BufCount;
        if (syscall_checked(SYS_io_uring_register, _fd, IORING_REGISTER_PBUF_RING, (nint)(&reg), 1, 0, 0) < 0) {
            // Ubuntu's 6.8.0-136 and later have this check inverted: they refuse the all-zero reserved words a correct
            // kernel requires (Launchpad #2162843). A correct kernel refuses a non-zero word, so this try can only
            // succeed where the first failed for that reason.
            reg.Resv0 = 1;
            if (syscall_checked(SYS_io_uring_register, _fd, IORING_REGISTER_PBUF_RING, (nint)(&reg), 1, 0, 0) < 0) {
                Fail("io_uring_register buffer ring");
            }
        }

        for (int bid = 0; bid < BufCount; bid++) {
            Recycle(bid);
        }

        PublishBuffers();
    }

    private byte* Map(nuint length, long offset) {
        void* p = mmap(null, length, PROT_READ_WRITE, MAP_SHARED | MAP_POPULATE, _fd, offset);
        if (p == (void*)-1) {
            Fail("mmap ring");
        }

        return (byte*)p;
    }

    private static void* Anonymous(nuint length) {
        void* p = mmap(null, length, PROT_READ_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == (void*)-1) {
            Fail("mmap");
        }

        return p;
    }

    public byte* Buffer(int bid) => _bufBase + ((long)bid * BufSize);

    /// <summary>Gives a receive buffer back; the kernel sees it after <see cref="PublishBuffers"/>.</summary>
    public void Recycle(int bid) {
        BufRingEntry* e = _bufRing + (_bufTail & (BufCount - 1));
        e->Addr = (ulong)Buffer(bid);
        e->Len = BufSize;
        e->Bid = (ushort)bid; // Resv stays: in entry 0 it is the ring's shared tail
        _bufTail++;
    }

    public int Returned => (ushort)(_bufTail - _bufPublished);

    public void PublishBuffers() {
        _bufPublished = _bufTail;
        Volatile.Write(ref *(ushort*)((byte*)_bufRing + 14), _bufTail);
    }

    private Sqe* GetSqe() {
        if (_tail - Volatile.Read(ref *_sqHead) > _sqMask) {
            Submit();
        }

        Sqe* s = _sqes + (_tail & _sqMask);
        *s = default;
        _tail++;
        return s;
    }

    public bool HasUnsubmitted => _tail != Volatile.Read(ref *_sqHead);

    /// <summary>The kernel's completion queue tail; it moves when a call runs the ring's deferred work.</summary>
    public uint CqTail => Volatile.Read(ref *_cqTail);

    /// <summary>Completions posted and not reaped yet.</summary>
    public uint CqReady => Volatile.Read(ref *_cqTail) - *_cqHead;

    /// <summary>Submits the queued entries without running deferred completions.</summary>
    public void Submit() {
        uint pending = _tail - Volatile.Read(ref *_sqHead);
        Volatile.Write(ref *_sqTail, _tail);
        syscall_fast(SYS_io_uring_enter, _fd, (nint)pending, 0, 0, 0, 0);
    }

    /// <summary>Submits, runs deferred completions, and waits for <paramref name="wait"/> of them.</summary>
    public void Enter(uint wait) {
        uint pending = _tail - Volatile.Read(ref *_sqHead);
        Volatile.Write(ref *_sqTail, _tail);
        syscall_fast(SYS_io_uring_enter, _fd, (nint)pending, (nint)wait, IORING_ENTER_GETEVENTS, 0, 0);
    }

    /// <summary>As <see cref="Enter(uint)"/>, but gives up after the timeout inside <paramref name="arg"/>.</summary>
    public void Enter(uint wait, GetEventsArg* arg) {
        uint pending = _tail - Volatile.Read(ref *_sqHead);
        Volatile.Write(ref *_sqTail, _tail);
        syscall_fast(SYS_io_uring_enter, _fd, (nint)pending, (nint)wait, IORING_ENTER_GETEVENTS | IORING_ENTER_EXT_ARG, (nint)arg, sizeof(GetEventsArg));
    }

    /// <summary>Copies up to <paramref name="room"/> completions to <paramref name="into"/> and frees them in the queue.</summary>
    public int Reap(Cqe* into, int room) {
        uint head = *_cqHead;
        uint tail = Volatile.Read(ref *_cqTail);
        int n = 0;
        while (head != tail && n < room) {
            into[n++] = _cqes[head & _cqMask];
            head++;
        }

        Volatile.Write(ref *_cqHead, head);
        return n;
    }

    /// <summary>Starts a multishot accept of every listener whose accept of this generation is not running.</summary>
    public void Accept(int[] listeners, bool newGeneration) {
        if (newGeneration) {
            AcceptGen++;
            AcceptArmed = 0;
        }

        for (int i = 0; i < listeners.Length; i++) {
            if ((AcceptArmed & (1u << i)) != 0) {
                continue;
            }

            Sqe* s = GetSqe();
            s->Opcode = IORING_OP_ACCEPT;
            s->Ioprio = IORING_ACCEPT_MULTISHOT;
            s->Fd = listeners[i];
            s->UserData = Tag(OpAccept, Index, i, AcceptGen);
            s->FileIndex = IORING_FILE_INDEX_ALLOC;
            AcceptArmed |= 1u << i;
        }

        Accepting = true;
    }

    public void StopAccept(int listenerCount) {
        for (int i = 0; i < listenerCount; i++) {
            if ((AcceptArmed & (1u << i)) == 0) {
                continue;
            }

            Sqe* s = GetSqe();
            s->Opcode = IORING_OP_ASYNC_CANCEL;
            s->Flags = IOSQE_CQE_SKIP_SUCCESS;
            s->Fd = -1;
            s->Addr = Tag(OpAccept, Index, i, AcceptGen);
            s->UserData = OpIgnore;
        }

        Accepting = false;
    }

    public void Recv(int slot) {
        Sqe* s = GetSqe();
        s->Opcode = IORING_OP_RECV;
        s->Flags = IOSQE_FIXED_FILE | IOSQE_BUFFER_SELECT;
        s->Ioprio = IORING_RECV_MULTISHOT;
        s->Fd = slot;
        s->UserData = Tag(OpRecv, Index, slot, Slots[slot].Gen);
        Slots[slot].State |= Loop.Recving;
    }

    public void Send(int op, int slot, byte* addr, int len, uint flags, int extra) {
        Sqe* s = GetSqe();
        s->Opcode = IORING_OP_SEND;
        s->Flags = IOSQE_FIXED_FILE;
        s->Fd = slot;
        s->Addr = (ulong)addr;
        s->Len = (uint)len;
        s->OpFlags = flags;
        s->UserData = Tag(op, Index, slot, Slots[slot].Gen, extra);
    }

    /// <summary>
    /// SHUTDOWN (sends the FIN now and ends the multishot receive) hard-linked to the CLOSE of the slot: on 6.8 a closed
    /// fixed file is released only after all older requests on its ring finish, which multishot receives never do. The
    /// CLOSE posts a completion, so "enter until a call adds none" (Loop.Run) does not stop while closes wait.
    /// </summary>
    public void ShutdownClose(int slot) {
        Sqe* s = GetSqe();
        s->Opcode = IORING_OP_SHUTDOWN;
        s->Flags = IOSQE_FIXED_FILE | IOSQE_IO_HARDLINK | IOSQE_CQE_SKIP_SUCCESS;
        s->Fd = slot;
        s->Len = SHUT_RDWR;
        s->UserData = OpIgnore;
        Sqe* c = GetSqe();
        c->Opcode = IORING_OP_CLOSE;
        c->FileIndex = (uint)slot + 1;
        c->UserData = OpIgnore;
    }

    private static void Fail(string what) =>
        throw new InvalidOperationException($"{what} failed: errno {Marshal.GetLastPInvokeError()}");
}
