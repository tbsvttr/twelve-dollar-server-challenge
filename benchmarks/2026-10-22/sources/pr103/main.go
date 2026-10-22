package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"hash"
	"io"
	"log"
	"net"
	"net/http"
	_ "net/http/pprof"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/mattn/go-sqlite3"

	"github.com/gin-gonic/gin"
)

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func init() {
	// temp_store and mmap_size have no DSN key in mattn/go-sqlite3, so set them per connection.
	sql.Register("sqlite3_feed", &sqlite3.SQLiteDriver{
		ConnectHook: func(conn *sqlite3.SQLiteConn) error {
			if _, err := conn.Exec("PRAGMA temp_store = MEMORY", nil); err != nil {
				return err
			}
			_, err := conn.Exec("PRAGMA mmap_size = 268435456", nil)
			return err
		},
	})
}

func connect(path string) *sql.DB {
	dsn := "file:" + path + "?_journal_mode=WAL&_synchronous=NORMAL&_busy_timeout=5000&_cache_size=-65536"
	db, err := sql.Open("sqlite3_feed", dsn)
	if err != nil {
		log.Fatal(err)
	}
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(4)
	return db
}

var errBody = func(msg string) gin.H { return gin.H{"error": msg} }

func parsePostID(s string) (int64, bool) {
	id, err := strconv.ParseInt(s, 10, 64)
	if err != nil || id <= 0 {
		return 0, false
	}
	return id, true
}

func main() {
	gin.SetMode(gin.ReleaseMode)

	if os.Getenv("PPROF") == "1" {
		go func() { log.Println(http.ListenAndServe("127.0.0.1:6060", nil)) }()
	}

	secret := []byte(envOr("JWT_SECRET", "twelve-dollar-challenge"))
	db := connect(envOr("SQLITE_PATH", "seed/feed.db"))
	defer db.Close()

	postQuery := `SELECT p.id, p.body, p.created_at, u.username,
		(SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
		FROM posts p JOIN users u ON u.id = p.user_id`

	feedStmt, err := db.Prepare(postQuery + ` ORDER BY p.created_at DESC, p.id DESC LIMIT 20`)
	if err != nil {
		log.Fatal(err)
	}
	postStmt, err := db.Prepare(postQuery + ` WHERE p.id = ?`)
	if err != nil {
		log.Fatal(err)
	}
	postExistsStmt, err := db.Prepare(`SELECT 1 FROM posts WHERE id = ?`)
	if err != nil {
		log.Fatal(err)
	}
	insertPostStmt, err := db.Prepare(`INSERT INTO posts (user_id, body) VALUES (?, ?) RETURNING id, created_at`)
	if err != nil {
		log.Fatal(err)
	}
	insertLikeStmt, err := db.Prepare(`INSERT INTO likes (user_id, post_id) SELECT ?, ? WHERE EXISTS (SELECT 1 FROM posts WHERE id = ?) ON CONFLICT (user_id, post_id) DO NOTHING`)
	if err != nil {
		log.Fatal(err)
	}

	started := time.Now()

	router := gin.New()
	router.SetTrustedProxies(nil)
	router.Use(func(c *gin.Context) {
		defer func() {
			if recover() != nil {
				c.AbortWithStatusJSON(http.StatusInternalServerError, errBody("internal server error"))
			}
		}()
		c.Next()
	})
	router.NoRoute(func(c *gin.Context) {
		c.JSON(http.StatusNotFound, errBody("not found"))
	})

	router.GET("/health", func(c *gin.Context) {
		var one int
		if err := db.QueryRow("SELECT 1").Scan(&one); err != nil {
			c.JSON(http.StatusServiceUnavailable, healthDegraded{
				Status: "degraded", DB: "unreachable", Error: err.Error(),
			})
			return
		}
		c.JSON(http.StatusOK, healthOK{
			Status: "ok", DB: "ok", UptimeS: int64(time.Since(started).Seconds()),
		})
	})

	router.GET("/feed", func(c *gin.Context) {
		rows, err := feedStmt.Query()
		if err != nil {
			c.JSON(http.StatusInternalServerError, errBody("internal server error"))
			return
		}
		defer rows.Close()

		posts := make([]Post, 0, 20)
		for rows.Next() {
			var p Post
			if err := rows.Scan(&p.ID, &p.Body, &p.CreatedAt, &p.Author, &p.LikeCount); err != nil {
				c.JSON(http.StatusInternalServerError, errBody("internal server error"))
				return
			}
			posts = append(posts, p)
		}
		if err := rows.Err(); err != nil {
			c.JSON(http.StatusInternalServerError, errBody("internal server error"))
			return
		}
		c.JSON(http.StatusOK, feedEnvelope{Posts: posts})
	})

	router.GET("/posts/:id", func(c *gin.Context) {
		id, ok := parsePostID(c.Param("id"))
		if !ok {
			c.JSON(http.StatusBadRequest, errBody("invalid post id"))
			return
		}
		var p Post
		err := postStmt.QueryRow(id).Scan(&p.ID, &p.Body, &p.CreatedAt, &p.Author, &p.LikeCount)
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusNotFound, errBody("post not found"))
			return
		}
		if err != nil {
			c.JSON(http.StatusInternalServerError, errBody("internal server error"))
			return
		}
		c.JSON(http.StatusOK, postEnvelope{Post: p})
	})

	authed := router.Group("/", Auth(secret))

	authed.POST("/posts", func(c *gin.Context) {
		var in struct {
			Body json.RawMessage `json:"body"`
		}
		if err := c.ShouldBindJSON(&in); err != nil {
			c.JSON(http.StatusBadRequest, errBody("malformed JSON body"))
			return
		}
		var raw string
		if len(in.Body) == 0 || in.Body[0] != '"' || json.Unmarshal(in.Body, &raw) != nil {
			c.JSON(http.StatusBadRequest, errBody("body is required"))
			return
		}
		body := strings.TrimSpace(raw)
		if body == "" {
			c.JSON(http.StatusBadRequest, errBody("body is required"))
			return
		}
		if utf8.RuneCountInString(body) > 500 {
			c.JSON(http.StatusBadRequest, errBody("body must be at most 500 characters"))
			return
		}

		var p Post
		err := insertPostStmt.QueryRow(c.GetInt64("uid"), body).Scan(&p.ID, &p.CreatedAt)
		if err != nil {
			c.JSON(http.StatusInternalServerError, errBody("internal server error"))
			return
		}
		p.Body = body
		p.Author = c.GetString("username")
		p.LikeCount = 0
		c.JSON(http.StatusCreated, postEnvelope{Post: p})
	})

	authed.POST("/posts/:id/like", func(c *gin.Context) {
		id, ok := parsePostID(c.Param("id"))
		if !ok {
			c.JSON(http.StatusBadRequest, errBody("invalid post id"))
			return
		}

		res, err := insertLikeStmt.Exec(c.GetInt64("uid"), id, id)
		if err != nil {
			c.JSON(http.StatusInternalServerError, errBody("internal server error"))
			return
		}
		if n, _ := res.RowsAffected(); n == 1 {
			c.JSON(http.StatusCreated, likeResponse{Liked: true, AlreadyLiked: false, PostID: id})
			return
		}

		var one int
		err = postExistsStmt.QueryRow(id).Scan(&one)
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusNotFound, errBody("post not found"))
			return
		}
		if err != nil {
			c.JSON(http.StatusInternalServerError, errBody("internal server error"))
			return
		}
		c.JSON(http.StatusOK, likeResponse{Liked: true, AlreadyLiked: true, PostID: id})
	})

	addr := net.JoinHostPort(envOr("HOST", "127.0.0.1"), envOr("PORT", "3000"))
	log.Printf("listening on %s", addr)
	if err := router.Run(addr); err != nil {
		log.Fatal(err)
	}
}

// base64url of {"alg":"HS256","typ":"JWT"}
const hdrHS256 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

func deny(c *gin.Context, body []byte) {
	c.Abort()
	c.Data(http.StatusUnauthorized, "application/json; charset=utf-8", body)
}

var (
	msgMissing = []byte(`{"error":"missing bearer token"}`)
	msgInvalid = []byte(`{"error":"invalid or expired token"}`)
	msgPayload = []byte(`{"error":"invalid token payload"}`)
)

type claims struct {
	Sub      json.RawMessage `json:"sub"`
	Username json.RawMessage `json:"username"`
	Exp      float64         `json:"exp"`
}

// verify checks structure, signature, alg and exp. Cheapest checks first,
// signature before any JSON work so garbage is rejected quickly.
func verify(pool *sync.Pool, tok string) (claims, bool) {
	var cl claims

	i := strings.IndexByte(tok, '.')
	j := strings.LastIndexByte(tok, '.')
	if i <= 0 || j <= i+1 || j == len(tok)-1 {
		return cl, false
	}
	if strings.IndexByte(tok[i+1:j], '.') >= 0 { // more than 3 parts
		return cl, false
	}

	sig, err := base64.RawURLEncoding.DecodeString(tok[j+1:])
	if err != nil || len(sig) != sha256.Size {
		return cl, false
	}

	m := pool.Get().(hash.Hash)
	m.Reset()
	io.WriteString(m, tok[:j])
	var sum [sha256.Size]byte
	want := m.Sum(sum[:0])
	pool.Put(m)

	if !hmac.Equal(sig, want) { // constant-time
		return cl, false
	}

	// pin alg (also blocks alg=none, though the signature check already would)
	if tok[:i] != hdrHS256 {
		hb, err := base64.RawURLEncoding.DecodeString(tok[:i])
		if err != nil {
			return cl, false
		}
		var h struct {
			Alg string `json:"alg"`
		}
		if json.Unmarshal(hb, &h) != nil || h.Alg != "HS256" {
			return cl, false
		}
	}

	pb, err := base64.RawURLEncoding.DecodeString(tok[i+1 : j])
	if err != nil || json.Unmarshal(pb, &cl) != nil {
		return cl, false
	}
	if cl.Exp <= float64(time.Now().Unix()) { // missing exp counts as expired
		return cl, false
	}
	return cl, true
}

// parseSub requires sub to be a positive integer, given as a JSON string ("42")
// or a bare number (42).
func parseSub(raw json.RawMessage) (int64, bool) {
	if len(raw) == 0 {
		return 0, false
	}
	s := string(raw)
	if raw[0] == '"' {
		if json.Unmarshal(raw, &s) != nil {
			return 0, false
		}
	}
	id, err := strconv.ParseInt(s, 10, 64)
	return id, err == nil && id > 0
}

// parseUsername requires username to be a JSON string.
func parseUsername(raw json.RawMessage) (string, bool) {
	if len(raw) == 0 || raw[0] != '"' {
		return "", false
	}
	var s string
	if json.Unmarshal(raw, &s) != nil {
		return "", false
	}
	return s, true
}

func Auth(secret []byte) gin.HandlerFunc {
	pool := &sync.Pool{New: func() any { return hmac.New(sha256.New, secret) }}

	return func(c *gin.Context) {
		h := c.GetHeader("Authorization")
		if !strings.HasPrefix(h, "Bearer ") {
			deny(c, msgMissing)
			return
		}

		cl, ok := verify(pool, h[7:])
		if !ok {
			deny(c, msgInvalid)
			return
		}

		uid, okSub := parseSub(cl.Sub)
		name, okName := parseUsername(cl.Username)
		if !okSub || !okName {
			deny(c, msgPayload)
			return
		}

		c.Set("uid", uid)
		c.Set("username", name)
		c.Next()
	}
}
