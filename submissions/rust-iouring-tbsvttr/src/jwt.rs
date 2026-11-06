use crate::sys::find_byte;

const STD_HS256_HEADER_B64: &[u8] = b"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

const SHA256_INIT: [u32; 8] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

const SHA256_K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

#[inline]
fn sha256_compress(state: &mut [u32; 8], block: &[u8; 64]) {
    #[cfg(target_arch = "x86_64")]
    {
        static HAS_SHANI: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);
        let flag = HAS_SHANI.load(std::sync::atomic::Ordering::Relaxed);
        let supported = if flag == 0 {
            let ok = std::is_x86_feature_detected!("sha")
                && std::is_x86_feature_detected!("sse4.1")
                && std::is_x86_feature_detected!("ssse3");
            HAS_SHANI.store(if ok { 1 } else { 2 }, std::sync::atomic::Ordering::Relaxed);
            ok
        } else {
            flag == 1
        };
        if supported {
            unsafe {
                sha256_compress_shani(state, block);
            }
            return;
        }
    }
    sha256_compress_scalar(state, block);
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "sha,sse4.1,ssse3")]
unsafe fn compress_m_shani(
    state: &mut [u32; 8],
    mut m0: core::arch::x86_64::__m128i,
    mut m1: core::arch::x86_64::__m128i,
    mut m2: core::arch::x86_64::__m128i,
    mut m3: core::arch::x86_64::__m128i,
) {
    unsafe {
        use core::arch::x86_64::*;

        let s0 = _mm_loadu_si128(state.as_ptr().cast());
        let s1 = _mm_loadu_si128(state.as_ptr().add(4).cast());
        let tmp = _mm_shuffle_epi32(s0, 0xB1);
        let efgh = _mm_shuffle_epi32(s1, 0x1B);
        let mut abef = _mm_alignr_epi8(tmp, efgh, 8);
        let mut cdgh = _mm_blend_epi16(efgh, tmp, 0xF0);
        let abef_save = abef;
        let cdgh_save = cdgh;

        let load_k = |idx: usize| -> __m128i {
            _mm_loadu_si128(SHA256_K.as_ptr().add(idx).cast())
        };

        macro_rules! rnd4 {
            ($m_cur:ident, $k_idx:expr) => {{
                let wk = _mm_add_epi32($m_cur, load_k($k_idx));
                cdgh = _mm_sha256rnds2_epu32(cdgh, abef, wk);
                abef = _mm_sha256rnds2_epu32(abef, cdgh, _mm_shuffle_epi32(wk, 0x0E));
            }};
            ($m0:ident, $m1:ident, $m2:ident, $m3:ident, $k_idx:expr) => {{
                let wk = _mm_add_epi32($m0, load_k($k_idx));
                cdgh = _mm_sha256rnds2_epu32(cdgh, abef, wk);
                $m0 = _mm_sha256msg1_epu32($m0, $m1);
                abef = _mm_sha256rnds2_epu32(abef, cdgh, _mm_shuffle_epi32(wk, 0x0E));
                $m0 = _mm_add_epi32($m0, _mm_alignr_epi8($m3, $m2, 4));
                $m0 = _mm_sha256msg2_epu32($m0, $m3);
            }};
        }

        rnd4!(m0, m1, m2, m3, 0);
        rnd4!(m1, m2, m3, m0, 4);
        rnd4!(m2, m3, m0, m1, 8);
        rnd4!(m3, m0, m1, m2, 12);
        rnd4!(m0, m1, m2, m3, 16);
        rnd4!(m1, m2, m3, m0, 20);
        rnd4!(m2, m3, m0, m1, 24);
        rnd4!(m3, m0, m1, m2, 28);
        rnd4!(m0, m1, m2, m3, 32);
        rnd4!(m1, m2, m3, m0, 36);
        rnd4!(m2, m3, m0, m1, 40);
        rnd4!(m3, m0, m1, m2, 44);
        rnd4!(m0, 48);
        rnd4!(m1, 52);
        rnd4!(m2, 56);
        rnd4!(m3, 60);

        abef = _mm_add_epi32(abef, abef_save);
        cdgh = _mm_add_epi32(cdgh, cdgh_save);

        let feba = _mm_shuffle_epi32(abef, 0x1B);
        let dchg = _mm_shuffle_epi32(cdgh, 0xB1);
        let out0 = _mm_blend_epi16(feba, dchg, 0xF0);
        let out1 = _mm_alignr_epi8(dchg, feba, 8);
        _mm_storeu_si128(state.as_mut_ptr().cast(), out0);
        _mm_storeu_si128(state.as_mut_ptr().add(4).cast(), out1);
    }
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "sha,sse4.1,ssse3")]
unsafe fn sha256_compress_shani(state: &mut [u32; 8], block: &[u8; 64]) {
    unsafe {
        use core::arch::x86_64::*;
        let bswap = _mm_set_epi8(12, 13, 14, 15, 8, 9, 10, 11, 4, 5, 6, 7, 0, 1, 2, 3);
        let ptr = block.as_ptr();
        compress_m_shani(
            state,
            _mm_shuffle_epi8(_mm_loadu_si128(ptr.cast()), bswap),
            _mm_shuffle_epi8(_mm_loadu_si128(ptr.add(16).cast()), bswap),
            _mm_shuffle_epi8(_mm_loadu_si128(ptr.add(32).cast()), bswap),
            _mm_shuffle_epi8(_mm_loadu_si128(ptr.add(48).cast()), bswap),
        );
    }
}

#[inline]
fn sha256_compress_scalar(state: &mut [u32; 8], block: &[u8; 64]) {
    let mut w = [0u32; 64];
    for i in 0..16 {
        let j = i * 4;
        w[i] = u32::from_be_bytes([block[j], block[j + 1], block[j + 2], block[j + 3]]);
    }
    for i in 16..64 {
        let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
        let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16]
            .wrapping_add(s0)
            .wrapping_add(w[i - 7])
            .wrapping_add(s1);
    }

    let mut a = state[0];
    let mut b = state[1];
    let mut c = state[2];
    let mut d = state[3];
    let mut e = state[4];
    let mut f = state[5];
    let mut g = state[6];
    let mut h = state[7];

    for i in 0..64 {
        let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
        let ch = (e & f) ^ ((!e) & g);
        let temp1 = h
            .wrapping_add(s1)
            .wrapping_add(ch)
            .wrapping_add(SHA256_K[i])
            .wrapping_add(w[i]);
        let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
        let maj = (a & b) ^ (a & c) ^ (b & c);
        let temp2 = s0.wrapping_add(maj);

        h = g;
        g = f;
        f = e;
        e = d.wrapping_add(temp1);
        d = c;
        c = b;
        b = a;
        a = temp1.wrapping_add(temp2);
    }

    state[0] = state[0].wrapping_add(a);
    state[1] = state[1].wrapping_add(b);
    state[2] = state[2].wrapping_add(c);
    state[3] = state[3].wrapping_add(d);
    state[4] = state[4].wrapping_add(e);
    state[5] = state[5].wrapping_add(f);
    state[6] = state[6].wrapping_add(g);
    state[7] = state[7].wrapping_add(h);
}

fn sha256_with_midstate(mut state: [u32; 8], prefix_bytes: u64, data: &[u8]) -> [u8; 32] {
    let mut chunks = data.chunks_exact(64);
    for chunk in &mut chunks {
        let mut blk = [0u8; 64];
        blk.copy_from_slice(chunk);
        sha256_compress(&mut state, &blk);
    }
    let rem = chunks.remainder();
    let total_bits = (prefix_bytes + data.len() as u64) * 8;

    let mut pad = [0u8; 64];
    pad[..rem.len()].copy_from_slice(rem);
    pad[rem.len()] = 0x80;

    if rem.len() >= 56 {
        sha256_compress(&mut state, &pad);
        pad = [0u8; 64];
    }
    pad[56..64].copy_from_slice(&total_bits.to_be_bytes());
    sha256_compress(&mut state, &pad);

    let mut out = [0u8; 32];
    for (i, &word) in state.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&word.to_be_bytes());
    }
    out
}

const fn build_b64url_lut() -> [u8; 256] {
    let mut table = [0xFFu8; 256];
    let mut c = b'A';
    while c <= b'Z' {
        table[c as usize] = c - b'A';
        c += 1;
    }
    let mut c = b'a';
    while c <= b'z' {
        table[c as usize] = c - b'a' + 26;
        c += 1;
    }
    let mut c = b'0';
    while c <= b'9' {
        table[c as usize] = c - b'0' + 52;
        c += 1;
    }
    table[b'-' as usize] = 62;
    table[b'_' as usize] = 63;
    table
}

const B64URL_LUT: [u8; 256] = build_b64url_lut();

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JwtError {
    MissingToken,
    InvalidOrExpired,
    InvalidPayload,
}

pub struct VerifiedClaims {
    pub user_id: i64,
    pub username_len: usize,
    pub username: [u8; 128],
}

#[derive(Clone, Copy)]
pub struct JwtVerifier {
    inner_midstate: [u32; 8],
    outer_midstate: [u32; 8],
}

impl JwtVerifier {
    pub fn new(secret: &[u8]) -> Self {
        let mut key_block = [0u8; 64];
        if secret.len() <= 64 {
            key_block[..secret.len()].copy_from_slice(secret);
        } else {
            let digest = sha256_with_midstate(SHA256_INIT, 0, secret);
            key_block[..32].copy_from_slice(&digest);
        }

        let mut ipad = [0x36u8; 64];
        let mut opad = [0x5cu8; 64];
        for i in 0..64 {
            ipad[i] ^= key_block[i];
            opad[i] ^= key_block[i];
        }

        let mut inner_midstate = SHA256_INIT;
        sha256_compress(&mut inner_midstate, &ipad);

        let mut outer_midstate = SHA256_INIT;
        sha256_compress(&mut outer_midstate, &opad);

        Self {
            inner_midstate,
            outer_midstate,
        }
    }

    pub fn verify_bearer(
        &self,
        auth_header: Option<&[u8]>,
        now_s: i64,
    ) -> Result<VerifiedClaims, JwtError> {
        let raw_hdr = auth_header.ok_or(JwtError::MissingToken)?;
        let hdr = trim_ascii(raw_hdr);
        if hdr.len() < 7 || !hdr[..7].eq_ignore_ascii_case(b"Bearer ") {
            return Err(JwtError::MissingToken);
        }
        let token = trim_ascii(&hdr[7..]);
        if token.is_empty() {
            return Err(JwtError::MissingToken);
        }
        self.verify_token(token, now_s)
    }

    pub fn verify_token(&self, token: &[u8], now_s: i64) -> Result<VerifiedClaims, JwtError> {
        let dot1 = find_byte(b'.', token).ok_or(JwtError::InvalidOrExpired)?;
        let rest = &token[dot1 + 1..];
        let dot2_rel = find_byte(b'.', rest).ok_or(JwtError::InvalidOrExpired)?;
        let dot2 = dot1 + 1 + dot2_rel;

        let hdr_b64 = &token[..dot1];
        let payload_b64 = &token[dot1 + 1..dot2];
        let sig_b64 = &token[dot2 + 1..];

        if hdr_b64.is_empty() || payload_b64.is_empty() || sig_b64.len() != 43 {
            return Err(JwtError::InvalidOrExpired);
        }

        if hdr_b64 != STD_HS256_HEADER_B64 {
            let mut hdr_buf = [0u8; 256];
            let hdr_len = decode_b64url(hdr_b64, &mut hdr_buf).ok_or(JwtError::InvalidOrExpired)?;
            if !header_has_hs256(&hdr_buf[..hdr_len]) {
                return Err(JwtError::InvalidOrExpired);
            }
        }

        let mut sig_bytes = [0u8; 32];
        let sig_len = decode_b64url(sig_b64, &mut sig_bytes).ok_or(JwtError::InvalidOrExpired)?;
        if sig_len != 32 {
            return Err(JwtError::InvalidOrExpired);
        }

        let signing_input = &token[..dot2];
        let inner_digest = sha256_with_midstate(self.inner_midstate, 64, signing_input);
        let expected_mac = sha256_with_midstate(self.outer_midstate, 64, &inner_digest);

        let mut diff = 0u8;
        for i in 0..32 {
            diff |= sig_bytes[i] ^ expected_mac[i];
        }
        if diff != 0 {
            return Err(JwtError::InvalidOrExpired);
        }

        let mut payload_buf = [0u8; 512];
        let payload_len =
            decode_b64url(payload_b64, &mut payload_buf).ok_or(JwtError::InvalidOrExpired)?;
        parse_payload_claims(&payload_buf[..payload_len], now_s)
    }
}

#[inline]
fn trim_ascii(mut s: &[u8]) -> &[u8] {
    while let Some((&first, rest)) = s.split_first() {
        if first == b' ' || first == b'\t' {
            s = rest;
        } else {
            break;
        }
    }
    while let Some((&last, rest)) = s.split_last() {
        if last == b' ' || last == b'\t' {
            s = rest;
        } else {
            break;
        }
    }
    s
}

fn decode_b64url(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let rem = input.len() & 3;
    if rem == 1 {
        return None;
    }
    let full_quads = input.len() >> 2;
    let needed = full_quads * 3 + if rem == 2 { 1 } else if rem == 3 { 2 } else { 0 };
    if needed > out.len() {
        return None;
    }

    let mut in_idx = 0usize;
    let mut out_idx = 0usize;
    for _ in 0..full_quads {
        let a = B64URL_LUT[input[in_idx] as usize];
        let b = B64URL_LUT[input[in_idx + 1] as usize];
        let c = B64URL_LUT[input[in_idx + 2] as usize];
        let d = B64URL_LUT[input[in_idx + 3] as usize];
        if (a | b | c | d) & 0xC0 != 0 {
            return None;
        }
        out[out_idx] = (a << 2) | (b >> 4);
        out[out_idx + 1] = (b << 4) | (c >> 2);
        out[out_idx + 2] = (c << 6) | d;
        in_idx += 4;
        out_idx += 3;
    }

    if rem == 2 {
        let a = B64URL_LUT[input[in_idx] as usize];
        let b = B64URL_LUT[input[in_idx + 1] as usize];
        if (a | b) & 0xC0 != 0 {
            return None;
        }
        out[out_idx] = (a << 2) | (b >> 4);
        out_idx += 1;
    } else if rem == 3 {
        let a = B64URL_LUT[input[in_idx] as usize];
        let b = B64URL_LUT[input[in_idx + 1] as usize];
        let c = B64URL_LUT[input[in_idx + 2] as usize];
        if (a | b | c) & 0xC0 != 0 {
            return None;
        }
        out[out_idx] = (a << 2) | (b >> 4);
        out[out_idx + 1] = (b << 4) | (c >> 2);
        out_idx += 2;
    }

    Some(out_idx)
}

fn header_has_hs256(b: &[u8]) -> bool {
    let mut i = skip_ws(b, 0);
    if i >= b.len() || b[i] != b'{' {
        return false;
    }
    i = skip_ws(b, i + 1);
    let mut is_hs256 = false;
    while i < b.len() && b[i] != b'}' {
        if b[i] != b'"' {
            return false;
        }
        let Some((key, next_i)) = read_raw_json_str(b, i) else {
            return false;
        };
        i = skip_ws(b, next_i);
        if i >= b.len() || b[i] != b':' {
            return false;
        }
        i = skip_ws(b, i + 1);
        if key == b"alg" {
            if i >= b.len() || b[i] != b'"' {
                return false;
            }
            let Some((val, next_v)) = read_raw_json_str(b, i) else {
                return false;
            };
            is_hs256 = val == b"HS256";
            i = next_v;
        } else {
            let Some(next_v) = skip_simple_json_val(b, i) else {
                return false;
            };
            i = next_v;
        }
        i = skip_ws(b, i);
        if i < b.len() && b[i] == b',' {
            i = skip_ws(b, i + 1);
        }
    }
    is_hs256
}

fn parse_payload_claims(b: &[u8], now_s: i64) -> Result<VerifiedClaims, JwtError> {
    let mut i = skip_ws(b, 0);
    if i >= b.len() || b[i] != b'{' {
        return Err(JwtError::InvalidOrExpired);
    }
    i = skip_ws(b, i + 1);

    let mut sub_raw: Option<&[u8]> = None;
    let mut sub_bad_type = false;
    let mut username_raw: Option<&[u8]> = None;
    let mut username_bad_type = false;
    let mut exp_val: Option<i64> = None;
    let mut nbf_val: Option<i64> = None;

    while i < b.len() && b[i] != b'}' {
        if b[i] != b'"' {
            return Err(JwtError::InvalidOrExpired);
        }
        let (key, after_key) = read_raw_json_str(b, i).ok_or(JwtError::InvalidOrExpired)?;
        i = skip_ws(b, after_key);
        if i >= b.len() || b[i] != b':' {
            return Err(JwtError::InvalidOrExpired);
        }
        i = skip_ws(b, i + 1);
        if i >= b.len() {
            return Err(JwtError::InvalidOrExpired);
        }

        match key {
            b"sub" => {
                if b[i] == b'"' {
                    let (val, next_i) = read_raw_json_str(b, i).ok_or(JwtError::InvalidOrExpired)?;
                    sub_raw = Some(val);
                    i = next_i;
                } else {
                    sub_bad_type = true;
                    i = skip_simple_json_val(b, i).ok_or(JwtError::InvalidOrExpired)?;
                }
            }
            b"username" => {
                if b[i] == b'"' {
                    let (val, next_i) = read_raw_json_str(b, i).ok_or(JwtError::InvalidOrExpired)?;
                    username_raw = Some(val);
                    i = next_i;
                } else {
                    username_bad_type = true;
                    i = skip_simple_json_val(b, i).ok_or(JwtError::InvalidOrExpired)?;
                }
            }
            b"exp" => {
                let (val, next_i) = parse_json_i64(b, i).ok_or(JwtError::InvalidOrExpired)?;
                exp_val = Some(val);
                i = next_i;
            }
            b"nbf" => {
                let (val, next_i) = parse_json_i64(b, i).ok_or(JwtError::InvalidOrExpired)?;
                nbf_val = Some(val);
                i = next_i;
            }
            _ => {
                i = skip_simple_json_val(b, i).ok_or(JwtError::InvalidOrExpired)?;
            }
        }

        i = skip_ws(b, i);
        if i < b.len() && b[i] == b',' {
            i = skip_ws(b, i + 1);
        } else if i < b.len() && b[i] == b'}' {
            break;
        } else {
            return Err(JwtError::InvalidOrExpired);
        }
    }

    let exp = exp_val.ok_or(JwtError::InvalidOrExpired)?;
    if now_s >= exp {
        return Err(JwtError::InvalidOrExpired);
    }
    if let Some(nbf) = nbf_val {
        if now_s < nbf {
            return Err(JwtError::InvalidOrExpired);
        }
    }

    if sub_bad_type || username_bad_type {
        return Err(JwtError::InvalidPayload);
    }
    let sub_bytes = sub_raw.ok_or(JwtError::InvalidPayload)?;
    let user_id = parse_positive_i64(sub_bytes).ok_or(JwtError::InvalidPayload)?;
    let uname = username_raw.ok_or(JwtError::InvalidPayload)?;
    if uname.is_empty() || uname.len() > 128 || uname.contains(&b'\\') {
        return Err(JwtError::InvalidPayload);
    }
    let mut claims = VerifiedClaims {
        user_id,
        username_len: uname.len(),
        username: [0u8; 128],
    };
    claims.username[..uname.len()].copy_from_slice(uname);
    Ok(claims)
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

fn read_raw_json_str(b: &[u8], quote_idx: usize) -> Option<(&[u8], usize)> {
    let mut i = quote_idx + 1;
    while i < b.len() {
        match b[i] {
            b'"' => return Some((&b[quote_idx + 1..i], i + 1)),
            b'\\' => {
                i += 2;
            }
            c if c < 0x20 => return None,
            _ => i += 1,
        }
    }
    None
}

fn parse_positive_i64(digits: &[u8]) -> Option<i64> {
    if digits.is_empty() || digits.len() > 19 {
        return None;
    }
    let mut val = 0i64;
    for &c in digits {
        if !c.is_ascii_digit() {
            return None;
        }
        val = val.checked_mul(10)?.checked_add((c - b'0') as i64)?;
    }
    if val >= 1 { Some(val) } else { None }
}

fn parse_json_i64(b: &[u8], mut i: usize) -> Option<(i64, usize)> {
    let neg = if i < b.len() && b[i] == b'-' {
        i += 1;
        true
    } else {
        false
    };
    let start = i;
    let mut val = 0i64;
    while i < b.len() && b[i].is_ascii_digit() {
        val = val.checked_mul(10)?.checked_add((b[i] - b'0') as i64)?;
        i += 1;
    }
    if i == start {
        return None;
    }
    Some((if neg { -val } else { val }, i))
}

fn skip_simple_json_val(b: &[u8], i: usize) -> Option<usize> {
    if i >= b.len() {
        return None;
    }
    match b[i] {
        b'"' => read_raw_json_str(b, i).map(|(_, next)| next),
        b'{' | b'[' => {
            let mut depth = 0usize;
            let mut cur = i;
            while cur < b.len() {
                match b[cur] {
                    b'"' => {
                        let (_, next) = read_raw_json_str(b, cur)?;
                        cur = next;
                        continue;
                    }
                    b'{' | b'[' => depth += 1,
                    b'}' | b']' => {
                        depth -= 1;
                        if depth == 0 {
                            return Some(cur + 1);
                        }
                    }
                    _ => {}
                }
                cur += 1;
            }
            None
        }
        _ => {
            let mut cur = i;
            while cur < b.len()
                && !matches!(b[cur], b',' | b'}' | b']' | b' ' | b'\t' | b'\r' | b'\n')
            {
                cur += 1;
            }
            if cur > i { Some(cur) } else { None }
        }
    }
}
