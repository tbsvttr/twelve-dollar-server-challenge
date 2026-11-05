using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using static Feed.Native;

namespace Feed;

/// <summary>Result of <see cref="Db.Like"/>.</summary>
internal enum LikeOutcome { Liked, AlreadyLiked, PostMissing, Failed }

/// <summary>
/// What the request thread and the checkpoint thread share about the WAL. A PASSIVE checkpoint never blocks writes, so
/// under steady writes it never finds every frame copied, and the WAL would grow without limit. So at
/// <see cref="HoldFrames"/> the loop holds writes (reads go on): the checkpoint thread copies the last frames and starts
/// the WAL again itself, so that the header fsync of a new WAL does not stop the request thread.
/// </summary>
internal static class Wal {
    /// <summary>A hold lasts as long as the checkpoint's fsyncs, not its copying, so a big WAL means fewer holds, not longer ones.</summary>
    public static readonly int HoldFrames = int.TryParse(Environment.GetEnvironmentVariable("MB_HOLD_FRAMES"), out int n) && n > 0 ? n : 15000;

    public static int Frames;      // WAL size after the last checkpoint (checkpoint thread)
    public static int HoldWrites;  // 1: writes wait until every frame is copied (request thread)
    public static int CaughtUp;    // 1: with writes held, every frame is copied (checkpoint thread)
    public static int RestartGate; // 1: the checkpoint thread is starting the WAL; 2: the loop is ending a hold that timed out
    public static int Commits;     // successful commits since the start (request thread)

    private static readonly AutoResetEvent Waker = new(false);

    /// <summary>Wakes the checkpoint thread at once when a hold starts, so the hold does not wait out its sleep.</summary>
    public static void Wake() => Waker.Set();

    public static void Sleep() => Waker.WaitOne(50);
}

/// <summary>
/// The request connection, used only by the request thread. Statements are prepared once. A pass of the loop is one
/// transaction: reads share one snapshot and writes one commit. A second connection on its own low-priority thread runs
/// the checkpoints, so their fsyncs never stop a request.
/// </summary>
internal sealed unsafe class Db {
    private const int FeedSize = 20;

    private readonly nint _db;
    private readonly nint _feedIds, _feedLikes, _feedRows, _feed, _post, _insertPost, _insertLike, _postExists, _ping, _begin, _commit, _rollback;
    private readonly long[] _ids = new long[FeedSize];
    private readonly long[] _counts = new long[FeedSize];
    private int _commitFailures;

    /// <summary>True while the pass's transaction is open.</summary>
    public bool InTransaction { get; private set; }

    public Db(string path) {
        Check(sqlite3_initialize(), "initialize");
        _db = Open(path);
        // unix-excl: only this process opens the file, so no fcntl lock per transaction, and the WAL index lives in heap
        // memory shared by the two connections. Public SQLite API, nothing patched.
        Exec(_db, "PRAGMA journal_mode = WAL");
        Exec(_db, "PRAGMA synchronous = NORMAL");
        Exec(_db, "PRAGMA wal_autocheckpoint = 0");
        // The WAL is cut to nothing each time it starts again. Frames aren't page-aligned, so overwriting an old WAL page that
        // reclaim has evicted reads it back from disk first, inside the COMMIT, on the request thread. Past the end of the file
        // there is nothing to read. The kernel also gets the old WAL's page cache back at once.
        Exec(_db, "PRAGMA journal_size_limit = 0");
        Exec(_db, "PRAGMA busy_timeout = 5000");
        // No mmap: a page in SQLite's cache is found with one lookup and keeps its parsed header; an mmap page is looked
        // up in the WAL index and parsed again on every fetch.
        Exec(_db, "PRAGMA mmap_size = 0");
        // The hot pages live here, in anonymous memory, which the kernel can't take back on a box with no swap. In the kernel's
        // page cache they look cold (SQLite's cache keeps them from being touched), so at the memory wall reclaim evicts them,
        // and the request thread blocks on a disk read in pread. MB_CACHE_KB overrides the size, for experiments.
        int cacheKb = int.TryParse(Environment.GetEnvironmentVariable("MB_CACHE_KB"), out int kb) && kb > 0 ? kb : 65536;
        Exec(_db, $"PRAGMA cache_size = -{cacheKb}");
        Exec(_db, "PRAGMA temp_store = MEMORY");

        const string select = "SELECT p.id, p.body, p.created_at, u.username, (SELECT count(*) FROM likes l WHERE l.post_id = p.id) FROM posts p JOIN users u ON u.id = p.user_id";
        _feed = Prepare(select + " ORDER BY p.created_at DESC, p.id DESC LIMIT 20");
        _post = Prepare(select + " WHERE p.id = ?1");
        _feedIds = Prepare("SELECT id FROM posts ORDER BY created_at DESC, id DESC LIMIT 20");
        _feedRows = Prepare("SELECT p.id, p.body, p.created_at, u.username FROM posts p JOIN users u ON u.id = p.user_id WHERE p.id BETWEEN ?1 AND ?2 ORDER BY p.id DESC");
        _feedLikes = Prepare("SELECT post_id, count(*) FROM likes WHERE post_id BETWEEN ?1 AND ?2 GROUP BY post_id");
        _insertPost = Prepare("INSERT INTO posts (user_id, body) VALUES (?1, ?2) RETURNING id, created_at");
        _insertLike = Prepare("INSERT INTO likes (user_id, post_id) SELECT ?1, ?2 WHERE EXISTS (SELECT 1 FROM posts WHERE id = ?2) ON CONFLICT (user_id, post_id) DO NOTHING");
        _postExists = Prepare("SELECT 1 FROM posts WHERE id = ?1");
        _ping = Prepare("SELECT 1");
        _begin = Prepare("BEGIN");
        _commit = Prepare("COMMIT");
        _rollback = Prepare("ROLLBACK");

        new Checkpointer(path).Start();
    }

    private static nint Open(string path) {
        byte[] file = Encoding.UTF8.GetBytes(path + "\0");
        nint db;
        fixed (byte* p = file, vfs = "unix-excl\0"u8) {
            int rc = sqlite3_open_v2(p, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, vfs);
            if (rc != SQLITE_OK) {
                throw new InvalidOperationException($"SQLite open failed ({rc})");
            }
        }

        return db;
    }

    /// <summary>Opens the pass's transaction if it is not open yet. False if it failed.</summary>
    private bool EnsureTransaction() {
        if (InTransaction) {
            return true;
        }

        if (Run(_begin) != SQLITE_DONE) {
            return false;
        }

        InTransaction = true;
        return true;
    }

    /// <summary>Commits the pass. On failure the transaction is rolled back and false returned.</summary>
    public bool Commit() {
        InTransaction = false;
        if (Run(_commit) == SQLITE_DONE) {
            Volatile.Write(ref Wal.Commits, Wal.Commits + 1);
            return true;
        }

        if (_commitFailures++ < 20) {
            Console.Error.WriteLine($"commit failed: {ErrorMessage(_db)}");
        }

        Run(_rollback);
        return false;
    }

    /// <summary>
    /// Writes {"posts":[...]}. When the 20 newest posts are one run of consecutive ids (posts are created in id order, so
    /// this is the usual case), one rowid range scan reads the posts and one range scan of the likes index counts all the
    /// likes. Anything else takes the plain query. False if a statement failed.
    /// </summary>
    public bool Feed(Out o) {
        if (!EnsureTransaction()) {
            return false;
        }

        int n = 0;
        int rc;
        while ((rc = sqlite3_step(_feedIds)) == SQLITE_ROW) {
            _ids[n++] = sqlite3_column_int64(_feedIds, 0); // LIMIT 20 keeps n within the array
        }

        sqlite3_reset(_feedIds);
        if (rc != SQLITE_DONE) {
            return false;
        }

        bool run = n > 0;
        for (int i = 1; i < n && run; i++) {
            run = _ids[i] == _ids[i - 1] - 1;
        }

        int start = o.Len;
        if (run) {
            int result = RangeFeed(n, o);
            if (result >= 0) {
                return result == 1;
            }

            o.Len = start;
        }

        return PlainFeed(o);
    }

    /// <summary>1 done, 0 a statement failed, -1 the rows do not match the ids (a post without a user row).</summary>
    private int RangeFeed(int n, Out o) {
        long hi = _ids[0], lo = _ids[n - 1];
        Array.Clear(_counts, 0, n);
        sqlite3_bind_int64(_feedLikes, 1, lo);
        sqlite3_bind_int64(_feedLikes, 2, hi);
        int rc;
        while ((rc = sqlite3_step(_feedLikes)) == SQLITE_ROW) {
            _counts[hi - sqlite3_column_int64(_feedLikes, 0)] = sqlite3_column_int64(_feedLikes, 1);
        }

        sqlite3_reset(_feedLikes);
        if (rc != SQLITE_DONE) {
            return 0;
        }

        sqlite3_bind_int64(_feedRows, 1, lo);
        sqlite3_bind_int64(_feedRows, 2, hi);
        o.Bytes("{\"posts\":["u8);
        int k = 0;
        bool match = true;
        while (match && (rc = sqlite3_step(_feedRows)) == SQLITE_ROW) {
            if (k < n && sqlite3_column_int64(_feedRows, 0) == _ids[k]) {
                if (k > 0) {
                    o.Byte((byte)',');
                }

                PostObject(_feedRows, o, _ids[k], _counts[k]);
                k++;
            } else {
                match = false;
            }
        }

        sqlite3_reset(_feedRows);
        if (!match || (rc == SQLITE_DONE && k != n)) {
            return -1;
        }

        if (rc != SQLITE_DONE) {
            return 0;
        }

        o.Bytes("]}"u8);
        return 1;
    }

    private bool PlainFeed(Out o) {
        o.Bytes("{\"posts\":["u8);
        bool first = true;
        int rc;
        while ((rc = sqlite3_step(_feed)) == SQLITE_ROW) {
            if (!first) {
                o.Byte((byte)',');
            }

            first = false;
            PostObject(_feed, o, sqlite3_column_int64(_feed, 0), sqlite3_column_int64(_feed, 4));
        }

        sqlite3_reset(_feed);
        o.Bytes("]}"u8);
        return rc == SQLITE_DONE;
    }

    /// <summary>Writes {"post":{...}}. Returns 200, 404 or 500.</summary>
    public int Post(long id, Out o) {
        if (!EnsureTransaction()) {
            return 500;
        }

        sqlite3_bind_int64(_post, 1, id);
        int rc = sqlite3_step(_post);
        int status = 500;
        if (rc == SQLITE_DONE) {
            status = 404;
        } else if (rc == SQLITE_ROW) {
            o.Bytes("{\"post\":"u8);
            PostObject(_post, o, id, sqlite3_column_int64(_post, 4));
            o.Byte((byte)'}');
            status = 200;
        }

        sqlite3_reset(_post);
        return status;
    }

    /// <summary>Inserts a post and writes its {"post":{...}} response. False if the insert failed.</summary>
    public bool CreatePost(long userId, ReadOnlySpan<byte> body, ReadOnlySpan<byte> username, Out o) {
        if (!EnsureTransaction()) {
            return false;
        }

        sqlite3_bind_int64(_insertPost, 1, userId);
        fixed (byte* b = body) {
            sqlite3_bind_text(_insertPost, 2, b, body.Length, 0); // SQLITE_STATIC: the pinned bytes outlive the run
            bool ok = false;
            if (sqlite3_step(_insertPost) == SQLITE_ROW) {
                o.Bytes("{\"post\":{\"id\":"u8);
                o.Int(sqlite3_column_int64(_insertPost, 0));
                o.Bytes(",\"body\":"u8);
                o.JsonString(body);
                o.Bytes(",\"created_at\":"u8);
                o.JsonString(Text(_insertPost, 1));
                o.Bytes(",\"author\":"u8);
                o.JsonString(username);
                o.Bytes(",\"like_count\":0}}"u8);
                ok = sqlite3_step(_insertPost) == SQLITE_DONE; // finishes the insert before the reset
            }

            sqlite3_reset(_insertPost);
            return ok;
        }
    }

    /// <summary>Records that the user likes the post.</summary>
    public LikeOutcome Like(long userId, long postId) {
        if (!EnsureTransaction()) {
            return LikeOutcome.Failed;
        }

        sqlite3_bind_int64(_insertLike, 1, userId);
        sqlite3_bind_int64(_insertLike, 2, postId);
        if (Run(_insertLike) != SQLITE_DONE) {
            return LikeOutcome.Failed;
        }

        if (sqlite3_changes(_db) == 1) {
            return LikeOutcome.Liked;
        }

        sqlite3_bind_int64(_postExists, 1, postId);
        return Run(_postExists) switch {
            SQLITE_ROW => LikeOutcome.AlreadyLiked,
            SQLITE_DONE => LikeOutcome.PostMissing,
            _ => LikeOutcome.Failed,
        };
    }

    /// <summary>Runs SELECT 1. Null when it works, otherwise SQLite's error message.</summary>
    public string? Health() {
        if (!EnsureTransaction()) {
            return ErrorMessage(_db);
        }

        return Run(_ping) == SQLITE_ROW ? null : ErrorMessage(_db);
    }

    /// <summary>One post object from columns 1 to 3 of the statement's current row. created_at is stored in the wire format.</summary>
    private static void PostObject(nint stmt, Out o, long id, long likes) {
        o.Bytes("{\"id\":"u8);
        o.Int(id);
        o.Bytes(",\"body\":"u8);
        o.JsonString(Text(stmt, 1));
        o.Bytes(",\"created_at\":"u8);
        o.JsonString(Text(stmt, 2));
        o.Bytes(",\"author\":"u8);
        o.JsonString(Text(stmt, 3));
        o.Bytes(",\"like_count\":"u8);
        o.Int(likes);
        o.Byte((byte)'}');
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static ReadOnlySpan<byte> Text(nint stmt, int column) {
        byte* p = sqlite3_column_text(stmt, column); // text before bytes, as SQLite's docs ask
        return new ReadOnlySpan<byte>(p, sqlite3_column_bytes(stmt, column));
    }

    private static int Run(nint stmt) {
        int rc = sqlite3_step(stmt);
        sqlite3_reset(stmt);
        return rc;
    }

    private static string ErrorMessage(nint db) => Marshal.PtrToStringUTF8((nint)sqlite3_errmsg(db)) ?? "unknown error";

    private static void Exec(nint db, string sql) {
        byte[] bytes = Encoding.UTF8.GetBytes(sql + "\0");
        fixed (byte* p = bytes) {
            int rc = sqlite3_exec(db, p, 0, 0, null);
            if (rc != SQLITE_OK) {
                throw new InvalidOperationException($"{sql}: {ErrorMessage(db)}");
            }
        }
    }

    private nint Prepare(string sql) {
        byte[] bytes = Encoding.UTF8.GetBytes(sql);
        nint stmt;
        fixed (byte* p = bytes) {
            int rc = sqlite3_prepare_v3(_db, p, bytes.Length, SQLITE_PREPARE_PERSISTENT, &stmt, null);
            if (rc != SQLITE_OK) {
                throw new InvalidOperationException($"{sql}: {ErrorMessage(_db)}");
            }
        }

        return stmt;
    }

    private static void Check(int rc, string what) {
        if (rc != SQLITE_OK) {
            throw new InvalidOperationException($"SQLite {what} failed ({rc})");
        }
    }

    /// <summary>
    /// The checkpoint thread and its own connection. Passive checkpoints copy the WAL and fsync it, and with writes held
    /// and every frame copied, one write of its own starts the WAL again here. That first frame makes SQLite write the WAL
    /// header and fsync the WAL even at synchronous=NORMAL, and that fsync can wait behind the file system's journal: on
    /// the request thread it would stop every request. It runs at nice 19: on one vCPU a checkpoint at normal priority
    /// holds the request thread off the CPU for its whole length, and the request thread's passes are short enough that
    /// the checkpoint still runs between them.
    /// </summary>
    private sealed class Checkpointer {
        private readonly nint _ck;
        private readonly byte[] _restart;

        public Checkpointer(string path) {
            _ck = Open(path);
            Exec(_ck, "PRAGMA journal_mode = WAL");
            Exec(_ck, "PRAGMA synchronous = NORMAL");
            Exec(_ck, "PRAGMA wal_autocheckpoint = 0");
            Exec(_ck, "PRAGMA journal_size_limit = 0"); // this connection usually starts the WAL again, so it does the cut
            Exec(_ck, "PRAGMA busy_timeout = 5000");
            Exec(_ck, "PRAGMA cache_size = 16"); // a checkpoint copies frames straight from the WAL; this connection reads no tables
            long version = 0;
            nint st;
            fixed (byte* q = "PRAGMA user_version"u8) {
                Check(sqlite3_prepare_v3(_ck, q, 19, 0, &st, null), "prepare user_version");
            }

            if (sqlite3_step(st) == SQLITE_ROW) {
                version = sqlite3_column_int64(st, 0);
            }

            sqlite3_finalize(st);
            _restart = Encoding.UTF8.GetBytes($"BEGIN IMMEDIATE; PRAGMA user_version = {version}; COMMIT\0");
        }

        public void Start() => new Thread(Run, 256 * 1024) { IsBackground = true, Name = "checkpoint" }.Start();

        private void Run() {
            if (!int.TryParse(Environment.GetEnvironmentVariable("MB_CK_NICE"), out int nice)) {
                nice = 19;
            }

            setpriority(0, (uint)syscall_fast(SYS_gettid, 0, 0, 0, 0, 0, 0), nice);
            int seen = -1;
            fixed (byte* restart = _restart, rollback = "ROLLBACK\0"u8) {
                while (true) {
                    if (Volatile.Read(ref Wal.HoldWrites) != 0) {
                        Thread.Sleep(1); // the loop waits for this checkpoint
                    } else {
                        Wal.Sleep();
                    }

                    bool held = Volatile.Read(ref Wal.HoldWrites) != 0;
                    int now = Volatile.Read(ref Wal.Commits);
                    // Caught up and the hold has not ended: a checkpoint now would copy the frame that started the WAL
                    // again, and the loop's next write would start it once more.
                    if ((held && Volatile.Read(ref Wal.CaughtUp) != 0) || (now == seen && !held)) {
                        continue;
                    }

                    seen = now;
                    int frames = 0, copied = 0;
                    sqlite3_wal_checkpoint_v2(_ck, null, SQLITE_CHECKPOINT_PASSIVE, &frames, &copied);
                    Volatile.Write(ref Wal.Frames, frames);
                    if (!held || copied < frames) {
                        continue;
                    }

                    if (frames == 0) {
                        Volatile.Write(ref Wal.CaughtUp, 1);
                    } else if (Interlocked.CompareExchange(ref Wal.RestartGate, 1, 0) == 0) {
                        if (Volatile.Read(ref Wal.HoldWrites) != 0) {
                            // If a pass's transaction still reads the old frames, the WAL does not start again: this
                            // only adds a frame, and the WAL goes on growing until the next hold.
                            if (sqlite3_exec(_ck, restart, 0, 0, null) == SQLITE_OK) {
                                Volatile.Write(ref Wal.CaughtUp, 1);
                            } else {
                                sqlite3_exec(_ck, rollback, 0, 0, null);
                            }
                        }

                        Volatile.Write(ref Wal.RestartGate, 0);
                    }
                }
            }
        }
    }
}
