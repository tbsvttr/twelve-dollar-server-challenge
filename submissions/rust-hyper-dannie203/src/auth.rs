use chrono::Utc;
use hmac::{Hmac, Mac};
use sha2::Sha256;

const B64_CHARS: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

#[inline(always)]
fn encode_base64_url_32(input: &[u8; 32], out: &mut [u8; 43]) {
    let mut in_idx = 0;
    let mut out_idx = 0;
    for _ in 0..10 {
        let b0 = input[in_idx] as usize;
        let b1 = input[in_idx + 1] as usize;
        let b2 = input[in_idx + 2] as usize;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out[out_idx] = B64_CHARS[(n >> 18) & 0x3F];
        out[out_idx + 1] = B64_CHARS[(n >> 12) & 0x3F];
        out[out_idx + 2] = B64_CHARS[(n >> 6) & 0x3F];
        out[out_idx + 3] = B64_CHARS[n & 0x3F];
        in_idx += 3;
        out_idx += 4;
    }
    let b0 = input[30] as usize;
    let b1 = input[31] as usize;
    let n = (b0 << 16) | (b1 << 8);
    out[40] = B64_CHARS[(n >> 18) & 0x3F];
    out[41] = B64_CHARS[(n >> 12) & 0x3F];
    out[42] = B64_CHARS[(n >> 6) & 0x3F];
}

#[inline(always)]
fn decode_b64_char(c: u8) -> Result<u8, ()> {
    match c {
        b'A'..=b'Z' => Ok(c - b'A'),
        b'a'..=b'z' => Ok(c - b'a' + 26),
        b'0'..=b'9' => Ok(c - b'0' + 52),
        b'-' => Ok(62),
        b'_' => Ok(63),
        _ => Err(()),
    }
}

fn base64_url_decode(src: &[u8], out: &mut [u8]) -> Result<usize, ()> {
    let mut out_idx = 0;
    let mut i = 0;
    let len = src.len();

    while i + 4 <= len {
        if out_idx + 3 > out.len() {
            return Err(());
        }

        let b0 = decode_b64_char(src[i])? as u32;
        let b1 = decode_b64_char(src[i + 1])? as u32;
        let b2 = decode_b64_char(src[i + 2])? as u32;
        let b3 = decode_b64_char(src[i + 3])? as u32;

        let n = (b0 << 18) | (b1 << 12) | (b2 << 6) | b3;
        out[out_idx] = (n >> 16) as u8;
        out[out_idx + 1] = (n >> 8) as u8;
        out[out_idx + 2] = n as u8;

        out_idx += 3;
        i += 4;
    }

    let rem = len - i;
    if rem == 2 {
        if out_idx + 1 > out.len() {
            return Err(());
        }
        let b0 = decode_b64_char(src[i])? as u32;
        let b1 = decode_b64_char(src[i + 1])? as u32;
        let n = (b0 << 18) | (b1 << 12);
        out[out_idx] = (n >> 16) as u8;
        out_idx += 1;
    } else if rem == 3 {
        if out_idx + 2 > out.len() {
            return Err(());
        }
        let b0 = decode_b64_char(src[i])? as u32;
        let b1 = decode_b64_char(src[i + 1])? as u32;
        let b2 = decode_b64_char(src[i + 2])? as u32;
        let n = (b0 << 18) | (b1 << 12) | (b2 << 6);
        out[out_idx] = (n >> 16) as u8;
        out[out_idx + 1] = (n >> 8) as u8;
        out_idx += 2;
    }

    Ok(out_idx)
}

pub enum AuthError {
    MissingBearerToken,
    InvalidOrExpiredToken,
    InvalidTokenPayload,
}

pub struct Claims {
    pub user_id: i64,
    pub username: String,
}

pub fn verify_jwt_spec(auth_header: Option<&str>, secret: &[u8]) -> Result<Claims, AuthError> {
    let header = auth_header.ok_or(AuthError::MissingBearerToken)?;
    if !header.starts_with("Bearer ") {
        return Err(AuthError::MissingBearerToken);
    }
    let token = header[7..].trim();
    if token.is_empty() {
        return Err(AuthError::MissingBearerToken);
    }
    let token_bytes = token.as_bytes();

    let dot1 = memchr::memchr(b'.', token_bytes).ok_or(AuthError::InvalidOrExpiredToken)?;
    let dot2 = memchr::memchr(b'.', &token_bytes[dot1 + 1..])
        .map(|idx| dot1 + 1 + idx)
        .ok_or(AuthError::InvalidOrExpiredToken)?;

    let header_b64 = &token_bytes[..dot1];
    let payload_b64 = &token_bytes[dot1 + 1..dot2];
    let token_sig = &token_bytes[dot2 + 1..];

    // Decode header to reject alg=none and verify bounds
    let mut header_buf = [0u8; 128];
    let h_len = base64_url_decode(header_b64, &mut header_buf)
        .map_err(|_| AuthError::InvalidOrExpiredToken)?;
    if let Ok(hdr_val) = serde_json::from_slice::<serde_json::Value>(&header_buf[..h_len]) {
        if hdr_val.get("alg").and_then(|a| a.as_str()) != Some("HS256") {
            return Err(AuthError::InvalidOrExpiredToken);
        }
    } else {
        return Err(AuthError::InvalidOrExpiredToken);
    }

    if token_sig.len() != 43 {
        return Err(AuthError::InvalidOrExpiredToken);
    }

    // Verify HMAC-SHA256
    let signing_input = &token_bytes[..dot2];
    let mut mac = Hmac::<Sha256>::new_from_slice(secret).map_err(|_| AuthError::InvalidOrExpiredToken)?;
    mac.update(signing_input);
    let hmac_res = mac.finalize().into_bytes();

    let mut expected_sig = [0u8; 43];
    let mut raw_digest = [0u8; 32];
    raw_digest.copy_from_slice(&hmac_res);
    encode_base64_url_32(&raw_digest, &mut expected_sig);

    let mut diff = 0u8;
    for i in 0..43 {
        diff |= expected_sig[i] ^ token_sig[i];
    }
    if diff != 0 {
        return Err(AuthError::InvalidOrExpiredToken);
    }

    // Decode and parse payload with bounds protection
    let mut payload_buf = [0u8; 512];
    let p_len = base64_url_decode(payload_b64, &mut payload_buf)
        .map_err(|_| AuthError::InvalidOrExpiredToken)?;
    let payload: serde_json::Value = serde_json::from_slice(&payload_buf[..p_len])
        .map_err(|_| AuthError::InvalidOrExpiredToken)?;

    // Check expiration: exp is mandatory; missing exp must return 401
    let exp = payload
        .get("exp")
        .and_then(|e| e.as_i64())
        .ok_or(AuthError::InvalidOrExpiredToken)?;

    let now = Utc::now().timestamp();
    if exp < now {
        return Err(AuthError::InvalidOrExpiredToken);
    }

    // Check sub (must be an integer, or numeric string)
    let user_id = match payload.get("sub") {
        Some(serde_json::Value::Number(n)) => n.as_i64().ok_or(AuthError::InvalidTokenPayload)?,
        Some(serde_json::Value::String(s)) => {
            s.parse::<i64>().map_err(|_| AuthError::InvalidTokenPayload)?
        }
        _ => return Err(AuthError::InvalidTokenPayload),
    };

    // Check username (must be present and non-empty string)
    let username = match payload.get("username").and_then(|u| u.as_str()) {
        Some(u) if !u.is_empty() => u.to_string(),
        _ => return Err(AuthError::InvalidTokenPayload),
    };

    Ok(Claims { user_id, username })
}
