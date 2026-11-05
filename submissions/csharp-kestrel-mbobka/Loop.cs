using System.Buffers;
using System.Buffers.Binary;
using System.Buffers.Text;
using System.Diagnostics;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using static Feed.Native;

namespace Feed;

/// <summary>
/// The request thread: owns every ring, parses HTTP/1.1, and runs every request. A pass is one wake-up: everything
/// received runs inside one SQLite transaction, the transaction commits, and only then do its responses reach the
/// kernel, so a 201 always follows its commit (rule 6) and writes share a commit (group commit).
/// Sends carry MSG_DONTWAIT, so they finish inside the submitting io_uring_enter and point straight into the arena.
/// </summary>
internal sealed unsafe class Loop {
    public const byte Live = 1, Recving = 2, Sending = 4, CloseAfter = 8, ContinueSent = 16, Closing = 32, Done = 64, HeldWrite = 128;

    private const int MaxRings = 8;
    private const int PassCap = 32768;    // completions read in one pass
    private const int MaxAnswersPerPass = 2048; // the rest is read out of the kernel now and answered in later passes
    private const uint WaitCompletions = 32;
    private const long WaitNanoseconds = 2_000_000;
    private const int MaxHeaderBytes = 16 * 1024;
    private const int MaxBodyBytes = 1 << 20;
    private const int HeaderRoom = 200;   // the most a response head takes

    private struct Record {
        public int Ring, Slot, Start, Len;
        public uint Gen;
        public bool Close;
    }

    private readonly record struct SlotRef(int Ring, int Slot, uint Gen);

    private readonly int[] _listeners;
    private readonly Api _api;
    private readonly Db _db;
    private readonly Ring?[] _rings = new Ring?[MaxRings];
    private int _ringCount;
    private readonly int _slotsPerRing;
    private readonly bool _enterUntilEmpty;

    /// <summary>
    /// The 2 GB box's budget: what the kernel keeps per open socket decides how many fit, and nothing the server does changes
    /// it. At this many the listeners stop listening, so the kernel answers a new SYN with a reset and allocates nothing.
    /// Accepting and closing instead costs a whole socket and CPU per refusal, and at 340,000 users that alone ended in the
    /// OOM killer. MB_MAX_CONN overrides it, for experiments.
    /// </summary>
    private static readonly int MaxConnections = int.TryParse(Environment.GetEnvironmentVariable("MB_MAX_CONN"), out int max) && max > 0 ? max : 320_000;

    private readonly Out _arena = new(12 << 20); // 2,048 answers at ~4 KB each; only the part in use is backed by memory
    private Record[] _records = new Record[1024];
    private int _recordCount;
    private int _pass;
    private int _answers;  // requests answered in this pass
    private int _open;     // connections open, all rings
    private bool _refusing; // at the limit: the listeners are not listening
    private readonly Queue<SlotRef> _backlog = new(); // slots with requests read out of the kernel, not answered yet
    private int _runStart; // where the current slot's output of this pass starts in the arena; -1: none yet

    private Cqe* _cqes;
    private int _cqeCap;
    private int _cqeCount;
    private Cqe* _carry;
    private int _carryCap;
    private int _carryCount;

    private readonly Queue<SlotRef> _rearm = new();
    private readonly List<SlotRef> _held = new();
    private readonly Dictionary<ulong, nint> _zombies = new(); // send buffers still in flight for closed connections

    private int _acceptRing;
    private int _holdAt = Wal.HoldFrames;
    private long _holdSince;

    private readonly byte[][] _prefixes;
    private readonly int[] _dateOffsets;
    private long _dateSecond = -1;

    private readonly bool _stats = Environment.GetEnvironmentVariable("MB_STATS") is not null;
    private long _stPasses, _stCqes, _stNoBufs, _stSpills, _stQueued, _stRejected, _stLast = Stopwatch.GetTimestamp(), _stMaxTicks;
    private int _stMaxCqes, _stMaxBacklog;

    public Loop(string host, int port, Api api, Db db) {
        _api = api;
        _db = db;
        _listeners = OpenListeners(host, port);
        _slotsPerRing = RaiseFdLimit();
        _enterUntilEmpty = KernelRunsTwentyPerEnter();
        _cqeCap = PassCap * 2;
        _carryCap = 4096;
        _cqes = (Cqe*)NativeMemory.Alloc((nuint)_cqeCap, (nuint)sizeof(Cqe));
        _carry = (Cqe*)NativeMemory.Alloc((nuint)_carryCap, (nuint)sizeof(Cqe));

        (byte[] Status, int Code)[] lines = [
            ("HTTP/1.1 200 OK\r\n"u8.ToArray(), 200),
            ("HTTP/1.1 201 Created\r\n"u8.ToArray(), 201),
            ("HTTP/1.1 400 Bad Request\r\n"u8.ToArray(), 400),
            ("HTTP/1.1 401 Unauthorized\r\n"u8.ToArray(), 401),
            ("HTTP/1.1 404 Not Found\r\n"u8.ToArray(), 404),
            ("HTTP/1.1 503 Service Unavailable\r\n"u8.ToArray(), 503),
            ("HTTP/1.1 500 Internal Server Error\r\n"u8.ToArray(), 500),
        ];
        _prefixes = new byte[lines.Length][];
        _dateOffsets = new int[lines.Length];
        for (int i = 0; i < lines.Length; i++) {
            byte[] head = [.. lines[i].Status, .. "Content-Type: application/json\r\nDate: "u8];
            _dateOffsets[i] = head.Length;
            _prefixes[i] = [.. head, .. new byte[29], .. "\r\nContent-Length: "u8];
        }
    }

    /// <summary>Starts the thread. Throws if a ring cannot be set up, so a kernel without io_uring fails at start.</summary>
    public void Start() {
        Exception? failure = null;
        using ManualResetEventSlim ready = new(false);
        Thread t = new(() => {
            try {
                AddRing();
                _rings[0]!.Accept(_listeners, newGeneration: true);
                _rings[0]!.Submit();
            } catch (Exception e) {
                failure = e;
            } finally {
                ready.Set();
            }

            if (failure is null) {
                Run();
            }
        }, 1024 * 1024) { IsBackground = true, Name = "io_uring" };
        t.Start();
        ready.Wait();
        if (failure is not null) {
            throw failure;
        }
    }

    /// <summary>Eight listeners: each has an accept queue of somaxconn (4,096), so a stall during a ramp overflows none.</summary>
    private static int[] OpenListeners(string host, int port) {
        int[] fds = new int[8];
        SockAddrIn address = new() {
            Family = AF_INET,
            Port = BinaryPrimitives.ReverseEndianness((ushort)port),
            Addr = BitConverter.ToUInt32(IPAddress.Parse(host).GetAddressBytes()),
        };
        for (int i = 0; i < fds.Length; i++) {
            int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
            if (fd < 0) {
                Fail("socket");
            }

            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(int));
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(int));
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(int)); // accepted sockets inherit it
            if (bind(fd, &address, (uint)sizeof(SockAddrIn)) < 0) {
                Fail($"bind {host}:{port}");
            }

            if (listen(fd, 65535) < 0) {
                Fail("listen");
            }

            fds[i] = fd;
        }

        return fds;
    }

    /// <summary>A fixed-file table holds at most RLIMIT_NOFILE entries, so raises the soft limit to the hard one.</summary>
    private static int RaiseFdLimit() {
        RLimit limit = default;
        if (getrlimit(RLIMIT_NOFILE, &limit) < 0) {
            Fail("getrlimit");
        }

        if (limit.Cur < limit.Max) {
            RLimit raised = new() { Cur = limit.Max, Max = limit.Max };
            if (setrlimit(RLIMIT_NOFILE, &raised) == 0) {
                limit = raised;
            }
        }

        return (int)Math.Min(limit.Cur, 65535UL);
    }

    /// <summary>
    /// From kernel 6.13 one io_uring_enter runs at most max(20, wait) deferred completions, so the loop must enter again
    /// until a call adds none. Kernel 6.8, the benchmark's, runs them all in one call, and the second call would find nothing.
    /// </summary>
    private static bool KernelRunsTwentyPerEnter() {
        string[] parts = File.ReadAllText("/proc/sys/kernel/osrelease").Split('.', '-');
        return !int.TryParse(parts[0], out int major) || !int.TryParse(parts[1], out int minor)
            || major > 6 || (major == 6 && minor >= 13);
    }

    private Ring AddRing() {
        Ring ring = new(_ringCount, _slotsPerRing);
        _rings[_ringCount++] = ring;
        return ring;
    }

    private void Run() {
        KernelTimespec timeout = new() { Nsec = WaitNanoseconds };
        GetEventsArg waitArg = new() { Ts = (ulong)&timeout };
        int openTotal = 0;
        while (true) {
            // 1. Wait in ring 0 for 32 completions or 2 ms, so one pass serves many sockets, then collect the other rings.
            for (int i = 0; i < _ringCount; i++) {
                Ring r = _rings[i]!;
                if (i > 0 || _carryCount > 0 || _backlog.Count > 0) {
                    r.Enter(0);
                } else if (openTotal == 0 && _ringCount == 1) {
                    r.Enter(1);
                } else {
                    r.Enter(WaitCompletions, &waitArg);
                }

                if (_enterUntilEmpty) {
                    for (int k = 0; k < 64; k++) {
                        uint before = r.CqTail;
                        r.Enter(r.CqReady);
                        if (r.CqTail == before) {
                            break;
                        }
                    }
                }
            }

            // 2. Handle the completions: new connections and received requests, whose responses go into the arena.
            _pass++;
            _answers = 0;
            long t0 = _stats ? Stopwatch.GetTimestamp() : 0;
            if (Volatile.Read(ref Wal.HoldWrites) != 0) {
                MaybeResume();
            }

            RunBacklog();
            CollectForPass();
            for (int i = 0; i < _cqeCount; i++) {
                Handle(in _cqes[i]);
            }

            int returned = 0;
            for (int i = 0; i < _ringCount; i++) {
                Ring r = _rings[i]!;
                returned += r.Returned;
                r.PublishBuffers();
            }

            // Receives that found no buffer: as many as buffers came back, so they do not fail again at once.
            int budget = Math.Min(_rearm.Count, Math.Min(Math.Max(returned, 32), Ring.BufCount / 2));
            for (; budget > 0; budget--) {
                SlotRef s = _rearm.Dequeue();
                Ring r = _rings[s.Ring]!;
                if (r.Slots[s.Slot].Gen == s.Gen && (r.Slots[s.Slot].State & (Live | Recving)) == Live) {
                    r.Recv(s.Slot);
                }
            }

            // 3. Commit, then send.
            bool committed = !_db.InTransaction || _db.Commit();
            if (Volatile.Read(ref Wal.HoldWrites) == 0 && Volatile.Read(ref Wal.Frames) >= _holdAt) {
                Volatile.Write(ref Wal.CaughtUp, 0);
                Volatile.Write(ref Wal.HoldWrites, 1);
                Wal.Wake();
                _holdSince = Environment.TickCount64;
            }

            Flush(committed);
            ManageAccept();

            // 4. Submit (the sends finish inside io_uring_enter) and handle their completions while the arena still
            // holds the bytes. Other completions wait for the next pass.
            openTotal = 0;
            for (int i = 0; i < _ringCount; i++) {
                Ring r = _rings[i]!;
                if (r.HasUnsubmitted) {
                    r.Submit();
                }
            }

            DrainSends();
            _arena.Reset();
            _recordCount = 0;
            for (int i = 0; i < _ringCount; i++) {
                openTotal += _rings[i]!.Open;
            }

            if (_stats) {
                Stats(t0, openTotal);
            }
        }
    }

    /// <summary>Answers requests read out of the kernel in earlier passes, oldest first, as far as this pass has room.</summary>
    private void RunBacklog() {
        _stMaxBacklog = Math.Max(_stMaxBacklog, _backlog.Count);
        while (_backlog.Count > 0 && _answers < MaxAnswersPerPass) {
            SlotRef h = _backlog.Dequeue();
            Ring r = _rings[h.Ring]!;
            Slot* s = r.Slots + h.Slot;
            if (s->Gen == h.Gen && s->Queued != 0) {
                s->Queued = 0;
                if ((s->State & (Live | Done)) == Live && s->InLen > 0) {
                    Process(r, h.Slot, s->In + s->InLen, 0);
                }
            }
        }
    }

    /// <summary>
    /// Moves received bytes from a kernel buffer into the slot's own, to be answered in a later pass. A request waiting in its
    /// socket costs a 3-4 KB network buffer, and after a stall hundreds of thousands of them run the box out of memory. Here it
    /// costs its own few hundred bytes, and reading it is far cheaper than answering it, so the backlog leaves the kernel at once.
    /// </summary>
    private void Stash(Ring r, int slot, byte* src, int n) {
        Slot* s = r.Slots + slot;
        int total = s->InLen + n;
        if (s->InCap < total) {
            int cap = Math.Max(total, s->InCap * 2);
            s->In = (byte*)NativeMemory.Realloc(s->In, (nuint)cap);
            s->InCap = cap;
        }

        new ReadOnlySpan<byte>(src, n).CopyTo(new Span<byte>(s->In + s->InLen, n));
        s->InLen = total;
        _stQueued++;
        if (s->Queued == 0) {
            s->Queued = 1;
            _backlog.Enqueue(new SlotRef(r.Index, slot, s->Gen));
        }
    }

    private void CollectForPass() {
        EnsureCqes(_carryCount + PassCap);
        new ReadOnlySpan<Cqe>(_carry, _carryCount).CopyTo(new Span<Cqe>(_cqes, _carryCount));
        _cqeCount = _carryCount;
        _carryCount = 0;
        int room = Math.Max(0, PassCap - _cqeCount);
        for (int i = 0; i < _ringCount && room > 0; i++) {
            int n = _rings[i]!.Reap(_cqes + _cqeCount, room);
            _cqeCount += n;
            room -= n;
        }
    }

    private void DrainSends() {
        for (int i = 0; i < _ringCount; i++) {
            Ring r = _rings[i]!;
            uint ready = r.CqReady;
            if (ready == 0) {
                continue;
            }

            EnsureCqes((int)ready);
            int n = r.Reap(_cqes, (int)ready);
            for (int k = 0; k < n; k++) {
                ref readonly Cqe c = ref _cqes[k];
                int op = (int)(c.UserData & 7);
                if (op is Ring.OpSendArena or Ring.OpSendOwn) {
                    Handle(in c);
                } else if (op != Ring.OpIgnore) {
                    if (_carryCount == _carryCap) {
                        _carryCap *= 2;
                        _carry = (Cqe*)NativeMemory.Realloc(_carry, (nuint)_carryCap * (nuint)sizeof(Cqe));
                    }

                    _carry[_carryCount++] = c;
                }
            }
        }
    }

    private void EnsureCqes(int need) {
        if (need > _cqeCap) {
            _cqeCap = need * 2;
            _cqes = (Cqe*)NativeMemory.Realloc(_cqes, (nuint)_cqeCap * (nuint)sizeof(Cqe));
        }
    }

    private void Handle(in Cqe c) {
        ulong u = c.UserData;
        Ring r = _rings[(int)((u >> 3) & 7)]!;
        try {
            switch ((int)(u & 7)) {
                case Ring.OpAccept: OnAccept(r, u, c.Res, c.Flags); break;
                case Ring.OpRecv: OnRecv(r, u, c.Res, c.Flags); break;
                case Ring.OpSendArena: OnSendArena(r, u, c.Res); break;
                case Ring.OpSendOwn: OnSendOwn(r, u, c.Res); break;
            }
        } catch (Exception e) {
            Console.Error.WriteLine(e);
        }
    }

    private void OnAccept(Ring r, ulong u, int res, uint flags) {
        if ((flags & IORING_CQE_F_MORE) == 0 && (uint)(u >> 22 & 0xFFFFFF) == (r.AcceptGen & 0xFFFFFF)) {
            r.AcceptArmed &= ~(1u << (int)((u >> 6) & 0xFFFF)); // ManageAccept arms it again
        }

        if (res >= 0) {
            if (_open >= MaxConnections) {
                // Accepted before the listeners stopped. Never Live: no receive, no state, and the CLOSE frees the slot.
                _stRejected++;
                r.ShutdownClose(res);
                return;
            }

            r.Slots[res].State = Live;
            r.Slots[res].Queued = 0;
            r.Slots[res].RecPass = 0;
            r.Open++;
            _open++;
            r.Recv(res);
        }
    }

    private void OnRecv(Ring r, ulong u, int res, uint flags) {
        int slot = (int)((u >> 6) & 0xFFFF);
        Slot* s = r.Slots + slot;
        if ((s->State & Live) != 0 && (s->Gen & 0xFFFFFF) == (uint)((u >> 22) & 0xFFFFFF)) {
            if ((flags & IORING_CQE_F_MORE) == 0) {
                s->State &= unchecked((byte)~Recving);
            }

            if (res > 0) {
                if ((s->State & Done) == 0) {
                    if (s->Queued != 0 || _answers >= MaxAnswersPerPass) {
                        Stash(r, slot, r.Buffer((int)(flags >> 16)), res);
                    } else {
                        Process(r, slot, r.Buffer((int)(flags >> 16)), res);
                    }
                }

                if ((s->State & (Live | Recving)) == Live) {
                    r.Recv(slot);
                }

                if ((flags & IORING_CQE_F_BUFFER) != 0) {
                    r.Recycle((int)(flags >> 16));
                }

                return;
            }

            if (res == 0 && s->Queued != 0) {
                // The client finished sending: what it sent before that still gets its answer, now.
                s->Queued = 0;
                if ((s->State & Done) == 0 && s->InLen > 0) {
                    Process(r, slot, s->In + s->InLen, 0);
                }
            }

            if ((s->State & Live) == 0) {
                // Answering the backlog closed the connection.
            } else if (res == -ENOBUFS) {
                _stNoBufs++;
                if ((s->State & Recving) == 0) {
                    _rearm.Enqueue(new SlotRef(r.Index, slot, s->Gen));
                }
            } else if (res == 0 && s->RecPass == _pass + 1) {
                // The client finished sending, and a response of this pass is waiting: it still gets it.
                _records[s->RecIdx].Close = true;
                s->State |= Done;
            } else if (res == 0 && (s->State & Sending) != 0) {
                s->State |= CloseAfter | Done;
            } else {
                CloseSlot(r, slot);
            }
        }

        if ((flags & IORING_CQE_F_BUFFER) != 0) {
            r.Recycle((int)(flags >> 16));
        }
    }

    /// <summary>Answers every complete request in a received buffer, keeping what is left in the slot.</summary>
    private void Process(Ring r, int slot, byte* src, int n) {
        Slot* s = r.Slots + slot;
        ReadOnlySpan<byte> data = new(src, n);
        if (s->InLen > 0) {
            int total = s->InLen + n;
            if (s->InCap < total) {
                int cap = Math.Max(total, s->InCap * 2);
                s->In = (byte*)NativeMemory.Realloc(s->In, (nuint)cap);
                s->InCap = cap;
            }

            data.CopyTo(new Span<byte>(s->In + s->InLen, n));
            s->InLen = total;
            data = new ReadOnlySpan<byte>(s->In, total);
        }

        // The slot's responses of this pass stay together, in order, at the end of the arena.
        int ri = -1;
        _runStart = -1;
        if (s->RecPass == _pass + 1) {
            ri = s->RecIdx;
            ref Record rc = ref _records[ri];
            if (rc.Start + rc.Len != _arena.Len) {
                int start = _arena.Grow(rc.Len);
                _arena.Buf.AsSpan(rc.Start, rc.Len).CopyTo(_arena.Buf.AsSpan(start));
                rc.Start = start;
            }

            if (rc.Len > 0) {
                _runStart = rc.Start;
            }
        }

        int before = _arena.Len;
        bool close = false, held = false;
        bool cont = (s->State & ContinueSent) != 0;
        int consumed;
        try {
            consumed = Parse(data, ref close, ref cont, ref held);
        } catch (Exception e) {
            Console.Error.WriteLine(e);
            _arena.Len = before;
            CloseSlot(r, slot);
            return;
        }

        if (held && (s->State & HeldWrite) == 0) {
            s->State |= HeldWrite;
            _held.Add(new SlotRef(r.Index, slot, s->Gen));
        }

        s->State = cont ? (byte)(s->State | ContinueSent) : (byte)(s->State & ~ContinueSent);
        int rest = data.Length - consumed;
        if (close || rest == 0) {
            FreeInput(s);
        } else if (s->InLen > 0) {
            if (consumed > 0) {
                Buffer.MemoryCopy(s->In + consumed, s->In, s->InCap, rest);
            }

            s->InLen = rest;
        } else {
            s->InCap = Math.Max(1024, rest);
            s->In = (byte*)NativeMemory.Alloc((nuint)s->InCap);
            data[consumed..].CopyTo(new Span<byte>(s->In, rest));
            s->InLen = rest;
        }

        if (_runStart < 0 && !close && ri < 0) {
            return;
        }

        if (ri < 0) {
            if (_recordCount == _records.Length) {
                Array.Resize(ref _records, _records.Length * 2);
            }

            ri = _recordCount++;
            ref Record added = ref _records[ri];
            added.Ring = r.Index;
            added.Slot = slot;
            added.Gen = s->Gen;
            added.Start = _runStart < 0 ? _arena.Len : _runStart;
            added.Close = false;
            s->RecPass = _pass + 1;
            s->RecIdx = ri;
        }

        ref Record rec = ref _records[ri];
        if (_runStart >= 0) {
            rec.Start = _runStart;
            rec.Len = _arena.Len - _runStart;
        }

        if (close) {
            rec.Close = true;
            s->State |= Done;
        }
    }

    /// <summary>
    /// Handles the requests in <paramref name="s"/> until one is incomplete, closes the connection, or is a write held
    /// while the checkpoint catches up. Returns the bytes consumed.
    /// </summary>
    private int Parse(ReadOnlySpan<byte> s, ref bool close, ref bool cont, ref bool held) {
        int off = 0;
        while (off < s.Length) {
            ReadOnlySpan<byte> rest = s[off..];
            int headEnd = rest.IndexOf("\r\n\r\n"u8);
            if (headEnd < 0) {
                if (rest.Length > MaxHeaderBytes) {
                    Respond(400, BadRequest, true);
                    close = true;
                }

                return off;
            }

            int lineEnd = rest.IndexOf("\r\n"u8);
            ReadOnlySpan<byte> line = rest[..lineEnd];
            int sp1 = line.IndexOf((byte)' ');
            ReadOnlySpan<byte> afterMethod = sp1 < 0 ? default : line[(sp1 + 1)..];
            int sp2 = afterMethod.IndexOf((byte)' ');
            if (sp1 <= 0 || sp2 <= 0 || !afterMethod[(sp2 + 1)..].StartsWith("HTTP/1."u8)) {
                Respond(400, BadRequest, true);
                close = true;
                return off;
            }

            ReadOnlySpan<byte> method = line[..sp1];
            ReadOnlySpan<byte> target = afterMethod[..sp2];
            bool closeThis = afterMethod[(sp2 + 1)..].SequenceEqual("HTTP/1.0"u8);
            ReadOnlySpan<byte> auth = default;
            bool hasAuth = false, expect = false, bad = false;
            int contentLength = 0;
            ReadOnlySpan<byte> headers = headEnd > lineEnd ? rest.Slice(lineEnd + 2, headEnd - lineEnd) : default;
            while (!headers.IsEmpty) {
                int e = headers.IndexOf("\r\n"u8);
                ReadOnlySpan<byte> h = e < 0 ? headers : headers[..e];
                headers = e < 0 ? default : headers[(e + 2)..];
                int colon = h.IndexOf((byte)':');
                if (colon <= 0) {
                    continue;
                }

                ReadOnlySpan<byte> name = h[..colon];
                switch (name.Length) {
                    case 13 when Ascii.EqualsIgnoreCase(name, "authorization"u8):
                        auth = h[(colon + 1)..].Trim(" \t"u8);
                        hasAuth = true;
                        break;
                    case 14 when Ascii.EqualsIgnoreCase(name, "content-length"u8):
                        ReadOnlySpan<byte> v = h[(colon + 1)..].Trim(" \t"u8);
                        if (v.Length is 0 or > 9) {
                            bad = true;
                        }

                        int value = 0;
                        foreach (byte c in v) {
                            if (c is < (byte)'0' or > (byte)'9') {
                                bad = true;
                            }

                            value = (value * 10) + (c - '0');
                        }

                        contentLength = value;
                        break;
                    case 10 when Ascii.EqualsIgnoreCase(name, "connection"u8):
                        ReadOnlySpan<byte> cv = h[(colon + 1)..].Trim(" \t"u8);
                        if (Ascii.EqualsIgnoreCase(cv, "close"u8)) {
                            closeThis = true;
                        } else if (Ascii.EqualsIgnoreCase(cv, "keep-alive"u8)) {
                            closeThis = false;
                        }

                        break;
                    case 17 when Ascii.EqualsIgnoreCase(name, "transfer-encoding"u8):
                        bad = true; // chunked bodies are out of scope
                        break;
                    case 6 when Ascii.EqualsIgnoreCase(name, "expect"u8):
                        expect = true;
                        break;
                }
            }

            if (bad || contentLength > MaxBodyBytes) {
                Respond(400, BadRequest, true);
                close = true;
                return off;
            }

            int totalLength = headEnd + 4 + contentLength;
            if (rest.Length < totalLength) {
                if (expect && !cont) {
                    AppendRaw("HTTP/1.1 100 Continue\r\n\r\n"u8);
                    cont = true;
                }

                return off;
            }

            if (Volatile.Read(ref Wal.HoldWrites) != 0 && method.SequenceEqual("POST"u8)) {
                held = true; // it stays in the input, and the loop runs it when the hold ends
                return off;
            }

            RunRequest(method, target, auth, hasAuth, rest.Slice(headEnd + 4, contentLength), closeThis);
            off += totalLength;
            cont = false;
            if (closeThis) {
                close = true;
                return off;
            }
        }

        return off;
    }

    private static ReadOnlySpan<byte> BadRequest => "{\"error\":\"bad request\"}"u8;

    private void RunRequest(ReadOnlySpan<byte> method, ReadOnlySpan<byte> target, ReadOnlySpan<byte> auth, bool hasAuth,
        ReadOnlySpan<byte> body, bool close) {
        _answers++;
        int mark = _arena.Len;
        int bodyStart = _arena.Grow(HeaderRoom) + HeaderRoom;
        int status;
        try {
            status = _api.Handle(method, target, auth, hasAuth, body, _arena);
        } catch (Exception e) {
            Console.Error.WriteLine(e);
            status = 500;
        }

        if (status == 500) {
            _arena.Len = bodyStart;
            _arena.Bytes("{\"error\":\"internal server error\"}"u8);
        }

        FinishResponse(mark, bodyStart, status, close);
    }

    private void Respond(int status, ReadOnlySpan<byte> json, bool close) {
        int mark = _arena.Len;
        int bodyStart = _arena.Grow(HeaderRoom) + HeaderRoom;
        _arena.Bytes(json);
        FinishResponse(mark, bodyStart, status, close);
    }

    /// <summary>
    /// Writes the head just before the body, which is already in the arena (no copy, no Content-Length to fill in). When
    /// the connection already has output in this pass, the response moves down to join it, as they go out in one send.
    /// </summary>
    private void FinishResponse(int mark, int bodyStart, int status, bool close) {
        int bodyLength = _arena.Len - bodyStart;
        RefreshDate();
        byte[] prefix = _prefixes[status switch { 200 => 0, 201 => 1, 400 => 2, 401 => 3, 404 => 4, 503 => 5, _ => 6 }];
        ReadOnlySpan<byte> tail = close ? "\r\nConnection: close\r\n\r\n"u8 : "\r\n\r\n"u8;
        byte* end = _arena.Ptr + bodyStart;
        byte* p = end - tail.Length;
        tail.CopyTo(new Span<byte>(p, tail.Length));
        int v = bodyLength;
        do {
            *--p = (byte)('0' + (v % 10));
            v /= 10;
        } while (v > 0);

        p -= prefix.Length;
        prefix.CopyTo(new Span<byte>(p, prefix.Length));
        int start = (int)(p - _arena.Ptr);
        if (_runStart < 0) {
            _runStart = start;
        } else {
            int length = _arena.Len - start;
            Buffer.MemoryCopy(p, _arena.Ptr + mark, length, length);
            _arena.Len = mark + length;
        }
    }

    private void AppendRaw(ReadOnlySpan<byte> bytes) {
        int start = _arena.Len;
        _arena.Bytes(bytes);
        if (_runStart < 0) {
            _runStart = start;
        }
    }

    private void RefreshDate() {
        long second = Environment.TickCount64 / 1000;
        if (second == _dateSecond) {
            return;
        }

        _dateSecond = second;
        for (int i = 0; i < _prefixes.Length; i++) {
            Utf8Formatter.TryFormat(DateTime.UtcNow, _prefixes[i].AsSpan(_dateOffsets[i]), out _, new StandardFormat('R'));
        }
    }

    /// <summary>After the commit: one send per connection with output. An own send still in flight keeps the new output back.</summary>
    private void Flush(bool committed) {
        for (int i = 0; i < _recordCount; i++) {
            ref Record rc = ref _records[i];
            Ring r = _rings[rc.Ring]!;
            Slot* s = r.Slots + rc.Slot;
            if ((s->State & Live) == 0 || s->Gen != rc.Gen) {
                continue;
            }

            if (!committed) {
                CloseSlot(r, rc.Slot); // no response may claim a write that did not land
            } else if ((s->State & Sending) != 0) {
                if (rc.Len > 0) {
                    if (s->PendCap - s->PendLen < rc.Len) {
                        int cap = Math.Max(s->PendCap * 2, s->PendLen + rc.Len);
                        s->Pend = (byte*)NativeMemory.Realloc(s->Pend, (nuint)cap);
                        s->PendCap = cap;
                    }

                    _arena.Buf.AsSpan(rc.Start, rc.Len).CopyTo(new Span<byte>(s->Pend + s->PendLen, rc.Len));
                    s->PendLen += rc.Len;
                }

                if (rc.Close) {
                    s->State |= CloseAfter;
                }
            } else if (rc.Len > 0) {
                r.Send(Ring.OpSendArena, rc.Slot, _arena.Ptr + rc.Start, rc.Len, MSG_NOSIGNAL | MSG_DONTWAIT, i);
            } else if (rc.Close) {
                CloseSlot(r, rc.Slot);
            }
        }
    }

    private void OnSendArena(Ring r, ulong u, int res) {
        int slot = (int)((u >> 6) & 0xFFFF);
        Slot* s = r.Slots + slot;
        if ((s->State & Live) == 0 || (s->Gen & 0xFFFFFF) != (uint)((u >> 22) & 0xFFFFFF)) {
            return;
        }

        ref Record rc = ref _records[(int)(u >> 46)];
        if (res == rc.Len) {
            if (rc.Close) {
                CloseSlot(r, slot);
            }
        } else if (res >= 0 || res == -EAGAIN || res == -EINTR) {
            // The socket did not take it all at once: the rest goes on from a buffer of the connection.
            int sent = Math.Max(res, 0);
            int left = rc.Len - sent;
            _stSpills++;
            s->Own = (byte*)NativeMemory.Alloc((nuint)left);
            _arena.Buf.AsSpan(rc.Start + sent, left).CopyTo(new Span<byte>(s->Own, left));
            s->OwnOff = 0;
            s->OwnLen = left;
            if (rc.Close) {
                s->State |= CloseAfter;
            }

            SendOwn(r, slot);
        } else {
            CloseSlot(r, slot);
        }
    }

    private static void SendOwn(Ring r, int slot) {
        Slot* s = r.Slots + slot;
        s->State |= Sending;
        r.Send(Ring.OpSendOwn, slot, s->Own + s->OwnOff, s->OwnLen, MSG_NOSIGNAL, 0);
    }

    private void OnSendOwn(Ring r, ulong u, int res) {
        int slot = (int)((u >> 6) & 0xFFFF);
        Slot* s = r.Slots + slot;
        if ((s->State & Live) == 0 || (s->Gen & 0xFFFFFF) != (uint)((u >> 22) & 0xFFFFFF)) {
            // The connection closed meanwhile: the kernel is done with the buffer now.
            if (_zombies.Remove(u & Ring.KeyMask, out nint buffer)) {
                NativeMemory.Free((void*)buffer);
            }

            return;
        }

        s->State &= unchecked((byte)~Sending);
        if (res == -EAGAIN || res == -EINTR) {
            SendOwn(r, slot);
        } else if (res <= 0) {
            FreeOwn(s);
            CloseSlot(r, slot);
        } else {
            s->OwnOff += res;
            s->OwnLen -= res;
            if (s->OwnLen > 0) {
                SendOwn(r, slot);
                return;
            }

            FreeOwn(s);
            if (s->PendLen > 0) {
                s->Own = s->Pend;
                s->OwnOff = 0;
                s->OwnLen = s->PendLen;
                s->Pend = null;
                s->PendLen = s->PendCap = 0;
                SendOwn(r, slot);
            } else if ((s->State & CloseAfter) != 0) {
                CloseSlot(r, slot);
            }
        }
    }

    private static void FreeOwn(Slot* s) {
        NativeMemory.Free(s->Own);
        s->Own = null;
        s->OwnOff = s->OwnLen = 0;
    }

    private static void FreeInput(Slot* s) {
        if (s->In != null) {
            NativeMemory.Free(s->In);
            s->In = null;
        }

        s->InLen = s->InCap = 0;
    }

    /// <summary>
    /// Ends a connection: frees its buffers, changes the generation so completions still in flight are recognised as
    /// stale, and queues SHUTDOWN + CLOSE. A send in flight keeps its buffer until its completion comes back.
    /// </summary>
    private void CloseSlot(Ring r, int slot) {
        Slot* s = r.Slots + slot;
        if ((s->State & Live) == 0) {
            return;
        }

        FreeInput(s);
        NativeMemory.Free(s->Pend);
        s->Pend = null;
        s->PendLen = s->PendCap = 0;
        if ((s->State & Sending) != 0) {
            _zombies[Ring.Tag(0, r.Index, slot, s->Gen)] = (nint)s->Own;
        } else {
            NativeMemory.Free(s->Own);
        }

        s->Own = null;
        s->OwnOff = s->OwnLen = 0;
        s->State = Closing;
        s->Queued = 0;
        s->Gen++;
        r.Open--;
        _open--;
        r.ShutdownClose(slot);
    }

    /// <summary>
    /// Ends a write hold once the checkpoint thread has copied every frame and started the WAL again, or after 500 ms
    /// (then the WAL goes on growing and the next hold comes later), and runs the held requests in this pass.
    /// </summary>
    private void MaybeResume() {
        bool caught = Volatile.Read(ref Wal.CaughtUp) != 0;
        bool timedOut = !caught && Environment.TickCount64 - _holdSince > 500
            && Interlocked.CompareExchange(ref Wal.RestartGate, 2, 0) == 0;
        if (!caught && !timedOut) {
            return;
        }

        _holdAt = caught ? Wal.HoldFrames : _holdAt + Wal.HoldFrames;
        Volatile.Write(ref Wal.Frames, 0);
        Volatile.Write(ref Wal.CaughtUp, 0);
        Volatile.Write(ref Wal.HoldWrites, 0);
        if (_stats) {
            Console.Error.WriteLine($"hold end caught={caught} ms={Environment.TickCount64 - _holdSince} slots={_held.Count}");
        }

        foreach (SlotRef h in _held) {
            Ring r = _rings[h.Ring]!;
            Slot* s = r.Slots + h.Slot;
            if (s->Gen == h.Gen && (s->State & HeldWrite) != 0) {
                s->State &= unchecked((byte)~HeldWrite);
                if ((s->State & (Live | Done)) == Live && s->InLen > 0) {
                    Process(r, h.Slot, s->In + s->InLen, 0);
                }
            }
        }

        _held.Clear();
        if (timedOut) {
            Volatile.Write(ref Wal.RestartGate, 0);
        }
    }

    /// <summary>Stops or restarts listening at the connection limit. Restarts a little under it, so it doesn't flap.</summary>
    private void ManageLimit() {
        if (!_refusing && _open >= MaxConnections) {
            _refusing = true;
            Ring current = _rings[_acceptRing]!;
            if (current.Accepting) {
                current.StopAccept(_listeners.Length);
            }

            foreach (int fd in _listeners) {
                shutdown(fd, (int)SHUT_RDWR);
            }
        } else if (_refusing && _open < MaxConnections - Math.Min(1024, MaxConnections / 16)) {
            _refusing = false;
            foreach (int fd in _listeners) {
                if (listen(fd, 65535) < 0) {
                    Console.Error.WriteLine($"listen failed: errno {Marshal.GetLastPInvokeError()}");
                }
            }
        }
    }

    /// <summary>Keeps one ring accepting: the first with room, a new one when all are nearly full.</summary>
    private void ManageAccept() {
        ManageLimit();
        if (_refusing) {
            return;
        }

        Ring current = _rings[_acceptRing]!;
        // Five rings of 64,511 hold the 320,000. A sixth, with its buffers, opens only if a burst of accepts overruns the reserve.
        int reserve = Math.Min(1024, current.SlotCount / 4);
        if (current.Accepting && current.SlotCount - current.Open < reserve) {
            current.StopAccept(_listeners.Length);
        }

        if (current.Accepting) {
            if (current.AcceptArmed != (1u << _listeners.Length) - 1) {
                current.Accept(_listeners, newGeneration: false); // a multishot accept ended by itself
            }

            return;
        }

        int target = -1;
        for (int i = 0; i < _ringCount && target < 0; i++) {
            if (_rings[i]!.SlotCount - _rings[i]!.Open >= 2 * reserve) {
                target = i;
            }
        }

        if (target < 0 && _ringCount < MaxRings) {
            try {
                target = AddRing().Index;
            } catch (Exception e) {
                Console.Error.WriteLine(e);
            }
        }

        if (target >= 0) {
            _acceptRing = target;
            _rings[target]!.Accept(_listeners, newGeneration: true);
        }
    }

    private void Stats(long t0, int openTotal) {
        long t1 = Stopwatch.GetTimestamp();
        _stPasses++;
        _stCqes += _cqeCount;
        _stMaxCqes = Math.Max(_stMaxCqes, _cqeCount);
        _stMaxTicks = Math.Max(_stMaxTicks, t1 - t0);
        if (t1 - _stLast > 5 * Stopwatch.Frequency) {
            Console.Error.WriteLine($"stats passes={_stPasses} cqes={_stCqes} maxcqes={_stMaxCqes} maxpass={_stMaxTicks * 1000.0 / Stopwatch.Frequency:F1}ms nobufs={_stNoBufs} spills={_stSpills} rearmq={_rearm.Count} queued={_stQueued} maxbacklog={_stMaxBacklog} rejected={_stRejected} open={openTotal} rings={_ringCount} gc={GC.CollectionCount(0)}/{GC.CollectionCount(1)}/{GC.CollectionCount(2)} heap={GC.GetGCMemoryInfo().HeapSizeBytes >> 20}MB alloc={GC.GetTotalAllocatedBytes() >> 20}MB");
            _stPasses = _stCqes = _stNoBufs = _stSpills = _stMaxTicks = _stQueued = 0;
            _stMaxCqes = _stMaxBacklog = 0;
            _stLast = t1;
        }
    }

    private static void Fail(string what) =>
        throw new InvalidOperationException($"{what} failed: errno {Marshal.GetLastPInvokeError()}");
}
