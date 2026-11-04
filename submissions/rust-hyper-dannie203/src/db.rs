use chrono::Utc;
use crossbeam_channel::Receiver;
use rusqlite::{params, Connection, OpenFlags, Statement};
use tokio::sync::oneshot;

use crate::models::Post;

pub struct ReaderConn {
    pub feed_stmt: Statement<'static>,
    pub post_stmt: Statement<'static>,
    pub _conn: Box<Connection>,
}

unsafe impl Send for ReaderConn {}

impl ReaderConn {
    pub fn new(sqlite_path: &str) -> Self {
        let conn = Box::new(
            Connection::open_with_flags(sqlite_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
                .expect("Failed to open read connection"),
        );
        init_sqlite_pragmas(&conn);

        let conn_ref: &'static Connection = unsafe { std::mem::transmute(&*conn) };

        // Set-Based CTE with indexed seek limits traversal strictly to 20 rows!
        let feed_stmt = conn_ref
            .prepare(
                "WITH recent AS (
                     SELECT id, user_id, body, created_at
                     FROM posts
                     ORDER BY created_at DESC, id DESC
                     LIMIT 20
                 )
                 SELECT r.id, r.body, r.created_at, u.username,
                        (SELECT COUNT(*) FROM likes l WHERE l.post_id = r.id) AS like_count
                 FROM recent r
                 JOIN users u ON u.id = r.user_id
                 ORDER BY r.created_at DESC, r.id DESC;",
            )
            .expect("Failed to prepare feed statement");

        let post_stmt = conn_ref
            .prepare(
                "SELECT p.id, p.body, p.created_at, u.username,
                        (SELECT COUNT(*) FROM likes l WHERE l.post_id = p.id) AS like_count
                 FROM posts p
                 JOIN users u ON u.id = p.user_id
                 WHERE p.id = ?1;",
            )
            .expect("Failed to prepare post statement");

        ReaderConn {
            feed_stmt,
            post_stmt,
            _conn: conn,
        }
    }
}

pub enum LikeResult {
    Created,
    AlreadyLiked,
    NotFound,
    Error(String),
}

pub enum WriteCommand {
    CreatePost {
        user_id: i64,
        body: String,
        created_at: String,
        author: String,
        respond_to: oneshot::Sender<Result<Post, String>>,
    },
    LikePost {
        user_id: i64,
        post_id: i64,
        respond_to: oneshot::Sender<LikeResult>,
    },
}

pub fn init_sqlite_pragmas(conn: &Connection) {
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA synchronous = NORMAL;
         PRAGMA temp_store = MEMORY;
         PRAGMA mmap_size = 536870912;
         PRAGMA cache_size = -64000;
         PRAGMA busy_timeout = 5000;",
    )
    .expect("Failed to set SQLite PRAGMAs");
}

pub fn start_writer_thread(sqlite_path: String, rx: Receiver<WriteCommand>) {
    std::thread::Builder::new()
        .name("sqlite-writer".into())
        .spawn(move || {
            let conn = Connection::open_with_flags(
                &sqlite_path,
                OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_CREATE,
            )
            .expect("Writer cannot open database");
            init_sqlite_pragmas(&conn);

            let mut insert_post_stmt = conn
                .prepare("INSERT INTO posts (user_id, body, created_at) VALUES (?1, ?2, ?3) RETURNING id")
                .unwrap();
            let mut check_post_stmt = conn
                .prepare("SELECT 1 FROM posts WHERE id = ?1")
                .unwrap();
            let mut check_like_stmt = conn
                .prepare("SELECT 1 FROM likes WHERE user_id = ?1 AND post_id = ?2")
                .unwrap();
            let mut insert_like_stmt = conn
                .prepare("INSERT OR IGNORE INTO likes (user_id, post_id, created_at) VALUES (?1, ?2, ?3)")
                .unwrap();

            while let Ok(cmd) = rx.recv() {
                match cmd {
                    WriteCommand::CreatePost { user_id, body, created_at, author, respond_to } => {
                        let res = (|| -> Result<Post, String> {
                            let id: i64 = insert_post_stmt
                                .query_row(params![user_id, body, created_at], |row| row.get(0))
                                .map_err(|e| format!("Insert post failed: {e}"))?;

                            Ok(Post {
                                id,
                                body,
                                created_at,
                                author,
                                like_count: 0,
                            })
                        })();
                        let _ = respond_to.send(res);
                    }
                    WriteCommand::LikePost { user_id, post_id, respond_to } => {
                        let exists = check_post_stmt.exists(params![post_id]).unwrap_or(false);
                        if !exists {
                            let _ = respond_to.send(LikeResult::NotFound);
                            continue;
                        }

                        let already_liked = check_like_stmt.exists(params![user_id, post_id]).unwrap_or(false);
                        if already_liked {
                            let _ = respond_to.send(LikeResult::AlreadyLiked);
                        } else {
                            let now_str = Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string();
                            // Rule 6: Strictly check execution result, never ignore errors!
                            match insert_like_stmt.execute(params![user_id, post_id, now_str]) {
                                Ok(_) => {
                                    let _ = respond_to.send(LikeResult::Created);
                                }
                                Err(e) => {
                                    let _ = respond_to.send(LikeResult::Error(e.to_string()));
                                }
                            }
                        }
                    }
                }
            }
        })
        .expect("Failed to spawn writer thread");
}
