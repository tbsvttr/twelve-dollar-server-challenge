use serde::Serialize;

#[derive(Serialize, Clone)]
pub struct Post {
    pub id: i64,
    pub body: String,
    pub created_at: String,
    pub author: String,
    pub like_count: i64,
}

#[derive(Serialize)]
pub struct SinglePostResp {
    pub post: Post,
}

#[derive(Serialize)]
pub struct FeedResp {
    pub posts: Vec<Post>,
}

#[derive(Serialize)]
pub struct LikeResp {
    pub liked: bool,
    pub already_liked: bool,
    pub post_id: i64,
}

#[derive(Serialize)]
pub struct HealthResp {
    pub status: &'static str,
    pub db: &'static str,
    pub uptime_s: u64,
}
