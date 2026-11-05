use std::ffi::{CString, c_char, c_int};
use std::ptr;

pub const FEED_MAX_ROWS: usize = 20;
pub const TEXT_POOL_CAP: usize = 24576;

#[repr(C)]
pub struct TvccDbEngine {
    _opaque: [u8; 0],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TvccPostRow {
    pub id: i64,
    pub body_off: u32,
    pub body_len: u32,
    pub created_off: u32,
    pub created_len: u32,
    pub author_off: u32,
    pub author_len: u32,
    pub like_count: i64,
}

#[repr(C)]
pub struct TvccFeedResult {
    pub count: u32,
    pub text_used: u32,
    pub rows: [TvccPostRow; FEED_MAX_ROWS],
    pub text: [u8; TEXT_POOL_CAP],
}

impl Default for TvccFeedResult {
    fn default() -> Self {
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
pub struct TvccSinglePostResult {
    pub id: i64,
    pub body_len: u32,
    pub created_len: u32,
    pub author_len: u32,
    pub like_count: i64,
    pub body: [u8; 2048],
    pub created_at: [u8; 64],
    pub author: [u8; 128],
}

impl Default for TvccSinglePostResult {
    fn default() -> Self {
        unsafe { std::mem::zeroed() }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LikeStatus {
    Created,
    AlreadyLiked,
    NotFound,
}

unsafe extern "C" {
    fn tvcc_db_open(path: *const c_char, out_eng: *mut *mut TvccDbEngine) -> c_int;
    fn tvcc_db_close(eng: *mut TvccDbEngine);
    fn tvcc_db_health(eng: *mut TvccDbEngine) -> c_int;
    fn tvcc_db_feed(eng: *mut TvccDbEngine, out: *mut TvccFeedResult) -> c_int;
    fn tvcc_db_get_post(eng: *mut TvccDbEngine, post_id: i64, out: *mut TvccSinglePostResult) -> c_int;
    fn tvcc_db_insert_post(
        eng: *mut TvccDbEngine,
        user_id: i64,
        body: *const u8,
        body_len: usize,
        created_at: *const u8,
        created_len: usize,
        out_post_id: *mut i64,
    ) -> c_int;
    fn tvcc_db_like_post(eng: *mut TvccDbEngine, post_id: i64, user_id: i64) -> c_int;
    fn tvcc_db_commit_batch(eng: *mut TvccDbEngine) -> c_int;
    fn tvcc_db_end_read_batch(eng: *mut TvccDbEngine);
    fn tvcc_db_poll_checkpoint(eng: *mut TvccDbEngine, has_inflight_reads: c_int) -> c_int;
}

pub struct Db {
    raw: *mut TvccDbEngine,
}

impl Db {
    pub fn open(path: &str) -> Result<Self, ()> {
        let c_path = CString::new(path).map_err(|_| ())?;
        let mut raw = ptr::null_mut();
        let rc = unsafe { tvcc_db_open(c_path.as_ptr(), &mut raw) };
        if rc == 0 && !raw.is_null() {
            Ok(Self { raw })
        } else {
            Err(())
        }
    }

    #[inline]
    pub fn health(&mut self) -> bool {
        unsafe { tvcc_db_health(self.raw) == 0 }
    }

    #[inline]
    pub fn feed(&mut self, out: &mut TvccFeedResult) -> Result<(), ()> {
        let rc = unsafe { tvcc_db_feed(self.raw, out) };
        if rc == 0 { Ok(()) } else { Err(()) }
    }

    #[inline]
    pub fn get_post(&mut self, post_id: i64, out: &mut TvccSinglePostResult) -> Result<bool, ()> {
        let rc = unsafe { tvcc_db_get_post(self.raw, post_id, out) };
        match rc {
            1 => Ok(true),
            0 => Ok(false),
            _ => Err(()),
        }
    }

    #[inline]
    pub fn insert_post(
        &mut self,
        user_id: i64,
        body: &[u8],
        created_at: &[u8],
    ) -> Result<i64, ()> {
        let mut post_id = 0i64;
        let rc = unsafe {
            tvcc_db_insert_post(
                self.raw,
                user_id,
                body.as_ptr(),
                body.len(),
                created_at.as_ptr(),
                created_at.len(),
                &mut post_id,
            )
        };
        if rc == 0 { Ok(post_id) } else { Err(()) }
    }

    #[inline]
    pub fn like_post(&mut self, post_id: i64, user_id: i64) -> Result<LikeStatus, ()> {
        let rc = unsafe { tvcc_db_like_post(self.raw, post_id, user_id) };
        match rc {
            1 => Ok(LikeStatus::Created),
            0 => Ok(LikeStatus::AlreadyLiked),
            -2 => Ok(LikeStatus::NotFound),
            _ => Err(()),
        }
    }

    #[allow(dead_code)]
    #[inline]
    pub fn commit_batch(&mut self) -> bool {
        unsafe { tvcc_db_commit_batch(self.raw) == 0 }
    }

    #[allow(dead_code)]
    #[inline]
    pub fn end_read_batch(&mut self) {
        unsafe { tvcc_db_end_read_batch(self.raw) };
    }

    #[inline]
    pub fn poll_checkpoint(&mut self, has_inflight_reads: bool) -> bool {
        unsafe { tvcc_db_poll_checkpoint(self.raw, i32::from(has_inflight_reads)) != 0 }
    }
}

impl Drop for Db {
    fn drop(&mut self) {
        if !self.raw.is_null() {
            unsafe { tvcc_db_close(self.raw) };
            self.raw = ptr::null_mut();
        }
    }
}

