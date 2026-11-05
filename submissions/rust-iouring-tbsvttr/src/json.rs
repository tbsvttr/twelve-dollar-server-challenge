use crate::db::{TvccFeedResult, TvccSinglePostResult};
use crate::sys::{CLOCK_REALTIME, clock_gettime, timespec, word_has_json_special};

pub(crate) const DIGIT_PAIRS: &[u8; 200] = b"\
0001020304050607080910111213141516171819\
2021222324252627282930313233343536373839\
4041424344454647484950515253545556575859\
6061626364656667686970717273747576777879\
8081828384858687888990919293949596979899";

const fn build_esc_table() -> [u8; 256] {
    let mut t = [0u8; 256];
    let mut i = 0;
    while i < 0x20 {
        t[i] = 1;
        i += 1;
    }
    t[b'"' as usize] = 1;
    t[b'\\' as usize] = 1;
    t
}

static ESC_TABLE: [u8; 256] = build_esc_table();

pub const INT_BOUND: usize = 20;

#[inline(always)]
pub const fn esc_bound(n: usize) -> usize {
    6 * n
}

pub struct JsonCur {
    p: *mut u8,
    end: *mut u8,
}

#[inline(always)]
pub fn fill_json(out: &mut Vec<u8>, bound: usize, f: impl FnOnce(&mut JsonCur)) {
    out.reserve(bound);
    let len = out.len();
    unsafe {
        let base = out.as_mut_ptr();
        let mut c = JsonCur {
            p: base.add(len),
            end: base.add(len + bound),
        };
        f(&mut c);
        debug_assert!(c.p <= c.end, "fill_json bound exceeded");
        out.set_len(c.p.offset_from(base) as usize);
    }
}

impl JsonCur {
    #[inline(always)]
    pub fn lit(&mut self, s: &[u8]) {
        debug_assert!(self.p as usize + s.len() <= self.end as usize);
        unsafe {
            std::ptr::copy_nonoverlapping(s.as_ptr(), self.p, s.len());
            self.p = self.p.add(s.len());
        }
    }

    #[inline(always)]
    pub fn byte(&mut self, b: u8) {
        debug_assert!(self.p < self.end);
        unsafe {
            *self.p = b;
            self.p = self.p.add(1);
        }
    }

    #[inline(always)]
    pub fn i64(&mut self, v: i64) {
        debug_assert!(self.p as usize + INT_BOUND <= self.end as usize);
        let mut buf = [0u8; 40];
        let mut i = 20usize;
        let mut n = v.unsigned_abs();
        while n >= 100 {
            let r = ((n % 100) as usize) * 2;
            n /= 100;
            i -= 2;
            buf[i] = DIGIT_PAIRS[r];
            buf[i + 1] = DIGIT_PAIRS[r + 1];
        }
        if n >= 10 {
            let r = (n as usize) * 2;
            i -= 2;
            buf[i] = DIGIT_PAIRS[r];
            buf[i + 1] = DIGIT_PAIRS[r + 1];
        } else {
            i -= 1;
            buf[i] = b'0' + n as u8;
        }
        if v < 0 {
            i -= 1;
            buf[i] = b'-';
        }
        unsafe {
            std::ptr::copy_nonoverlapping(buf.as_ptr().add(i), self.p, INT_BOUND);
            self.p = self.p.add(20 - i);
        }
    }

    #[inline]
    pub fn esc(&mut self, s: &[u8]) {
        debug_assert!(self.p as usize + esc_bound(s.len()) <= self.end as usize);
        let mut i = 0usize;
        #[cfg(target_arch = "x86_64")]
        {
            #[cfg(target_feature = "avx2")]
            while i + 32 <= s.len() {
                let m = unsafe { simd::store_check32(s.as_ptr().add(i), self.p) };
                i += self.chunk_tail(s, i, 32, m);
            }
            while i + 16 <= s.len() {
                let m = unsafe { simd::store_check16(s.as_ptr().add(i), self.p) };
                i += self.chunk_tail(s, i, 16, m);
            }
        }
        while i + 8 <= s.len() {
            let w = u64::from_le_bytes(s[i..i + 8].try_into().unwrap());
            if word_has_json_special(w) != 0 {
                for &c in &s[i..i + 8] {
                    self.esc_byte(c);
                }
            } else {
                unsafe {
                    std::ptr::write_unaligned(self.p as *mut u64, w.to_le());
                    self.p = self.p.add(8);
                }
            }
            i += 8;
        }
        for &c in &s[i..] {
            self.esc_byte(c);
        }
    }

    #[inline(always)]
    #[allow(dead_code)]
    fn chunk_tail(&mut self, s: &[u8], i: usize, n: usize, m: u32) -> usize {
        if m == 0 {
            unsafe { self.p = self.p.add(n) };
        } else {
            let k = m.trailing_zeros() as usize;
            unsafe { self.p = self.p.add(k) };
            for &c in &s[i + k..i + n] {
                self.esc_byte(c);
            }
        }
        n
    }

    #[inline(always)]
    fn esc_byte(&mut self, c: u8) {
        if ESC_TABLE[c as usize] == 0 {
            self.byte(c);
        } else {
            self.esc_special(c);
        }
    }

    #[cold]
    fn esc_special(&mut self, c: u8) {
        const HEX: &[u8; 16] = b"0123456789abcdef";
        match c {
            b'"' => self.lit(b"\\\""),
            b'\\' => self.lit(b"\\\\"),
            b'\n' => self.lit(b"\\n"),
            b'\r' => self.lit(b"\\r"),
            b'\t' => self.lit(b"\\t"),
            0x08 => self.lit(b"\\b"),
            0x0c => self.lit(b"\\f"),
            _ => self.lit(&[
                b'\\',
                b'u',
                b'0',
                b'0',
                HEX[(c >> 4) as usize],
                HEX[(c & 0x0f) as usize],
            ]),
        }
    }
}

#[cfg(target_arch = "x86_64")]
mod simd {
    use std::arch::x86_64::*;

    #[inline(always)]
    pub unsafe fn store_check16(src: *const u8, dst: *mut u8) -> u32 {
        let v = unsafe { _mm_loadu_si128(src as *const __m128i) };
        unsafe { _mm_storeu_si128(dst as *mut __m128i, v) };
        let ctl = unsafe { _mm_cmpeq_epi8(_mm_min_epu8(v, _mm_set1_epi8(0x1f)), v) };
        let q = unsafe { _mm_cmpeq_epi8(v, _mm_set1_epi8(b'"' as i8)) };
        let b = unsafe { _mm_cmpeq_epi8(v, _mm_set1_epi8(b'\\' as i8)) };
        unsafe { _mm_movemask_epi8(_mm_or_si128(ctl, _mm_or_si128(q, b))) as u32 }
    }

    #[cfg(target_feature = "avx2")]
    #[inline(always)]
    pub unsafe fn store_check32(src: *const u8, dst: *mut u8) -> u32 {
        let v = unsafe { _mm256_loadu_si256(src as *const __m256i) };
        unsafe { _mm256_storeu_si256(dst as *mut __m256i, v) };
        let ctl = unsafe { _mm256_cmpeq_epi8(_mm256_min_epu8(v, _mm256_set1_epi8(0x1f)), v) };
        let q = unsafe { _mm256_cmpeq_epi8(v, _mm256_set1_epi8(b'"' as i8)) };
        let b = unsafe { _mm256_cmpeq_epi8(v, _mm256_set1_epi8(b'\\' as i8)) };
        unsafe { _mm256_movemask_epi8(_mm256_or_si256(ctl, _mm256_or_si256(q, b))) as u32 }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BodyError {
    MalformedJson,
    MissingOrEmpty,
    TooLong,
}

#[inline]
pub fn push_u64(out: &mut Vec<u8>, mut val: u64) {
    if val < 10 {
        out.push(b'0' + val as u8);
        return;
    }
    let mut tmp = [0u8; 20];
    let mut idx = 20usize;
    while val >= 100 {
        let rem = ((val % 100) as usize) * 2;
        val /= 100;
        idx -= 2;
        tmp[idx] = DIGIT_PAIRS[rem];
        tmp[idx + 1] = DIGIT_PAIRS[rem + 1];
    }
    if val < 10 {
        idx -= 1;
        tmp[idx] = b'0' + val as u8;
    } else {
        let rem = (val as usize) * 2;
        idx -= 2;
        tmp[idx] = DIGIT_PAIRS[rem];
        tmp[idx + 1] = DIGIT_PAIRS[rem + 1];
    }
    out.extend_from_slice(&tmp[idx..]);
}

#[inline]
pub fn push_i64(out: &mut Vec<u8>, val: i64) {
    if val < 0 {
        out.push(b'-');
        push_u64(out, val.wrapping_neg() as u64);
    } else {
        push_u64(out, val as u64);
    }
}

#[inline]
pub fn write_single_post_json(
    out: &mut Vec<u8>,
    id: i64,
    body: &[u8],
    created_at: &[u8],
    author: &[u8],
    like_count: i64,
) {
    let bound = 128 + esc_bound(body.len() + created_at.len() + author.len());
    fill_json(out, bound, |c| {
        c.lit(b"{\"post\":{\"id\":");
        c.i64(id);
        c.lit(b",\"body\":\"");
        c.esc(body);
        c.lit(b"\",\"created_at\":\"");
        c.esc(created_at);
        c.lit(b"\",\"author\":\"");
        c.esc(author);
        c.lit(b"\",\"like_count\":");
        c.i64(like_count);
        c.lit(b"}}");
    });
}

#[inline]
pub fn write_single_post_result(out: &mut Vec<u8>, post: &TvccSinglePostResult) {
    write_single_post_json(
        out,
        post.id,
        &post.body[..post.body_len as usize],
        &post.created_at[..post.created_len as usize],
        &post.author[..post.author_len as usize],
        post.like_count,
    );
}

#[inline]
pub fn write_feed_result(out: &mut Vec<u8>, feed: &TvccFeedResult) {
    const ROW_FIXED: usize =
        b",{\"id\":,\"body\":\"\",\"created_at\":\"\",\"author\":\"\",\"like_count\":}".len()
            + 2 * INT_BOUND;
    let count = feed.count as usize;
    let pool = &feed.text[..feed.text_used as usize];
    let bound = b"{\"posts\":[]}".len() + count * ROW_FIXED + esc_bound(pool.len());
    fill_json(out, bound, |c| {
        c.lit(b"{\"posts\":[");
        for (idx, row) in feed.rows[..count].iter().enumerate() {
            if idx > 0 {
                c.byte(b',');
            }
            c.lit(b"{\"id\":");
            c.i64(row.id);
            c.lit(b",\"body\":\"");
            let b_start = row.body_off as usize;
            let b_end = b_start + row.body_len as usize;
            c.esc(&pool[b_start..b_end]);
            c.lit(b"\",\"created_at\":\"");
            let c_start = row.created_off as usize;
            let c_end = c_start + row.created_len as usize;
            c.esc(&pool[c_start..c_end]);
            c.lit(b"\",\"author\":\"");
            let a_start = row.author_off as usize;
            let a_end = a_start + row.author_len as usize;
            c.esc(&pool[a_start..a_end]);
            c.lit(b"\",\"like_count\":");
            c.i64(row.like_count);
            c.byte(b'}');
        }
        c.lit(b"]}");
    });
}

#[inline]
pub fn write_like_json(out: &mut Vec<u8>, already_liked: bool, post_id: i64) {
    if already_liked {
        out.extend_from_slice(b"{\"liked\":true,\"already_liked\":true,\"post_id\":");
    } else {
        out.extend_from_slice(b"{\"liked\":true,\"already_liked\":false,\"post_id\":");
    }
    push_i64(out, post_id);
    out.push(b'}');
}

#[inline]
pub fn write_health_json(out: &mut Vec<u8>, uptime_s: u64) {
    out.extend_from_slice(b"{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":");
    push_u64(out, uptime_s);
    out.push(b'}');
}

#[allow(dead_code)]
#[inline]
pub fn format_utc_iso_ms() -> [u8; 24] {
    let mut ts = timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    unsafe {
        clock_gettime(CLOCK_REALTIME, &mut ts);
    }
    format_utc_iso_ms_from(ts)
}

#[inline]
pub fn format_utc_iso_ms_from(ts: timespec) -> [u8; 24] {
    let secs = ts.tv_sec.max(0) as u64;
    let millis = (ts.tv_nsec.max(0) as u64 / 1_000_000) % 1000;

    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let hour = (rem / 3600) as usize;
    let min = ((rem % 3600) / 60) as usize;
    let sec = (rem % 60) as usize;

    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let mut year = (yoe as i64 + era * 400) as u32;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as usize;
    let month = (if mp < 10 { mp + 3 } else { mp - 9 }) as usize;
    if month <= 2 {
        year += 1;
    }

    let y_hi = ((year / 100) as usize) * 2;
    let y_lo = ((year % 100) as usize) * 2;
    let mo2 = month * 2;
    let d2 = day * 2;
    let h2 = hour * 2;
    let mi2 = min * 2;
    let s2 = sec * 2;
    let ms_hi = (millis / 100) as u8;
    let ms_lo = ((millis % 100) as usize) * 2;

    [
        DIGIT_PAIRS[y_hi],
        DIGIT_PAIRS[y_hi + 1],
        DIGIT_PAIRS[y_lo],
        DIGIT_PAIRS[y_lo + 1],
        b'-',
        DIGIT_PAIRS[mo2],
        DIGIT_PAIRS[mo2 + 1],
        b'-',
        DIGIT_PAIRS[d2],
        DIGIT_PAIRS[d2 + 1],
        b'T',
        DIGIT_PAIRS[h2],
        DIGIT_PAIRS[h2 + 1],
        b':',
        DIGIT_PAIRS[mi2],
        DIGIT_PAIRS[mi2 + 1],
        b':',
        DIGIT_PAIRS[s2],
        DIGIT_PAIRS[s2 + 1],
        b'.',
        b'0' + ms_hi,
        DIGIT_PAIRS[ms_lo],
        DIGIT_PAIRS[ms_lo + 1],
        b'Z',
    ]
}

/* =========================================================================
 * Strict RFC 8259 JSON Body Parser for POST /posts
 * ========================================================================= */

pub fn extract_and_validate_post_body<'a>(
    raw: &[u8],
    scratch: &'a mut Vec<u8>,
) -> Result<&'a [u8], BodyError> {
    let mut cur = skip_ws(raw, 0);
    if cur >= raw.len() || raw[cur] != b'{' {
        return Err(BodyError::MalformedJson);
    }
    cur = skip_ws(raw, cur + 1);

    scratch.clear();
    let mut found_body_str = false;
    let mut found_body_non_str = false;

    if cur < raw.len() && raw[cur] == b'}' {
        cur = skip_ws(raw, cur + 1);
        if cur != raw.len() {
            return Err(BodyError::MalformedJson);
        }
        return Err(BodyError::MissingOrEmpty);
    }

    loop {
        if cur >= raw.len() || raw[cur] != b'"' {
            return Err(BodyError::MalformedJson);
        }
        let (key_is_body, after_key) = parse_json_key_is_body(raw, cur)?;
        cur = skip_ws(raw, after_key);
        if cur >= raw.len() || raw[cur] != b':' {
            return Err(BodyError::MalformedJson);
        }
        cur = skip_ws(raw, cur + 1);
        if cur >= raw.len() {
            return Err(BodyError::MalformedJson);
        }

        if key_is_body {
            if raw[cur] == b'"' {
                scratch.clear();
                cur = decode_json_string_into(raw, cur, scratch)?;
                found_body_str = true;
                found_body_non_str = false;
            } else {
                cur = skip_json_value(raw, cur, 0)?;
                found_body_str = false;
                found_body_non_str = true;
            }
        } else {
            cur = skip_json_value(raw, cur, 0)?;
        }

        cur = skip_ws(raw, cur);
        if cur >= raw.len() {
            return Err(BodyError::MalformedJson);
        }
        match raw[cur] {
            b',' => {
                cur = skip_ws(raw, cur + 1);
            }
            b'}' => {
                cur = skip_ws(raw, cur + 1);
                break;
            }
            _ => return Err(BodyError::MalformedJson),
        }
    }

    if cur != raw.len() {
        return Err(BodyError::MalformedJson);
    }
    if found_body_non_str || !found_body_str {
        return Err(BodyError::MissingOrEmpty);
    }

    let text = std::str::from_utf8(scratch.as_slice()).map_err(|_| BodyError::MalformedJson)?;
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err(BodyError::MissingOrEmpty);
    }
    if trimmed.chars().count() > 500 {
        return Err(BodyError::TooLong);
    }

    let start_off = trimmed.as_ptr() as usize - text.as_ptr() as usize;
    let end_off = start_off + trimmed.len();
    Ok(&scratch[start_off..end_off])
}

#[inline]
fn skip_ws(b: &[u8], mut i: usize) -> usize {
    while i < b.len() {
        match b[i] {
            b' ' | b'\t' | b'\r' | b'\n' => i += 1,
            _ => break,
        }
    }
    i
}

fn parse_json_key_is_body(b: &[u8], quote_idx: usize) -> Result<(bool, usize), BodyError> {
    if b.get(quote_idx..quote_idx + 6) == Some(b"\"body\"") {
        return Ok((true, quote_idx + 6));
    }
    let mut tmp = Vec::with_capacity(16);
    let next = decode_json_string_into(b, quote_idx, &mut tmp)?;
    Ok((tmp.as_slice() == b"body", next))
}

fn decode_json_string_into(
    b: &[u8],
    quote_idx: usize,
    out: &mut Vec<u8>,
) -> Result<usize, BodyError> {
    let mut i = quote_idx + 1;
    let mut chunk_start = i;

    while i < b.len() {
        let c = b[i];
        if c == b'"' {
            if i > chunk_start {
                let slice = &b[chunk_start..i];
                if std::str::from_utf8(slice).is_err() {
                    return Err(BodyError::MalformedJson);
                }
                out.extend_from_slice(slice);
            }
            return Ok(i + 1);
        }
        if c < 0x20 {
            return Err(BodyError::MalformedJson);
        }
        if c != b'\\' {
            i += 1;
            continue;
        }

        if i > chunk_start {
            let slice = &b[chunk_start..i];
            if std::str::from_utf8(slice).is_err() {
                return Err(BodyError::MalformedJson);
            }
            out.extend_from_slice(slice);
        }
        i += 1;
        if i >= b.len() {
            return Err(BodyError::MalformedJson);
        }
        match b[i] {
            b'"' => {
                out.push(b'"');
                i += 1;
            }
            b'\\' => {
                out.push(b'\\');
                i += 1;
            }
            b'/' => {
                out.push(b'/');
                i += 1;
            }
            b'b' => {
                out.push(0x08);
                i += 1;
            }
            b'f' => {
                out.push(0x0c);
                i += 1;
            }
            b'n' => {
                out.push(b'\n');
                i += 1;
            }
            b'r' => {
                out.push(b'\r');
                i += 1;
            }
            b't' => {
                out.push(b'\t');
                i += 1;
            }
            b'u' => {
                if i + 5 > b.len() {
                    return Err(BodyError::MalformedJson);
                }
                let code = parse_hex4(&b[i + 1..i + 5])?;
                i += 5;
                let ch = if (0xD800..=0xDBFF).contains(&code) {
                    if i + 6 <= b.len() && b[i] == b'\\' && b[i + 1] == b'u' {
                        let low = parse_hex4(&b[i + 2..i + 6])?;
                        if (0xDC00..=0xDFFF).contains(&low) {
                            i += 6;
                            let combined =
                                0x10000 + (((code as u32 - 0xD800) << 10) | (low as u32 - 0xDC00));
                            char::from_u32(combined).unwrap_or('\u{FFFD}')
                        } else {
                            '\u{FFFD}'
                        }
                    } else {
                        '\u{FFFD}'
                    }
                } else if (0xDC00..=0xDFFF).contains(&code) {
                    '\u{FFFD}'
                } else {
                    char::from_u32(code as u32).unwrap_or('\u{FFFD}')
                };
                let mut utf8 = [0u8; 4];
                out.extend_from_slice(ch.encode_utf8(&mut utf8).as_bytes());
            }
            _ => return Err(BodyError::MalformedJson),
        }
        chunk_start = i;
    }

    Err(BodyError::MalformedJson)
}

#[inline]
fn parse_hex4(four: &[u8]) -> Result<u16, BodyError> {
    let mut val = 0u16;
    for &b in four {
        let d = match b {
            b'0'..=b'9' => b - b'0',
            b'a'..=b'f' => b - b'a' + 10,
            b'A'..=b'F' => b - b'A' + 10,
            _ => return Err(BodyError::MalformedJson),
        };
        val = (val << 4) | (d as u16);
    }
    Ok(val)
}

fn skip_json_value(b: &[u8], i: usize, depth: usize) -> Result<usize, BodyError> {
    if depth > 64 || i >= b.len() {
        return Err(BodyError::MalformedJson);
    }
    match b[i] {
        b'"' => skip_json_string(b, i),
        b'{' => {
            let mut cur = skip_ws(b, i + 1);
            if cur < b.len() && b[cur] == b'}' {
                return Ok(cur + 1);
            }
            loop {
                if cur >= b.len() || b[cur] != b'"' {
                    return Err(BodyError::MalformedJson);
                }
                cur = skip_json_string(b, cur)?;
                cur = skip_ws(b, cur);
                if cur >= b.len() || b[cur] != b':' {
                    return Err(BodyError::MalformedJson);
                }
                cur = skip_ws(b, cur + 1);
                cur = skip_json_value(b, cur, depth + 1)?;
                cur = skip_ws(b, cur);
                if cur >= b.len() {
                    return Err(BodyError::MalformedJson);
                }
                match b[cur] {
                    b',' => cur = skip_ws(b, cur + 1),
                    b'}' => return Ok(cur + 1),
                    _ => return Err(BodyError::MalformedJson),
                }
            }
        }
        b'[' => {
            let mut cur = skip_ws(b, i + 1);
            if cur < b.len() && b[cur] == b']' {
                return Ok(cur + 1);
            }
            loop {
                cur = skip_json_value(b, cur, depth + 1)?;
                cur = skip_ws(b, cur);
                if cur >= b.len() {
                    return Err(BodyError::MalformedJson);
                }
                match b[cur] {
                    b',' => cur = skip_ws(b, cur + 1),
                    b']' => return Ok(cur + 1),
                    _ => return Err(BodyError::MalformedJson),
                }
            }
        }
        b't' => {
            if b.get(i..i + 4) == Some(b"true") {
                Ok(i + 4)
            } else {
                Err(BodyError::MalformedJson)
            }
        }
        b'f' => {
            if b.get(i..i + 5) == Some(b"false") {
                Ok(i + 5)
            } else {
                Err(BodyError::MalformedJson)
            }
        }
        b'n' => {
            if b.get(i..i + 4) == Some(b"null") {
                Ok(i + 4)
            } else {
                Err(BodyError::MalformedJson)
            }
        }
        b'-' | b'0'..=b'9' => skip_json_number(b, i),
        _ => Err(BodyError::MalformedJson),
    }
}

fn skip_json_string(b: &[u8], quote_idx: usize) -> Result<usize, BodyError> {
    let mut i = quote_idx + 1;
    let mut chunk_start = i;
    while i < b.len() {
        let c = b[i];
        if c == b'"' {
            if std::str::from_utf8(&b[chunk_start..i]).is_err() {
                return Err(BodyError::MalformedJson);
            }
            return Ok(i + 1);
        }
        if c < 0x20 {
            return Err(BodyError::MalformedJson);
        }
        if c != b'\\' {
            i += 1;
            continue;
        }
        if std::str::from_utf8(&b[chunk_start..i]).is_err() {
            return Err(BodyError::MalformedJson);
        }
        i += 1;
        if i >= b.len() {
            return Err(BodyError::MalformedJson);
        }
        match b[i] {
            b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't' => i += 1,
            b'u' => {
                if i + 5 > b.len() {
                    return Err(BodyError::MalformedJson);
                }
                let _ = parse_hex4(&b[i + 1..i + 5])?;
                i += 5;
            }
            _ => return Err(BodyError::MalformedJson),
        }
        chunk_start = i;
    }
    Err(BodyError::MalformedJson)
}

fn skip_json_number(b: &[u8], mut i: usize) -> Result<usize, BodyError> {
    if b[i] == b'-' {
        i += 1;
        if i >= b.len() {
            return Err(BodyError::MalformedJson);
        }
    }
    match b[i] {
        b'0' => i += 1,
        b'1'..=b'9' => {
            i += 1;
            while i < b.len() && b[i].is_ascii_digit() {
                i += 1;
            }
        }
        _ => return Err(BodyError::MalformedJson),
    }
    if i < b.len() && b[i] == b'.' {
        i += 1;
        if i >= b.len() || !b[i].is_ascii_digit() {
            return Err(BodyError::MalformedJson);
        }
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
    }
    if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
        i += 1;
        if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
            i += 1;
        }
        if i >= b.len() || !b[i].is_ascii_digit() {
            return Err(BodyError::MalformedJson);
        }
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
    }
    Ok(i)
}
