mod auth;
mod db;
mod models;

use std::convert::Infallible;
use std::env;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Instant;

use chrono::Utc;
use crossbeam_channel::{bounded, Receiver, Sender};
use http_body_util::{BodyExt, Full};
use hyper::body::{Bytes, Incoming};
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use hyper_util::server::conn::auto::Builder;
use rusqlite::{params, Connection};
use serde::Serialize;
use tokio::net::TcpListener;
use tokio::sync::oneshot;

use auth::{verify_jwt_spec, AuthError};
use db::{init_sqlite_pragmas, start_writer_thread, LikeResult, ReaderConn, WriteCommand};
use models::{FeedResp, HealthResp, LikeResp, Post, SinglePostResp};

struct AppState {
    jwt_secret: Vec<u8>,
    start_time: Instant,
    writer_tx: Sender<WriteCommand>,
    reader_pool: (Sender<ReaderConn>, Receiver<ReaderConn>),
}

#[inline(always)]
fn json_resp<T: Serialize>(status: StatusCode, data: &T) -> Response<Full<Bytes>> {
    let body = serde_json::to_vec(data).unwrap();
    Response::builder()
        .status(status)
        .header("Content-Type", "application/json")
        .body(Full::new(Bytes::from(body)))
        .unwrap()
}

#[inline(always)]
fn error_resp(status: StatusCode, msg: &str) -> Response<Full<Bytes>> {
    let json = format!(r#"{{"error":"{}"}}"#, msg);
    Response::builder()
        .status(status)
        .header("Content-Type", "application/json")
        .body(Full::new(Bytes::from(json)))
        .unwrap()
}

#[inline(always)]
fn parse_positive_id(s: &str) -> Option<i64> {
    if s.is_empty() {
        return None;
    }
    for &b in s.as_bytes() {
        if !(b'0'..=b'9').contains(&b) {
            return None;
        }
    }
    let val = s.parse::<i64>().ok()?;
    if val <= 0 {
        None
    } else {
        Some(val)
    }
}

async fn handle_request(
    req: Request<Incoming>,
    state: Arc<AppState>,
) -> Result<Response<Full<Bytes>>, Infallible> {
    let path = req.uri().path();
    let method = req.method();

    // 0. GET /health (Regex: ^{"status":"ok","db":"ok","uptime_s":[0-9]+}$)
    if method == Method::GET && path == "/health" {
        let uptime_s = state.start_time.elapsed().as_secs();
        return Ok(json_resp(
            StatusCode::OK,
            &HealthResp {
                status: "ok",
                db: "ok",
                uptime_s,
            },
        ));
    }

    // 1. GET /feed
    if method == Method::GET && path == "/feed" {
        let mut reader = state.reader_pool.1.recv().unwrap();
        let mut rows = reader.feed_stmt.query([]).unwrap();

        let mut posts = Vec::with_capacity(20);
        while let Ok(Some(row)) = rows.next() {
            posts.push(Post {
                id: row.get(0).unwrap(),
                body: row.get(1).unwrap(),
                created_at: row.get(2).unwrap(),
                author: row.get(3).unwrap(),
                like_count: row.get(4).unwrap(),
            });
        }
        drop(rows);
        let _ = state.reader_pool.0.send(reader);

        return Ok(json_resp(StatusCode::OK, &FeedResp { posts }));
    }

    // 2. GET /posts/:id
    if method == Method::GET && path.starts_with("/posts/") && !path.ends_with("/like") {
        let id_str = &path["/posts/".len()..];
        let post_id = match parse_positive_id(id_str) {
            Some(id) => id,
            None => return Ok(error_resp(StatusCode::BAD_REQUEST, "invalid post id")),
        };

        let mut reader = state.reader_pool.1.recv().unwrap();
        let post_opt = reader
            .post_stmt
            .query_row(params![post_id], |row| {
                Ok(Post {
                    id: row.get(0)?,
                    body: row.get(1)?,
                    created_at: row.get(2)?,
                    author: row.get(3)?,
                    like_count: row.get(4)?,
                })
            })
            .ok();
        let _ = state.reader_pool.0.send(reader);

        return match post_opt {
            Some(post) => Ok(json_resp(StatusCode::OK, &SinglePostResp { post })),
            None => Ok(error_resp(StatusCode::NOT_FOUND, "post not found")),
        };
    }

    // 3. POST /posts (Auth required)
    if method == Method::POST && path == "/posts" {
        let auth_header = req
            .headers()
            .get("Authorization")
            .and_then(|h| h.to_str().ok());

        let claims = match verify_jwt_spec(auth_header, &state.jwt_secret) {
            Ok(c) => c,
            Err(AuthError::MissingBearerToken) => {
                return Ok(error_resp(StatusCode::UNAUTHORIZED, "missing bearer token"))
            }
            Err(AuthError::InvalidOrExpiredToken) => {
                return Ok(error_resp(StatusCode::UNAUTHORIZED, "invalid or expired token"))
            }
            Err(AuthError::InvalidTokenPayload) => {
                return Ok(error_resp(StatusCode::UNAUTHORIZED, "invalid token payload"))
            }
        };

        let body_bytes = match req.into_body().collect().await {
            Ok(c) => c.to_bytes(),
            Err(_) => return Ok(error_resp(StatusCode::BAD_REQUEST, "malformed JSON body")),
        };

        let payload_json: serde_json::Value = match serde_json::from_slice(&body_bytes) {
            Ok(v) => v,
            Err(_) => return Ok(error_resp(StatusCode::BAD_REQUEST, "malformed JSON body")),
        };

        let post_body = match payload_json.get("body") {
            Some(serde_json::Value::String(s)) => s,
            _ => return Ok(error_resp(StatusCode::BAD_REQUEST, "body is required")),
        };

        let trimmed = post_body.trim();
        if trimmed.is_empty() {
            return Ok(error_resp(StatusCode::BAD_REQUEST, "body is required"));
        }

        if trimmed.chars().count() > 500 {
            return Ok(error_resp(StatusCode::BAD_REQUEST, "body must be at most 500 characters"));
        }

        let created_at = Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string();
        let (tx, rx) = oneshot::channel();

        state
            .writer_tx
            .send(WriteCommand::CreatePost {
                user_id: claims.user_id,
                body: trimmed.to_string(),
                created_at,
                author: claims.username,
                respond_to: tx,
            })
            .unwrap();

        return match rx.await {
            Ok(Ok(post)) => Ok(json_resp(StatusCode::CREATED, &SinglePostResp { post })),
            Ok(Err(e)) => Ok(error_resp(StatusCode::INTERNAL_SERVER_ERROR, &e)),
            Err(_) => Ok(error_resp(StatusCode::INTERNAL_SERVER_ERROR, "writer cancelled")),
        };
    }

    // 4. POST /posts/:id/like (Auth required)
    if method == Method::POST && path.starts_with("/posts/") && path.ends_with("/like") {
        let auth_header = req
            .headers()
            .get("Authorization")
            .and_then(|h| h.to_str().ok());

        let claims = match verify_jwt_spec(auth_header, &state.jwt_secret) {
            Ok(c) => c,
            Err(AuthError::MissingBearerToken) => {
                return Ok(error_resp(StatusCode::UNAUTHORIZED, "missing bearer token"))
            }
            Err(AuthError::InvalidOrExpiredToken) => {
                return Ok(error_resp(StatusCode::UNAUTHORIZED, "invalid or expired token"))
            }
            Err(AuthError::InvalidTokenPayload) => {
                return Ok(error_resp(StatusCode::UNAUTHORIZED, "invalid token payload"))
            }
        };

        let id_part = &path["/posts/".len()..path.len() - "/like".len()];
        let post_id = match parse_positive_id(id_part) {
            Some(id) => id,
            None => return Ok(error_resp(StatusCode::BAD_REQUEST, "invalid post id")),
        };

        let (tx, rx) = oneshot::channel();
        state
            .writer_tx
            .send(WriteCommand::LikePost {
                user_id: claims.user_id,
                post_id,
                respond_to: tx,
            })
            .unwrap();

        return match rx.await {
            Ok(LikeResult::Created) => Ok(json_resp(
                StatusCode::CREATED,
                &LikeResp {
                    liked: true,
                    already_liked: false,
                    post_id,
                },
            )),
            Ok(LikeResult::AlreadyLiked) => Ok(json_resp(
                StatusCode::OK,
                &LikeResp {
                    liked: true,
                    already_liked: true,
                    post_id,
                },
            )),
            Ok(LikeResult::NotFound) => Ok(error_resp(StatusCode::NOT_FOUND, "post not found")),
            Ok(LikeResult::Error(e)) => Ok(error_resp(StatusCode::INTERNAL_SERVER_ERROR, &e)),
            Err(_) => Ok(error_resp(StatusCode::INTERNAL_SERVER_ERROR, "writer cancelled")),
        };
    }

    // Catch-all 404
    Ok(error_resp(StatusCode::NOT_FOUND, "not found"))
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let sqlite_path = env::var("SQLITE_PATH").unwrap_or_else(|_| "sqlite.db".into());
    let jwt_secret = env::var("JWT_SECRET")
        .unwrap_or_else(|_| "twelve-dollar-challenge".into())
        .into_bytes();
    let host = env::var("HOST").unwrap_or_else(|_| "0.0.0.0".into());
    let port = env::var("PORT").unwrap_or_else(|_| "3000".into());
    let addr: SocketAddr = format!("{}:{}", host, port).parse()?;

    // Ensure database file and pragmas on startup
    {
        let conn = Connection::open(&sqlite_path)?;
        init_sqlite_pragmas(&conn);
    }

    // Launch Single-Writer Channel & Thread
    let (writer_tx, writer_rx) = bounded::<WriteCommand>(20_000);
    start_writer_thread(sqlite_path.clone(), writer_rx);

    // Initialize 16 Persistent Readers in Pool
    let (reader_tx, reader_rx) = bounded::<ReaderConn>(16);
    for _ in 0..16 {
        reader_tx.send(ReaderConn::new(&sqlite_path)).unwrap();
    }

    let state = Arc::new(AppState {
        jwt_secret,
        start_time: Instant::now(),
        writer_tx,
        reader_pool: (reader_tx, reader_rx),
    });

    let listener = TcpListener::bind(addr).await?;
    println!("Listening on http://{}", addr);

    loop {
        let (stream, _) = match listener.accept().await {
            Ok(s) => s,
            Err(_) => {
                tokio::time::sleep(std::time::Duration::from_millis(5)).await;
                continue;
            }
        };
        let io = TokioIo::new(stream);
        let state = Arc::clone(&state);

        tokio::task::spawn(async move {
            let auto = Builder::new(hyper_util::rt::TokioExecutor::new());
            if let Err(err) = auto
                .serve_connection_with_upgrades(
                    io,
                    service_fn(move |req| {
                        let state = Arc::clone(&state);
                        async move { handle_request(req, state).await }
                    }),
                )
                .await
            {
                let _ = err;
            }
        });
    }
}
