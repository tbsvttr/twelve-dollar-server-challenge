use crate::json::push_u64;
use crate::sys::find_byte;

pub const MAX_HEADER_BYTES: usize = 8192;
pub const MAX_BODY_BYTES: usize = 65536;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Method {
    Get,
    Post,
    Other,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ParsedRequest<'a> {
    pub method: Method,
    pub path: &'a [u8],
    pub auth_header: Option<&'a [u8]>,
    pub body: &'a [u8],
    pub close_conn: bool,
    pub total_consumed: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ParseState<'a> {
    Complete(ParsedRequest<'a>),
    Incomplete,
    Invalid,
}

pub fn parse_http_request(buf: &[u8]) -> ParseState<'_> {
    let search_cap = buf.len().min(MAX_HEADER_BYTES);
    let Some(hdr_end) = find_crlf_crlf(&buf[..search_cap]) else {
        if buf.len() >= MAX_HEADER_BYTES {
            return ParseState::Invalid;
        }
        return ParseState::Incomplete;
    };

    let head = &buf[..hdr_end];
    let body_offset = hdr_end + 4;

    let line1_end = find_crlf(head).unwrap_or(head.len());
    let req_line = &head[..line1_end];

    let (method, after_method) = if req_line.starts_with(b"GET ") {
        (Method::Get, 4)
    } else if req_line.starts_with(b"POST ") {
        (Method::Post, 5)
    } else {
        let Some(sp) = find_byte(b' ', req_line) else {
            return ParseState::Invalid;
        };
        if sp == 0 {
            return ParseState::Invalid;
        }
        (Method::Other, sp + 1)
    };

    let rest_line = &req_line[after_method..];
    let Some(sp2) = find_byte(b' ', rest_line) else {
        return ParseState::Invalid;
    };
    if sp2 == 0 {
        return ParseState::Invalid;
    }
    let raw_target = &rest_line[..sp2];
    let version = &rest_line[sp2 + 1..];
    let is_http10 = version == b"HTTP/1.0";
    if !is_http10 && version != b"HTTP/1.1" {
        return ParseState::Invalid;
    }

    let path = match find_byte(b'?', raw_target) {
        Some(q) => &raw_target[..q],
        None => raw_target,
    };

    let mut auth_header: Option<&[u8]> = None;
    let mut content_len: usize = 0;
    let mut has_content_len = false;
    let mut close_conn = is_http10;

    let mut pos = line1_end + 2;
    while pos < head.len() {
        let rem = &head[pos..];
        let line_len = find_crlf(rem).unwrap_or(rem.len());
        let line = &rem[..line_len];
        pos += line_len + 2;
        if line.is_empty() {
            continue;
        }

        let first = line[0] | 0x20;
        if first == b'a' && line.len() >= 14 && line[..14].eq_ignore_ascii_case(b"authorization:") {
            auth_header = Some(trim_ows(&line[14..]));
        } else if first == b'c' {
            if line.len() >= 15 && line[..15].eq_ignore_ascii_case(b"content-length:") {
                let val_bytes = trim_ows(&line[15..]);
                let Some(cl) = parse_content_length(val_bytes) else {
                    return ParseState::Invalid;
                };
                if cl > MAX_BODY_BYTES || (has_content_len && cl != content_len) {
                    return ParseState::Invalid;
                }
                content_len = cl;
                has_content_len = true;
            } else if line.len() >= 11 && line[..11].eq_ignore_ascii_case(b"connection:") {
                let val = trim_ows(&line[11..]);
                if val.eq_ignore_ascii_case(b"close") {
                    close_conn = true;
                } else if is_http10 && val.eq_ignore_ascii_case(b"keep-alive") {
                    close_conn = false;
                }
            }
        } else if first == b't'
            && line.len() >= 18
            && line[..18].eq_ignore_ascii_case(b"transfer-encoding:")
        {
            return ParseState::Invalid;
        }
    }

    let total_needed = body_offset + content_len;
    if buf.len() < total_needed {
        return ParseState::Incomplete;
    }

    ParseState::Complete(ParsedRequest {
        method,
        path,
        auth_header,
        body: &buf[body_offset..total_needed],
        close_conn,
        total_consumed: total_needed,
    })
}

#[inline]
fn find_crlf(b: &[u8]) -> Option<usize> {
    let mut pos = 0usize;
    while pos + 1 < b.len() {
        let idx = find_byte(b'\r', &b[pos..])?;
        let abs = pos + idx;
        if abs + 1 < b.len() && b[abs + 1] == b'\n' {
            return Some(abs);
        }
        pos = abs + 1;
    }
    None
}

#[inline]
fn find_crlf_crlf(b: &[u8]) -> Option<usize> {
    let mut pos = 0usize;
    while pos + 3 < b.len() {
        let idx = find_byte(b'\r', &b[pos..])?;
        let abs = pos + idx;
        if abs + 3 < b.len() && b[abs + 1] == b'\n' && b[abs + 2] == b'\r' && b[abs + 3] == b'\n' {
            return Some(abs);
        }
        pos = abs + 1;
    }
    None
}

#[inline]
fn trim_ows(mut s: &[u8]) -> &[u8] {
    while let Some((&f, rest)) = s.split_first() {
        if f == b' ' || f == b'\t' {
            s = rest;
        } else {
            break;
        }
    }
    while let Some((&l, rest)) = s.split_last() {
        if l == b' ' || l == b'\t' {
            s = rest;
        } else {
            break;
        }
    }
    s
}

#[inline]
fn parse_content_length(s: &[u8]) -> Option<usize> {
    if s.is_empty() || s.len() > 8 {
        return None;
    }
    let mut v = 0usize;
    for &b in s {
        if !b.is_ascii_digit() {
            return None;
        }
        v = v * 10 + (b - b'0') as usize;
    }
    Some(v)
}

#[inline]
pub fn write_static_json_response(
    out: &mut Vec<u8>,
    status_code: u16,
    close_conn: bool,
    json_body: &[u8],
) {
    push_response_head(out, status_code, close_conn, json_body.len());
    out.extend_from_slice(json_body);
}

#[inline]
pub fn write_dynamic_json_response<F>(
    out: &mut Vec<u8>,
    status_code: u16,
    close_conn: bool,
    _body_scratch: &mut Vec<u8>,
    build_body: F,
) where
    F: FnOnce(&mut Vec<u8>),
{
    let prefix: &[u8] = match (status_code, close_conn) {
        (200, false) => b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0000\r\n\r\n",
        (201, false) => b"HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 0000\r\n\r\n",
        (400, false) => b"HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 0000\r\n\r\n",
        (401, false) => b"HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: 0000\r\n\r\n",
        (404, false) => b"HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 0000\r\n\r\n",
        (500, false) => b"HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: 0000\r\n\r\n",
        (503, false) => b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: 0000\r\n\r\n",
        (200, true) => b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: 0000\r\n\r\n",
        (201, true) => b"HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: 0000\r\n\r\n",
        (400, true) => b"HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: 0000\r\n\r\n",
        (401, true) => b"HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: 0000\r\n\r\n",
        (404, true) => b"HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: 0000\r\n\r\n",
        (500, true) => b"HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: 0000\r\n\r\n",
        _ => b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: 0000\r\n\r\n",
    };
    out.extend_from_slice(prefix);
    let body_start = out.len();
    build_body(out);
    let body_len = out.len() - body_start;
    let slot = body_start - 8;
    let mut digits = [0u8; 20];
    let mut d = digits.len();
    let mut v = body_len;
    loop {
        d -= 1;
        digits[d] = b'0' + (v % 10) as u8;
        v /= 10;
        if v == 0 {
            break;
        }
    }
    let digits = &digits[d..];
    if digits.len() == 4 {
        out[slot..slot + 4].copy_from_slice(digits);
    } else {
        let delta = digits.len() as isize - 4;
        if delta > 0 {
            out.resize(out.len() + delta as usize, 0);
        }
        let new_start = (body_start as isize + delta) as usize;
        out.copy_within(body_start..body_start + body_len, new_start);
        out.truncate(new_start + body_len);
        out[slot..slot + digits.len()].copy_from_slice(digits);
        out[slot + digits.len()..new_start].copy_from_slice(b"\r\n\r\n");
    }
}

#[inline]
fn push_response_head(out: &mut Vec<u8>, status_code: u16, close_conn: bool, body_len: usize) {
    let prefix: &[u8] = match (status_code, close_conn) {
        (200, false) => b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ",
        (201, false) => b"HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: ",
        (400, false) => b"HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: ",
        (401, false) => b"HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: ",
        (404, false) => b"HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: ",
        (500, false) => b"HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: ",
        (503, false) => b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: ",
        (200, true) => b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
        (201, true) => b"HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
        (400, true) => b"HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
        (401, true) => b"HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
        (404, true) => b"HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
        (500, true) => b"HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
        _ => b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
    };
    out.extend_from_slice(prefix);
    push_u64(out, body_len as u64);
    out.extend_from_slice(b"\r\n\r\n");
}
