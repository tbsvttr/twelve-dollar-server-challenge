package main

type Post struct {
	ID        int64  `json:"id"`
	Body      string `json:"body"`
	CreatedAt string `json:"created_at"`
	Author    string `json:"author"`
	LikeCount int64  `json:"like_count"`
}

type postEnvelope struct {
	Post Post `json:"post"`
}

type feedEnvelope struct {
	Posts []Post `json:"posts"`
}

type healthOK struct {
	Status  string `json:"status"`
	DB      string `json:"db"`
	UptimeS int64  `json:"uptime_s"`
}

type healthDegraded struct {
	Status string `json:"status"`
	DB     string `json:"db"`
	Error  string `json:"error"`
}

type likeResponse struct {
	Liked        bool  `json:"liked"`
	AlreadyLiked bool  `json:"already_liked"`
	PostID       int64 `json:"post_id"`
}
