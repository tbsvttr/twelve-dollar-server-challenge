package tds.challenge.db;

import io.vertx.core.Context;
import io.vertx.core.Future;
import io.vertx.core.Promise;
import io.vertx.core.json.JsonObject;
import org.sqlite.SQLiteConfig;

import java.nio.file.Path;
import java.sql.*;
import java.util.*;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.function.Consumer;

/**
 * A single thread that owns one SQLite connection and executes submitted operations
 * one after another (actor style). Callers get a Vert.x Future back.
 * <p>
 * Use one instance as WRITER (group commit: everything queued at the moment the thread
 * wakes up is executed in ONE transaction, i.e. one fsync) and one as READER
 * (read-only connection, WAL mode, so it never waits for the writer).
 * <p>
 * Rules for operations:
 * - they run on the DB thread, never on the event loop; keep them short and bounded
 * - they may only use the Session they are given
 * - don't close/commit anything on the Session; close ResultSets, never the cached statements
 */
public final class DbThread implements AutoCloseable {

    private static final int MAX_CACHED_STATEMENTS = 64;

    @FunctionalInterface
    public interface Op<T> {
        T run(Session session) throws Exception;
    }

    /**
     * Queue is full
     */
    public static final class OverloadedException extends RuntimeException {
        OverloadedException(String message) {
            super(message, null, false, false);
        }
    }

    public static final class ClosedException extends RuntimeException {
        ClosedException(String message) {
            super(message, null, false, false);
        }
    }

    /**
     * Thread-confined view of the connection with a prepared-statement cache.
     */
    public static final class Session {
        private final Connection conn;
        private final Map<String, PreparedStatement> cache;

        Session(Connection conn, int maxStatements) {
            this.conn = conn;
            this.cache = new LinkedHashMap<>(4, 0.75f, true) {
                @Override
                protected boolean removeEldestEntry(Map.Entry<String, PreparedStatement> eldest) {
                    if (size() > maxStatements) {
                        closeQuietly(eldest.getValue());
                        return true;
                    }
                    return false;
                }
            };
        }

        /**
         * Cached statement, parameters cleared. Do NOT close it; close its ResultSet instead.
         */
        public PreparedStatement prepare(String sql) throws SQLException {
            PreparedStatement ps = cache.get(sql);
            if (ps == null) {
                ps = conn.prepareStatement(sql);
                cache.put(sql, ps);
            } else {
                ps.clearParameters();
            }
            return ps;
        }

        void close() {
            cache.values().forEach(DbThread::closeQuietly);
            cache.clear();
            closeQuietly(conn);
        }
    }

    private static final class Task<T> {
        final Op<T> op;
        final Promise<T> promise;
        final long enqueuedNanos = System.nanoTime();
        T result;
        Throwable error;

        Task(Op<T> op, Promise<T> promise) {
            this.op = op;
            this.promise = promise;
        }

        void run(Session session) {
            try {
                result = op.run(session);
            } catch (Exception e) {
                error = e;
            }
        }

        void fail(Throwable t) {
            result = null;
            error = t;
        }

        void complete() {
            if (error != null) {
                promise.tryFail(error);
            } else {
                promise.tryComplete(result);
            }
        }
    }

    // ---------------------------------------------------------------- factories

    /**
     * Open writer connection and starts the thread.
     */
    public static DbThread writer(String dbFilePath, Context ctx) throws SQLException {
        Connection c = openConnection(dbFilePath, true);
        try {
            c.setAutoCommit(false);          // writer works in explicit transactions, one per batch
        } catch (SQLException e) {
            closeQuietly(c);
            throw e;
        }
        return start(new DbThread("db-writer", true, c, ctx, 1024, 128));
    }

    public static DbThread reader(String dbFilePath, Context ctx) throws SQLException {
        return start(new DbThread("db-reader", false, openConnection(dbFilePath, false), ctx, 8192, 16));
    }

    private static DbThread start(DbThread t) {
        t.thread.start();
        return t;
    }

    private static Connection openConnection(String dbFilePath, boolean writer) throws SQLException {
        Path dbFile = Path.of(dbFilePath).toAbsolutePath();

        SQLiteConfig cfg = new SQLiteConfig();
        cfg.setJournalMode(SQLiteConfig.JournalMode.WAL);
        cfg.setSynchronous(SQLiteConfig.SynchronousMode.NORMAL);
        cfg.setPragma(SQLiteConfig.Pragma.BUSY_TIMEOUT, "500");   // safe: we are never on the event loop
        cfg.enforceForeignKeys(true);

        Connection c = DriverManager.getConnection("jdbc:sqlite:" + dbFile, cfg.toProperties());
        if (!writer) {
            try (Statement st = c.createStatement()) {
                st.execute("PRAGMA query_only = ON");
            } catch (SQLException e) {
                closeQuietly(c);
                throw e;
            }
        }
        return c;
    }

    // ---------------------------------------------------------------- instance

    private final String name;
    private final boolean writer;
    private final Context ctx;
    private final Session session;
    private final ArrayBlockingQueue<Task<?>> queue;
    private final int maxBatch;
    private final Thread thread;
    private volatile boolean running = true;
    private final long startMs;

    private DbThread(String name, boolean writer, Connection conn, Context ctx, int queueCapacity, int maxBatch) {
        this.name = name;
        this.writer = writer;
        this.ctx = ctx;
        this.session = new Session(conn, MAX_CACHED_STATEMENTS);
        this.queue = new ArrayBlockingQueue<>(queueCapacity);
        this.maxBatch = maxBatch;
        this.thread = new Thread(this::loop, name);
        this.thread.setDaemon(true);
        this.startMs = System.currentTimeMillis();
    }

    /**
     * Call from the event loop. The returned future completes on this DbThread's Vert.x context.
     */
    public <T> Future<T> submit(Op<T> op) {
        if (!running) {
            return Future.failedFuture(new ClosedException(name + " is closed"));
        }
        Task<T> task = new Task<>(op, Promise.promise());
        if (!queue.offer(task)) {
            return Future.failedFuture(new OverloadedException(name + " queue is full"));
        }
        return task.promise.future();
    }

    /**
     * Stops the thread (queued tasks fail with ClosedException) and closes the connection. Blocking.
     */
    @Override
    public void close() {
        running = false;
        thread.interrupt();
        try {
            thread.join(5_000);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    public Future<Consumer<JsonObject>> verifyConnection() {
        return submit(s -> {
            try (ResultSet ignore = s.prepare("SELECT 1;").executeQuery()) {
                final long uptimeS = (System.currentTimeMillis() - this.startMs) / 1000;
                return jo -> jo.put("status", "ok").put("db", "ok").put("uptime_s", uptimeS);
            } catch (SQLException sqle) {
                return jo -> jo.put("status", "degraded").put("db", "unreachable").put("error", sqle.getMessage());
            }
        });
    }

    // ---------------------------------------------------------------- the loop

    private void loop() {
        while (running) {
            Task<?> first;
            try {
                first = queue.take();                 // parks while idle: no CPU use
            } catch (InterruptedException e) {
                continue;                             // loop condition re-checks 'running'
            }

            List<Task<?>> batch = new ArrayList<>(maxBatch);
            batch.add(first);
            queue.drainTo(batch, maxBatch - 1);     // take what is already waiting, never wait for more

            try {
                if (writer) {
                    runWriteBatch(batch);
                } else {
                    for (Task<?> t : batch) {
                        t.run(session);
                    }
                }
            } catch (Throwable fatal) {
                System.out.printf("%s: unexpected failure, failing batch of %s%n", name, batch.size(), fatal);
                if (writer) {
                    rollbackQuietly();
                }
                for (Task<?> t : batch) {
                    if (t.error == null) {
                        t.fail(fatal);
                    }
                }
            }

            dispatch(batch);
        }

        failPending();
        session.close();
    }

    /**
     * One transaction for the whole batch; each op in its own savepoint so one failure doesn't affect the rest.
     */
    private void runWriteBatch(List<Task<?>> batch) {
        try (Statement st = session.conn.createStatement()) {
            for (Task<?> t : batch) {
                st.execute("SAVEPOINT op");
                t.run(session);
                if (t.error != null) {
                    st.execute("ROLLBACK TO op");       // undo the partial effects of this op only
                }
                st.execute("RELEASE op");
            }
            session.conn.commit();                  // single fsync for all successful ops
        } catch (SQLException e) {
            System.out.printf("%s: batch transaction failed, rolling back %s ops%n%s%n", name, batch.size(), e);
            rollbackQuietly();
            for (Task<?> t : batch) {
                if (t.error == null) {                // never report success for an uncommitted write
                    t.fail(e);
                }
            }
        }
    }

    /**
     * One hop to the event loop for the whole batch.
     */
    private void dispatch(List<Task<?>> batch) {
        try {
            ctx.runOnContext(v -> batch.forEach(t -> t.complete()));
        } catch (RuntimeException e) {            // context already shut down
            batch.forEach(t -> t.complete());
        }
    }

    private void failPending() {
        ClosedException closed = new ClosedException(name + " is closed");
        Task<?> t;
        while ((t = queue.poll()) != null) {
            t.fail(closed);
            t.complete();
        }
    }

    private void rollbackQuietly() {
        try {
            session.conn.rollback();
        } catch (SQLException ignored) {
            // connection state is unknown; the next batch will report its own error
        }
    }

    private static void closeQuietly(AutoCloseable c) {
        try {
            c.close();
        } catch (Exception ignored) {
            // nothing useful to do
        }
    }
}
