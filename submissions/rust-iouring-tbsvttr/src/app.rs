use std::time::Instant;

use crate::db::{Db, LikeStatus, TvccFeedResult, TvccSinglePostResult};
use crate::http::{
    Method, ParsedRequest, write_dynamic_json_response, write_static_json_response,
};
use crate::json::{
    BodyError, extract_and_validate_post_body, format_utc_iso_ms_from, write_feed_result,
    write_health_json, write_like_json, write_single_post_json, write_single_post_result,
};
use crate::jwt::{JwtError, JwtVerifier};
use crate::sys::{CLOCK_REALTIME, clock_gettime, timespec};

const ERR_NOT_FOUND: &[u8] = b"{\"error\":\"not found\"}";
const ERR_INVALID_POST_ID: &[u8] = b"{\"error\":\"invalid post id\"}";
const ERR_POST_NOT_FOUND: &[u8] = b"{\"error\":\"post not found\"}";
const ERR_MISSING_BEARER: &[u8] = b"{\"error\":\"missing bearer token\"}";
const ERR_INVALID_OR_EXPIRED: &[u8] = b"{\"error\":\"invalid or expired token\"}";
const ERR_INVALID_PAYLOAD: &[u8] = b"{\"error\":\"invalid token payload\"}";
const ERR_BODY_REQUIRED: &[u8] = b"{\"error\":\"body is required\"}";
const ERR_BODY_TOO_LONG: &[u8] = b"{\"error\":\"body must be at most 500 characters\"}";
const ERR_MALFORMED_JSON: &[u8] = b"{\"error\":\"malformed JSON body\"}";
const ERR_INTERNAL: &[u8] = b"{\"error\":\"internal error\"}";
const ERR_DB_UNREACHABLE: &[u8] = b"{\"status\":\"error\",\"db\":\"unreachable\"}";

pub struct App {
    pub db: Db,
    jwt: JwtVerifier,
    started_at: Instant,
    feed_scratch: Box<TvccFeedResult>,
    post_scratch: Box<TvccSinglePostResult>,
    json_scratch: Vec<u8>,
    body_scratch: Vec<u8>,
}

impl App {
    pub fn new(db: Db, jwt_secret: &[u8]) -> Self {
        Self {
            db,
            jwt: JwtVerifier::new(jwt_secret),
            started_at: Instant::now(),
            feed_scratch: Box::new(TvccFeedResult::default()),
            post_scratch: Box::new(TvccSinglePostResult::default()),
            json_scratch: Vec::with_capacity(8192),
            body_scratch: Vec::with_capacity(2048),
        }
    }

    #[allow(dead_code)]
    #[inline]
    pub fn is_write_request(req: &ParsedRequest<'_>) -> bool {
        req.method == Method::Post
    }

    pub fn handle_request(&mut self, req: &ParsedRequest<'_>, out: &mut Vec<u8>) {
        match req.method {
            Method::Get => {
                if req.path == b"/feed" {
                    self.handle_feed(req.close_conn, out);
                } else if let Some(rest) = req.path.strip_prefix(b"/posts/") {
                    if rest.is_empty() || rest.contains(&b'/') {
                        write_static_json_response(out, 404, req.close_conn, ERR_NOT_FOUND);
                    } else {
                        self.handle_get_post(rest, req.close_conn, out);
                    }
                } else if req.path == b"/health" {
                    self.handle_health(req.close_conn, out);
                } else {
                    write_static_json_response(out, 404, req.close_conn, ERR_NOT_FOUND);
                }
            }
            Method::Post => {
                if req.path == b"/posts" {
                    self.handle_create_post(req, out);
                } else if let Some(rest) = req.path.strip_prefix(b"/posts/") {
                    if let Some(id_slice) = rest.strip_suffix(b"/like") {
                        if id_slice.is_empty() || id_slice.contains(&b'/') {
                            write_static_json_response(out, 404, req.close_conn, ERR_NOT_FOUND);
                        } else {
                            self.handle_like_post(req, id_slice, out);
                        }
                    } else {
                        write_static_json_response(out, 404, req.close_conn, ERR_NOT_FOUND);
                    }
                } else {
                    write_static_json_response(out, 404, req.close_conn, ERR_NOT_FOUND);
                }
            }
            Method::Other => {
                write_static_json_response(out, 404, req.close_conn, ERR_NOT_FOUND);
            }
        }
    }

    fn handle_feed(&mut self, close_conn: bool, out: &mut Vec<u8>) {
        if self.db.feed(&mut self.feed_scratch).is_ok() {
            let feed_ref = &*self.feed_scratch;
            write_dynamic_json_response(out, 200, close_conn, &mut self.json_scratch, |b| {
                write_feed_result(b, feed_ref);
            });
        } else {
            write_static_json_response(out, 500, close_conn, ERR_INTERNAL);
        }
    }

    fn handle_get_post(&mut self, id_bytes: &[u8], close_conn: bool, out: &mut Vec<u8>) {
        let Some(post_id) = parse_strict_post_id(id_bytes) else {
            write_static_json_response(out, 400, close_conn, ERR_INVALID_POST_ID);
            return;
        };
        match self.db.get_post(post_id, &mut self.post_scratch) {
            Ok(true) => {
                let post_ref = &*self.post_scratch;
                write_dynamic_json_response(out, 200, close_conn, &mut self.json_scratch, |b| {
                    write_single_post_result(b, post_ref);
                });
            }
            Ok(false) => {
                write_static_json_response(out, 404, close_conn, ERR_POST_NOT_FOUND);
            }
            Err(()) => {
                write_static_json_response(out, 500, close_conn, ERR_INTERNAL);
            }
        }
    }

    fn handle_health(&mut self, close_conn: bool, out: &mut Vec<u8>) {
        if self.db.health() {
            let uptime_s = self.started_at.elapsed().as_secs();
            write_dynamic_json_response(out, 200, close_conn, &mut self.json_scratch, |b| {
                write_health_json(b, uptime_s);
            });
        } else {
            write_static_json_response(out, 503, close_conn, ERR_DB_UNREACHABLE);
        }
    }

    fn handle_create_post(&mut self, req: &ParsedRequest<'_>, out: &mut Vec<u8>) {
        let now_ts = unix_now_timespec();
        let claims = match self.jwt.verify_bearer(req.auth_header, now_ts.tv_sec) {
            Ok(c) => c,
            Err(err) => {
                write_jwt_error(out, req.close_conn, err);
                return;
            }
        };

        let trimmed_body = match extract_and_validate_post_body(req.body, &mut self.body_scratch) {
            Ok(s) => s,
            Err(BodyError::MalformedJson) => {
                write_static_json_response(out, 400, req.close_conn, ERR_MALFORMED_JSON);
                return;
            }
            Err(BodyError::MissingOrEmpty) => {
                write_static_json_response(out, 400, req.close_conn, ERR_BODY_REQUIRED);
                return;
            }
            Err(BodyError::TooLong) => {
                write_static_json_response(out, 400, req.close_conn, ERR_BODY_TOO_LONG);
                return;
            }
        };

        let created_at = format_utc_iso_ms_from(now_ts);
        match self.db.insert_post(claims.user_id, trimmed_body, &created_at) {
            Ok(post_id) => {
                let author = &claims.username[..claims.username_len];
                write_dynamic_json_response(out, 201, req.close_conn, &mut self.json_scratch, |b| {
                    write_single_post_json(b, post_id, trimmed_body, &created_at, author, 0);
                });
            }
            Err(()) => {
                write_static_json_response(out, 500, req.close_conn, ERR_INTERNAL);
            }
        }
    }

    fn handle_like_post(&mut self, req: &ParsedRequest<'_>, id_bytes: &[u8], out: &mut Vec<u8>) {
        /* SPEC rule: Auth MUST run before :id validation */
        let now_s = unix_now_secs();
        let claims = match self.jwt.verify_bearer(req.auth_header, now_s) {
            Ok(c) => c,
            Err(err) => {
                write_jwt_error(out, req.close_conn, err);
                return;
            }
        };

        let Some(post_id) = parse_strict_post_id(id_bytes) else {
            write_static_json_response(out, 400, req.close_conn, ERR_INVALID_POST_ID);
            return;
        };

        match self.db.like_post(post_id, claims.user_id) {
            Ok(LikeStatus::Created) => {
                write_dynamic_json_response(out, 201, req.close_conn, &mut self.json_scratch, |b| {
                    write_like_json(b, false, post_id);
                });
            }
            Ok(LikeStatus::AlreadyLiked) => {
                write_dynamic_json_response(out, 200, req.close_conn, &mut self.json_scratch, |b| {
                    write_like_json(b, true, post_id);
                });
            }
            Ok(LikeStatus::NotFound) => {
                write_static_json_response(out, 404, req.close_conn, ERR_POST_NOT_FOUND);
            }
            Err(()) => {
                write_static_json_response(out, 500, req.close_conn, ERR_INTERNAL);
            }
        }
    }
}

#[inline]
fn write_jwt_error(out: &mut Vec<u8>, close_conn: bool, err: JwtError) {
    let body = match err {
        JwtError::MissingToken => ERR_MISSING_BEARER,
        JwtError::InvalidOrExpired => ERR_INVALID_OR_EXPIRED,
        JwtError::InvalidPayload => ERR_INVALID_PAYLOAD,
    };
    write_static_json_response(out, 401, close_conn, body);
}

#[inline]
fn parse_strict_post_id(bytes: &[u8]) -> Option<i64> {
    if bytes.is_empty() || bytes.len() > 19 {
        return None;
    }
    let mut v = 0i64;
    for &b in bytes {
        if !b.is_ascii_digit() {
            return None;
        }
        v = v.checked_mul(10)?.checked_add((b - b'0') as i64)?;
    }
    if v >= 1 { Some(v) } else { None }
}

#[inline]
fn unix_now_timespec() -> timespec {
    let mut ts = timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    unsafe {
        clock_gettime(CLOCK_REALTIME, &mut ts);
    }
    ts
}

#[inline]
fn unix_now_secs() -> i64 {
    unix_now_timespec().tv_sec
}
